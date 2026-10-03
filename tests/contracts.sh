#!/usr/bin/env bash
# Offline protocol/adapter regression tests. Never contacts a cloud or database.
set -Eeuo pipefail
PROJECT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../setup.sh
source "$PROJECT/setup.sh"
TESTROOT=$(mktemp -d)
trap 'rm -rf -- "$TESTROOT"' EXIT
init_paths "$TESTROOT/root"; layout; new_work
COUNT=0
pass() { COUNT=$((COUNT+1)); printf 'PASS %02d %s\n' "$COUNT" "$1"; }
fixture_dest() {
    DEST_TYPE="$1"; DEST_NAME=fixture; DEST_ID=11111111111111111111111111111111
    DEST_FILE="$ETC/providers/fixture.conf"
    jq -n --arg t "$1" '{format:1,type:$t,name:"fixture",id:"11111111111111111111111111111111",keep:1,tested:true,folder:"folder-1",access_token:"synthetic-token",refresh_token:"synthetic-refresh",expires_at:9999999999,client_id:"synthetic-client",client_secret:"synthetic-secret",tenant:"consumers",username:"synthetic-user",password:"synthetic-password",endpoint:"https://s3.example.invalid",bucket:"backup-bucket",region:"us-east-1",access_key:"synthetic-key",secret_key:"synthetic-secret"}' | json_write "$DEST_FILE"
    DEST=$(cat "$DEST_FILE")
}
# Fail all accidental network calls, including future additions to tests.
curl() { printf 'Unexpected network/curl call in offline tests\n' >&2; return 99; }
ssh() { printf 'Unexpected SSH call in offline tests\n' >&2; return 99; }
sleep() { :; }
dd if=/dev/zero of="$WORK/payload.bin" bs=1M count=11 status=none
(
    fixture_dest google
    session_path "$WORK/payload.bin"
    printf '{"url":"https://www.googleapis.com/upload/session","id":"file-1"}' | json_write "$SESSION"
    N=0
    http() {
        N=$((N+1)); HTTP_BODY="$WORK/body"; HTTP_HEADERS="$WORK/headers"; : > "$HTTP_HEADERS"
        case "$N" in
            1) [[ $1 == PUT && $6 == 'Content-Range: bytes */11534336' ]]; HTTP_CODE=308;;
            2) [[ $6 == 'Content-Range: bytes 0-8388607/11534336' ]]; [[ $(stat -c %s "$3") == 8388608 ]]; HTTP_CODE=503; return 1;;
            3) [[ $6 == 'Content-Range: bytes */11534336' ]]; printf 'Range: bytes=0-8388607\r\n' > "$HTTP_HEADERS"; HTTP_CODE=308;;
            4) [[ $6 == 'Content-Range: bytes 8388608-11534335/11534336' ]]; [[ $(stat -c %s "$3") == 3145728 ]]; HTTP_CODE=200; printf '{"id":"file-1"}' > "$HTTP_BODY";;
            *) return 90;;
        esac
    }
    google_upload "$WORK/payload.bin"
    [[ $REMOTE_ID == file-1 && $N == 4 && ! -e $SESSION ]]
)
pass 'Google resumable upload recovers the server-confirmed offset after a lost response'
(
    fixture_dest dropbox; session_path "$WORK/payload.bin"
    printf '{"session_id":"s1","offset":0}' | json_write "$SESSION"; N=0
    http() {
        N=$((N+1)); HTTP_BODY="$WORK/body"; HTTP_HEADERS="$WORK/headers"; : > "$HTTP_HEADERS"
        case "$N" in
            1) [[ $2 == */append_v2 ]]; HTTP_CODE=409; printf '{"error":{".tag":"incorrect_offset","correct_offset":8388608}}' > "$HTTP_BODY";;
            2) [[ $6 == *'"offset":8388608'* && $(stat -c %s "$3") == 3145728 ]]; HTTP_CODE=200; printf null > "$HTTP_BODY";;
            3) [[ $2 == */finish && $6 == *'"offset":11534336'* ]]; HTTP_CODE=200; printf '{"id":"id:db1"}' > "$HTTP_BODY";;
            *) return 90;;
        esac
    }
    dropbox_upload "$WORK/payload.bin"
    [[ $REMOTE_ID == id:db1 && $N == 3 ]]
)
pass 'Dropbox upload session handles incorrect_offset and finalizes the exact byte count'
(
    fixture_dest onedrive; session_path "$WORK/payload.bin"
    printf '{"url":"https://upload.example.invalid/session"}' | json_write "$SESSION"; N=0
    http() {
        N=$((N+1)); HTTP_BODY="$WORK/body"; HTTP_HEADERS="$WORK/headers"
        [[ $4 == none ]] # The capability upload URL must not receive Graph bearer tokens.
        case "$N" in
            1) [[ $1 == GET ]]; HTTP_CODE=200; printf '{"nextExpectedRanges":["0-"]}' > "$HTTP_BODY";;
            2) [[ $6 == 'Content-Range: bytes 0-10485759/11534336' ]]; HTTP_CODE=416;;
            3) [[ $1 == GET ]]; HTTP_CODE=200; printf '{"nextExpectedRanges":["10485760-"]}' > "$HTTP_BODY";;
            4) [[ $6 == 'Content-Range: bytes 10485760-11534335/11534336' ]]; HTTP_CODE=201; printf '{"id":"one-1"}' > "$HTTP_BODY";;
            *) return 90;;
        esac
    }
    onedrive_upload "$WORK/payload.bin"
    [[ $REMOTE_ID == one-1 && $N == 4 ]]
)
pass 'OneDrive 320-KiB-aligned chunks recover after HTTP 416 without leaking bearer authorization'
(
    fixture_dest s3; N=0
    dd if=/dev/zero of="$WORK/multipart.bin" bs=1M count=65 status=none
    s3_request() {
        N=$((N+1)); HTTP_BODY="$WORK/body"; HTTP_HEADERS="$WORK/headers"; HTTP_CODE=200
        case "$N" in
            1) [[ $1 == POST && $2 == *'?uploads=' ]];;
            2) [[ $2 == *'partNumber=1&uploadId=upload-1' && $(stat -c %s "$3") == 67108864 ]]; printf 'ETag: "11111111111111111111111111111111"\r\n' > "$HTTP_HEADERS";;
            3) [[ $2 == *'partNumber=2&uploadId=upload-1' && $(stat -c %s "$3") == 1048576 ]]; printf 'ETag: "22222222222222222222222222222222"\r\n' > "$HTTP_HEADERS";;
            4) [[ $1 == POST && $2 == *'?uploadId=upload-1' ]]; grep -q '<PartNumber>2</PartNumber>' "$3";;
            *) return 90;;
        esac
    }
    xml_value() { printf upload-1; }; xmlstarlet() { printf CompleteMultipartUploadResult; }
    s3_upload "$WORK/multipart.bin"
    [[ $N == 4 && -z $CANCEL_SESSION && $REMOTE_ID == folder-1/multipart.bin ]]
)
pass 'S3 multipart obeys part sizes, includes returned ETags, and validates completion'
(
    fixture_dest s3
    s3_upload() { CANCEL_SESSION='owned/file?uploadId=synthetic'; return 1; }
    s3_abort() { printf aborted > "$WORK/abort-marker"; }
    if provider_upload "$WORK/payload.bin"; then exit 1; fi
    [[ -f $WORK/abort-marker && -z $CANCEL_SESSION ]]
)
pass 'S3 failed multipart upload invokes abort'
(
    fixture_dest s3
    # Inspect the actual transport config while replacing the curl executable.
    curl() {
        [[ $1 == -q && $2 == --config ]]
        grep -q 'aws-sigv4 = "aws:amz:us-east-1:s3"' "$3"
        grep -q 'x-amz-content-sha256:' "$3"
        grep -q 'user = "synthetic-key:synthetic-secret"' "$3"
        printf 200
    }
    http PUT https://s3.example.invalid/backup-bucket/test "$WORK/payload.bin" s3 1
    [[ $HTTP_CODE == 200 ]]
)
pass 'S3 uses curl SigV4 with a payload hash and private-file credentials'
(
    fixture_dest google; state_edit "$DEST_FILE" '.expires_at=0'; DEST=$(cat "$DEST_FILE")
    http() {
        [[ $1 == POST && $2 == https://oauth2.googleapis.com/token && $4 == none ]]
        grep -q 'grant_type=refresh_token' "$3"
        HTTP_BODY="$WORK/token-response"; HTTP_CODE=200
        printf '{"access_token":"new-access","refresh_token":"new-refresh","expires_in":3600}' > "$HTTP_BODY"
    }
    refresh_token
    [[ $(jq -r .refresh_token "$DEST_FILE") == new-refresh && $(jq -r .access_token "$DEST_FILE") == new-access ]]
    secret_ok "$DEST_FILE"
)
pass 'Refresh-token rotation is persisted atomically with strict permissions'
(
    fixture_dest onedrive; state_edit "$DEST_FILE" '.expires_at=0'; DEST=$(cat "$DEST_FILE")
    http() { HTTP_BODY="$WORK/revoked"; HTTP_CODE=400; printf '{"error":"invalid_grant"}' > "$HTTP_BODY"; }
    if refresh_token >/dev/null 2>&1; then exit 1; fi
    [[ $(jq -r .refresh_token "$DEST_FILE") == synthetic-refresh ]]
)
pass 'Revoked OAuth authorization fails closed and retains prior credential state'
(
    fixture_dest google; N=0
    google_api() {
        N=$((N+1)); HTTP_BODY="$WORK/page"
        if ((N==1)); then printf '{"files":[{"id":"a","name":"one.tar.gz","size":"2"}],"nextPageToken":"next"}' > "$HTTP_BODY"
        else [[ $2 == *pageToken=next ]]; printf '{"files":[{"id":"b","name":"two.tar.gz","size":"3"}]}' > "$HTTP_BODY"; fi
    }
    provider_list > "$WORK/list-result"
    [[ $(jq length "$WORK/list-result") == 2 && $N == 2 ]]
)
pass 'Remote listing follows pagination before returning a complete inventory'
(
    fixture_dest webdav; N=0
    dest_put folder https://dav.example.invalid/owned
    http() {
        N=$((N+1)); HTTP_CODE=201
        if ((N==1)); then [[ $1 == PUT && $2 == *.partial ]]
        else [[ $1 == MOVE && $6 == 'Destination: https://dav.example.invalid/owned/payload.bin' && $7 == 'Overwrite: F' ]]; fi
    }
    provider_upload "$WORK/payload.bin"; [[ $REMOTE_ID == payload.bin && $N == 2 ]]
)
pass 'WebDAV stages a partial object then moves it without overwriting a final object'
(
    fixture_dest sftp
    DEST=$(jq '.directory="/backups"|.username="backup"|.host="example.invalid"|.port=22|.key="/root/key"' <<< "$DEST")
    ssh_exec() { return 0; }
    sftp_batch() { grep -q 'put -a' "$WORK/sftp.batch"; grep -q 'rename .*partial' "$WORK/sftp.batch"; }
    provider_upload "$WORK/payload.bin"; [[ $REMOTE_ID == payload.bin ]]
    [[ ${SSH_ARGS[*]} == *StrictHostKeyChecking=yes* ]]
)
pass 'SFTP uses resumable staging and strict host-key verification'
(
    fixture_dest google
    printf '{"storageQuota":{"limit":"100","usage":"90"}}' > "$WORK/quota"
    google_api() { HTTP_BODY="$WORK/quota"; }
    if provider_quota 11 >/dev/null 2>&1; then exit 1; fi
)
pass 'Insufficient provider quota fails before uploading data'
(
    fixture_dest google
    provider_meta() { printf '{"id":"a","name":"payload.bin","size":11534336,"hash":"incorrect","hash_kind":"md5"}'; }
    if provider_verify "$WORK/payload.bin" a >/dev/null 2>&1; then exit 1; fi
)
pass 'A remote provider hash mismatch is not accepted as a successful backup'
(
    # Native database adapters are exercised with fake client executables and
    # synthetic data; no database server, daemon, or package is installed.
    mkdir -p "$WORK/fakebin"
    cat > "$WORK/fakebin/mariadb-dump" <<'EOF'
#!/usr/bin/env bash
if [[ $1 == --help ]]; then printf 'no-tablespaces set-gtid-purged\n'; exit; fi
[[ $1 == --defaults-extra-file=* ]] || exit 5
[[ " $* " == *' --single-transaction '* && " $* " == *' --routines '* && " $* " == *' --hex-blob '* ]] || exit 6
printf 'CREATE DATABASE fixture_mysql;\n'
EOF
    cat > "$WORK/fakebin/pg_dump" <<'EOF'
#!/usr/bin/env bash
[[ " $* " == *' --create '* && " $* " == *' --dbname=fixture_pg '* ]] || exit 7
printf 'CREATE DATABASE fixture_pg;\n'
EOF
    cat > "$WORK/fakebin/pg_dumpall" <<'EOF'
#!/usr/bin/env bash
[[ " $* " == *' --globals-only '* ]] || exit 8
printf 'CREATE ROLE fixture_role;\n'
EOF
    cat > "$WORK/fakebin/mongodump" <<'EOF'
#!/usr/bin/env bash
[[ " $* " == *' --config='* && " $* " == *' --dumpDbUsersAndRoles '* ]] || exit 9
for arg in "$@"; do case "$arg" in --archive=*) printf 'fixture native archive\n' | gzip > "${arg#*=}";; esac; done
EOF
    chmod +x "$WORK/fakebin/"*
    PATH="$WORK/fakebin:$PATH"
    printf '[client]\n' | atom "$ETC/mysql.cnf"
    printf '*:*:*:fixture:synthetic\n' | atom "$ETC/postgres.pass"
    printf 'uri: "mongodb://localhost"\n' | atom "$ETC/mongo.yml"
    CONFIG='{"databases":{"mysql":{"names":["fixture_mysql"],"accounts":false},"postgres":{"names":["fixture_pg"],"os_user":"","host":"localhost","port":"5432","user":"fixture"},"mongo":{"names":["fixture_mongo"]}}}'
    dump_databases
    grep -q 'CREATE DATABASE fixture_mysql' "$WORK/payload/database/mysql/fixture_mysql.sql"
    grep -q 'CREATE ROLE fixture_role' "$WORK/payload/database/postgres/globals.sql"
    gzip -t "$WORK/payload/database/mongo/fixture_mongo.archive.gz"
)
pass 'MySQL, PostgreSQL globals, and MongoDB adapters invoke native logical dump commands'
(
    fixture_dest google
    printf 0 > "$WORK/http-count"
    curl() {
        local n out headers
        n=$(cat "$WORK/http-count"); n=$((n+1)); printf '%s' "$n" > "$WORK/http-count"
        out=$(sed -n 's/^output = "\(.*\)"/\1/p' "$3")
        headers=$(sed -n 's/^dump-header = "\(.*\)"/\1/p' "$3")
        printf '{"ok":true}' > "$out"
        case "$n" in 1) printf 'Retry-After: 1\r\n' > "$headers"; printf 429;; 2) printf 503;; 3) printf 200;; *) return 99;; esac
    }
    http GET https://www.googleapis.com/synthetic '' bearer 4 >/dev/null 2>&1
    [[ $HTTP_CODE == 200 && $(cat "$WORK/http-count") == 3 ]]
)
pass 'HTTP transport retries rate limits and transient failures within a bounded budget'
(
    fixture_dest google
    curl() {
        local out; out=$(sed -n 's/^output = "\(.*\)"/\1/p' "$3")
        printf '<html>Login required</html>' > "$out"; printf 200
    }
    if request_json GET https://www.googleapis.com/synthetic >/dev/null 2>&1; then exit 1; fi
)
pass 'HTTP 200 with an HTML error page is rejected by JSON API adapters'
(
    fixture_dest google
    for n in 1 2; do
        id=$(printf '%032x' "$n")
        jq -n --arg id "$id" --arg s "$SERVER_ID" --arg d "$DEST_ID" --arg t "2026-01-0${n}T00:00:00Z" --arg n "$n" \
          '{id:$id,server_id:$s,filename:("backup-"+$n+".tar.gz"),sha256:("0"*64),size:1,started:$t,status:"SUCCESS",local:"NONE",remote:{($d):{status:"VERIFIED",archive:{id:("a"+$n),name:("backup-"+$n+".tar.gz"),size:1},checksum:{id:("c"+$n),name:("backup-"+$n+".tar.gz.sha256"),size:80}}}}' | json_write "$STATE/records/$id.json"
    done
    provider_delete() { printf '%s\n' "$1" >> "$WORK/deleted"; }
    provider_list() { return 1; }
    if remote_retention >/dev/null 2>&1; then exit 1; fi
    [[ ! -e $WORK/deleted ]]
    provider_list() { printf '[{"id":"a1","name":"backup-1.tar.gz","size":1}]'; }
    if remote_retention >/dev/null 2>&1; then exit 1; fi
    [[ ! -e $WORK/deleted ]]
    provider_list() { printf '[{"id":"a1","name":"backup-1.tar.gz","size":1},{"id":"c1","name":"backup-1.tar.gz.sha256","size":80},{"id":"unrelated","name":"my-manual-backup.tar.gz","size":9}]'; }
    remote_retention >/dev/null 2>&1
    [[ $(cat "$WORK/deleted") == $'a1\nc1' ]]
    [[ $(jq -r --arg d "$DEST_ID" '.remote[$d].status' "$STATE/records/00000000000000000000000000000001.json") == PRUNED ]]
    rm "$STATE/records/"*.json
)
pass 'Remote retention deletes only recorded pairs, and never prunes after failed/inconsistent listings'
(
    fixture_dest webdav; BACKUP_DIR="$TESTROOT/localzero"; mkdir "$BACKUP_DIR"
    ARCHIVE="$BACKUP_DIR/zero-full-2026-01-01_00-00-00_UTC.tar.gz"; ARCHIVE_NAME=${ARCHIVE##*/}
    tar -czf "$ARCHIVE" -C "$WORK" payload.bin
    (cd "$BACKUP_DIR" && sha256sum "$ARCHIVE_NAME") > "$ARCHIVE.sha256"
    RUN_ID=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; RECORD="$STATE/records/$RUN_ID.json"; LOCAL_KEEP=0; RUN_OK=0
    cp "$ARCHIVE.sha256" "$WORK/remote-original"
    jq -n --arg id "$RUN_ID" --arg s "$SERVER_ID" --arg p "$ARCHIVE" --arg n "$ARCHIVE_NAME" --arg h "$(sha256sum "$ARCHIVE"|cut -d' ' -f1)" --argjson size "$(stat -c %s "$ARCHIVE")" \
      '{id:$id,server_id:$s,path:$p,filename:$n,sha256:$h,size:$size,started:"2026-01-01T00:00:00Z",local:"VERIFIED",status:"PENDING",remote:{},retention:{}}' | json_write "$RECORD"
    provider_quota() { return 0; }
    provider_upload() { REMOTE_ID=$(basename "$1"); }
    provider_verify() { jq -n --arg n "$(basename "$1")" --argjson s "$(stat -c %s "$1")" '{id:$n,name:$n,size:$s}'; }
    provider_download() { cp "$WORK/remote-original" "$2"; }
    provider_list() { printf '[]'; }
    transfer_backup >/dev/null 2>&1
    [[ $RUN_OK == 1 && ! -f $ARCHIVE && ! -f $ARCHIVE.sha256 ]]
    [[ $(jq -r .local "$RECORD") == PRUNED && $(jq -r .status "$RECORD") == SUCCESS ]]
    rm "$RECORD"
)
pass 'Local retention zero removes the pair only after all remote verification succeeds'
(
    fixture_dest google; session_path "$WORK/payload.bin"
    printf '{"url":"https://www.googleapis.com/upload/session","id":"file-1"}' | json_write "$SESSION"
    http() { HTTP_CODE=308; HTTP_BODY="$WORK/evil-body"; HTTP_HEADERS="$WORK/evil-headers"; printf '%s\n' 'Range: bytes=0-a[$(touch /tmp/ab-must-not-execute)]' > "$HTTP_HEADERS"; }
    if google_upload "$WORK/payload.bin" >/dev/null 2>&1; then exit 1; fi
)
pass 'Malformed provider offsets are rejected before Bash arithmetic evaluation'
(
    installroot="$TESTROOT/rollback"
    mkdir -p "$installroot/etc/automate-backups" "$installroot/usr/local/sbin" "$installroot/etc/systemd/system" "$installroot/application"
    printf '#!/bin/sh\nprintf old-version\n' > "$installroot/usr/local/sbin/automate-backups"
    chmod 755 "$installroot/usr/local/sbin/automate-backups"
    printf 'original-service\n' > "$installroot/etc/systemd/system/automate-backups.service"
    printf 'original-timer\n' > "$installroot/etc/systemd/system/automate-backups.timer"
    default_config | jq --arg b "$installroot/archives" --arg s "$installroot/application" '.backup_dir=$b|.sources=[$s]|.schedule.enabled=false' > "$installroot/etc/automate-backups/config.conf"
    cp "$installroot/etc/automate-backups/config.conf" "$TESTROOT/original-conf"
    if bash -c '
        source "$1"
        init_paths "$2"
        root_required() { :; }; dependencies() { :; }
        ask() { ANSWER=2; }
        schedule_apply() { return 1; }
        traps
        install_project
    ' _ "$PROJECT/setup.sh" "$installroot" > "$TESTROOT/rollback.log" 2>&1; then exit 1; fi
    cmp "$TESTROOT/original-conf" "$installroot/etc/automate-backups/config.conf"
    grep -q old-version "$installroot/usr/local/sbin/automate-backups"
    grep -q original-service "$installroot/etc/systemd/system/automate-backups.service"
    grep -q original-timer "$installroot/etc/systemd/system/automate-backups.timer"
    grep -q 'Restoring installation files' "$TESTROOT/rollback.log"
)
pass 'An installation activation failure rolls back the existing config, executable and units'
printf '\nAll %s offline contract tests passed. No provider integration was live-tested.\n' "$COUNT"
