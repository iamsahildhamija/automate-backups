#!/usr/bin/env bash
# Automate Backups Scheduling & Transferring — https://github.com/iamsahildhamija/automate-backups
# Configuration and state are JSON, never executable shell code.
set -Eeuo pipefail
umask 077
VERSION="1.0.0"
SELF="${BASH_SOURCE[0]}"
WORK="" PARTIAL="" RECORD="" LOCKED=0 HTTP_CODE=000 HTTP_BODY="" HTTP_HEADERS=""
RUN_OK=0 CANCEL_SESSION="" CALLBACK_PID="" INSTALL_PENDING=0
DEST_FILE="" DEST='{}' CONFIG='{}' SERVER_ID="" RUN_ID=""

init_paths() {
    PREFIX="${1:-}"
    ETC="$PREFIX/etc/automate-backups"
    STATE="$PREFIX/var/lib/automate-backups"
    LOGDIR="$PREFIX/var/log/automate-backups"
    DEFAULT_BACKUPS="$PREFIX/var/backups/automate-backups"
    BIN="$PREFIX/usr/local/sbin/automate-backups"
    UNITDIR="$PREFIX/etc/systemd/system"
    CONF="$ETC/config.conf"
}
init_paths
have() { command -v "$1" >/dev/null 2>&1; }
now() { date -u +%FT%TZ; }
fail() { log ERROR "$*"; return 1; }
log() {
    local level="$1"; shift
    printf '[%s] %s\n' "$level" "$*" >&2
    if [[ -d $LOGDIR ]]; then printf '%s [%s] %s\n' "$(now)" "$level" "$*" >> "$LOGDIR/automate-backups.log"; fi
}
root_required() { (( EUID == 0 )) || fail 'Run this command as root (sudo bash setup.sh, or sudo automate-backups).'; }
atom() {
    local target="$1" temp
    temp=$(mktemp "${target}.new.XXXXXX") || return
    if cat > "$temp" && chmod 600 "$temp"; then mv -f -- "$temp" "$target"; else rm -f -- "$temp"; return 1; fi
}
json_write() { local target="$1"; jq -e . | atom "$target"; }
secret_ok() {
    local f="$1" mode owner
    [[ -f $f && ! -L $f ]] || return 1
    read -r owner mode < <(stat -c '%u %a' -- "$f")
    [[ $owner == "$EUID" ]] && (( (8#$mode & 077) == 0 ))
}
secure_dir() {
    local d="$1"
    [[ ! -L $d ]] || fail "Refusing symlink directory: $d" || return
    mkdir -p -- "$d" || return
    [[ $(stat -c %u -- "$d") == "$EUID" ]] || fail "Directory is not owned by root: $d" || return
    chmod 700 -- "$d"
}
layout() {
    local d
    for d in "$ETC" "$ETC/providers" "$STATE" "$STATE/records" "$STATE/sessions" "$LOGDIR"; do secure_dir "$d" || return; done
    if [[ ! -f $STATE/server-id ]]; then openssl rand -hex 16 | atom "$STATE/server-id"; fi
    SERVER_ID=$(cat "$STATE/server-id")
    [[ $SERVER_ID =~ ^[a-f0-9]{32}$ ]] || fail 'Invalid persistent server ID; refusing to manage backups.'
}
new_work() { [[ -n $WORK ]] || WORK=$(mktemp -d "$STATE/work.XXXXXX"); }
lock() {
    exec 9>"$STATE/operation.lock"
    if ! flock -n 9; then
        log ERROR 'Another Automate Backups operation is already running.'
        [[ ! -f $STATE/active.json ]] || jq '{pid,started,operation}' "$STATE/active.json" >&2
        return 1
    fi
    LOCKED=1
    jq -n --argjson pid "$$" --arg ticks "$(awk '{print $22}' /proc/$$/stat)" --arg start "$(now)" --arg op "${1:-operation}" '{pid:$pid,start_ticks:$ticks,started:$start,operation:$op}' | json_write "$STATE/active.json"
}
state_edit() { local f="$1" filter="$2"; shift 2; jq "$@" "$filter" "$f" | json_write "$f"; }
cleanup() {
    local rc=$?
    trap - EXIT INT TERM HUP
    [[ -z $CALLBACK_PID ]] || kill "$CALLBACK_PID" 2>/dev/null || true
    if [[ -n $CANCEL_SESSION ]] && declare -F s3_abort >/dev/null; then s3_abort >/dev/null 2>&1 || true; fi
    if [[ -n $RECORD && -f $RECORD && $RUN_OK == 0 ]]; then
        state_edit "$RECORD" '.status="FAILED" | .error="Operation failed or interrupted; see log" | .ended=$t' --arg t "$(now)" || true
        log ERROR 'Backup did not complete. Valid local archives and older backups were retained.'
    fi
    if [[ ${CONFIG_PENDING:-0} == 1 ]]; then
        rm -rf -- "$CONFIG_LIVE"; mv -- "$CONFIG_OLD" "$CONFIG_LIVE"
        ETC="$CONFIG_LIVE"; CONF="$ETC/config.conf"; CONFIG=$(cat "$CONF")
        schedule_apply || true
    fi
    if (( INSTALL_PENDING )); then rollback_install || true; fi
    [[ -z $PARTIAL ]] || rm -f -- "$PARTIAL" "${PARTIAL}.sha256"
    [[ -z $WORK ]] || rm -rf -- "$WORK"
    if (( LOCKED )); then rm -f -- "$STATE/active.json"; fi
    exit "$rc"
}
traps() { trap cleanup EXIT; trap 'exit 130' INT; trap 'exit 143' TERM HUP; }
ask() {
    local label="$1" def="${2:-}" secret="${3:-0}" reply
    if ! { : < /dev/tty; } 2>/dev/null; then fail 'Interactive setup requires a terminal; download setup.sh then run it from a terminal.'; return 1; fi
    printf '%s%s: ' "$label" "${def:+ [$def]}" > /dev/tty
    if [[ $secret == 1 ]]; then IFS= read -r -s reply < /dev/tty || return; printf '\n' > /dev/tty
    else IFS= read -r reply < /dev/tty || return; fi
    ANSWER="${reply:-$def}"
    [[ $ANSWER != *$'\n'* && $ANSWER != *$'\r'* ]] || fail 'Multiline input is not accepted.'
}
yes() { ask "$1 (1 Yes / 2 No)" "${2:-2}"; [[ $ANSWER == 1 ]]; }
uint() { [[ $1 =~ ^(0|[1-9][0-9]{0,5})$ ]]; }
json_int() { jq -en --arg v "$1" '$v|tonumber'; }
url_ok() { [[ $1 =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?(/[^[:space:]\"\<\>\#\\]*)?$ && $1 != *'@'* ]]; }
ident() { [[ $1 =~ ^[a-z][a-z0-9_-]{0,39}$ ]]; }
filename_ok() { [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; }
path_ok() {
    local p="$1" resolved
    [[ $p == /* && $p != *$'\n'* && $p != *$'\r'* && $p != *$'\t'* ]] || return 1
    resolved=$(realpath -m -- "$p") || return
    case "$resolved" in /|/proc|/proc/*|/sys|/sys/*|/dev|/dev/*|/run|/run/*) return 1;; esac
    [[ -e $p ]] || return 1
    if [[ $resolved =~ ^/var/lib/docker/volumes/[A-Za-z0-9_.-]+/_data$ ]]; then return 0; fi
    case "$resolved" in /var/lib/mysql|/var/lib/mysql/*|/var/lib/postgresql|/var/lib/postgresql/*|/var/lib/mongodb|/var/lib/mongodb/*|/var/lib/docker|/var/lib/docker/*) return 1;; esac
}
timezone_ok() { [[ $1 =~ ^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)*$ && -f /usr/share/zoneinfo/$1 ]]; }
config_validate() {
    local file="$1" p tz bd canonical_bd reserved
    jq -e '
      type=="object" and .format==1 and (.sources|type=="array" and length>0) and
      all(.sources[]; type=="string") and (.local_keep|type=="number" and floor==. and .>=0 and .<=999999) and
      (.bandwidth_kib|type=="number" and floor==. and .>=0 and .<=999999) and
      (.reserve_mib|type=="number" and floor==. and .>=64) and
      (.schedule.enabled|type=="boolean") and (.schedule.mode|IN("daily","interval","weekly","weekdays","monthly","custom")) and
      (.schedule.time|test("^([01][0-9]|2[0-3]):[0-5][0-9]$")) and
      (.schedule.every|type=="number" and floor==. and .>=1 and .<=365) and
      (.schedule.monthday|type=="number" and floor==. and .>=1 and .<=28) and
      (.schedule.days|type=="array" and length>0) and all(.schedule.days[]; IN(1,2,3,4,5,6,7)) and
      (.schedule.anchor|test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")) and
      (.schedule.calendar|type=="string" and (test("[\\r\\n]")|not)) and
      (.databases|type=="object") and all(.databases[]; type=="object" and (.names|type=="array") and
      all(.names[]; type=="string" and test("^[A-Za-z0-9_][A-Za-z0-9_.-]*$")))
    ' "$file" >/dev/null || fail 'Invalid JSON configuration or invalid retention/schedule values.' || return
    tz=$(jq -r .schedule.timezone "$file"); timezone_ok "$tz" || fail "Unknown timezone: $tz" || return
    bd=$(jq -r .backup_dir "$file")
    [[ $bd == /* && $bd != / && $bd != *$'\n'* && $bd != *$'\t'* && $bd != *$'\r'* ]] || return 1
    case "$(realpath -m "$bd")" in /etc|/etc/*|/usr|/usr/*|/proc*|/sys*|/dev*|/run*|"$STATE"|"$STATE"/*) fail 'Unsafe backup directory'; return 1;; esac
    canonical_bd=$(realpath -m "$bd")
    case "$canonical_bd" in /home|/root|/tmp|/srv|/var|/var/log|/var/lib|/var/www|/usr/local|/usr/local/sbin) fail 'Use a dedicated archive directory, not a shared system directory.'; return 1;; esac
    for reserved in "$ETC" "$PREFIX/etc/automate-backups" "$STATE" "$LOGDIR"; do
        [[ $canonical_bd != "$reserved" && $canonical_bd != "$reserved/"* && $reserved != "$canonical_bd/"* ]] || fail 'Archive directory overlaps application configuration/state/logs.' || return
    done
    date -u -d "$(jq -r .schedule.anchor "$file")" +%F >/dev/null 2>&1 || return
    while IFS= read -r p; do
        path_ok "$p" || fail "Missing or unsafe source: $p" || return
        [[ $(realpath -m "$p") != "$canonical_bd" && $(realpath -m "$p") != "$canonical_bd/"* ]] || fail 'A backup directory cannot be a source.' || return
    done < <(jq -r '.sources[]' "$file")
    local engine
    while IFS= read -r engine; do [[ $engine =~ ^(mysql|postgres|mongo)$ ]] || return 1; done < <(jq -r '.databases|keys[]' "$file")
}
load_config() {
    secret_ok "$CONF" || fail "Missing or insecure configuration: $CONF" || return
    config_validate "$CONF" || return
    CONFIG=$(cat "$CONF")
    BACKUP_DIR=$(realpath -m -- "$(jq -r .backup_dir <<< "$CONFIG")")
    local normalized p
    normalized=$(while IFS= read -r p; do realpath -m -- "$p"; done < <(jq -r '.sources[]' <<< "$CONFIG") | jq -Rsc 'split("\n")[:-1]')
    CONFIG=$(jq --arg b "$BACKUP_DIR" --argjson s "$normalized" '.backup_dir=$b|.sources=$s' <<< "$CONFIG")
    LOCAL_KEEP=$(jq -r .local_keep <<< "$CONFIG")
    BANDWIDTH=$(jq -r .bandwidth_kib <<< "$CONFIG")
    secure_dir "$BACKUP_DIR"
}
package_manager() {
    local x
    for x in apt-get dnf yum zypper apk pacman; do if have "$x"; then printf '%s\n' "$x"; return; fi; done
    printf 'unknown\n'
}
install_packages() {
    local pm; pm=$(package_manager)
    log INFO "Installing required packages with $pm: $*"
    case "$pm" in
        apt-get) apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@";;
        dnf|yum) "$pm" install -y "$@";;
        zypper) zypper --non-interactive install "$@";;
        apk) apk add "$@";;
        pacman) pacman -S --needed --noconfirm "$@";;
        *) fail "Install required packages manually: $*";;
    esac
}
dependencies() {
    local c pkg pm; local -a missing=()
    pm=$(package_manager)
    for c in curl jq tar gzip sha256sum realpath stat du df dd timeout find flock openssl cmp; do
        have "$c" && continue
        case "$c" in sha256sum|realpath|stat|du|df|dd|timeout) pkg=coreutils;; find) pkg=findutils;; cmp) pkg=diffutils;; flock) pkg=util-linux; [[ $pm != apk ]] || pkg=util-linux-misc;; *) pkg="$c";; esac
        [[ " ${missing[*]} " == *" $pkg "* ]] || missing+=("$pkg")
    done
    if ! tar --version 2>/dev/null | head -1 | grep -q 'GNU tar'; then missing+=(tar); fi
    if ! stat --version 2>/dev/null | grep -q 'GNU coreutils'; then missing+=(coreutils); fi
    if ! find --version 2>/dev/null | grep -q 'GNU findutils'; then missing+=(findutils); fi
    [[ ${#missing[@]} == 0 ]] || install_packages "${missing[@]}" || return
    tar --version | head -1 | grep -q 'GNU tar' || fail 'GNU tar is required for portable ACL/xattr handling.' || return
    (( BASH_VERSINFO[0] >= 4 )) || fail 'Bash 4 or newer is required.'
}
rotate_log() {
    local f="$LOGDIR/automate-backups.log" i
    if [[ -f $f ]] && (( $(stat -c %s "$f") > 5242880 )); then
        rm -f "$f.5"
        for i in 4 3 2 1; do [[ ! -f $f.$i ]] || mv "$f.$i" "$f.$((i+1))"; done
        mv "$f" "$f.1"
    fi
}

# Discovery is deliberately bounded to known layouts and configuration trees.
discover() {
    local p f line
    : > "$WORK/discovered.tsv"
    add_source() { [[ -e $2 ]] && path_ok "$2" && printf '%s\t%s\n' "$1" "$(realpath -m "$2")" >> "$WORK/discovered.tsv" || true; }
    shopt -s nullglob
    for p in /var/www/* /srv/www/* /home/*/public_html /home/*/domains/*/public_html /var/www/vhosts/*/httpdocs /www/wwwroot/*; do add_source website "$p"; done
    for p in /etc/nginx /etc/apache2 /etc/httpd /usr/local/lsws/conf /usr/local/apache/conf; do
        [[ -d $p ]] || continue
        while IFS= read -r -d '' f; do
            while IFS= read -r line; do
                # Only literal absolute roots; variables and complex expressions are not guessed.
                line=$(sed -E 's/^[[:space:]]*(DocumentRoot|root|docRoot)[[:space:]]+"?([^";]+)"?;?.*/\2/I' <<< "$line")
                [[ $line == /* && $line != *'$'* ]] && add_source website "$line"
            done < <(grep -Ei '^[[:space:]]*(DocumentRoot|root|docRoot)[[:space:]]+"?/' "$f" 2>/dev/null || true)
        done < <(find "$p" -maxdepth 4 -type f \( -name '*.conf' -o -name '*.vhost' -o -path '*/sites-enabled/*' -o -path '*/sites-available/*' \) -print0 2>/dev/null)
    done
    for p in /var/mail /var/vmail /home/*/mail /home/vmail /usr/local/psa/var/mailnames; do add_source mail "$p"; done
    if have postconf; then
        p=$(postconf -h virtual_mailbox_base 2>/dev/null || true); [[ -z $p ]] || add_source mail "$p"
    fi
    if have doveconf; then
        p=$(doveconf -h mail_location 2>/dev/null || true); p="${p#maildir:}"; p="${p#mbox:}"; p="${p%%:*}"
        [[ $p != *'%'* && $p != *'~'* ]] && add_source mail "$p"
    fi
    for p in /etc/nginx /etc/apache2 /etc/httpd /usr/local/lsws/conf /usr/local/apache/conf /etc/php /etc/php.ini /etc/php.d /etc/php-fpm.conf /etc/php-fpm.d /etc/my.cnf /etc/my.cnf.d /etc/mysql /etc/postgresql /etc/postgresql-common /etc/mongod.conf /etc/mongodb.conf; do add_source config "$p"; done
    for p in /etc/postfix /etc/dovecot /etc/exim /etc/exim4 /etc/exim.conf /etc/opendkim /etc/opendkim.conf /etc/virtual /etc/valiases /etc/vdomainaliases; do add_source mail-config "$p"; done
    for p in /etc/letsencrypt /etc/ssl /etc/pki /etc/fail2ban /etc/firewalld /etc/nftables.conf /etc/nftables /etc/iptables /etc/ufw /etc/ssh/sshd_config /etc/ssh/sshd_config.d /etc/systemd/system /etc/cron.d /etc/cron.daily /etc/cron.hourly /etc/cron.weekly /etc/cron.monthly /etc/crontab /var/spool/cron /etc/crontabs /etc/hostname /etc/hosts /etc/fstab /etc/sysctl.conf /etc/sysctl.d /etc/netplan /etc/network /etc/NetworkManager/system-connections /etc/apt/apt.conf.d /etc/dnf/automatic.conf /etc/yum/yum-cron.conf; do add_source system "$p"; done
    sort -u -k2,2 "$WORK/discovered.tsv" -o "$WORK/discovered.tsv"
    shopt -u nullglob
}
source_wizard() {
    local p group n=0 choice existing; local -a paths=() selected=()
    discover
    printf '\nDetected sources (missing or ambiguous locations are not guessed):\n'
    while IFS=$'\t' read -r group p; do paths+=("$p"); n=$((n+1)); printf '%3d. %-12s %s\n' "$n" "$group" "$p"; done < "$WORK/discovered.tsv"
    if (( ${#paths[@]} )); then
        ask '1 Include detected sources / 2 Select individually / 3 Keep current sources' '1'; choice="$ANSWER"
        case "$choice" in
            1) selected=("${paths[@]}");;
            2) for p in "${paths[@]}"; do if yes "Include $p?" 1; then selected+=("$p"); fi; done;;
            3) while IFS= read -r p; do selected+=("$p"); done < <(jq -r '.sources[]?' <<< "$CONFIG");;
            *) fail 'Invalid source selection'; return 1;;
        esac
    fi
    log INFO 'If mailboxes/authentication maps are missing, add their exact paths. Unix mailbox accounts may require a separately secured account mapping; /etc/shadow is not selected automatically.'
    while :; do
        ask 'Additional absolute source path (blank to finish)' ''; p="$ANSWER"; [[ -n $p ]] || break
        path_ok "$p" || { log WARN 'Path is missing, virtual, a raw database directory, or otherwise unsafe.'; continue; }
        case "$p" in /home|/var|/etc|/srv) yes "Broad path $p may contain unrelated secrets and large amounts of data. Include it?" 2 || continue;; esac
        selected+=("$(realpath -m "$p")")
    done
    if have docker; then
        local -a docker_ids=()
        mapfile -t docker_ids < <(docker ps -aq 2>/dev/null || true)
        docker inspect "${docker_ids[@]}" 2>/dev/null | jq -r '.[] | select((.Config.Image|test("(^|/)(mysql|mariadb|postgres|mongo)(:|@|$)")) or any(.Mounts[]?; .Destination|test("^/(var/lib/(mysql|postgresql|mongodb)|data/db)(/|$)"))) | .Mounts[]? | .Source' > "$WORK/docker-db-paths" || : > "$WORK/docker-db-paths"
        printf '\nDocker detected. Live database volumes must use native database dumps. Quiesce other application volumes before backup.\n'
        ask 'Docker: 1 Skip / 2 Select named volumes / 3 Add bind mount' 1
        case "$ANSWER" in
            2) while IFS= read -r p; do
                    [[ -n $p ]] || continue
                    if yes "Include named volume $p (only after arranging consistent application data)?" 2; then
                        existing=$(docker volume inspect --format '{{.Mountpoint}}' "$p")
                        [[ $existing == /var/lib/docker/volumes/*/_data ]] || fail 'Unexpected Docker volume path' || return
                        if grep -Fxq "$existing" "$WORK/docker-db-paths"; then
                            log WARN 'Known database container volume refused. Configure native dumps or a separate consistency-safe backup.'
                        else selected+=("$existing"); fi
                    fi
               done < <(docker volume ls --format '{{.Name}}' 2>/dev/null || true);;
            3) ask 'Absolute bind mount path'; path_ok "$ANSWER" || return
               if grep -Fxq "$ANSWER" "$WORK/docker-db-paths"; then fail 'Known live database bind mount refused.'; return 1; fi
               selected+=("$ANSWER");;
            1) :;; *) return 1;;
        esac
    fi
    (( ${#selected[@]} > 0 )) || fail 'Select at least one source.' || return
    # Remove nested duplicate sources; tar would otherwise archive their contents twice.
    printf '%s\n' "${selected[@]}" | sort -u | jq -Rsc 'split("\n")[:-1] | sort_by(length) | reduce .[] as $p ([]; if any(.[]; . as $q | $p|startswith($q+"/")) then . else .+[$p] end)' > "$WORK/sources.json"
    CONFIG=$(jq --slurpfile s "$WORK/sources.json" '.sources=$s[0]' <<< "$CONFIG")
}
mysql_cmd() { "${MYSQL_CLIENT:-$(command -v mariadb || command -v mysql)}" --defaults-extra-file="$ETC/mysql.cnf" --batch --skip-column-names "$@"; }
pg_cmd() {
    local osuser; osuser=$(jq -r '.databases.postgres.os_user // ""' <<< "$CONFIG")
    if [[ -n $osuser ]]; then runuser -u "$osuser" -- "$@"; else PGPASSFILE="$ETC/postgres.pass" "$@"; fi
}
ini_escape() { local v="$1"; v=${v//\\/\\\\}; v=${v//\"/\\\"}; printf '%s' "$v"; }
select_databases() {
    local engine="$1" name choice; local -a names=()
    printf '\n%s databases:\n' "$engine"; cat "$WORK/db-list"
    ask '1 All listed databases / 2 Choose individually / 3 Skip' 1; choice="$ANSWER"
    [[ $choice != 3 ]] || { CONFIG=$(jq --arg e "$engine" 'del(.databases[$e])' <<< "$CONFIG"); return; }
    [[ $choice == 1 || $choice == 2 ]] || return 1
    while IFS= read -r name; do
        [[ $name =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]*$ ]] || { log WARN "Database name requires a manual native backup: $name"; continue; }
        if [[ $choice == 1 ]] || yes "Include $name?" 1; then names+=("$name"); fi
    done < "$WORK/db-list"
    if (( ${#names[@]} )); then
        printf '%s\n' "${names[@]}" | jq -Rsc 'split("\n")[:-1]' > "$WORK/db-names"
        CONFIG=$(jq --arg e "$engine" --slurpfile n "$WORK/db-names" '.databases[$e].names=$n[0]' <<< "$CONFIG")
    else CONFIG=$(jq --arg e "$engine" 'del(.databases[$e])' <<< "$CONFIG"); fi
}
database_wizard() {
    local user password host port uri
    if jq -e '.databases|length>0' <<< "$CONFIG" >/dev/null; then
        if ! yes 'Reconfigure database selection (2 keeps existing database settings)?' 2; then return 0; fi
        CONFIG=$(jq '.databases={}' <<< "$CONFIG")
    fi
    if have mariadb || have mysql; then
        if yes 'Configure MariaDB/MySQL logical dumps?' 1; then
            ask 'Database host (localhost uses local socket)' localhost; host="$ANSWER"
            ask 'Database user' root; user="$ANSWER"
            ask 'Database password (blank for socket authentication)' '' 1; password="$ANSWER"
            printf '[client]\nhost="%s"\nuser="%s"\npassword="%s"\n' "$(ini_escape "$host")" "$(ini_escape "$user")" "$(ini_escape "$password")" | atom "$ETC/mysql.cnf"
            mysql_cmd -e "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME NOT IN ('information_schema','performance_schema','mysql','sys') ORDER BY SCHEMA_NAME" > "$WORK/db-list" || fail 'MySQL login failed.' || return
            select_databases mysql || return
            if jq -e '.databases.mysql' <<< "$CONFIG" >/dev/null; then
                if yes 'Also export database account definitions/grants (includes password hashes for all non-system accounts; review during restore)?' 1; then
                    CONFIG=$(jq '.databases.mysql.accounts=true' <<< "$CONFIG")
                else CONFIG=$(jq '.databases.mysql.accounts=false' <<< "$CONFIG"); fi
            fi
        fi
    fi
    if have psql; then
        if yes 'Configure PostgreSQL logical dumps?' 1; then
            ask 'Local PostgreSQL OS user (use - for password-based libpq configuration)' postgres; user="$ANSWER"
            if [[ $user != - ]]; then
                [[ $user =~ ^[a-z_][a-z0-9_-]*$ ]] && id "$user" >/dev/null && have runuser || fail 'Invalid OS user or runuser missing.' || return
                CONFIG=$(jq --arg u "$user" '.databases.postgres.os_user=$u' <<< "$CONFIG")
            else
                ask 'Host' localhost; host="$ANSWER"; ask 'Port' 5432; port="$ANSWER"; uint "$port" && ((port>0 && port<65536)) || return
                ask 'User' postgres; user="$ANSWER"; ask 'Password' '' 1; password="$ANSWER"
                # .pgpass escaping; libpq connection fields remain non-secret.
                password=${password//\\/\\\\}; password=${password//:/\\:}
                [[ $host != *:* && $user != *:* ]] || fail 'Use a DNS hostname without colons.' || return
                printf '%s:%s:*:%s:%s\n' "$host" "$port" "$user" "$password" | atom "$ETC/postgres.pass"
                CONFIG=$(jq --arg h "$host" --arg p "$port" --arg u "$user" '.databases.postgres={os_user:"",host:$h,port:$p,user:$u,names:[]}' <<< "$CONFIG")
            fi
            pg_options
            pg_cmd psql "${PG_ARGS[@]}" -d postgres -Atc "SELECT datname FROM pg_database WHERE NOT datistemplate AND datname <> 'postgres' ORDER BY datname" > "$WORK/db-list" || return
            select_databases postgres || return
        fi
    fi
    if have mongodump; then
        if yes 'Configure MongoDB native dumps?' 1; then
            mongodump --help | grep -q -- '--config' || fail 'MongoDB Database Tools with --config support required.' || return
            ask 'MongoDB connection URI (stored privately; never logged)' 'mongodb://localhost:27017' 1; uri="$ANSWER"
            printf 'uri: %s\n' "$(printf '%s' "$uri" | jq -Rs .)" | atom "$ETC/mongo.yml"
            if have mongosh; then
                printf 'const c = new Mongo(%s); print(c.getDB("admin").runCommand({listDatabases:1,nameOnly:true}).databases.filter(x => !["local","admin","config"].includes(x.name)).map(x=>x.name).join("\n"));\n' "$(printf '%s' "$uri" | jq -Rs .)" > "$WORK/mongo-discover.js"
                mongosh --nodb --quiet --file "$WORK/mongo-discover.js" > "$WORK/db-list" || return
                rm -f "$WORK/mongo-discover.js"
            else
                ask 'Database names separated by spaces'; printf '%s\n' "$ANSWER" | tr ' ' '\n' > "$WORK/db-list"
            fi
            select_databases mongo || return
        fi
    fi
}
pg_options() {
    PG_ARGS=()
    if [[ $(jq -r '.databases.postgres.os_user // ""' <<< "$CONFIG") == '' ]]; then
        PG_ARGS=(-h "$(jq -r .databases.postgres.host <<< "$CONFIG")" -p "$(jq -r .databases.postgres.port <<< "$CONFIG")" -U "$(jq -r .databases.postgres.user <<< "$CONFIG")")
    fi
}
dump_databases() {
    local db dump account stmt dump_help
    mkdir -p "$WORK/payload/database"
    if jq -e '.databases.mysql.names|length>0' <<< "$CONFIG" >/dev/null; then
        dump=$(command -v mariadb-dump || command -v mysqldump) || fail 'Install the native MySQL/MariaDB dump client.' || return
        secret_ok "$ETC/mysql.cnf" || return
        mkdir -p "$WORK/payload/database/mysql"
        local -a opts=(--single-transaction --quick --routines --events --triggers --hex-blob --default-character-set=utf8mb4)
        dump_help=$("$dump" --help)
        [[ $dump_help != *no-tablespaces* ]] || opts+=(--no-tablespaces)
        [[ $dump_help != *set-gtid-purged* ]] || opts+=(--set-gtid-purged=OFF)
        while IFS= read -r db; do
            "$dump" --defaults-extra-file="$ETC/mysql.cnf" "${opts[@]}" --databases "$db" > "$WORK/payload/database/mysql/$db.sql" || fail "MySQL dump failed: $db" || return
        done < <(jq -r '.databases.mysql.names[]' <<< "$CONFIG")
        if [[ $(jq -r .databases.mysql.accounts <<< "$CONFIG") == true ]]; then
            mysql_cmd -e "SELECT CONCAT(QUOTE(User),'@',QUOTE(Host)) FROM mysql.user WHERE User NOT IN ('mysql.sys','mysql.session','mysql.infoschema','mariadb.sys')" > "$WORK/accounts"
            : > "$WORK/payload/database/mysql/accounts-and-grants.sql"
            while IFS= read -r account; do
                stmt=$(mysql_cmd --raw -e "SHOW CREATE USER $account") || fail 'Unable to export account definitions; grant backup was requested.' || return
                printf '%s;\n' "${stmt#*$'\t'}" >> "$WORK/payload/database/mysql/accounts-and-grants.sql"
                mysql_cmd --raw -e "SHOW GRANTS FOR $account" | sed 's/;*$/;/' >> "$WORK/payload/database/mysql/accounts-and-grants.sql" || return
            done < "$WORK/accounts"
        fi
    fi
    if jq -e '.databases.postgres.names|length>0' <<< "$CONFIG" >/dev/null; then
        have pg_dump && have pg_dumpall || fail 'PostgreSQL native client tools required.' || return
        pg_options; mkdir -p "$WORK/payload/database/postgres"
        pg_cmd pg_dumpall "${PG_ARGS[@]}" --globals-only > "$WORK/payload/database/postgres/globals.sql" || return
        while IFS= read -r db; do pg_cmd pg_dump "${PG_ARGS[@]}" -Fp --create --dbname="$db" > "$WORK/payload/database/postgres/$db.sql" || return; done < <(jq -r '.databases.postgres.names[]' <<< "$CONFIG")
    fi
    if jq -e '.databases.mongo.names|length>0' <<< "$CONFIG" >/dev/null; then
        secret_ok "$ETC/mongo.yml" || return; mkdir -p "$WORK/payload/database/mongo"
        while IFS= read -r db; do
            mongodump --config="$ETC/mongo.yml" --db="$db" --dumpDbUsersAndRoles --archive="$WORK/payload/database/mongo/$db.archive.gz" --gzip > "$WORK/mongo.out" 2>&1 || fail "MongoDB dump failed for $db. Check native client compatibility and credentials." || return
        done < <(jq -r '.databases.mongo.names[]' <<< "$CONFIG")
    fi
    log BACKUP 'Logical database dumps completed.'
}
metadata() {
    local out="$WORK/payload/metadata" c path
    mkdir -p "$out"
    capture() { local name="$1"; shift; if have "$1"; then timeout 45 "$@" > "$out/$name.txt" 2>&1 || printf '\nCommand unavailable, timed out, or incomplete.\n' >> "$out/$name.txt"; else printf 'Not installed: %s\n' "$1" > "$out/$name.txt"; fi; }
    capture os cat /etc/os-release; capture kernel uname -a; capture disks lsblk -f; capture disk-usage df -hT
    capture network ip -brief address; capture routes ip route
    case "$(package_manager)" in
        apt-get) capture packages dpkg-query -W;; dnf|yum|zypper) capture packages rpm -qa;;
        apk) capture packages apk info -vv;; pacman) capture packages pacman -Q;; *) printf 'Unknown package manager\n' > "$out/packages.txt";;
    esac
    capture services systemctl list-unit-files --state=enabled --no-pager
    capture version-nginx nginx -v; capture version-litespeed /usr/local/lsws/bin/lshttpd -v
    for c in php mariadb mysql psql mongodump; do capture "version-$c" "$c" --version; done
    capture version-apache apachectl -v; capture version-httpd httpd -v
    capture postfix postconf -n; capture dovecot doveconf -n; capture exim exim -bV
    capture firewall-nft nft list ruleset; capture firewall-iptables iptables-save; capture firewall-ip6tables ip6tables-save
    capture firewall-firewalld firewall-cmd --list-all-zones; capture firewall-ufw ufw status verbose
    capture selinux-contexts semanage fcontext -l -C; capture selinux-booleans semanage boolean -l -C
    capture cron-root crontab -l
    if [[ -d /etc/letsencrypt/live ]]; then find /etc/letsencrypt/live -maxdepth 2 -name cert.pem -print > "$out/certificates.txt"; fi
    jq -n --arg version "$VERSION" --arg id "$RUN_ID" --arg server "$SERVER_ID" --arg host "$HOSTNAME_SAFE" --arg time "$(now)" --arg arch "$(uname -m)" --argjson config "$CONFIG" \
      '{version:$version,backup_id:$id,server_id:$server,hostname:$host,utc:$time,architecture:$arch,configuration:$config,checksum:"The SHA-256 of this archive is in the external .sha256 sidecar; self-inclusion is impossible.",restore_notes:"Extract into staging. Original paths are relative to filesystem/. Review database grants and configs before importing. Provider credentials must be reauthorized."}' > "$out/backup-manifest.json"
}
tar_options() {
    TAR_META=(--numeric-owner)
    local h; h=$(tar --help)
    [[ $h != *'--acls'* ]] || TAR_META+=(--acls)
    [[ $h != *'--xattrs'* ]] || TAR_META+=(--xattrs --xattrs-include='*')
    [[ $h != *'--selinux'* ]] || TAR_META+=(--selinux)
}
preflight() {
    local total=0 size p dbsize=0 reserve free needed last=0
    while IFS= read -r p; do
        size=$(du -sx -B1 --exclude="$BACKUP_DIR" --exclude="$STATE" -- "$p" 2>/dev/null | cut -f1) || fail "Cannot estimate source size: $p" || return
        total=$((total+size))
    done < <(jq -r '.sources[]' <<< "$CONFIG")
    if jq -e '.databases.mysql.names|length>0' <<< "$CONFIG" >/dev/null; then
        dbsize=$(mysql_cmd -e 'SELECT COALESCE(SUM(DATA_LENGTH+INDEX_LENGTH),0) FROM information_schema.TABLES' 2>/dev/null || printf 0)
        [[ $dbsize =~ ^[0-9]+$ ]] || dbsize=0
    fi
    if jq -e '.databases.postgres.names|length>0' <<< "$CONFIG" >/dev/null; then
        pg_options
        size=$(pg_cmd psql "${PG_ARGS[@]}" -d postgres -Atc 'SELECT COALESCE(SUM(pg_database_size(oid)),0) FROM pg_database' 2>/dev/null || printf 0)
        [[ $size =~ ^[0-9]+$ ]] && dbsize=$((dbsize+size))
    fi
    # Conservative allowance for MongoDB or an engine whose size cannot be queried.
    if jq -e '.databases|length>0' <<< "$CONFIG" >/dev/null && ((dbsize==0)); then dbsize=1073741824; fi
    free=$(df -PB1 "$BACKUP_DIR" | awk 'NR==2{print $4}')
    reserve=$(( $(jq -r .reserve_mib <<< "$CONFIG") * 1048576 ))
    needed=$((total*12/10+dbsize*3+reserve+134217728))
    for p in "$STATE"/records/*.json; do
        [[ -f $p ]] || continue
        size=$(jq -r '.size // 0' "$p") || return
        ((size<=last)) || last=$size
    done
    ((needed>=last*12/10+dbsize+reserve)) || needed=$((last*12/10+dbsize+reserve))
    log INFO "Pre-flight: source bytes=$total; database estimate=$dbsize; previous archive maximum=$last; free bytes=$free; required estimate=$needed"
    (( free > needed )) || fail 'Insufficient local disk space.' || return
    # Dumps and chunk staging also need space if /var/lib is another filesystem.
    free=$(df -PB1 "$STATE" | awk 'NR==2{print $4}')
    (( free > dbsize*2+reserve+134217728 )) || fail 'Insufficient working-directory space.'
}
archive_create() {
    local p rc=0 sha; local -a excludes=() low=(nice -n 10)
    have ionice && low+=(ionice -c 2 -n 7)
    HOSTNAME_SAFE=$(hostname -f 2>/dev/null || hostname); HOSTNAME_SAFE=${HOSTNAME_SAFE//[^a-zA-Z0-9._-]/_}
    ARCHIVE_NAME="$HOSTNAME_SAFE-full-$(date -u +%Y-%m-%d_%H-%M-%S_UTC).tar.gz"
    ARCHIVE="$BACKUP_DIR/$ARCHIVE_NAME"; PARTIAL="$ARCHIVE.partial"
    [[ ! -e $ARCHIVE && ! -e $PARTIAL ]] || fail 'Backup filename already exists; retry after this second.' || return
    preflight || return
    dump_databases || return; metadata || return
    : > "$WORK/sources.nul"
    while IFS= read -r p; do printf '%s\0' "${p#/}" >> "$WORK/sources.nul"; done < <(jq -r '.sources[]' <<< "$CONFIG")
    # Absolute exclusions protect recursion, runtime data, raw databases, and active secrets even under broad sources.
    for p in "$BACKUP_DIR" "$STATE" "$ETC" "$LOGDIR" /proc /sys /dev /run /var/lib/mysql /var/lib/postgresql /var/lib/mongodb; do excludes+=("--exclude=${p#/}"); done
    excludes+=("--exclude=${ETC#/}.previous.*" --exclude='var/lib/docker/overlay2' --exclude='var/lib/docker/containers')
    if jq -e '.databases.mysql.names|length>0' <<< "$CONFIG" >/dev/null; then
        p=$(mysql_cmd -e 'SELECT @@datadir') || return
        [[ $p == /* && $p != / ]] || fail 'Cannot identify MySQL data directory.' || return
        p=${p%/}; excludes+=("--exclude=${p#/}")
    fi
    if jq -e '.databases.postgres.names|length>0' <<< "$CONFIG" >/dev/null; then
        pg_options; p=$(pg_cmd psql "${PG_ARGS[@]}" -d postgres -Atc 'SHOW data_directory') || return
        [[ $p == /* && $p != / ]] || fail 'Cannot identify PostgreSQL data directory.' || return
        p=${p%/}; excludes+=("--exclude=${p#/}")
    fi
    tar_options
    if "${low[@]}" tar "${TAR_META[@]}" --one-file-system --create --gzip --file="$PARTIAL" "${excludes[@]}" \
        --transform='flags=r;s,^,filesystem/,' -C / --null --verbatim-files-from --files-from="$WORK/sources.nul" \
        --transform='flags=r;s,^filesystem/metadata,metadata,;s,^filesystem/database,database,' -C "$WORK/payload" metadata database 2> "$WORK/tar.err"; then :; else rc=$?; fi
    if ((rc!=0)); then
        log ERROR "tar exited $rc. A source may have changed or become unreadable; archive was not committed."
        cat "$WORK/tar.err" >&2; return 1
    fi
    gzip -t "$PARTIAL" && tar -tzf "$PARTIAL" >/dev/null || fail 'Archive validation failed.' || return
    mv -- "$PARTIAL" "$ARCHIVE"; PARTIAL=""
    (cd "$BACKUP_DIR" && sha256sum -- "$ARCHIVE_NAME") | atom "$ARCHIVE.sha256"
    verify_local "$ARCHIVE" || return
    sha=$(sha256sum "$ARCHIVE" | cut -d' ' -f1)
    jq -n --arg id "$RUN_ID" --arg server "$SERVER_ID" --arg host "$HOSTNAME_SAFE" --arg start "$STARTED" --arg path "$ARCHIVE" --arg name "$ARCHIVE_NAME" --arg sha "$sha" --argjson size "$(stat -c %s "$ARCHIVE")" --argjson config "$CONFIG" \
      '{id:$id,server_id:$server,hostname:$host,started:$start,filename:$name,path:$path,size:$size,sha256:$sha,local:"VERIFIED",status:"PENDING",configuration:$config,remote:{},retention:{}}' | json_write "$RECORD"
    log VERIFY 'Archive, gzip, tar readability, and SHA-256 verification passed.'
}
verify_local() {
    local f="$1" sum name expected
    [[ -f $f && -f $f.sha256 && ! -L $f && ! -L $f.sha256 ]] || fail 'Archive/checksum pair missing or symlinked.' || return
    name=$(basename "$f"); filename_ok "$name" || return
    # Verify one exact sidecar line, never execute a user-supplied checksum path list.
    read -r sum expected < "$f.sha256"
    [[ $sum =~ ^[a-f0-9]{64}$ && $expected == "$name" && $(wc -l < "$f.sha256") == 1 ]] || fail 'Malformed checksum sidecar.' || return
    [[ $(sha256sum "$f" | cut -d' ' -f1) == "$sum" ]] && gzip -t "$f" && tar -tzf "$f" >/dev/null
}

# Direct HTTPS transport. Secrets/URLs are passed to curl in private config files,
# never as curl command-line arguments. Response bodies never enter normal logs.
curl_setting() {
    local key="$1" value="$2"
    [[ $value != *$'\n'* && $value != *$'\r'* ]] || return 1
    value=${value//\\/\\\\}; value=${value//\"/\\\"}
    printf '%s = "%s"\n' "$key" "$value"
}
header_value() { awk -v key="$1" 'tolower($0) ~ "^"tolower(key)":" {sub(/^[^:]+:[ \t]*/,""); sub(/\r$/,""); val=$0} END{print val}' "$HTTP_HEADERS"; }
http() {
    local method="$1" url="$2" body="${3:-}" auth="${4:-bearer}" tries="${5:-4}" attempt=0 code rc delay cf token datahash
    shift 5 || true
    local -a extra=("$@")
    url_ok "$url" || fail 'Invalid HTTPS endpoint.' || return
    new_work
    cf="$WORK/http.curl"; HTTP_BODY="$WORK/http.body"; HTTP_HEADERS="$WORK/http.headers"
    {
        curl_setting url "$url"
        if [[ $method == HEAD ]]; then printf 'head\n'; else curl_setting request "$method"; fi
        printf 'silent\nshow-error\nconnect-timeout = 20\nmax-time = 3600\nspeed-time = 120\nspeed-limit = 128\nproto = "=https"\nproto-redir = "=https"\n'
        curl_setting output "$HTTP_BODY"; curl_setting dump-header "$HTTP_HEADERS"
        printf 'write-out = "%%{http_code}"\n'
        if [[ ${BANDWIDTH:-0} != 0 ]]; then curl_setting limit-rate "${BANDWIDTH}K"; fi
        case "$auth" in
            bearer) token=$(jq -r '.access_token // empty' <<< "$DEST"); [[ -n $token ]] || return 1; curl_setting header "Authorization: Bearer $token";;
            basic) curl_setting user "$(jq -r '[.username,.password]|join(":")' <<< "$DEST")";;
            s3)
                curl_setting aws-sigv4 "aws:amz:$(jq -r .region <<< "$DEST"):s3"
                curl_setting user "$(jq -r '[.access_key,.secret_key]|join(":")' <<< "$DEST")"
                token=$(jq -r '.session_token // empty' <<< "$DEST"); [[ -z $token ]] || curl_setting header "x-amz-security-token: $token"
                if [[ -n $body ]]; then datahash=$(sha256sum "$body" | cut -d' ' -f1); else datahash=$(printf '' | sha256sum | cut -d' ' -f1); fi
                curl_setting header "x-amz-content-sha256: $datahash";;
            none) :;; *) return 1;;
        esac
        if [[ -n $body ]]; then
            if [[ $method == PUT ]]; then curl_setting upload-file "$body"; else curl_setting data-binary "@$body"; fi
        fi
        local h; for h in "${extra[@]}"; do curl_setting header "$h" || return; done
    } > "$cf" || return
    while ((attempt<tries)); do
        attempt=$((attempt+1)); : > "$HTTP_BODY"; : > "$HTTP_HEADERS"
        rc=0; code=$(curl -q --config "$cf" 2> "$WORK/http.error") || rc=$?
        HTTP_CODE=${code:-000}
        if ((rc==0)) && [[ $code != 429 && $code != 408 && ! $code =~ ^5[0-9][0-9]$ ]] && ! { [[ $code == 403 ]] && jq -e '.error.errors[]?.reason|IN("rateLimitExceeded","userRateLimitExceeded")' "$HTTP_BODY" >/dev/null 2>&1; }; then return 0; fi
        ((attempt<tries)) || break
        delay=$(( (1<<attempt) + RANDOM%3 )); token=$(header_value Retry-After)
        [[ ! $token =~ ^[0-9]{1,2}$ ]] || delay=$token
        ((delay<=60)) || delay=60
        log WARN "Temporary HTTP/transport failure ($HTTP_CODE); retry $attempt/$tries in ${delay}s."
        sleep "$delay"
    done
    fail "HTTPS request failed (HTTP $HTTP_CODE). Local backup retained."
}
expect_http() { [[ " $* " == *" $HTTP_CODE "* ]] || { log ERROR "Provider returned HTTP $HTTP_CODE. Check quota, permissions, and authorization; use destination reauthorize if needed."; return 1; }; }
json_response() { jq -e 'type=="object"' "$HTTP_BODY" >/dev/null 2>&1 || fail 'Provider returned invalid JSON.'; }
uri() { jq -rn --arg v "$1" '$v|@uri'; }
uri_path() { jq -rn --arg v "$1" '$v|split("/")|map(@uri)|join("/")'; }
request_json() {
    local method="$1" url="$2" data="${3:-}" retries="${4:-4}"
    if [[ -n $data ]]; then printf '%s' "$data" > "$WORK/request.json"; data="$WORK/request.json"; fi
    http "$method" "$url" "$data" bearer "$retries" 'Content-Type: application/json' || return
    if [[ $HTTP_CODE == 401 ]]; then refresh_token force || return; http "$method" "$url" "$data" bearer "$retries" 'Content-Type: application/json' || return; fi
    expect_http 200 201 202 204 || return
    [[ $HTTP_CODE == 204 ]] || json_response
}
dest_value() { jq -r --arg k "$1" '.[$k] // ""' <<< "$DEST"; }
dest_put() {
    local k="$1" v="$2"
    printf '%s' "$v" | jq -Rs --arg k "$k" --slurpfile d "$DEST_FILE" '$d[0] + {($k):.}' | json_write "$DEST_FILE" || return
    DEST=$(cat "$DEST_FILE")
}
dest_validate() {
    local f="$1" type url val
    secret_ok "$f" || fail 'Provider configuration must be owned by root and mode 0600.' || return
    jq -e '.format==1 and (.type|IN("google","dropbox","onedrive","s3","sftp","webdav")) and
      (.id|test("^[a-f0-9]{32}$")) and (.name|test("^[a-z][a-z0-9_-]{0,39}$")) and
      (.keep|type=="number" and floor==. and .>=1 and .<=999999) and (.tested|type=="boolean")' "$f" >/dev/null || return
    type=$(jq -r .type "$f")
    case "$type" in
        google|dropbox|onedrive)
            jq -e '(.client_id|type=="string" and length>0) and (.access_token|type=="string" and length>0) and (.refresh_token|type=="string" and length>0) and (.expires_at|type=="number" and floor==. and .>=0 and .<100000000000)' "$f" >/dev/null || return;;
        s3) jq -e '(.access_key|type=="string" and length>0) and (.secret_key|type=="string" and length>0)' "$f" >/dev/null || return;;
        webdav) jq -e '(.username|type=="string") and (.password|type=="string")' "$f" >/dev/null || return;;
    esac
    case "$type" in
        s3)
            url=$(jq -r .endpoint "$f"); url_ok "$url" && [[ $url =~ ^https://[a-zA-Z0-9.-]+(:[0-9]+)?$ ]] || return
            val=$(jq -r .bucket "$f"); [[ $val =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ && $val != *..* ]] || return
            val=$(jq -r .region "$f"); [[ $val =~ ^[a-z0-9-]+$ ]] || return;;
        webdav) url=$(jq -r .endpoint "$f"); url_ok "$url" && [[ $url != *'?'* ]] || return;;
        sftp)
            val=$(jq -r .host "$f"); [[ $val =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*$ ]] || return
            val=$(jq -r .username "$f"); [[ $val =~ ^[a-z_][a-z0-9_-]*$ ]] || return
            val=$(jq -r .directory "$f"); [[ $val =~ ^/[A-Za-z0-9_./-]+$ && $val != *'..'* ]] || return
            val=$(jq -r .port "$f"); uint "$val" && ((val>0 && val<65536)) || return
            secret_ok "$(jq -r .key "$f")" || return;;
        onedrive) val=$(jq -r .tenant "$f"); [[ $val =~ ^[A-Za-z0-9.-]+$ ]] || return;;
    esac
}
load_dest() {
    DEST_FILE="$1"; dest_validate "$DEST_FILE" || fail 'Invalid provider configuration.' || return
    DEST=$(cat "$DEST_FILE"); DEST_TYPE=$(dest_value type); DEST_NAME=$(dest_value name); DEST_ID=$(dest_value id)
    new_work
}
token_save() {
    jq -e '.access_token|type=="string" and length>0' "$HTTP_BODY" >/dev/null || fail 'Authorization failed; run destination reauthorize.' || return
    jq --slurpfile t "$HTTP_BODY" --argjson now "$(date +%s)" \
        '.access_token=$t[0].access_token | .refresh_token=($t[0].refresh_token // .refresh_token) | .expires_at=($now+($t[0].expires_in // 3600))' "$DEST_FILE" | json_write "$DEST_FILE" || return
    DEST=$(cat "$DEST_FILE")
}
refresh_token() {
    case "$DEST_TYPE" in google|dropbox|onedrive) :;; *) return 0;; esac
    local exp url
    exp=$(jq -r '.expires_at // 0' <<< "$DEST")
    [[ $exp =~ ^[0-9]{1,11}$ ]] || fail 'Invalid token expiry state.' || return
    if [[ ${1:-} != force ]] && ((exp>$(date +%s)+120)); then return 0; fi
    jq -e '.refresh_token|type=="string" and length>0' "$DEST_FILE" >/dev/null || fail "Authorization requires user action: automate-backups destination reauthorize $DEST_NAME" || return
    case "$DEST_TYPE" in google) url=https://oauth2.googleapis.com/token;; dropbox) url=https://api.dropboxapi.com/oauth2/token;; onedrive) url="https://login.microsoftonline.com/$(dest_value tenant)/oauth2/v2.0/token";; esac
    jq -r '{grant_type:"refresh_token",client_id,refresh_token} + (if (.client_secret // "")!="" then {client_secret} else {} end) | to_entries|map((.key|@uri)+"="+(.value|@uri))|join("&")' "$DEST_FILE" > "$WORK/token.form"
    http POST "$url" "$WORK/token.form" none 1 'Content-Type: application/x-www-form-urlencoded' || return
    expect_http 200 && json_response && token_save || fail "Token refresh failed. Reauthorize destination $DEST_NAME."
}
oauth_callback() {
    # Small Python standard-library listener is used only for interactive Google OAuth.
    # It binds loopback, validates state, expires, and never logs the code or tokens.
    have python3 || fail 'Google authorization requires system python3 for its loopback callback. Install it, then retry.' || return
    local state="$1" verifier="$2" port url
    printf '%s' "$state" > "$WORK/oauth-state"
    python3 - "$WORK" <<'PY' &
import http.server, json, pathlib, secrets, sys, time, urllib.parse
p=pathlib.Path(sys.argv[1]); state=(p/'oauth-state').read_text(); done=False
class Callback(http.server.BaseHTTPRequestHandler):
    def log_message(self,*args): pass
    def do_GET(self):
        global done
        q=urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
        good=secrets.compare_digest(q.get('state',[''])[0],state) and bool(q.get('code'))
        self.send_response(200 if good else 400); self.end_headers()
        self.wfile.write(b'Authorization received. Return to your terminal.' if good else b'Invalid authorization response.')
        if good:
            (p/'oauth-code').write_text(q['code'][0]); done=True
server=http.server.HTTPServer(('127.0.0.1',0),Callback); server.timeout=1
(p/'oauth-port').write_text(str(server.server_port)); end=time.monotonic()+600
while not done and time.monotonic()<end: server.handle_request()
server.server_close()
sys.exit(0 if done else 1)
PY
    CALLBACK_PID=$!
    local i; for i in {1..50}; do [[ ! -f $WORK/oauth-port ]] || break; sleep .1; done
    [[ -f $WORK/oauth-port ]] || return 1
    port=$(cat "$WORK/oauth-port"); OAUTH_REDIRECT="http://127.0.0.1:$port"
    local challenge; challenge=$(printf '%s' "$verifier" | openssl dgst -sha256 -binary | openssl base64 -A | tr '+/' '-_' | tr -d '=')
    url="https://accounts.google.com/o/oauth2/v2/auth?client_id=$(uri "$(dest_value client_id)")&redirect_uri=$(uri "$OAUTH_REDIRECT")&response_type=code&scope=https%3A%2F%2Fwww.googleapis.com%2Fauth%2Fdrive.file&access_type=offline&prompt=consent&state=$state&code_challenge=$challenge&code_challenge_method=S256"
    printf '\nFor a remote server, open a SECOND terminal on your computer and forward this loopback port:\nssh -N -L %s:127.0.0.1:%s YOUR_SSH_USER@YOUR_SERVER\nThen open this official Google URL in your computer browser (10 minute timeout):\n%s\n' "$port" "$port" "$url" > /dev/tty
    wait "$CALLBACK_PID" || fail 'Google authorization timed out or was rejected.' || return
    CALLBACK_PID=""
}
provider_auth() {
    local state verifier code url tenant interval deadline err
    case "$DEST_TYPE" in
        google)
            printf '\nUse your own Google Cloud Desktop OAuth client, with Drive API enabled and consent screen configured. Scope: drive.file. See README.\n'
            ask 'OAuth client ID'; dest_put client_id "$ANSWER"
            ask 'OAuth client secret' '' 1; dest_put client_secret "$ANSWER"
            state=$(openssl rand -hex 24); verifier=$(openssl rand -hex 32)
            oauth_callback "$state" "$verifier" || return
            printf '%s' "$verifier" > "$WORK/verifier"; printf '%s' "$OAUTH_REDIRECT" > "$WORK/redirect"
            jq -r --rawfile code "$WORK/oauth-code" --rawfile verifier "$WORK/verifier" --rawfile redirect "$WORK/redirect" \
              '{grant_type:"authorization_code",client_id,client_secret,code:$code,code_verifier:$verifier,redirect_uri:$redirect}|to_entries|map((.key|@uri)+"="+(.value|@uri))|join("&")' "$DEST_FILE" > "$WORK/token.form"
            http POST https://oauth2.googleapis.com/token "$WORK/token.form" none 1 'Content-Type: application/x-www-form-urlencoded' || return
            expect_http 200 && token_save || return;;
        dropbox)
            printf '\nCreate a Dropbox Scoped Access / App Folder app. Enable files.content.write, files.content.read, files.metadata.read and account_info.read.\n'
            ask 'Dropbox app key'; dest_put client_id "$ANSWER"
            ask 'Dropbox app secret' '' 1; dest_put client_secret "$ANSWER"
            verifier=$(openssl rand -hex 32)
            code=$(printf '%s' "$verifier" | openssl dgst -sha256 -binary | openssl base64 -A | tr '+/' '-_' | tr -d '=')
            printf 'Open this official URL; Dropbox displays an authorization code:\nhttps://www.dropbox.com/oauth2/authorize?client_id=%s&response_type=code&token_access_type=offline&code_challenge=%s&code_challenge_method=S256\n' "$(uri "$(dest_value client_id)")" "$code" > /dev/tty
            ask 'Authorization code' '' 1; printf '%s' "$ANSWER" > "$WORK/oauth-code"; printf '%s' "$verifier" > "$WORK/verifier"
            jq -r --rawfile code "$WORK/oauth-code" --rawfile verifier "$WORK/verifier" '{grant_type:"authorization_code",client_id,client_secret,code:$code,code_verifier:$verifier}|to_entries|map((.key|@uri)+"="+(.value|@uri))|join("&")' "$DEST_FILE" > "$WORK/token.form"
            http POST https://api.dropboxapi.com/oauth2/token "$WORK/token.form" none 1 'Content-Type: application/x-www-form-urlencoded' || return
            expect_http 200 && token_save || return;;
        onedrive)
            printf '\nRegister a public client in Microsoft Entra; enable public client flows and delegated Files.ReadWrite.AppFolder. See README.\n'
            ask 'Application (client) ID'; dest_put client_id "$ANSWER"
            ask 'Tenant ID (consumers for personal accounts, organizations or tenant ID for work)' consumers; tenant="$ANSWER"
            [[ $tenant =~ ^[A-Za-z0-9.-]+$ ]] || return; dest_put tenant "$tenant"
            jq -r '{client_id,scope:"offline_access Files.ReadWrite.AppFolder"}|to_entries|map((.key|@uri)+"="+(.value|@uri))|join("&")' "$DEST_FILE" > "$WORK/token.form"
            http POST "https://login.microsoftonline.com/$tenant/oauth2/v2.0/devicecode" "$WORK/token.form" none 1 'Content-Type: application/x-www-form-urlencoded' || return
            expect_http 200 && json_response || return
            jq -r '.message' "$HTTP_BODY" > /dev/tty
            cp "$HTTP_BODY" "$WORK/device.json"
            jq -e '(.interval // 5 | type=="number" and floor==. and .>=1 and .<=60) and (.expires_in|type=="number" and floor==. and .>=1 and .<=3600)' "$WORK/device.json" >/dev/null || return
            interval=$(jq -r '.interval // 5' "$WORK/device.json"); deadline=$(( $(date +%s)+$(jq -r .expires_in "$WORK/device.json") ))
            jq -r --slurpfile d "$WORK/device.json" '{grant_type:"urn:ietf:params:oauth:grant-type:device_code",client_id,device_code:$d[0].device_code}|to_entries|map((.key|@uri)+"="+(.value|@uri))|join("&")' "$DEST_FILE" > "$WORK/token.form"
            while (( $(date +%s) < deadline )); do
                sleep "$interval"
                http POST "https://login.microsoftonline.com/$tenant/oauth2/v2.0/token" "$WORK/token.form" none 1 'Content-Type: application/x-www-form-urlencoded' || return
                if [[ $HTTP_CODE == 200 ]]; then token_save; return; fi
                err=$(jq -r '.error // "invalid_response"' "$HTTP_BODY")
                case "$err" in authorization_pending) :;; slow_down) interval=$((interval+5));; *) fail "Microsoft authorization failed ($err)."; return 1;; esac
            done
            fail 'Device authorization expired.'; return 1;;
        s3)
            ask 'New access key ID (blank keeps current)' '' 1; [[ -z $ANSWER ]] || dest_put access_key "$ANSWER"
            ask 'New secret access key (blank keeps current)' '' 1; [[ -z $ANSWER ]] || dest_put secret_key "$ANSWER"
            ask 'New session token (blank keeps current, - clears)' '' 1
            if [[ $ANSWER == - ]]; then dest_put session_token ""; elif [[ -n $ANSWER ]]; then dest_put session_token "$ANSWER"; fi;;
        webdav)
            ask 'WebDAV username' "$(dest_value username)"; dest_put username "$ANSWER"
            ask 'New WebDAV password (blank keeps current)' '' 1; [[ -z $ANSWER ]] || dest_put password "$ANSWER";;
        sftp) log INFO 'SFTP reauthorization retests the configured key and pinned host fingerprints; use destination add for a different server.';;
    esac
}

# Provider adapters return canonical metadata: {id,name,size,hash,hash_kind}.
# A provider is only offered when upload/list/verify/download/delete are implemented.
google_api() { request_json "$1" "https://www.googleapis.com/drive/v3/$2" "${3:-}" "${4:-4}"; }
dropbox_api() { request_json POST "https://api.dropboxapi.com/2/$1" "${2:-null}" "${3:-4}"; }
graph_api() { request_json "$1" "https://graph.microsoft.com/v1.0/$2" "${3:-}" "${4:-4}"; }
xml_ready() { have xmlstarlet || fail 'Install xmlstarlet for S3/WebDAV XML parsing.'; }
xml_safe() { ! grep -Eqi '<!DOCTYPE|<!ENTITY' "$HTTP_BODY" && xmlstarlet val -q "$HTTP_BODY"; }
xml_value() { xmlstarlet sel -t -v "//*[local-name()='$1']" "$HTTP_BODY"; }
s3_base() { printf '%s/%s' "$(dest_value endpoint)" "$(dest_value bucket)"; }
s3_request() {
    http "$1" "$(s3_base)/$2" "${3:-}" s3 "${4:-4}" "${@:5}" || return
    [[ $1 == HEAD ]] && return 0
    [[ ! -s $HTTP_BODY ]] || { xml_safe && [[ $(xmlstarlet sel -t -v 'local-name(/*)' "$HTTP_BODY") != Error ]]; } || fail 'S3 returned an XML error or invalid response.'
}
sftp_settings() {
    SSH_ARGS=(-o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=20 -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o "UserKnownHostsFile=$ETC/providers/$DEST_NAME.known_hosts" -i "$(dest_value key)")
    SSH_TARGET="$(dest_value username)@$(dest_value host)"
    REMOTE_DIR="$(dest_value directory)/Automate-Backups-$SERVER_ID-$DEST_ID"
}
ssh_exec() { sftp_settings; ssh "${SSH_ARGS[@]}" -p "$(dest_value port)" "$SSH_TARGET" "$1"; }
sftp_batch() {
    sftp_settings
    local -a rate=(); (( ${BANDWIDTH:-0} == 0 )) || rate=(-l "$((BANDWIDTH*8))")
    sftp "${SSH_ARGS[@]}" "${rate[@]}" -P "$(dest_value port)" -b "$WORK/sftp.batch" "$SSH_TARGET" > "$WORK/sftp.out" 2>&1
}
provider_init() {
    local folder data
    refresh_token || return
    case "$DEST_TYPE" in
        google)
            if [[ -n $(dest_value folder) ]]; then google_api GET "files/$(uri "$(dest_value folder)")?fields=id,mimeType,trashed" || return; jq -e '.trashed==false and .mimeType=="application/vnd.google-apps.folder"' "$HTTP_BODY" >/dev/null; return; fi
            data=$(jq -n --arg s "$SERVER_ID" '{name:"Automate Backups",mimeType:"application/vnd.google-apps.folder",appProperties:{server_id:$s}}')
            google_api POST files "$data" 1 || return; folder=$(jq -r .id "$HTTP_BODY")
            data=$(jq -n --arg s "$SERVER_ID" --arg d "$DEST_ID" --arg p "$folder" --arg h "$(hostname)" '{name:($h+"-"+$s),parents:[$p],mimeType:"application/vnd.google-apps.folder",appProperties:{server_id:$s,destination_id:$d}}')
            google_api POST files "$data" 1 || return; dest_put folder "$(jq -r .id "$HTTP_BODY")";;
        dropbox)
            folder="/Automate Backups/$SERVER_ID-$DEST_ID"; dest_put folder "$folder"
            # Dropbox create_folder_v2 creates missing parents; conflict on a preexisting dedicated folder is acceptable only after metadata verification.
            data=$(jq -n --arg p "$folder" '{path:$p,autorename:false}')
            if ! dropbox_api files/create_folder_v2 "$data" 1; then
                dropbox_api files/get_metadata "$(jq -n --arg p "$folder" '{path:$p}')" || return
                jq -e '.[".tag"]=="folder"' "$HTTP_BODY" >/dev/null || return
            fi;;
        onedrive)
            if [[ -n $(dest_value folder) ]]; then graph_api GET "me/drive/items/$(uri "$(dest_value folder)")"; return; fi
            graph_api GET me/drive/special/approot || return; folder=$(jq -r .id "$HTTP_BODY")
            data=$(jq -n --arg n "$(hostname)-$SERVER_ID-$DEST_ID" '{name:$n,folder:{},"@microsoft.graph.conflictBehavior":"fail"}')
            graph_api POST "me/drive/items/$(uri "$folder")/children" "$data" 1 || return
            dest_put folder "$(jq -r .id "$HTTP_BODY")";;
        s3)
            xml_ready || return
            curl --help all | grep -q -- '--aws-sigv4' || fail 'S3 requires curl 7.75 or newer with --aws-sigv4.' || return
            dest_put folder "Automate-Backups/$SERVER_ID/$DEST_ID"
            s3_request GET "?list-type=2&max-keys=1&prefix=$(uri "$(dest_value folder)/")" '' 4 || return; expect_http 200;;
        sftp)
            have sftp && have ssh || fail 'OpenSSH client tools required.' || return
            sftp_settings; ssh_exec "umask 077; mkdir -p '$REMOTE_DIR'; test -d '$REMOTE_DIR'";;
        webdav)
            xml_ready || return; folder="$(dest_value endpoint)/Automate-Backups-$SERVER_ID-$DEST_ID"; dest_put folder "$folder"
            http MKCOL "$folder/" '' basic 1 || return
            expect_http 201 405 || return
            provider_list >/dev/null;;
    esac
}
provider_meta() {
    local id="$1" data size hash folder
    refresh_token || return
    case "$DEST_TYPE" in
        google)
            google_api GET "files/$(uri "$id")?fields=id,name,size,md5Checksum,parents,trashed" || return
            jq -e --arg f "$(dest_value folder)" '.trashed==false and (.parents|index($f)!=null) and (.size|tonumber)>=0' "$HTTP_BODY" >/dev/null || return
            jq '{id,name,size:(.size|tonumber),hash:.md5Checksum,hash_kind:"md5"}' "$HTTP_BODY";;
        dropbox)
            dropbox_api files/get_metadata "$(jq -n --arg p "$id" '{path:$p}')" || return
            jq -e --arg p "$(dest_value folder | tr '[:upper:]' '[:lower:]')/" '.[".tag"]=="file" and (.path_lower|startswith($p))' "$HTTP_BODY" >/dev/null || return
            jq '{id,name,size,hash:.content_hash,hash_kind:"dropbox"}' "$HTTP_BODY";;
        onedrive)
            graph_api GET "me/drive/items/$(uri "$id")" || return
            jq -e --arg f "$(dest_value folder)" '.parentReference.id==$f and .file!=null' "$HTTP_BODY" >/dev/null || return
            jq '{id,name,size,hash:(.file.hashes.sha1Hash // null),hash_kind:"sha1"}' "$HTTP_BODY";;
        s3)
            [[ $id == "$(dest_value folder)/"* && $id != *'..'* ]] || return
            s3_request HEAD "$(uri_path "$id")" '' 4 || return; expect_http 200 || return
            size=$(header_value Content-Length); [[ $size =~ ^[0-9]+$ ]] || return
            jq -n --arg id "$id" --arg name "${id##*/}" --argjson size "$size" '{id:$id,name:$name,size:$size,hash:null,hash_kind:null}' ;;
        sftp)
            filename_ok "$id" || return; sftp_settings
            data=$(ssh_exec "test -f '$REMOTE_DIR/$id' && test ! -L '$REMOTE_DIR/$id' && stat -c %s '$REMOTE_DIR/$id' && sha256sum '$REMOTE_DIR/$id'") || return
            size=${data%%$'\n'*}; hash=${data#*$'\n'}; hash=${hash%% *}
            [[ $size =~ ^[0-9]+$ && $hash =~ ^[a-f0-9]{64}$ ]] || return
            jq -n --arg id "$id" --argjson size "$size" --arg h "$hash" '{id:$id,name:$id,size:$size,hash:$h,hash_kind:"sha256"}' ;;
        webdav)
            filename_ok "$id" || return
            http HEAD "$(dest_value folder)/$(uri "$id")" '' basic 4 || return; expect_http 200 || return
            size=$(header_value Content-Length); [[ $size =~ ^[0-9]+$ ]] || return
            jq -n --arg id "$id" --argjson size "$size" '{id:$id,name:$id,size:$size,hash:null,hash_kind:null}' ;;
    esac
}
provider_list() {
    local page='' next='' url data prefix line name size
    refresh_token || return
    printf '[]' > "$WORK/list.json"
    case "$DEST_TYPE" in
        google)
            while :; do
                url="files?pageSize=1000&q=$(uri "'$(dest_value folder)' in parents and trashed=false")&fields=nextPageToken,files(id,name,size)&pageToken=$(uri "$page")"
                google_api GET "$url" || return
                jq -e '.files|type=="array"' "$HTTP_BODY" >/dev/null || return
                jq --slurpfile p "$HTTP_BODY" '. + [$p[0].files[] | select(.size!=null) | {id,name,size:(.size|tonumber)}]' "$WORK/list.json" | json_write "$WORK/list.json"
                next=$(jq -r '.nextPageToken // empty' "$HTTP_BODY"); [[ -n $next ]] || break
                [[ $next != "$page" ]] || return; page="$next"
            done;;
        dropbox)
            dropbox_api files/list_folder "$(jq -n --arg p "$(dest_value folder)" '{path:$p,recursive:false,limit:2000}')" || return
            while :; do
                jq -e '.entries|type=="array"' "$HTTP_BODY" >/dev/null || return
                jq --slurpfile p "$HTTP_BODY" '. + [$p[0].entries[]|select(.[".tag"]=="file")|{id,name,size}]' "$WORK/list.json" | json_write "$WORK/list.json"
                [[ $(jq -r .has_more "$HTTP_BODY") == true ]] || break
                next=$(jq -r .cursor "$HTTP_BODY"); [[ $next != "$page" ]] || return; page="$next"
                dropbox_api files/list_folder/continue "$(jq -n --arg c "$page" '{cursor:$c}')" || return
            done;;
        onedrive)
            url="https://graph.microsoft.com/v1.0/me/drive/items/$(uri "$(dest_value folder)")/children?\$top=200"
            while :; do
                [[ $url == https://graph.microsoft.com/v1.0/* ]] || return
                request_json GET "$url" || return
                jq -e '.value|type=="array"' "$HTTP_BODY" >/dev/null || return
                jq --slurpfile p "$HTTP_BODY" '. + [$p[0].value[]|select(.file!=null)|{id,name,size}]' "$WORK/list.json" | json_write "$WORK/list.json"
                next=$(jq -r '.["@odata.nextLink"] // empty' "$HTTP_BODY"); [[ -n $next ]] || break
                [[ $next != "$url" ]] || return; url="$next"
            done;;
        s3)
            while :; do
                s3_request GET "?list-type=2&prefix=$(uri "$(dest_value folder)/")${page:+&continuation-token=$(uri "$page")}" '' 4 || return; expect_http 200 || return
                xmlstarlet sel -t -m '//*[local-name()="Contents"]' -v '*[local-name()="Key"]' -o $'\t' -v '*[local-name()="Size"]' -n "$HTTP_BODY" > "$WORK/xml-list"
                jq -Rn '[inputs|split("\t")|{id:.[0],name:(.[0]|split("/")|last),size:(.[1]|tonumber)}]' < "$WORK/xml-list" > "$WORK/page.json" || return
                jq --slurpfile p "$WORK/page.json" '.+$p[0]' "$WORK/list.json" | json_write "$WORK/list.json"
                [[ $(xml_value IsTruncated) == true ]] || break
                next=$(xml_value NextContinuationToken); [[ -n $next && $next != "$page" ]] || return; page="$next"
            done;;
        sftp)
            sftp_settings
            ssh_exec "find '$REMOTE_DIR' -maxdepth 1 -type f -printf '%f\t%s\n'" > "$WORK/ssh-list" || return
            jq -Rn '[inputs|split("\t")|select(length==2)|{id:.[0],name:.[0],size:(.[1]|tonumber)}]' < "$WORK/ssh-list" > "$WORK/list.json" || return;;
        webdav)
            printf '<?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop><d:getcontentlength/><d:resourcetype/></d:prop></d:propfind>' > "$WORK/propfind.xml"
            http PROPFIND "$(dest_value folder)/" "$WORK/propfind.xml" basic 4 'Depth: 1' 'Content-Type: application/xml' || return; expect_http 207 && xml_safe || return
            # Only safe project-style ASCII names are candidates. Unrelated DAV files are ignored.
            xmlstarlet sel -t -m '//*[local-name()="response"]' -v '*[local-name()="href"]' -o $'\t' -v '*[local-name()="propstat"][contains(*[local-name()="status"]," 200 ")]/*[local-name()="prop"]/*[local-name()="getcontentlength"]' -n "$HTTP_BODY" > "$WORK/dav-list"
            : > "$WORK/dav-items"
            while IFS=$'\t' read -r name size; do
                name=${name##*/}; filename_ok "$name" && [[ $size =~ ^[0-9]+$ ]] || continue
                jq -n --arg n "$name" --argjson s "$size" '{id:$n,name:$n,size:$s}' >> "$WORK/dav-items"
            done < "$WORK/dav-list"
            jq -s . "$WORK/dav-items" > "$WORK/list.json";;
    esac
    jq -e 'type=="array" and all(.[]; (.id|type=="string") and (.name|type=="string") and (.size|type=="number" and .>=0))' "$WORK/list.json" >/dev/null || return
    cat "$WORK/list.json"
}
provider_delete() {
    local id="$1"
    case "$DEST_TYPE" in
        google) google_api DELETE "files/$(uri "$id")";;
        dropbox) dropbox_api files/delete_v2 "$(jq -n --arg p "$id" '{path:$p}')";;
        onedrive) graph_api DELETE "me/drive/items/$(uri "$id")";;
        s3) [[ $id == "$(dest_value folder)/"* ]] || return; s3_request DELETE "$(uri_path "$id")" '' 4 && expect_http 204 200;;
        sftp) filename_ok "$id" || return; sftp_settings; printf 'rm "%s/%s"\n' "$REMOTE_DIR" "$id" > "$WORK/sftp.batch"; sftp_batch;;
        webdav) filename_ok "$id" || return; http DELETE "$(dest_value folder)/$(uri "$id")" '' basic 4 && expect_http 200 204;;
    esac
}
provider_quota() {
    local free=-1 need="$1"
    case "$DEST_TYPE" in
        google) if google_api GET 'about?fields=storageQuota'; then free=$(jq -r 'if .storageQuota.limit then (.storageQuota.limit|tonumber)-(.storageQuota.usage|tonumber) else -1 end' "$HTTP_BODY"); fi;;
        dropbox) if dropbox_api users/get_space_usage null; then free=$(jq -r '(.allocation.allocated // -1) as $a | if $a>=0 then $a-.used else -1 end' "$HTTP_BODY"); fi;;
        onedrive) if graph_api GET me/drive; then free=$(jq -r '.quota.remaining // -1' "$HTTP_BODY"); fi;;
        sftp) sftp_settings; free=$(ssh_exec "df -PB1 '$REMOTE_DIR' | awk 'NR==2{print \$4}'" 2>/dev/null || printf '%s' -1);;
    esac
    if [[ $free =~ ^[0-9]+$ ]]; then
        log INFO "Remote quota: $free bytes available; upload requires $need."
        ((free>=need)) || fail 'Remote quota insufficient.'
    else log WARN 'Remote quota is not available through this provider/account; upload errors remain fatal.'; fi
}
dropbox_hash() {
    local f="$1" offset=0 size; size=$(stat -c %s "$f"); : > "$WORK/hash-blocks"
    while ((offset<size)); do
        dd if="$f" iflag=skip_bytes,count_bytes skip="$offset" count=4194304 status=none | openssl dgst -sha256 -binary >> "$WORK/hash-blocks" || return
        offset=$((offset+4194304))
    done
    sha256sum "$WORK/hash-blocks" | cut -d' ' -f1
}
provider_verify() {
    local f="$1" id="$2" meta expected actual kind
    meta=$(provider_meta "$id") || return
    [[ $(jq -r .name <<< "$meta") == "$(basename "$f")" && $(jq -r .size <<< "$meta") == "$(stat -c %s "$f")" ]] || fail 'Remote name or size mismatch.' || return
    expected=$(jq -r '.hash // empty' <<< "$meta"); kind=$(jq -r '.hash_kind // empty' <<< "$meta")
    if [[ -n $expected ]]; then
        case "$kind" in
            md5) actual=$(md5sum "$f" | cut -d' ' -f1);;
            sha1) actual=$(sha1sum "$f" | cut -d' ' -f1);;
            sha256) actual=$(sha256sum "$f" | cut -d' ' -f1);;
            dropbox) actual=$(dropbox_hash "$f");;
            *) fail 'Unknown provider checksum algorithm'; return 1;;
        esac
        [[ ${expected,,} == "${actual,,}" ]] || fail 'Remote checksum mismatch.' || return
    fi
    printf '%s\n' "$meta"
}
session_path() { SESSION="$STATE/sessions/$DEST_ID-$(basename "$1").json"; }
session_url_save() { printf '%s' "$1" | jq -Rs '{url:.}' | json_write "$SESSION"; }
chunk() { dd if="$1" of="$WORK/chunk" iflag=skip_bytes,count_bytes skip="$2" count="$3" status=none; }
google_upload() {
    local f="$1" name size url offset=0 end range meta id attempts=0
    name=$(basename "$f"); size=$(stat -c %s "$f"); session_path "$f"
    if [[ ! -f $SESSION ]]; then
        google_api GET 'files/generateIds?count=1&space=drive&type=files' || return
        id=$(jq -r '.ids[0]' "$HTTP_BODY")
        meta=$(jq -n --arg id "$id" --arg n "$name" --arg folder "$(dest_value folder)" --arg s "$SERVER_ID" --arg d "$DEST_ID" '{id:$id,name:$n,parents:[$folder],appProperties:{server_id:$s,destination_id:$d}}')
        printf '%s' "$meta" > "$WORK/request.json"
        http POST 'https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable' "$WORK/request.json" bearer 1 'Content-Type: application/json' "X-Upload-Content-Length: $size" 'X-Upload-Content-Type: application/octet-stream' || return
        expect_http 200 201 || return
        url=$(header_value Location); [[ $url == https://www.googleapis.com/* ]] || return
        session_url_save "$url"; state_edit "$SESSION" '.id=$id' --arg id "$id"
    fi
    url=$(jq -r .url "$SESSION"); id=$(jq -r .id "$SESSION")
    [[ $url == https://www.googleapis.com/* ]] || return
    : > "$WORK/empty"
    while ((attempts<6)); do
        attempts=$((attempts+1)); refresh_token || return
        http PUT "$url" "$WORK/empty" bearer 4 "Content-Range: bytes */$size" || return
        case "$HTTP_CODE" in
            200|201) REMOTE_ID=$(jq -r .id "$HTTP_BODY"); rm -f "$SESSION"; return;;
            404|410)
                if provider_meta "$id" >/dev/null 2>&1; then REMOTE_ID="$id"; rm -f "$SESSION"; return; fi
                rm -f "$SESSION"; fail 'Google upload session expired; retry this backup to start a new session.'; return 1;;
            308) range=$(header_value Range); offset=0
                 if [[ -n $range ]]; then
                     [[ $range =~ ^bytes=0-[0-9]{1,18}$ ]] || fail 'Invalid Google upload range.' || return
                     offset=$(( ${range##*-}+1 )); ((offset<=size)) || return
                 fi;;
            *) expect_http 308; return 1;;
        esac
        while ((offset<size)); do
            end=$((offset+8388608)); ((end<=size)) || end=$size
            chunk "$f" "$offset" "$((end-offset))" || return
            if ! http PUT "$url" "$WORK/chunk" bearer 1 "Content-Range: bytes $offset-$((end-1))/$size" 'Content-Type: application/octet-stream'; then break; fi
            if [[ $HTTP_CODE == 200 || $HTTP_CODE == 201 ]]; then REMOTE_ID=$(jq -r .id "$HTTP_BODY"); rm -f "$SESSION"; return; fi
            if [[ $HTTP_CODE != 308 ]]; then break; fi
            range=$(header_value Range); [[ $range =~ ^bytes=0-[0-9]{1,18}$ ]] || return
            end=$(( ${range##*-}+1 )); ((end>offset && end<=size)) || return
            offset=$end
        done
        sleep "$((attempts*2))"
    done
    fail 'Google resumable upload failed; saved session can be retried.'
}
dropbox_upload() {
    local f="$1" name size sid offset=0 end args correct tries=0
    name=$(basename "$f"); size=$(stat -c %s "$f"); session_path "$f"
    if [[ ! -f $SESSION ]]; then
        : > "$WORK/empty"
        http POST https://content.dropboxapi.com/2/files/upload_session/start "$WORK/empty" bearer 1 'Dropbox-API-Arg: {"close":false}' 'Content-Type: application/octet-stream' || return
        expect_http 200 && json_response || return
        jq '{session_id,offset:0}' "$HTTP_BODY" | json_write "$SESSION"
    fi
    sid=$(jq -r .session_id "$SESSION"); offset=$(jq -r .offset "$SESSION")
    [[ -n $sid && $sid != null && $offset =~ ^[0-9]{1,18}$ ]] && ((offset<=size)) || fail 'Invalid Dropbox session state.' || return
    while ((offset<size && tries<6)); do
        refresh_token || return
        end=$((offset+8388608)); ((end<=size)) || end=$size
        chunk "$f" "$offset" "$((end-offset))" || return
        args=$(jq -nc --arg s "$sid" --argjson o "$offset" '{cursor:{session_id:$s,offset:$o},close:false}')
        if http POST https://content.dropboxapi.com/2/files/upload_session/append_v2 "$WORK/chunk" bearer 1 "Dropbox-API-Arg: $args" 'Content-Type: application/octet-stream' && [[ $HTTP_CODE == 200 ]]; then
            offset=$end; state_edit "$SESSION" '.offset=$o' --argjson o "$offset"
        else
            correct=$(jq -r '[..|objects|.correct_offset? // empty][0] // empty' "$HTTP_BODY" 2>/dev/null || true)
            if [[ $correct =~ ^[0-9]{1,18}$ ]] && ((correct<=size)); then offset=$correct; else sleep "$((2+tries*2))"; fi
            tries=$((tries+1))
        fi
    done
    ((offset==size)) || fail 'Dropbox upload incomplete; retry saved session.' || return
    : > "$WORK/empty"
    args=$(jq -nc --arg s "$sid" --argjson o "$size" --arg p "$(dest_value folder)/$name" '{cursor:{session_id:$s,offset:$o},commit:{path:$p,mode:"add",autorename:false,mute:true,strict_conflict:true}}')
    if http POST https://content.dropboxapi.com/2/files/upload_session/finish "$WORK/empty" bearer 1 "Dropbox-API-Arg: $args" 'Content-Type: application/octet-stream' && [[ $HTTP_CODE == 200 ]]; then
        REMOTE_ID=$(jq -r .id "$HTTP_BODY"); rm -f "$SESSION"; return
    fi
    # The finish response may be lost after a successful commit; metadata decides.
    if provider_meta "$(dest_value folder)/$name" > "$WORK/finished-meta"; then REMOTE_ID=$(jq -r .id "$WORK/finished-meta"); rm -f "$SESSION"; return; fi
    fail 'Dropbox finalization failed; older backups retained.'
}
onedrive_upload() {
    local f="$1" name size url offset end attempts=0
    name=$(basename "$f"); size=$(stat -c %s "$f"); session_path "$f"
    if [[ ! -f $SESSION ]]; then
        graph_api POST "me/drive/items/$(uri "$(dest_value folder)"):/$(uri "$name"):/createUploadSession" "$(jq -n --arg n "$name" '{item:{name:$n,"@microsoft.graph.conflictBehavior":"fail"}}')" 1 || return
        url=$(jq -r .uploadUrl "$HTTP_BODY"); url_ok "$url" || return; session_url_save "$url"
    fi
    url=$(jq -r .url "$SESSION")
    while ((attempts<6)); do
        attempts=$((attempts+1))
        http GET "$url" '' none 4 || return
        if [[ $HTTP_CODE == 404 || $HTTP_CODE == 410 ]]; then
            if graph_api GET "me/drive/items/$(uri "$(dest_value folder)"):/$(uri "$name")"; then REMOTE_ID=$(jq -r .id "$HTTP_BODY"); rm -f "$SESSION"; return; fi
            rm -f "$SESSION"; fail 'OneDrive upload session expired; retry this backup.'; return 1
        fi
        expect_http 200 && json_response || return
        offset=$(jq -r '.nextExpectedRanges[0]|split("-")[0]' "$HTTP_BODY")
        [[ $offset =~ ^[0-9]{1,18}$ ]] && ((offset<=size)) || return
        while ((offset<size)); do
            end=$((offset+10485760)); ((end<=size)) || end=$size
            chunk "$f" "$offset" "$((end-offset))" || return
            # Upload URLs carry their own authorization; do not send the Graph bearer token.
            if ! http PUT "$url" "$WORK/chunk" none 1 "Content-Range: bytes $offset-$((end-1))/$size"; then break; fi
            case "$HTTP_CODE" in
                200|201) REMOTE_ID=$(jq -r .id "$HTTP_BODY"); rm -f "$SESSION"; return;;
                202) end=$(jq -r '.nextExpectedRanges[0]|split("-")[0]' "$HTTP_BODY"); [[ $end =~ ^[0-9]{1,18}$ ]] && ((end>offset && end<=size)) || return; offset=$end;;
                *) break;;
            esac
        done
        sleep "$((attempts*2))"
    done
    fail 'OneDrive resumable upload failed; saved session can be retried.'
}
s3_abort() {
    [[ -n $CANCEL_SESSION ]] || return 0
    http DELETE "$(s3_base)/$CANCEL_SESSION" '' s3 2 || return
    if [[ $HTTP_CODE == 404 ]]; then
        xml_safe && [[ $(xml_value Code) == NoSuchUpload ]] || return
    else
        expect_http 204 200 || return
        [[ ! -s $HTTP_BODY ]] || { xml_safe && [[ $(xmlstarlet sel -t -v 'local-name(/*)' "$HTTP_BODY") != Error ]]; } || return
    fi
    [[ -z ${SESSION:-} ]] || rm -f -- "$SESSION"
}
s3_upload() {
    local f="$1" size name key query upload part=1 offset=0 end etag partsize=67108864 md5
    name=$(basename "$f"); size=$(stat -c %s "$f"); key="$(dest_value folder)/$name"; query=$(uri_path "$key")
    session_path "$f"
    if [[ -f $SESSION ]]; then
        CANCEL_SESSION=$(jq -r .abort_query "$SESSION")
        [[ $CANCEL_SESSION == "$query?uploadId="* ]] || fail 'Invalid stored S3 upload ownership.' || return
        s3_abort || fail 'Unable to abort the previous incomplete S3 upload; retry later.' || return
        CANCEL_SESSION=""
    fi
    if ((size<=67108864)); then
        md5=$(openssl dgst -md5 -binary "$f" | openssl base64 -A)
        s3_request PUT "$query" "$f" 4 'Content-Type: application/octet-stream' "Content-MD5: $md5" || return; expect_http 200 || return
    else
        # Every part >=5 MiB except the last; never exceed the 10,000-part limit.
        ((size<=partsize*9999)) || partsize=$(( ((size+9998)/9999+1048575)/1048576*1048576 ))
        ((partsize<=5368709120)) || fail 'Backup exceeds multipart limits.' || return
        s3_request POST "$query?uploads=" '' 1 'Content-Type: application/octet-stream' || return; expect_http 200 || return
        upload=$(xml_value UploadId); [[ -n $upload ]] || return
        CANCEL_SESSION="$query?uploadId=$(uri "$upload")"
        printf '%s' "$CANCEL_SESSION" | jq -Rs '{abort_query:.}' | json_write "$SESSION"
        printf '<CompleteMultipartUpload>' > "$WORK/complete.xml"
        while ((offset<size)); do
            end=$((offset+partsize)); ((end<=size)) || end=$size
            chunk "$f" "$offset" "$((end-offset))" || return
            md5=$(openssl dgst -md5 -binary "$WORK/chunk" | openssl base64 -A)
            s3_request PUT "$query?partNumber=$part&uploadId=$(uri "$upload")" "$WORK/chunk" 4 "Content-MD5: $md5" || return; expect_http 200 || return
            etag=$(header_value ETag); [[ $etag =~ ^\"[a-fA-F0-9-]+\"$ ]] || fail 'Unexpected multipart ETag.' || return
            printf '<Part><PartNumber>%s</PartNumber><ETag>%s</ETag></Part>' "$part" "$etag" >> "$WORK/complete.xml"
            part=$((part+1)); offset=$end
        done
        printf '</CompleteMultipartUpload>' >> "$WORK/complete.xml"
        s3_request POST "$query?uploadId=$(uri "$upload")" "$WORK/complete.xml" 1 'Content-Type: application/xml' || return; expect_http 200 || return
        [[ $(xmlstarlet sel -t -v 'local-name(/*)' "$HTTP_BODY") == CompleteMultipartUploadResult ]] || fail 'S3 finalization not confirmed.' || return
        CANCEL_SESSION=""; rm -f "$SESSION"
    fi
    REMOTE_ID="$key"
}
provider_upload() {
    local f="$1" name existing batchverb=put
    name=$(basename "$f"); filename_ok "$name" || return
    [[ $f != *'"'* && $f != *\\* && $f != *$'\n'* && $f != *$'\r'* ]] || return
    refresh_token || return
    # Recover a finalized object if the process stopped before recording its ID.
    if [[ $name == *.tar.gz || $name == *.tar.gz.sha256 ]]; then
        provider_list > "$WORK/upload-inventory" || return
        existing=$(jq -r --arg n "$name" '[.[]|select(.name==$n)] | if length==0 then "" elif length==1 then .[0].id else error("duplicate backup name") end' "$WORK/upload-inventory") || return
        if [[ -n $existing ]]; then
            provider_verify "$f" "$existing" >/dev/null || fail 'An existing remote object with this backup name does not match.' || return
            REMOTE_ID="$existing"; return 0
        fi
    fi
    case "$DEST_TYPE" in
        google) google_upload "$f";; dropbox) dropbox_upload "$f";; onedrive) onedrive_upload "$f";; s3) if ! s3_upload "$f"; then s3_abort || true; CANCEL_SESSION=""; return 1; fi;;
        sftp)
            sftp_settings
            # Reput resumes a private staging file. A completed file is renamed only after transfer success.
            if ssh_exec "test -f '$REMOTE_DIR/$name.partial'" >/dev/null 2>&1; then batchverb='put -a'; fi
            printf '%s "%s" "%s/%s.partial"\nrename "%s/%s.partial" "%s/%s"\n' "$batchverb" "$f" "$REMOTE_DIR" "$name" "$REMOTE_DIR" "$name" "$REMOTE_DIR" "$name" > "$WORK/sftp.batch"
            sftp_batch || fail 'SFTP upload failed; partial remote file may remain for retry.' || return
            REMOTE_ID="$name";;
        webdav)
            http PUT "$(dest_value folder)/$(uri "$name").partial" "$f" basic 4 'Content-Type: application/octet-stream' || return; expect_http 200 201 204 || return
            http MOVE "$(dest_value folder)/$(uri "$name").partial" '' basic 1 "Destination: $(dest_value folder)/$(uri "$name")" 'Overwrite: F' || return; expect_http 201 204 || return
            REMOTE_ID="$name";;
    esac
}
provider_download() {
    local id="$1" target="$2" url
    refresh_token || return
    case "$DEST_TYPE" in
        google) http GET "https://www.googleapis.com/drive/v3/files/$(uri "$id")?alt=media" '' bearer 4 || return; expect_http 200 || return; mv "$HTTP_BODY" "$target";;
        dropbox) http POST https://content.dropboxapi.com/2/files/download '' bearer 4 "Dropbox-API-Arg: $(jq -nc --arg p "$id" '{path:$p}')" || return; expect_http 200 || return; mv "$HTTP_BODY" "$target";;
        onedrive)
            graph_api GET "me/drive/items/$(uri "$id")" || return
            url=$(jq -r '.["@microsoft.graph.downloadUrl"]' "$HTTP_BODY")
            http GET "$url" '' none 4 || return; expect_http 200 || return; mv "$HTTP_BODY" "$target";;
        s3) [[ $id == "$(dest_value folder)/"* ]] || return; http GET "$(s3_base)/$(uri_path "$id")" '' s3 4 || return; expect_http 200 || return; mv "$HTTP_BODY" "$target";;
        sftp) filename_ok "$id" || return; sftp_settings; printf 'get "%s/%s" "%s"\n' "$REMOTE_DIR" "$id" "$target" > "$WORK/sftp.batch"; sftp_batch;;
        webdav) filename_ok "$id" || return; http GET "$(dest_value folder)/$(uri "$id")" '' basic 4 || return; expect_http 200 || return; mv "$HTTP_BODY" "$target";;
    esac
}
provider_test() {
    local f="$WORK/ab-test-$(openssl rand -hex 8).txt" id
    printf 'Automate Backups connection test %s\n' "$(now)" > "$f"
    provider_init || return
    provider_upload "$f" || return; id="$REMOTE_ID"
    if ! provider_verify "$f" "$id" >/dev/null; then log ERROR 'Test object verification failed; it was left for inspection.'; return 1; fi
    provider_download "$id" "$WORK/test-download" || return
    cmp -s "$f" "$WORK/test-download" || fail 'Connection test download differs from original.' || return
    provider_list >/dev/null || return
    provider_delete "$id" || fail 'Connection test deletion failed.' || return
    state_edit "$DEST_FILE" '.tested=true | .tested_at=$t' --arg t "$(now)"; DEST=$(cat "$DEST_FILE")
    log VERIFY "$DEST_NAME: authentication, folder, upload, metadata, download, listing, and delete passed."
}

# Retention is ledger-driven. No glob, age heuristic, or arbitrary remote file is
# ever a deletion candidate. Unknown/corrupt state disables cleanup.
ledger_validate() {
    local f
    for f in "$STATE"/records/*.json; do
        [[ -f $f ]] || continue
        secret_ok "$f" && jq -e --arg server "$SERVER_ID" '
          .server_id==$server and (.id|test("^[a-f0-9]{32}$")) and
          (.filename|test("^[A-Za-z0-9][A-Za-z0-9._-]*\\.tar\\.gz$")) and
          (.sha256|test("^[a-f0-9]{64}$")) and (.size|type=="number" and .>=0) and
          (.status|IN("PENDING","FAILED","SUCCESS")) and (.remote|type=="object") and
          (.started|test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T"))' "$f" >/dev/null || fail 'State damaged: retention skipped; no backups deleted.' || return
    done
}
retention_candidates() {
    local type="$1" keep="$2" dest="${3:-}" f
    : > "$WORK/ledger.ndjson"
    for f in "$STATE"/records/*.json; do [[ ! -f $f ]] || cat "$f" >> "$WORK/ledger.ndjson"; done
    jq -sr --arg t "$type" --arg d "$dest" --argjson k "$keep" '
      map(select(.status=="SUCCESS" and (if $t=="local" then .local=="VERIFIED" else .remote[$d].status=="VERIFIED" end))) |
      sort_by(.started,.id)|reverse|.[$k:][]|.id' "$WORK/ledger.ndjson"
}
local_retention() {
    local id f path
    ledger_validate || return
    retention_candidates local "$LOCAL_KEEP" > "$WORK/local-prune" || return
    # Validate every candidate before deleting any. Protect moved paths and tampered symlinks.
    while IFS= read -r id; do
        f="$STATE/records/$id.json"; path=$(jq -r .path "$f")
        [[ $path == "$BACKUP_DIR/$(jq -r .filename "$f")" && -f $path && -f $path.sha256 && ! -L $path && ! -L $path.sha256 ]] || fail 'Local retention metadata inconsistent; nothing deleted.' || return
        if ((LOCAL_KEEP==0)); then
            jq -e '.remote|length>0 and all(.[]; .status=="VERIFIED" or .status=="PRUNED")' "$f" >/dev/null || fail 'Zero local retention requires verified remote backups.' || return
        fi
    done < "$WORK/local-prune"
    while IFS= read -r id; do
        f="$STATE/records/$id.json"; path=$(jq -r .path "$f")
        rm -- "$path" "$path.sha256" || return
        state_edit "$f" '.local="PRUNED"' || return
        log RETENTION "Removed owned local backup set $id."
    done < "$WORK/local-prune"
}
remote_retention() {
    local id f archive check size aid cid keep listing="$WORK/retention-list.json"
    ledger_validate || return
    keep=$(jq -r .keep <<< "$DEST")
    provider_list > "$listing" || fail 'Remote listing failed: retention skipped.' || return
    retention_candidates remote "$keep" "$DEST_ID" > "$WORK/remote-prune" || return
    # Listing must contain exactly one copy of BOTH recorded objects of each set.
    while IFS= read -r id; do
        f="$STATE/records/$id.json"
        archive=$(jq -c --arg d "$DEST_ID" '.remote[$d].archive' "$f"); check=$(jq -c --arg d "$DEST_ID" '.remote[$d].checksum' "$f")
        jq -e --argjson a "$archive" --argjson c "$check" '
          ([.[]|select(.id==$a.id and .name==$a.name and .size==$a.size)]|length)==1 and
          ([.[]|select(.id==$c.id and .name==$c.name and .size==$c.size)]|length)==1' "$listing" >/dev/null || fail 'Remote metadata inconsistent: retention skipped.' || return
    done < "$WORK/remote-prune"
    while IFS= read -r id; do
        f="$STATE/records/$id.json"
        aid=$(jq -r --arg d "$DEST_ID" '.remote[$d].archive.id' "$f"); cid=$(jq -r --arg d "$DEST_ID" '.remote[$d].checksum.id' "$f")
        # Two-object deletion cannot be transactional on these providers. Record
        # intent first; an interrupted deletion is quarantined from future pruning.
        state_edit "$f" '.remote[$d].status="PRUNING"' --arg d "$DEST_ID" || return
        provider_delete "$aid" && provider_delete "$cid" || fail 'Retention delete incomplete; set quarantined for manual review.' || return
        state_edit "$f" '.remote[$d].status="PRUNED"' --arg d "$DEST_ID" || return
        log RETENTION "Removed owned remote backup set $id from $DEST_NAME."
    done < "$WORK/remote-prune"
}
transfer_backup() {
    local f meta aid cid p count=0 needed
    for f in "$ETC"/providers/*.conf; do
        [[ -f $f ]] || continue; count=$((count+1))
        load_dest "$f" || return
        [[ $(jq -r .tested <<< "$DEST") == true ]] || fail "Destination $DEST_NAME has not passed its connection test." || return
        needed=4096
        aid=$(jq -r --arg d "$DEST_ID" '.remote[$d].archive_id // empty' "$RECORD")
        [[ -n $aid ]] || needed=$(( $(stat -c %s "$ARCHIVE") + 4096 ))
        provider_quota "$needed" || return
        log UPLOAD "Uploading to $DEST_NAME ($DEST_TYPE)."
        aid=$(jq -r --arg d "$DEST_ID" '.remote[$d].archive_id // empty' "$RECORD")
        if [[ -z $aid ]]; then
            provider_upload "$ARCHIVE" || return; aid="$REMOTE_ID"
            state_edit "$RECORD" '.remote[$d]={name:$n,type:$t,status:"PENDING",archive_id:$a}' --arg d "$DEST_ID" --arg n "$DEST_NAME" --arg t "$DEST_TYPE" --arg a "$aid" || return
        fi
        meta=$(provider_verify "$ARCHIVE" "$aid") || return
        state_edit "$RECORD" '.remote[$d].archive=$m' --arg d "$DEST_ID" --argjson m "$meta" || return
        cid=$(jq -r --arg d "$DEST_ID" '.remote[$d].checksum_id // empty' "$RECORD")
        if [[ -z $cid ]]; then
            provider_upload "$ARCHIVE.sha256" || return; cid="$REMOTE_ID"
            state_edit "$RECORD" '.remote[$d].checksum_id=$c' --arg d "$DEST_ID" --arg c "$cid" || return
        fi
        meta=$(provider_verify "$ARCHIVE.sha256" "$cid") || return
        provider_download "$cid" "$WORK/remote-checksum" || return
        cmp -s "$ARCHIVE.sha256" "$WORK/remote-checksum" || fail 'Remote checksum sidecar content differs.' || return
        state_edit "$RECORD" '.remote[$d].checksum=$m | .remote[$d].status="VERIFIED"' --arg d "$DEST_ID" --argjson m "$meta" || return
        log VERIFY "$DEST_NAME: finalized archive and checksum verified."
    done
    ((LOCAL_KEEP>0 || count>0)) || fail 'Local retention zero is unsafe without a remote destination.' || return
    state_edit "$RECORD" '.status="SUCCESS" | .error=null | .ended=$t' --arg t "$(now)" || return
    RUN_OK=1
    # No retention runs until the entire configured destination set is verified.
    for f in "$ETC"/providers/*.conf; do
        [[ -f $f ]] || continue; load_dest "$f" || return
        if remote_retention; then p=PASS; else p=SKIPPED; log WARN "Remote retention skipped/failed for $DEST_NAME; backup remains successful."; fi
        state_edit "$RECORD" '.retention[$d]=$p' --arg d "$DEST_ID" --arg p "$p" || return
    done
    if local_retention; then p=PASS; else p=SKIPPED; log WARN 'Local retention skipped/failed; backup remains successful.'; fi
    state_edit "$RECORD" '.retention.local=$p' --arg p "$p"
    log BACKUP "SUCCESS — backup ID $RUN_ID"
}
run_backup() {
    load_config || return
    if ((LOCKED==0)); then lock backup || return; fi
    new_work; rotate_log
    RUN_ID=$(openssl rand -hex 16); STARTED=$(now); RECORD="$STATE/records/$RUN_ID.json"; RUN_OK=0
    jq -n --arg id "$RUN_ID" --arg s "$SERVER_ID" --arg t "$STARTED" '{id:$id,server_id:$s,started:$t,filename:"pending.tar.gz",path:"",sha256:("0"*64),size:0,status:"PENDING",local:"NONE",remote:{},retention:{}}' | json_write "$RECORD"
    if ! archive_create; then
        state_edit "$RECORD" '.status="FAILED"|.ended=$t|.error="Local backup creation failed; see logs"' --arg t "$(now)"
        return 1
    fi
    if ! transfer_backup; then
        ((RUN_OK==0)) || return 1
        state_edit "$RECORD" '.status="FAILED"|.ended=$t|.error="Remote transfer failed; valid local backup retained"' --arg t "$(now)"
        return 1
    fi
}
retry_backup() {
    local id="$1"
    [[ $id =~ ^[a-f0-9]{32}$ ]] || fail 'Use a backup ID from list.' || return
    load_config; lock retry; new_work
    RECORD="$STATE/records/$id.json"; secret_ok "$RECORD" || return
    [[ $(jq -r .server_id "$RECORD") == "$SERVER_ID" ]] || return
    ARCHIVE=$(jq -r .path "$RECORD"); ARCHIVE_NAME=$(jq -r .filename "$RECORD"); RUN_ID="$id"; RUN_OK=0
    [[ $ARCHIVE == "$BACKUP_DIR/$ARCHIVE_NAME" ]] && verify_local "$ARCHIVE" || return
    transfer_backup
}
destination_wizard() {
    local choice name type id file key host port known endpoint
    printf '\nDestinations:\n1 Local only\n2 Google Drive\n3 Dropbox\n4 Microsoft OneDrive\n5 Amazon S3\n6 S3-compatible storage\n7 SFTP / Remote Linux\n8 HTTPS WebDAV\n'
    ask 'Destination' 1; choice="$ANSWER"
    case "$choice" in 1) return 0;; 2) type=google;; 3) type=dropbox;; 4) type=onedrive;; 5|6) type=s3;; 7) type=sftp;; 8) type=webdav;; *) return 1;; esac
    ask 'Unique destination name (lowercase letters, digits, - or _)' "$type"; name="$ANSWER"; ident "$name" || fail 'Invalid destination name.' || return
    [[ ! -e $ETC/providers/$name.conf ]] || fail 'That destination already exists; use reauthorize or remove it first.' || return
    id=$(openssl rand -hex 16); file="$ETC/providers/$name.pending"
    jq -n --arg n "$name" --arg t "$type" --arg i "$id" '{format:1,name:$n,type:$t,id:$i,keep:6,tested:false}' | json_write "$file"
    DEST_FILE="$file"; DEST=$(cat "$file"); DEST_TYPE="$type"; DEST_NAME="$name"; DEST_ID="$id"
    case "$type" in
        google|dropbox|onedrive) provider_auth || return;;
        s3)
            if ! have xmlstarlet; then install_packages xmlstarlet || return; fi
            ask 'Bucket name'; dest_put bucket "$ANSWER"
            ask 'Signing region' us-east-1; dest_put region "$ANSWER"
            endpoint="https://s3.$(dest_value region).amazonaws.com"; [[ $choice == 5 ]] || endpoint=''
            ask 'HTTPS S3 endpoint (hostname only, without bucket/path)' "$endpoint"; dest_put endpoint "${ANSWER%/}"
            ask 'Access key ID' '' 1; dest_put access_key "$ANSWER"
            ask 'Secret access key' '' 1; dest_put secret_key "$ANSWER"
            ask 'Session token (blank if not used; temporary credentials must be renewed manually)' '' 1; dest_put session_token "$ANSWER";;
        sftp)
            have ssh && have sftp && have ssh-keyscan && have ssh-keygen || fail 'Install openssh-client/openssh-clients before configuring SFTP.' || return
            ask 'Remote DNS hostname or IPv4 address'; host="$ANSWER"; dest_put host "$host"
            ask 'SSH port' 22; port="$ANSWER"; dest_put port "$port"
            ask 'SSH username'; dest_put username "$ANSWER"
            ask 'Existing private SSH key path (unattended access, mode 0600)'; key="$ANSWER"; dest_put key "$key"
            ask 'Existing remote base directory' /backups; dest_put directory "${ANSWER%/}"
            dest_validate "$file" || fail 'Invalid SFTP settings.' || return
            known="$ETC/providers/$name.known_hosts"
            ssh-keyscan -T 10 -p "$port" "$host" > "$WORK/known_hosts" 2>/dev/null || return
            [[ -s $WORK/known_hosts ]] || return
            ssh-keygen -lf "$WORK/known_hosts"
            yes 'Have you independently compared these SSH fingerprints with your remote server/provider console?' 2 || return 1
            cat "$WORK/known_hosts" | atom "$known";;
        webdav)
            if ! have xmlstarlet; then install_packages xmlstarlet || return; fi
            ask 'Existing HTTPS WebDAV collection URL'; dest_put endpoint "${ANSWER%/}"
            ask 'WebDAV username'; dest_put username "$ANSWER"
            ask 'WebDAV password/application password' '' 1; dest_put password "$ANSWER";;
    esac
    ask 'Successful backups to retain on this destination' 6
    uint "$ANSWER" && ((ANSWER>0)) || fail 'Remote retention must be at least 1.' || return
    state_edit "$file" '.keep=$k' --argjson k "$ANSWER"; DEST=$(cat "$file")
    dest_validate "$file" || fail 'Destination configuration is invalid.' || return
    provider_test || { log ERROR 'Destination was not activated. Its pending credential file can be removed or reviewed.'; return 1; }
    mv "$file" "$ETC/providers/$name.conf"; DEST_FILE="$ETC/providers/$name.conf"
}

systemd_live() { [[ -z $PREFIX && -d /run/systemd/system ]] && have systemctl; }
calendar_expression() {
    local mode time tz days day
    mode=$(jq -r .schedule.mode <<< "$CONFIG"); time=$(jq -r .schedule.time <<< "$CONFIG"); tz=$(jq -r .schedule.timezone <<< "$CONFIG")
    case "$mode" in
        daily|interval) printf '*-*-* %s:00 %s\n' "$time" "$tz";;
        weekly|weekdays)
            days=$(jq -r '.schedule.days|map(["","Mon","Tue","Wed","Thu","Fri","Sat","Sun"][.])|join(",")' <<< "$CONFIG")
            printf '%s *-*-* %s:00 %s\n' "$days" "$time" "$tz";;
        monthly) day=$(jq -r .schedule.monthday <<< "$CONFIG"); printf '*-*-%02d %s:00 %s\n' "$day" "$time" "$tz";;
        custom) printf '%s %s\n' "$(jq -r .schedule.calendar <<< "$CONFIG")" "$tz";;
    esac
}
schedule_wizard() {
    local mode n time tz days=7 monthday=1 every=1 cal='' detected
    printf '\nSchedule: 1 Daily / 2 Every N days / 3 Weekly / 4 Selected weekdays / 5 Monthly / 6 Custom systemd calendar / 7 Disabled\n'
    ask 'Frequency' 1
    case "$ANSWER" in
        1) mode=daily;;
        2) mode=interval; ask 'Every how many calendar days (1-365)' 2; every="$ANSWER"; uint "$every" && ((every>0 && every<=365)) || return;;
        3) mode=weekly; ask 'Weekday (Monday=1 ... Sunday=7)' 7; days="$ANSWER";;
        4) mode=weekdays; ask 'Weekdays separated by commas (Monday=1 ... Sunday=7)' '1,3,5'; days="$ANSWER";;
        5) mode=monthly; ask 'Day of month (1-28)' 1; monthday="$ANSWER"; uint "$monthday" && ((monthday>0 && monthday<=28)) || return;;
        6) systemd_live || fail 'Custom calendars require a running systemd host.' || return; mode=custom; ask 'OnCalendar expression WITHOUT timezone (the selected timezone is appended)' '*-*-* 02:00:00'; cal="$ANSWER";;
        7) CONFIG=$(jq '.schedule.enabled=false' <<< "$CONFIG"); return;;
        *) return 1;;
    esac
    [[ $days =~ ^[1-7](,[1-7])*$ ]] || fail 'Invalid weekday list.' || return
    ask 'Backup time (24-hour HH:MM)' '02:00'; time="$ANSWER"; [[ $time =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || return
    detected=$(timedatectl show -p Timezone --value 2>/dev/null || true); [[ -n $detected ]] || detected=$(cat /etc/timezone 2>/dev/null || printf UTC)
    printf 'Detected server timezone: %s\n' "$detected"
    ask 'Timezone: 1 Server timezone / 2 Asia/Kolkata / 3 Enter another' 1
    case "$ANSWER" in 1) tz="$detected";; 2) tz=Asia/Kolkata;; 3) ask 'IANA timezone' UTC; tz="$ANSWER";; *) return 1;; esac
    timezone_ok "$tz" || fail 'Timezone not installed; install tzdata or choose an available zone.' || return
    CONFIG=$(jq --arg m "$mode" --arg t "$time" --arg z "$tz" --arg c "$cal" --arg a "$(TZ="$tz" date +%F)" --argjson d "[$days]" --argjson day "$monthday" --argjson e "$every" \
      '.schedule={enabled:true,mode:$m,time:$t,timezone:$z,days:$d,monthday:$day,every:$e,anchor:$a,calendar:$c}' <<< "$CONFIG")
    if systemd_live; then systemd-analyze calendar "$(calendar_expression)" >/dev/null || fail 'Invalid systemd calendar.'; fi
}
date_matches() {
    local date="$1" weekday="$2" day="$3" mode anchor current every
    mode=$(jq -r .schedule.mode <<< "$CONFIG")
    case "$mode" in
        daily) return 0;;
        weekly|weekdays) jq -e --argjson d "$weekday" '.schedule.days|index($d)!=null' <<< "$CONFIG" >/dev/null;;
        monthly) (( 10#$day == $(jq -r .schedule.monthday <<< "$CONFIG") ));;
        interval)
            anchor=$(date -u -d "$(jq -r .schedule.anchor <<< "$CONFIG")" +%s); current=$(date -u -d "$date" +%s); every=$(jq -r .schedule.every <<< "$CONFIG")
            ((current>=anchor && ((current-anchor)/86400)%every==0));;
        custom) return 0;;
    esac
}
schedule_tick() {
    local force="${1:-}" tz today weekday day minute slot marker
    load_config || return; [[ $(jq -r .schedule.enabled <<< "$CONFIG") == true ]] || return 0
    tz=$(jq -r .schedule.timezone <<< "$CONFIG")
    read -r today weekday day minute < <(TZ="$tz" date '+%F %u %d %H:%M')
    if [[ $force != --systemd ]]; then [[ $minute == "$(jq -r .schedule.time <<< "$CONFIG")" ]] || return 0; fi
    date_matches "$today" "$weekday" "$day" || return 0
    slot="$today $(jq -r .schedule.time <<< "$CONFIG") $tz"
    [[ $(jq -r .schedule.mode <<< "$CONFIG") != custom ]] || slot="$today $minute $tz"
    lock scheduled || return
    marker="$STATE/last-slot"; [[ ! -f $marker || $(cat "$marker") != "$slot" ]] || return 0
    printf '%s\n' "$slot" | atom "$marker"
    run_backup
}
cron_remove() {
    have crontab || return 0
    crontab -l > "$WORK/crontab.current" 2>/dev/null || : > "$WORK/crontab.current"
    sed '/^# BEGIN AUTOMATE-BACKUPS$/,/^# END AUTOMATE-BACKUPS$/d' "$WORK/crontab.current" > "$WORK/crontab.next"
    cmp -s "$WORK/crontab.current" "$WORK/crontab.next" || crontab "$WORK/crontab.next"
}
schedule_apply() {
    local enabled calendar
    enabled=$(jq -r .schedule.enabled <<< "$CONFIG"); new_work
    if [[ -n $PREFIX ]]; then mkdir -p "$UNITDIR"; fi
    if systemd_live || [[ -n $PREFIX ]]; then
        calendar=$(calendar_expression)
        if systemd_live; then systemd-analyze calendar "$calendar" >/dev/null || return; fi
        mkdir -p "$UNITDIR"
        cat <<EOF | atom "$UNITDIR/automate-backups.service"
[Unit]
Description=Automate Backups
Wants=network-online.target
After=network-online.target
[Service]
Type=oneshot
ExecStart=$BIN tick --systemd
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7
UMask=0077
TimeoutStartSec=infinity
TimeoutStopSec=120
KillMode=control-group
EOF
        cat <<EOF | atom "$UNITDIR/automate-backups.timer"
[Unit]
Description=Automate Backups schedule
[Timer]
OnCalendar=$calendar
Persistent=true
AccuracySec=1min
Unit=automate-backups.service
[Install]
WantedBy=timers.target
EOF
        if systemd_live; then
            systemctl daemon-reload || return
            if [[ $enabled == true ]]; then systemctl enable --now automate-backups.timer || return; else systemctl disable --now automate-backups.timer || return; fi
            cron_remove || return
        fi
    else
        if ! have crontab; then
            [[ $enabled != false ]] || return 0
            fail 'No scheduler available. Install and start cron, or disable the schedule.'; return 1
        fi
        [[ $(jq -r .schedule.mode <<< "$CONFIG") != custom ]] || fail 'Custom calendars require systemd.' || return
        cron_remove || return
        if [[ $enabled == true ]]; then
            crontab -l > "$WORK/crontab.next" 2>/dev/null || : > "$WORK/crontab.next"
            printf '\n# BEGIN AUTOMATE-BACKUPS\n* * * * * %s tick >/dev/null 2>&1\n# END AUTOMATE-BACKUPS\n' "$BIN" >> "$WORK/crontab.next"
            crontab "$WORK/crontab.next" || return
            log INFO 'Cron dispatcher installed. Ensure your distribution cron/crond service is enabled; doctor reports service availability.'
        fi
    fi
}
next_backup() {
    local tz i date day weekday candidate start nowepoch
    [[ $(jq -r .schedule.enabled <<< "$CONFIG") == true ]] || { printf 'Disabled\n'; return; }
    if [[ $(jq -r .schedule.mode <<< "$CONFIG") == custom ]]; then
        systemd-analyze calendar "$(calendar_expression)" 2>/dev/null | sed -n 's/.*Next elapse: /Next custom occurrence: /p'; return
    fi
    tz=$(jq -r .schedule.timezone <<< "$CONFIG"); start=$(TZ="$tz" date +%F); nowepoch=$(date +%s)
    for ((i=0;i<370;i++)); do
        read -r date weekday day < <(date -u -d "$start +$i days" '+%F %u %d')
        date_matches "$date" "$weekday" "$day" || continue
        candidate=$(TZ="$tz" date -d "$date $(jq -r .schedule.time <<< "$CONFIG")" +%s 2>/dev/null) || continue
        ((candidate>nowepoch)) || continue
        TZ="$tz" date -d "@$candidate" "+%d %b %Y %H:%M $tz"; return
    done
    printf 'Could not resolve next occurrence\n'
}
retention_wizard() {
    local f val count=0
    ask 'Successful backups to retain locally (0 requires verified remote copies)' "$(jq -r .local_keep <<< "$CONFIG")"; val="$ANSWER"; uint "$val" || return
    for f in "$ETC"/providers/*.conf; do [[ ! -f $f ]] || count=$((count+1)); done
    ((val>0 || count>0)) || fail 'Local-only backups require local retention >=1.' || return
    CONFIG=$(jq --argjson k "$val" '.local_keep=$k' <<< "$CONFIG")
    for f in "$ETC"/providers/*.conf; do
        [[ -f $f ]] || continue
        ask "Successful backups to retain on $(jq -r .name "$f")" "$(jq -r .keep "$f")"
        uint "$ANSWER" && ((ANSWER>0)) || return
        state_edit "$f" '.keep=$k' --argjson k "$ANSWER"
    done
}
default_config() {
    jq -n --arg b "$DEFAULT_BACKUPS" --arg a "$(date -u +%F)" '{format:1,sources:[],databases:{},backup_dir:$b,local_keep:2,bandwidth_kib:0,reserve_mib:512,schedule:{enabled:true,mode:"daily",time:"02:00",timezone:"UTC",days:[7],monthday:1,every:1,anchor:$a,calendar:""}}'
}
rollback_install() {
    log WARN 'Restoring installation files from the pre-install snapshot.'
    local x
    [[ -z ${OLD_ETC:-} || ! -d $OLD_ETC ]] || { rm -rf -- "$LIVE_ETC"; mv -- "$OLD_ETC" "$LIVE_ETC"; }
    if [[ ${HAD_ETC:-1} == 0 && -z ${OLD_ETC:-} ]]; then rm -rf -- "$LIVE_ETC"; fi
    for x in binary service timer; do
        local target
        case "$x" in binary) target="$BIN";; service) target="$UNITDIR/automate-backups.service";; timer) target="$UNITDIR/automate-backups.timer";; esac
        if [[ -f $ROLLBACK/$x ]]; then cp -p "$ROLLBACK/$x" "$target"; else rm -f "$target"; fi
    done
    if systemd_live; then
        systemctl daemon-reload || true
        if [[ ${WAS_ENABLED:-false} == true ]]; then systemctl enable --now automate-backups.timer || true; else systemctl disable --now automate-backups.timer >/dev/null 2>&1 || true; fi
    elif [[ -z $PREFIX && -f $ROLLBACK/crontab ]]; then crontab "$ROLLBACK/crontab" || true; fi
    INSTALL_PENDING=0
}
install_project() {
    root_required; dependencies; layout; lock setup; new_work
    local choice draft live_conf source first=2
    if [[ -f $CONF ]]; then
        printf '\nAutomate Backups already configured.\n1 Reconfigure\n2 Repair installation\n3 Add destination\n4 Change schedule\n5 Run backup now\n6 Exit\n'
        ask 'Action' 1; choice="$ANSWER"
        case "$choice" in 3) load_config; destination_wizard; return;; 4) config_change schedule; return;; 5) run_backup; return;; 6) return;; 1|2) :;; *) return 1;; esac
        load_config
    else choice=1; CONFIG=$(default_config); fi
    LIVE_ETC="$ETC"; live_conf="$CONF"; draft="$WORK/config-draft"; mkdir "$draft"; cp -a "$ETC/." "$draft/"
    ETC="$draft"; CONF="$ETC/config.conf"; mkdir -p "$ETC/providers"
    if [[ $choice == 1 ]]; then
        printf '\nAutomate Backups %s Setup\nOS: ' "$VERSION"; sed -n 's/^PRETTY_NAME=//p' /etc/os-release 2>/dev/null || true
        printf 'Hostname: %s\nPackage manager: %s\n' "$(hostname)" "$(package_manager)"
        source_wizard || return; database_wizard || return
        ask 'Local backup directory' "$(jq -r .backup_dir <<< "$CONFIG")"; CONFIG=$(jq --arg b "${ANSWER%/}" '.backup_dir=$b' <<< "$CONFIG")
        destination_wizard || return
        retention_wizard || return; schedule_wizard || return
        ask 'Upload bandwidth in KiB/s (0 = unlimited)' "$(jq -r .bandwidth_kib <<< "$CONFIG")"; uint "$ANSWER" || return
        CONFIG=$(jq --argjson b "$ANSWER" '.bandwidth_kib=$b' <<< "$CONFIG")
        if yes 'Run the first backup now, before activating the schedule?' 1; then first=1; fi
    fi
    printf '%s\n' "$CONFIG" | json_write "$CONF"; config_validate "$CONF" || return
    local f
    for f in "$ETC"/providers/*.conf; do [[ -f $f ]] || continue; load_dest "$f" || return; [[ $(jq -r .tested <<< "$DEST") == true ]] || fail 'Untested destination; setup not activated.' || return; done
    source="$SELF"
    if [[ ! -f $source ]]; then
        source="$WORK/setup-source.sh"
        curl -q --proto '=https' --tlsv1.2 -fsS 'https://raw.githubusercontent.com/iamsahildhamija/automate-backups/main/setup.sh' -o "$source" || fail 'Could not retrieve installable source. Use the inspect-before-running installation method.' || return
    fi
    bash -n "$source" || return
    ROLLBACK=$(mktemp -d "$WORK/install-rollback.XXXXXX")
    [[ ! -f $BIN ]] || cp -p "$BIN" "$ROLLBACK/binary"
    [[ ! -f $UNITDIR/automate-backups.service ]] || cp -p "$UNITDIR/automate-backups.service" "$ROLLBACK/service"
    [[ ! -f $UNITDIR/automate-backups.timer ]] || cp -p "$UNITDIR/automate-backups.timer" "$ROLLBACK/timer"
    WAS_ENABLED=false
    if systemd_live; then systemctl is-enabled --quiet automate-backups.timer 2>/dev/null && WAS_ENABLED=true; elif [[ -z $PREFIX ]] && have crontab; then crontab -l > "$ROLLBACK/crontab" 2>/dev/null || : > "$ROLLBACK/crontab"; fi
    OLD_ETC="$LIVE_ETC.previous.$$"; INSTALL_PENDING=1
    mv "$LIVE_ETC" "$OLD_ETC"; mv "$draft" "$LIVE_ETC"; ETC="$LIVE_ETC"; CONF="$live_conf"
    mkdir -p "$(dirname "$BIN")"
    install -m 0755 "$source" "$BIN.new" && mv "$BIN.new" "$BIN" || return
    load_config || return
    if [[ $first == 1 ]]; then
        run_backup || { log ERROR 'First backup failed; installation/configuration will roll back. Existing backups remain.'; return 1; }
    fi
    schedule_apply || return
    INSTALL_PENDING=0; rm -rf -- "$OLD_ETC"; OLD_ETC=""
    log INFO 'Automate Backups configured successfully.'
    status_command
}
config_change() {
    local action="$1" draft stage oldconfig
    new_work; load_config || return; oldconfig="$CONFIG"
    CONFIG_LIVE="$ETC"; CONFIG_OLD="$ETC.previous.$$"
    draft=$(mktemp -d "$WORK/change.XXXXXX"); cp -a "$ETC/." "$draft/"
    ETC="$draft"; CONF="$ETC/config.conf"
    case "$action" in
        schedule) schedule_wizard || return;;
        retention) retention_wizard || return;;
        config)
            printf '1 Sources and databases\n2 Backup directory and bandwidth\n3 Schedule\n4 Retention\n'
            ask 'Setting' 1
            case "$ANSWER" in
                1) source_wizard || return; database_wizard || return;;
                2) ask 'Backup directory' "$BACKUP_DIR"; CONFIG=$(jq --arg p "${ANSWER%/}" '.backup_dir=$p' <<< "$CONFIG"); ask 'Bandwidth in KiB/s' "$BANDWIDTH"; uint "$ANSWER" || return; CONFIG=$(jq --argjson b "$ANSWER" '.bandwidth_kib=$b' <<< "$CONFIG");;
                3) schedule_wizard || return;; 4) retention_wizard || return;; *) return 1;;
            esac;;
    esac
    printf '%s' "$CONFIG" | json_write "$CONF"; config_validate "$CONF" || return
    mv "$CONFIG_LIVE" "$CONFIG_OLD"; CONFIG_PENDING=1
    mv "$draft" "$CONFIG_LIVE"; ETC="$CONFIG_LIVE"; CONF="$ETC/config.conf"
    if ! schedule_apply; then
        rm -rf -- "$ETC"; mv "$CONFIG_OLD" "$ETC"; CONFIG_PENDING=0
        CONFIG="$oldconfig"; schedule_apply || true; return 1
    fi
    CONFIG_PENDING=0; rm -rf -- "$CONFIG_OLD"
    log INFO 'Configuration updated.'
}

records_array() {
    local f; for f in "$STATE"/records/*.json; do [[ ! -f $f ]] || cat "$f"; done | jq -s 'sort_by(.started)'
}
status_command() {
    load_config || return
    printf 'Automate Backups %s\nServer ID: %s\nLocal directory: %s\nLocal retention: %s\n' "$VERSION" "$SERVER_ID" "$BACKUP_DIR" "$LOCAL_KEEP"
    jq '.schedule' <<< "$CONFIG"
    records_array | jq 'last // {} | {id,status,started,ended,size,local,remote,retention,error}'
    printf 'Next backup: '; next_backup
    if systemd_live; then systemctl list-timers automate-backups.timer --no-pager; fi
}
doctor_command() {
    local c f bad=0
    printf 'Automate Backups %s\nOS: ' "$VERSION"; sed -n 's/^PRETTY_NAME=//p' /etc/os-release || true
    printf 'Package manager: %s\nInit: ' "$(package_manager)"; cat /proc/1/comm
    printf '\nRequired binaries:\n'
    for c in bash curl jq tar gzip sha256sum openssl flock realpath stat du df dd timeout find; do if have "$c"; then printf 'PASS %s\n' "$c"; else printf 'MISSING %s\n' "$c"; bad=1; fi; done
    if load_config; then printf 'Configuration: PASS\n'; else bad=1; fi
    discover; cat "$WORK/discovered.tsv"
    printf '\nNative database/mail clients:\n'
    for c in mariadb mysql mariadb-dump mysqldump psql pg_dump pg_dumpall mongodump mongosh postconf doveconf exim docker; do have "$c" && printf '%s: %s\n' "$c" "$(command -v "$c")"; done
    [[ -z ${BACKUP_DIR:-} ]] || df -h "$BACKUP_DIR" "$STATE"
    for f in "$ETC"/providers/*.conf; do
        [[ -f $f ]] || continue
        if load_dest "$f"; then
            jq '{name,type,tested,tested_at,expires_at,keep,refresh_token_present:((.refresh_token // "")!="")}' "$f"
            if [[ $DEST_TYPE =~ ^(google|dropbox|onedrive)$ ]] && (( $(jq -r '.expires_at // 0' "$f") <= $(date +%s)+120 )); then
                log WARN 'Access token expired/near expiry; doctor does not rotate credentials. Run destination test to check refresh.'
            else (refresh_token() { return 0; }; provider_quota 0) || bad=1; fi
        else bad=1; fi
    done
    if systemd_live; then systemctl status automate-backups.timer --no-pager || true
    elif have crontab; then crontab -l 2>/dev/null | sed -n '/^# BEGIN AUTOMATE-BACKUPS$/,/^# END AUTOMATE-BACKUPS$/p'; pgrep -x 'cron|crond' >/dev/null || log WARN 'No running cron/crond process found.'
    else log WARN 'No scheduler installed.'; fi
    records_array | jq 'last // {} | {id,status,ended,local,retention}'
    return "$bad"
}
download_command() {
    local id="$1" dest_name="${2:-}" output="${3:-$PWD}" file aid cid found=0 name need free
    [[ $id =~ ^[a-f0-9]{32}$ ]] || fail 'Use a recorded backup ID.' || return
    RECORD=""; file="$STATE/records/$id.json"; secret_ok "$file" || return
    [[ $(jq -r .server_id "$file") == "$SERVER_ID" ]] || return
    name=$(jq -r .filename "$file"); filename_ok "$name" || return
    [[ -d $output && ! -L $output && $output != *$'\n'* && $output != *'"'* ]] || return
    [[ ! -e $output/$name && ! -e $output/$name.sha256 ]] || fail 'Output files already exist; refusing overwrite.' || return
    need=$(( $(jq -r .size "$file") + 134217728 ))
    for f in "$STATE" "$output"; do
        free=$(df -PB1 "$f" | awk 'NR==2{print $4}')
        ((free>need)) || fail 'Insufficient space to download and validate this backup.' || return
    done
    local f
    for f in "$ETC"/providers/*.conf; do
        [[ -f $f ]] || continue; load_dest "$f" || return
        [[ -z $dest_name || $DEST_NAME == "$dest_name" ]] || continue
        [[ $(jq -r --arg d "$DEST_ID" '.remote[$d].status // ""' "$file") == VERIFIED ]] || continue
        aid=$(jq -r --arg d "$DEST_ID" '.remote[$d].archive.id' "$file"); cid=$(jq -r --arg d "$DEST_ID" '.remote[$d].checksum.id' "$file")
        mkdir -p "$WORK/download"
        provider_download "$aid" "$WORK/download/$name" && provider_download "$cid" "$WORK/download/$name.sha256" || return
        verify_local "$WORK/download/$name" || fail 'Downloaded backup checksum or archive verification failed.' || return
        [[ $(sha256sum "$WORK/download/$name" | cut -d' ' -f1) == "$(jq -r .sha256 "$file")" ]] || return
        # Use noclobber copy semantics in the caller's directory.
        PARTIAL=$(mktemp "$output/$name.partial.XXXXXX")
        cp "$WORK/download/$name" "$PARTIAL" || return
        [[ $(sha256sum "$PARTIAL" | cut -d' ' -f1) == "$(jq -r .sha256 "$file")" ]] || return
        mv -n "$PARTIAL" "$output/$name"; [[ ! -e $PARTIAL ]] || fail 'Output appeared concurrently; download not committed.' || return
        PARTIAL=""
        cp -n "$WORK/download/$name.sha256" "$output/$name.sha256"
        found=1; log VERIFY "Downloaded and verified: $output/$name"; break
    done
    ((found)) || fail 'No recorded verified copy on the selected destination. For lost state use the provider UI and ordinary checksum/tar tools.'
}
stop_active() {
    local pid ticks recorded_ticks cmd i
    [[ -f $STATE/active.json ]] || return 0
    pid=$(jq -r .pid "$STATE/active.json" 2>/dev/null) || return
    [[ $pid =~ ^[0-9]+$ && $pid != "$$" && -r /proc/$pid/cmdline ]] || return 0
    ticks=$(awk '{print $22}' "/proc/$pid/stat"); recorded_ticks=$(jq -r '.start_ticks // ""' "$STATE/active.json")
    [[ -n $recorded_ticks && $recorded_ticks == "$ticks" ]] || fail 'Active PID identity cannot be confirmed; refusing to signal it.' || return
    cmd=$(tr '\0' ' ' < "/proc/$pid/cmdline")
    [[ $cmd == *"$BIN"* ]] || fail 'An unrecognized process owns the active record; stop it manually before uninstall.' || return
    log INFO "Stopping active backup PID $pid."
    kill -TERM "$pid" || return
    for i in {1..30}; do kill -0 "$pid" 2>/dev/null || return 0; sleep 1; done
    fail 'Backup is still shutting down; retry uninstall after it exits.'
}
uninstall_command() {
    local purge="${1:-}" backupdir="$DEFAULT_BACKUPS"
    [[ ! -f $CONF ]] || backupdir=$(jq -r .backup_dir "$CONF")
    new_work
    if systemd_live; then
        systemctl disable --now automate-backups.timer >/dev/null 2>&1 || true
        systemctl stop automate-backups.service >/dev/null 2>&1 || true
    fi
    stop_active || return; lock uninstall || return
    if [[ -z $PREFIX ]]; then cron_remove || return; fi
    rm -f "$UNITDIR/automate-backups.timer" "$UNITDIR/automate-backups.service" "$BIN"
    if systemd_live; then systemctl daemon-reload; fi
    log INFO "Uninstalled. Local archives remain at $backupdir. All remote backups remain untouched."
    if [[ $purge == --purge ]]; then
        # No path read from configuration is a purge target.
        rm -rf -- "$ETC" "$LOGDIR"
        rm -rf -- "$WORK"; WORK=""
        rm -rf -- "$STATE"; LOCKED=0
    else log INFO 'Configuration, provider credentials, ownership records, and logs retained for reinstall.'; fi
}

self_test() (
    set -Eeuo pipefail
    local sandbox original_self count=0 source_dir f id before after rc
    original_self=$(realpath "$SELF"); sandbox=$(mktemp -d)
    trap 'rm -rf -- "$sandbox"' EXIT
    trap 'exit 143' TERM; trap 'exit 130' INT
    for f in jq tar gzip sha256sum flock openssl realpath; do have "$f" || { printf 'Missing test dependency: %s\n' "$f"; exit 1; }; done
    init_paths "$sandbox/root"; WORK=""; RECORD=""; LOCKED=0; RUN_OK=0; INSTALL_PENDING=0
    layout; new_work; source_dir="$sandbox/source"; mkdir "$source_dir"
    printf 'test application data\n' > "$source_dir/index.txt"
    printf 'hidden attribute file\n' > "$source_dir/.hidden"
    ln -s index.txt "$source_dir/link"
    CONFIG=$(default_config | jq --arg p "$source_dir" '.sources=[$p] | .reserve_mib=64 | .schedule.enabled=false')
    printf '%s' "$CONFIG" | json_write "$CONF"
    ok() { count=$((count+1)); printf 'PASS %02d %s\n' "$count" "$1"; }
    config_validate "$CONF"; ok 'JSON configuration parsing'
    jq '.local_keep=-1' "$CONF" > "$WORK/bad.conf"
    if config_validate "$WORK/bad.conf" >/dev/null 2>&1; then exit 1; fi; ok 'negative retention rejected'
    jq '.local_keep="$(touch /tmp/should-never-run)"' "$CONF" > "$WORK/bad.conf"
    if config_validate "$WORK/bad.conf" >/dev/null 2>&1; then exit 1; fi; ok 'executable-looking config remains data and is rejected'
    for f in / /proc /sys /dev /run /var/lib/mysql "$sandbox/absent"; do if path_ok "$f"; then exit 1; fi; done
    ok 'invalid and dangerous source paths rejected'
    discover; [[ -f $WORK/discovered.tsv ]]; ok 'bounded source discovery'
    [[ $(TZ=Asia/Kolkata date -d '2026-09-27 02:00' -u +%s 2>/dev/null) != '' ]]; timezone_ok Asia/Kolkata
    if timezone_ok '../etc/passwd'; then exit 1; fi; ok 'timezone validation'
    CONFIG=$(jq '.schedule.enabled=true|.schedule.mode="weekdays"|.schedule.days=[1,3,5]' <<< "$CONFIG")
    [[ $(calendar_expression) == 'Mon,Wed,Fri *-*-* 02:00:00 UTC' ]]
    date_matches 2026-09-28 1 28; if date_matches 2026-09-29 2 29; then exit 1; fi
    schedule_apply; [[ -f $UNITDIR/automate-backups.timer ]]; ok 'schedule generation and weekday selection'
    CONFIG=$(jq '.schedule.mode="interval"|.schedule.every=3|.schedule.anchor="2026-09-27"' <<< "$CONFIG")
    date_matches 2026-09-30 3 30; if date_matches 2026-09-29 2 29; then exit 1; fi; ok 'every-N-calendar-days scheduling'
    CONFIG=$(jq '.schedule.enabled=false|.schedule.mode="daily"' <<< "$CONFIG"); printf '%s' "$CONFIG" | json_write "$CONF"
    # Metadata collection itself is read-only; use a small fixture during repeated engine tests.
    metadata() { mkdir -p "$WORK/payload/metadata"; printf '{"self_test":true}\n' > "$WORK/payload/metadata/backup-manifest.json"; }
    run_backup >/dev/null 2>&1; [[ $RUN_OK == 1 ]]; verify_local "$ARCHIVE"; ok 'local backup, tar/gzip validation and SHA-256'
    mkdir "$WORK/extracted"; tar -xzf "$ARCHIVE" -C "$WORK/extracted"
    cmp "$source_dir/index.txt" "$WORK/extracted/filesystem${source_dir}/index.txt"
    [[ -L $WORK/extracted/filesystem${source_dir}/link ]]; ok 'portable layout, hidden files and symlink preservation'
    if tar -tzf "$ARCHIVE" | grep -q "${STATE#/}"; then exit 1; fi; ok 'working-directory recursion protection'
    cp "$ARCHIVE.sha256" "$WORK/sidecar.original"; printf 'invalid\n' > "$ARCHIVE.sha256"
    if verify_local "$ARCHIVE" >/dev/null 2>&1; then exit 1; fi
    cp "$WORK/sidecar.original" "$ARCHIVE.sha256"; ok 'checksum corruption rejected'
    before=$(find "$BACKUP_DIR" -name '*.tar.gz' | wc -l)
    (preflight() { return 1; }; if run_backup >/dev/null 2>&1; then exit 1; else exit 0; fi)
    after=$(find "$BACKUP_DIR" -name '*.tar.gz' | wc -l); [[ $before == "$after" ]]; ok 'pre-flight failure preserves prior backups'
    (df() { printf 'Filesystem 1-blocks Used Available Capacity Mounted\nfixture 100 99 1 99%% /\n'; }; if preflight >/dev/null 2>&1; then exit 1; else exit 0; fi)
    ok 'insufficient disk space aborts'
    if (exec 9>&-; exec 8>"$STATE/operation.lock"; flock -n 8); then exit 1; fi; ok 'single-instance lock blocks concurrent operation'
    # Synthetic successful sets validate count ordering without copying user data.
    cp "$RECORD" "$WORK/template-record"
    for rc in 1 2 3 4 5 6 7; do
        id=$(printf '%032x' "$rc"); f="$BACKUP_DIR/fixture-$rc.tar.gz"
        cp "$ARCHIVE" "$f"; (cd "$BACKUP_DIR" && sha256sum "${f##*/}") > "$f.sha256"
        jq --arg id "$id" --arg p "$f" --arg n "${f##*/}" --arg t "2026-01-0${rc}T00:00:00Z" '.id=$id|.path=$p|.filename=$n|.started=$t' "$WORK/template-record" | json_write "$STATE/records/$id.json"
    done
    [[ $(retention_candidates local 6 | wc -l) == 2 ]]; ok 'retention=6 chooses oldest successful sets'
    [[ $(retention_candidates local 1 | wc -l) == 7 ]]; ok 'retention=1 preserves newest successful set'
    LOCAL_KEEP=1; local_retention >/dev/null 2>&1
    [[ $(find "$BACKUP_DIR" -name '*.tar.gz' | wc -l) == 1 ]]; ok 'actual local pair deletion is count-based'
    printf '{bad json' > "$STATE/records/corrupt.json"
    if local_retention >/dev/null 2>&1; then exit 1; fi
    [[ -f $ARCHIVE ]]; rm "$STATE/records/corrupt.json"; ok 'corrupt state disables pruning'
    id=$(openssl rand -hex 16)
    jq -n --arg id "$id" '{format:1,name:"fixture",id:$id,type:"webdav",keep:6,tested:true,endpoint:"https://example.invalid/dav",folder:"https://example.invalid/dav/owned",username:"test",password:"synthetic"}' | json_write "$ETC/providers/fixture.conf"
    dest_validate "$ETC/providers/fixture.conf"; ok 'provider configuration parsing'
    # No network request: only this subshell replaces transport with explicit failures.
    (
        hostname() { printf 'failure-fixture\n'; }
        provider_quota() { return 0; }
        provider_upload() { return 1; }
        jq '.local_keep=0' "$CONF" | json_write "$CONF"
        if run_backup >/dev/null 2>&1; then exit 1; fi
        verify_local "$ARCHIVE"
        [[ $(find "$BACKUP_DIR" -name '*.tar.gz' | wc -l) == 2 ]]
    )
    ok 'failed upload preserves valid local archive at local retention zero and all prior backups'
    # Child signal test exercises real EXIT/TERM traps and filesystem cleanup.
    bash -c 'source "$1"; init_paths "$2"; layout; new_work; printf "%s\n" "$WORK" > "$3"; PARTIAL="$STATE/interrupted.partial"; printf incomplete > "$PARTIAL"; traps; kill -TERM $$' _ "$original_self" "$sandbox/signal" "$sandbox/child-work" >/dev/null 2>&1 && exit 1 || rc=$?
    [[ $rc == 143 && ! -e $(cat "$sandbox/child-work") && ! -e $sandbox/signal/var/lib/automate-backups/interrupted.partial ]]; ok 'interrupted run removes temporary data'
    # Fresh/repeat installation, reconfiguration and uninstall use the actual
    # installer with deterministic wizard input and an isolated filesystem root.
    (
        init_paths "$sandbox/install"; WORK=""; RECORD=""; LOCKED=0; RUN_OK=0; INSTALL_PENDING=0; SELF="$original_self"
        root_required() { return 0; }; dependencies() { return 0; }
        source_wizard() { CONFIG=$(jq --arg p "$source_dir" '.sources=[$p]|.reserve_mib=64' <<< "$CONFIG"); }
        database_wizard() { return 0; }; destination_wizard() { return 0; }; retention_wizard() { return 0; }; schedule_wizard() { return 0; }
        ask() { ANSWER="${2:-}"; [[ $1 != 'Action' ]] || ANSWER=2; }
        yes() { return 1; }
        install_project >/dev/null; [[ -x $BIN && -f $CONF ]]
        LOCKED=0; exec 9>&-; install_project >/dev/null
        [[ $(find "$UNITDIR" -name automate-backups.timer | wc -l) == 1 ]]
        config_change schedule >/dev/null; config_validate "$CONF"
        mkdir -p "$DEFAULT_BACKUPS"; printf 'keep me' > "$DEFAULT_BACKUPS/preserved.tar.gz"
        rm -f "$STATE/active.json"; LOCKED=0; exec 9>&-; uninstall_command >/dev/null
        [[ ! -e $BIN && -f $CONF && -f $DEFAULT_BACKUPS/preserved.tar.gz ]]
        LOCKED=0; exec 9>&-; install_project >/dev/null; [[ -x $BIN ]]
        rm -f "$STATE/active.json"; LOCKED=0; exec 9>&-; uninstall_command --purge >/dev/null
        [[ ! -e $ETC && ! -e $STATE && -f $DEFAULT_BACKUPS/preserved.tar.gz ]]
    )
    ok 'fresh/repeat install, reconfigure, uninstall, reinstall, purge preserve backups'
    (
        init_paths "$sandbox/recursion"; WORK=""; RECORD=""; LOCKED=0; RUN_OK=0
        exec 9>&-; layout; new_work
        mkdir -p "$PREFIX/application" "$ETC.previous.fixture"
        printf 'include this\n' > "$PREFIX/application/index.txt"
        printf 'never archive credentials\n' > "$ETC/providers/private.pending"
        printf 'never archive old credentials\n' > "$ETC.previous.fixture/private.conf"
        CONFIG=$(default_config | jq --arg p "$PREFIX" '.sources=[$p]|.reserve_mib=64|.schedule.enabled=false')
        printf '%s' "$CONFIG" | json_write "$CONF"
        run_backup >/dev/null 2>&1
        tar -tzf "$ARCHIVE" > "$WORK/listing"
        grep -q '/application/index.txt' "$WORK/listing"
        if grep -E 'private.pending|private.conf|server-id|operation.lock|\.tar\.gz' "$WORK/listing"; then exit 1; fi
        jq --arg p "$LOGDIR/archives" '.backup_dir=$p' "$CONF" > "$WORK/unsafe.conf"
        if config_validate "$WORK/unsafe.conf" >/dev/null 2>&1; then exit 1; fi
    )
    ok 'broad source excludes nested archives, state, active credentials and rollback credentials'
    ok 'archive directory inside purge targets is rejected'
    printf '\nAll %s self-tests passed. No user data uploaded; no host schedule changed.\n' "$count"
)
help_command() {
    cat <<'HELP'
Automate Backups — portable Linux workload backups
Usage: automate-backups COMMAND
  run                              Create, validate, upload, then apply retention
  retry BACKUP_ID                  Retry uploads for a retained local backup
  status                           Schedule and last backup state
  list                             Recorded local and remote backup sets
  logs [LINES]                     Recent log lines (default 100)
  config                           Change selected configuration
  doctor                           Read-only diagnostics / provider quota
  schedule                         Change schedule and timezone
  retention                        Change local and remote retention counts
  destination list
  destination add
  destination remove NAME          Detach destination; do not delete remote files
  destination test NAME            Create/read/delete a tiny test object
  destination reauthorize NAME     Reauthorize and retest
  verify ARCHIVE.tar.gz             Validate archive and its .sha256 sidecar
  download BACKUP_ID [NAME] [DIR]   Download a recorded remote set, verified
  self-test                        Isolated non-destructive regression tests
  uninstall [--purge]               Always keep local and remote backup archives
  version
  help
Run setup.sh with no arguments for the interactive setup wizard.
HELP
}
main() {
    local cmd="${1:-install}" action name f n
    shift || true
    case "$cmd" in
        version|--version) printf '%s\n' "$VERSION"; return;;
        help|--help|-h) help_command; return;;
        self-test) self_test; return;;
        verify) [[ $# == 1 ]] || { help_command; return 1; }; verify_local "$1" && printf 'Archive and SHA-256: VERIFIED\n'; return;;
    esac
    root_required || return
    if [[ $cmd == install ]]; then traps; install_project; return; fi
    for n in jq flock openssl; do have "$n" || fail "Required binary missing: $n" || return; done
    layout; traps
    case "$cmd" in
        run) run_backup;;
        tick) schedule_tick "${1:-}";;
        retry) retry_backup "${1:?Backup ID required}";;
        status) status_command;;
        list) records_array | jq '.[]|{id,filename,status,started,size,local,remote,retention}';;
        logs) n="${1:-100}"; uint "$n" && ((n>0)) || return; tail -n "$n" "$LOGDIR/automate-backups.log";;
        config|schedule|retention) lock "$cmd"; new_work; config_change "$cmd";;
        doctor) lock doctor; new_work; doctor_command;;
        download) lock download; new_work; load_config; download_command "${1:?Backup ID required}" "${2:-}" "${3:-$PWD}";;
        destination)
            action="${1:-list}"; name="${2:-}"; lock destination; new_work; load_config
            case "$action" in
                list) for f in "$ETC"/providers/*.conf; do [[ ! -f $f ]] || jq '{name,type,id,keep,tested,tested_at}' "$f"; done;;
                add) destination_wizard;;
                test|reauthorize|remove)
                    ident "$name" || fail 'Supply the destination name from destination list.' || return
                    f="$ETC/providers/$name.conf"; load_dest "$f" || return
                    case "$action" in
                        test) provider_test;;
                        reauthorize)
                            cp "$f" "$f.pending"; DEST_FILE="$f.pending"
                            if provider_auth && provider_test; then mv "$f.pending" "$f"; else rm -f "$f.pending"; return 1; fi;;
                        remove)
                            if ((LOCAL_KEEP==0)); then
                                n=$(find "$ETC/providers" -maxdepth 1 -name '*.conf' -type f | wc -l)
                                ((n>1)) || fail 'Set local retention >=1 before removing the last remote destination.' || return
                            fi
                            rm -f "$f" "$ETC/providers/$name.known_hosts"
                            log INFO "Detached $name. All remote backups and local ownership records retained.";;
                    esac;;
                *) help_command; return 1;;
            esac;;
        uninstall) [[ $# == 0 || ${1:-} == --purge ]] || return; uninstall_command "${1:-}";;
        *) help_command; return 1;;
    esac
}
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
