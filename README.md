# Automate Backups Scheduling & Transferring Script for Linux

**Portable backups for Linux web-hosting workloads using direct cloud APIs and a single Bash program.**

This package is a standalone Linux backup utility that discovers common website, database, mail, and configuration locations, lets the administrator choose what to include, creates a validated `.tar.gz` archive with a SHA-256 sidecar, uploads the verified files to configured destinations, and applies retention only after successful verification.

No rclone, restic, Borg, duplicity, Docker, Node.js, proprietary archive format, or always-running backup daemon is required.

**Validation status:** Core and offline protocol tests pass in an Ubuntu 24.04 container. Cloud accounts, live database servers, other distributions, real systemd/cron activation, and disaster recovery on a replacement server have **not** been live-tested. Treat the first deployment as a staged rollout: run the connection test, create a backup, and perform a recovery drill before relying on unattended operation. This repository does not claim provider certification or universal panel compatibility.

## Architecture

Automate Backups uses one Bash program for installation, configuration, backup execution, provider communication, verification, retention, recovery tooling, and lifecycle management. It creates ordinary gzip-compressed tar archives and native database dumps rather than a proprietary backup format.

### Scope

Selected sources may include:

- Website/application files discovered under common layouts and literal document roots from Apache, Nginx and LiteSpeed configuration.
- MariaDB/MySQL logical SQL dumps, optional database account definitions and grants.
- PostgreSQL SQL dumps and roles/globals; MongoDB native logical archives with database users/roles.
- Detected mailbox directories and Postfix, Dovecot, Exim and OpenDKIM configuration.
- Web/PHP/database configuration, SSL certificates, cron, custom systemd units, firewall, Fail2Ban, SSH server configuration, hostname, hosts, network and update configuration.
- Package, service, network, disk, software-version and SELinux recovery metadata.
- Explicit custom paths and selected Docker named volumes or bind mounts.

Discovery is bounded; it does not scan every mounted disk. Common cPanel, Plesk, DirectAdmin and aaPanel layouts improve discovery, but no panel is required. CyberPanel, ISPConfig and custom deployments can supply additional paths. Panel discovery does not imply a panel-native full-account restore.

This is **not** a disk image, bootable clone, block snapshot, live filesystem snapshot, application-consistent orchestration service, or automatic bare-metal recovery system. Operating systems and services must be installed separately during recovery.

Live files can change during a backup. A nonzero `tar` result, including changed files, fails the run. `--single-transaction` protects transactional MySQL tables, not MyISAM or concurrent schema changes. Separate database dumps are not a cross-database snapshot. MongoDB per-database dumps are not an oplog snapshot. Arrange a maintenance window or application quiescence where consistency requires it.

## Repository

```text
automate-backups/
├── setup.sh
├── README.md
├── LICENSE
└── tests/
    └── contracts.sh
```

All runtime logic is in `setup.sh`. The one additional test file contains reproducible, offline provider/database fixtures; it is not installed on the server. The installed CLI is named `automate-backups`.

## Environment

| Platform | Package-manager route | Important conditions |
| --- | --- | --- |
| Ubuntu / Debian | `apt-get` | Bash, GNU tools, supported native DB clients |
| AlmaLinux / Rocky / RHEL-compatible / Fedora | `dnf`, then `yum` | Required packages must be available in configured repositories |
| CentOS-compatible | `yum` or `dnf` | Maintained repositories and current-enough TLS/curl; obsolete releases are not certified |
| openSUSE / SUSE | `zypper` | GNU tools and a working scheduler |
| Alpine | `apk` | Install Bash to start the script; GNU tar/coreutils/findutils replace BusyBox limitations |
| Arch-based | `pacman` | System packages must already be coherently updated; installer does not force a distribution upgrade |

These are implemented compatibility routes, **not a tested distribution matrix**.

Root is required for installation, configuration changes and workload backups. Essential lightweight packages are installed if missing: Bash 4+, curl, jq 1.6+, GNU tar, gzip, GNU coreutils, GNU findutils, util-linux/flock, OpenSSL and diffutils/cmp. Standard `awk`, `sed`, `grep`, hostname and timezone data are expected. Package operations may install the distribution's normal dependencies; database servers and unrelated software are never installed.

Additional requirements:

- Native database client tools matching the server. Install them yourself if only the database server is present; the wizard only offers engines whose tools can be detected.
- S3: curl **7.75+** with `--aws-sigv4`, and `xmlstarlet`.
- WebDAV: `xmlstarlet`.
- SFTP: OpenSSH `ssh`, `sftp`, `ssh-keyscan` and `ssh-keygen`.
- Google interactive authorization only: an existing system `python3` for a small standard-library loopback callback. No Python package, virtual environment or Python backup engine is used. The installer reports this requirement rather than silently installing a runtime.
- A valid system CA trust store and `tzdata`. TLS verification is never disabled.
- systemd timers, or a working and enabled cron/crond service. Without a scheduler, choose a disabled schedule and run manually.

## Installation

Publish these files to your repository before using the following GitHub URL. Creating the files locally does not publish the repository.

Recommended inspect-before-running installation:

```bash
curl -fsSL https://raw.githubusercontent.com/iamsahildhamija/automate-backups/main/setup.sh -o setup.sh
less setup.sh
sudo bash setup.sh
```

From an existing root Bash shell, process substitution is also supported:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/iamsahildhamija/automate-backups/main/setup.sh)
```

Prompts read `/dev/tty`, so they do not consume script input. For a streamed source, installation retrieves the installable script again from the fixed HTTPS repository URL and syntax-checks it. Downloading and inspecting a local copy avoids that second retrieval and gives you the exact source being installed. Do not add `sudo` in front of process substitution; file-descriptor handling varies. Use the downloaded-file command instead.

Re-running setup offers reconfiguration, repair, adding a destination, changing the schedule, a manual backup or exit. It does not generate duplicate systemd units or cron blocks. Existing archives remain intact.

## Configuration

1. Detect the OS and package manager.
2. Show candidate website, mail and configuration paths.
3. Include detected paths, select individually, or keep the existing selection; add custom paths.
4. Configure detected database clients and select named databases.
5. Choose the local staging/archive directory and an optional remote destination.
6. Authorize the provider and pass a tiny create/read/list/delete connection test.
7. Set independent local/remote retention counts.
8. Select the frequency, backup time and explicit IANA timezone.
9. Optionally limit upload bandwidth in KiB/s.
10. Optionally run the first complete backup before activating the schedule.
11. Activate scheduling and show status/next occurrence.

Local archives always exist long enough to validate and transfer them, including with local retention `0`. Multiple remote destinations can be added after installation. Every configured destination is required for an overall successful run.

Review the discovered source list. Mail authentication maps, panel-specific metadata and unusual document roots cannot always be inferred. If mail storage is not found, enter the actual mailbox path as a custom source or leave it unselected. The tool does not invent a mailbox location.

Database selection saves the current list of names. A database created later is **not automatically added**; rerun `config` to discover/select it. Unsupported database-name characters are reported and need a separate native backup.

## Destinations and verification

| Destination | Transfer | Verification | Resume behavior |
| --- | --- | --- | --- |
| Local server | Temporary archive, then rename | gzip, tar readability, SHA-256 | Interrupted temporary files are removed |
| Google Drive | Official resumable upload, 8 MiB chunks | Parent folder, ID, name, size, MD5 | Persisted session; server-reported byte offsets |
| Dropbox | Official upload sessions, 8 MiB chunks | App-folder path, ID, size, Dropbox content hash | Persisted session and `incorrect_offset` recovery |
| Microsoft OneDrive | Microsoft Graph upload session, 10 MiB chunks | Parent, ID, name, size, SHA-1 where returned | Persisted capability URL and `nextExpectedRanges` |
| Amazon S3 | Direct signed API, multipart above 64 MiB | Final HEAD/size, upload Content-MD5, exact sidecar download | Chunk retries; interrupted multipart aborted and restarted |
| S3-compatible storage | Same SigV4/API implementation | Same checks; endpoint must implement the APIs | Same as S3; no individual vendor certification |
| SFTP / remote Linux | OpenSSH SFTP, partial file then rename | Remote Linux `stat` and SHA-256 | Resume an existing partial file |
| HTTPS WebDAV | Streamed PUT to partial object, then MOVE | Final HEAD/size, exact sidecar download | Whole PUT retries; generic DAV has no portable chunk-resume protocol |

The SHA-256 sidecar is uploaded and its downloaded contents must match exactly. S3 multipart ETags are **not** treated as SHA-256. Dropbox's content hash is computed using its documented 4 MiB block algorithm. Google MD5 and OneDrive SHA-1 checks use the corresponding local algorithm.

All remote adapters implement authorization/configuration, connection testing, upload, metadata verification, listing, deletion and download. Listing includes pagination where the API paginates. HTTP retries are bounded with backoff/jitter and bounded `Retry-After` handling. Invalid JSON, failed TLS/HTTP requests and quota failures do not count as success.

### Local storage

Default: `/var/backups/automate-backups/`, root-owned and mode `0700`. Archives/checksums are private. The wizard accepts another absolute directory. Sources are canonicalized; the backup directory, working data and active Automate Backups credentials are excluded even if a parent source is selected.

Sources `/`, virtual filesystems and known raw database directories are refused. GNU tar stays on one filesystem for each selected source: explicitly add separate mounted source filesystems you want included. Broad `/home`, `/var`, `/etc` or `/srv` selections require confirmation.

### Google Drive setup

1. In your own [Google Cloud project](https://console.cloud.google.com/), enable the Google Drive API.
2. Configure OAuth consent/audience and create a **Desktop app** OAuth client. If the app is in testing, add your account as a test user. Testing-mode refresh tokens may have limited lifetimes; follow Google's production/verification requirements for your audience.
3. Select Google Drive and enter your client ID and secret privately.
4. On a headless server, follow the displayed SSH loopback-forwarding command in a second terminal on your computer. Keep the forwarding connection open during authorization.
5. Open the displayed official Google URL in your computer browser. Choose your own account and approve the requested `drive.file` scope.
6. The loopback listener receives the callback, validates state and exchanges the PKCE-protected code. The browser confirms completion; return to setup.
7. The connection test creates the application/server folders, verifies a tiny object and removes it.

Only app-created/app-used Drive files are requested; full-drive access and deprecated Google out-of-band code flows are not used. No maintainer-owned OAuth secret is embedded. OAuth occurs on Google's own pages; the wizard never asks for a Google account password. Refresh tokens support scheduled operation. The temporary listener binds `127.0.0.1`, expires after ten minutes and closes after receiving a valid callback. No public HTTP port is needed.

### Dropbox setup

Create a **Scoped access / App folder** application in the [Dropbox App Console](https://www.dropbox.com/developers/apps). Enable `files.content.write`, `files.content.read`, `files.metadata.read`, and `account_info.read`. Enter its app key and secret.

The official Dropbox URL requests offline access and uses PKCE. Without a redirect URI Dropbox displays a code; paste that code into the private prompt. The refresh token is stored locally. Backups are under the app folder's `Automate Backups/<server-id>-<destination-id>/` namespace. Reauthorize if you change app scopes.

### Microsoft OneDrive setup

Register your own application in [Microsoft Entra](https://entra.microsoft.com/). Choose the account types you will use, allow **public client flows**, and configure delegated Microsoft Graph `Files.ReadWrite.AppFolder`. The script requests `offline_access` as well.

Enter the application/client ID and tenant (`consumers` for a personal account, or your tenant ID/appropriate organization audience). Visit Microsoft's displayed verification URL, enter the code and approve access. No client secret or account password is requested. Tenant policy may require administrator approval or block device-code authorization.

A dedicated server/destination folder is created under the application's OneDrive app folder. The delegated account must have a provisioned drive. This implementation targets Microsoft Graph's global cloud; sovereign-cloud endpoints are not configurable.

### Amazon S3 setup

Create an existing **general-purpose bucket**, then supply its region, regional HTTPS endpoint, access key and secret key. An optional session token is supported. Temporary AWS credentials do not renew through instance metadata/STS automatically; use `destination reauthorize NAME` to replace them before expiry.

The implementation uses curl's maintained AWS Signature Version 4 signer directly, with an explicit payload hash. It does not depend on the AWS CLI or SDK. Path-style bucket addressing is used. S3 Express/directory buckets are not supported.

Grant only the required permissions on your dedicated bucket/prefix:

- `s3:ListBucket` on the bucket, limited to the application prefix where practical.
- `s3:GetObject`, `s3:PutObject`, `s3:DeleteObject` and `s3:AbortMultipartUpload` on `Automate-Backups/*` or a more restricted installed namespace.
- Any additional KMS permissions your bucket's server-side encryption policy requires.

No bucket is created, made public or reconfigured. Configure a bucket lifecycle rule to abort stale incomplete multipart uploads after an appropriate period. The tool aborts failed uploads and records an unfinished upload for another abort attempt, but power loss or `SIGKILL` can interrupt cleanup.

Retention issues ordinary object DELETE requests. With S3 versioning, historical object versions may remain billable; manage noncurrent versions with your own bucket policy. Object Lock/retention policies can prevent deletion, in which case cleanup reports failure and preserves remaining data.

### S3-compatible storage setup

Use the S3-compatible menu option, then provide the HTTPS endpoint **without a bucket or path**, bucket, signing region and credentials. The endpoint must support path-style addressing, SigV4, ListObjectsV2, HEAD, multipart upload and ordinary GET/PUT/DELETE. There is no arbitrary signing override or insecure-HTTP option. The per-destination connection test is mandatory; no specific third-party vendor is claimed as live-tested.

### SFTP setup

Use a remote Linux account with standard `find`, `stat`, `sha256sum`, SFTP and permission to create its dedicated backup directory. Provide an existing root-readable SSH private key with mode `0600` and unattended authentication suitable for scheduled jobs. A password prompt or an interactive-only SSH agent is unsuitable for nightly operation.

Setup displays host-key fingerprints. **Independently compare them** with your remote server/provider console before accepting. A key fetched over the network is not identity verification on its own. Scheduled connections require the pinned host keys; changed fingerprints are never silently accepted.

The remote base path is deliberately restricted to simple absolute paths without spaces or `..`. A server/destination-specific subdirectory is created with restrictive permissions. SFTP is used for data transfer; SSH runs the remote Linux metadata/hash/list commands. This is not an SFTP-only appliance adapter.

### WebDAV setup

Enter an existing HTTPS collection URL, username and password/application password. The server must support MKCOL, Depth-1 PROPFIND, PUT, MOVE, HEAD, GET and DELETE. It creates a dedicated child collection. Redirecting endpoints should be replaced with their final HTTPS collection URL. TLS validation stays enabled.

A PUT streams from disk; the complete archive is not loaded into RAM. A failed PUT may leave a `.partial` object; it is reused/replaced on retry and never included in successful retention. Generic WebDAV cannot promise provider-specific chunking or multipart resume.

### Unsupported providers: pCloud and Box

**Not supported in version 1.0.0.** They are intentionally absent from the menu. Their regional OAuth/API behavior (pCloud) and OAuth rotation/chunked-upload lifecycle (Box) need dedicated implementation and validation before being offered. There are no placeholder provider functions or pretend successful integrations.

## Scheduling

```bash
sudo automate-backups schedule
```

Choose daily, every N calendar days, weekly, selected weekdays, monthly (days 1–28), or a custom systemd calendar. Custom expressions omit the timezone; the chosen timezone is appended. The time and IANA timezone are stored explicitly and do not change the server's timezone.

On systemd hosts, a oneshot service and persistent timer run the job and exit. `Persistent=true` allows systemd to trigger a missed timer after downtime. For interval schedules, the current local date must still match the saved calendar-day anchor; this version does not replay every missed interval. DST nonexistent times may be skipped; a repeated daily time is dispatched at most once. Monthly dates beyond day 28 are excluded deliberately.

Without systemd, a tagged root-crontab entry checks once per minute. It evaluates dates with the configured `TZ` instead of assuming `CRON_TZ` is supported. The cron service must already be installed and enabled. Cron does not replay jobs missed while the server was off. A slot is marked before running, so a failure is not retried every minute; use `run` or `retry` explicitly.

`flock` serializes backups, destination management, configuration changes and diagnostics. A second operation prints the active PID and start time. Normal backups use `nice` and `ionice` when available. No daemon waits for the next backup.

## Retention and failure handling

```bash
sudo automate-backups retention
```

Local and remote counts are independent. Each remote destination has its own count, at least `1`. Local-only operation requires at least one local backup. Local retention `0` keeps a validated archive until all configured remote copies and sidecars have been verified.

The sequence is:

1. Estimate space and check free disk.
2. Create native database dumps and metadata.
3. Create `.tar.gz.partial` and validate gzip/tar readability.
4. Rename to the final archive, create the SHA-256 sidecar and verify it.
5. Upload and verify both files on every configured remote destination.
6. Mark the backup successful.
7. Apply remote retention, then local retention.
8. Remove temporary work files.

A failed local backup or failed upload does not prune old successful sets. Failed/pending local archives can accumulate by design: repair the problem and retry them, or review and remove them manually. Space estimates are conservative heuristics, not a guaranteed hard filesystem quota. Do not depend on compression ratios to squeeze a backup onto an almost-full disk.

Only root-owned JSON ledger records with this installation's persistent server ID identify retention candidates. A failed listing, missing pair, inconsistent size or damaged ledger disables cleanup. Unrelated remote files are ignored. Two-file deletion is not transactional on these services: a failed/interrupted deletion is marked `PRUNING` and quarantined for manual inspection.

The oldest successful sets are selected by their original creation time. A retry of an older backup does not become a newly dated backup. If the hostname changes, filenames change but the persistent server ID and remote namespace keep ownership stable. A new installation with a new ID cannot prune the old installation's backups.

Protect `/var/lib/automate-backups/` separately if you want to retain the CLI's ownership/download index during disaster recovery. It is excluded from workload archives because upload-session URLs are credentials. Without this ledger, use the provider UI/native tools to download existing archives; the tool intentionally does not guess ownership or reconstruct deletion rights from filenames. Reauthorizing the same configured destination preserves its namespace; removing and adding it creates a new destination ID.

## Commands

```bash
sudo automate-backups run
sudo automate-backups status
sudo automate-backups list
sudo automate-backups logs
sudo automate-backups logs 250
sudo automate-backups doctor
sudo automate-backups config
sudo automate-backups schedule
sudo automate-backups retention
sudo automate-backups destination list
sudo automate-backups destination add
sudo automate-backups destination test drive
sudo automate-backups destination reauthorize drive
sudo automate-backups destination remove drive
sudo automate-backups retry BACKUP_ID
sudo automate-backups download BACKUP_ID drive /root/recovery
sudo automate-backups verify /root/recovery/ARCHIVE.tar.gz
automate-backups version
automate-backups help
```

Replace `drive` with the name you selected and `BACKUP_ID` with the ID from `list`; `ARCHIVE.tar.gz` is your actual filename. Create the download directory first. Omitting the destination name uses the first available recorded verified destination. `download` validates before committing files and refuses to overwrite existing output. Downloads require space in both the working and destination filesystems.

`config` offers source/database selection, archive directory/bandwidth, scheduling and retention. Changes are validated and staged before activation. Changing the archive directory does not relocate earlier archives; cleanup skips mismatched old paths rather than deleting them. Move old backups manually only after reviewing their ledger paths.

`doctor` reports detected sources/clients, binary availability, config validity, free space, scheduler, last backup, authorization state and quota where available. It does not upload/delete data or rotate an expired OAuth token. Use `destination test NAME` to exercise refresh and the complete provider round trip.

## Runtime files

| Path | Purpose |
| --- | --- |
| `/usr/local/sbin/automate-backups` | Installed copy of `setup.sh` |
| `/etc/automate-backups/config.conf` | Private JSON configuration; never sourced as shell |
| `/etc/automate-backups/providers/NAME.conf` | Configured provider credentials and namespace only |
| `/etc/automate-backups/providers/NAME.known_hosts` | Pinned SFTP host keys, if configured |
| `/etc/automate-backups/mysql.cnf` | Native MySQL/MariaDB login options, if configured |
| `/etc/automate-backups/postgres.pass` | libpq password file, if configured |
| `/etc/automate-backups/mongo.yml` | MongoDB native-tool connection config, if configured |
| `/var/lib/automate-backups/server-id` | Persistent installation ownership ID |
| `/var/lib/automate-backups/records/` | Atomic per-backup JSON state |
| `/var/lib/automate-backups/sessions/` | Private resumable-session state |
| `/var/lib/automate-backups/work.*` | Per-operation temporary files |
| `/var/log/automate-backups/automate-backups.log` | Private operational log |
| `/var/backups/automate-backups/` | Default archive/checksum location |
| `/etc/systemd/system/automate-backups.service` | systemd oneshot job |
| `/etc/systemd/system/automate-backups.timer` | systemd schedule |

Configuration/state/credentials use private directories and `0600` files. Provider files are created only when configured. A failed add may retain a private `.pending` file for review; it is never scheduled. Logs rotate on backup start above 5 MiB, keeping five prior files. Long-lived JSON backup records are intentionally not automatically discarded because they establish ownership/history.

## Recovery

Keep a copy of this guide and practice on a separate server. The outer archive is ordinary gzip-compressed tar:

```text
metadata/backup-manifest.json
metadata/*.txt
database/mysql/DB.sql
database/mysql/accounts-and-grants.sql
database/postgres/DB.sql
database/postgres/globals.sql
database/mongo/DB.archive.gz
filesystem/var/www/...
filesystem/etc/...
filesystem/<other original absolute paths without the leading slash>
```

Not every optional file appears in every backup. Native MongoDB dumps require `mongorestore`, but the enclosing tar archive has no Automate Backups-specific decoder.

First download **both** the archive and its `.sha256` sidecar, using the CLI if its ledger survives, or the provider's ordinary UI/API if it does not. Keep filenames unchanged.

```bash
cd /root/recovery
sha256sum -c server.example.com-full-2026-09-27_14-10-25_UTC.tar.gz.sha256
gzip -t server.example.com-full-2026-09-27_14-10-25_UTC.tar.gz
tar -tzf server.example.com-full-2026-09-27_14-10-25_UTC.tar.gz
mkdir -m 700 restore-staging
tar --numeric-owner --acls --xattrs --selinux -xzf server.example.com-full-2026-09-27_14-10-25_UTC.tar.gz -C restore-staging
```

On tar implementations without ACL/xattr/SELinux support, ordinary `tar -xzf ARCHIVE.tar.gz -C restore-staging` still extracts files, but cannot reproduce all security metadata. Extract as root only in a trusted, private staging directory when restoring numeric ownership. Inspect an archive before extracting it; do not extract an untrusted archive as root.

The archive's own SHA-256 cannot be embedded inside itself without changing that checksum. The manifest explains this and the final digest lives in the external sidecar and local ledger.

A conservative recovery sequence:

1. Provision a clean OS and install matching service/database versions, using the saved package/version metadata as a reference.
2. Review `metadata/backup-manifest.json` and the included source list. Recreate only necessary users/groups with the correct UID/GID; do not blindly overwrite account databases.
3. Review service configuration in staging and adapt hostnames, paths, interfaces, credentials and permissions to the new host.
4. Review database role/grant files before import. MariaDB/MySQL account syntax and password hashes are version-specific; broad grants include accounts beyond the selected application databases when that option was enabled. PostgreSQL globals may include powerful roles and password hashes.
5. Import databases into an isolated/matching database service first. For example, use the native `mariadb`/`mysql` client for `.sql`, `psql -v ON_ERROR_STOP=1` for PostgreSQL roles/SQL, and `mongorestore --archive=DB.archive.gz --gzip` for the MongoDB archive. Supply connection credentials privately; do not put passwords in command lines. Database dump files can contain CREATE DATABASE statements and privileged grants—inspect them first.
6. Copy reviewed application files and mailboxes from `filesystem/` to the intended targets with ownership/ACL/xattr preservation. Stop or quiesce the affected service for the actual cutover.
7. Validate configuration with the service's own test command before starting/reloading it. Confirm database access, app health, mail users/mappings and TLS behavior.
8. Review cron and custom systemd units before enabling them; they may reference unavailable paths or duplicate the backup scheduler.
9. Reinstall Automate Backups, recreate cloud/DB authorization, and run a new backup/recovery test.

There is deliberately no command that overwrites a live site, database, mailbox or entire `/etc` tree.

## Security and backup integrity

**There is no archive-level encryption.** Archives may include private keys, mailbox contents, configuration passwords and database authentication hashes. Local permissions and transport encryption do not turn an archive into an encrypted file. Choose a destination/account whose access controls and provider-side security meet your requirements. SHA-256 checksums detect accidental corruption; unsigned sidecars are not proof against an attacker who can replace both files.

Cloud traffic uses official HTTPS endpoints or administrator-configured HTTPS storage; SSH/SFTP uses pinned host keys. OAuth account passwords never enter this tool. Secrets are provided to curl through private configuration/body files and to database tools through private native config files, rather than ordinary process arguments. Provider/API responses are data, never shell code. Active destination credentials and upload-session URLs are excluded from backups.

Selected service configuration may itself contain service credentials; this is necessary for that selected recovery scope. `/etc/shadow` and unrelated home-directory credentials are not automatically selected. Administrators should review broad custom paths and secure local crash/storage access appropriately.

Optional webhook notifications and an automatic updater are not implemented in this release. Use your existing monitoring to check command exit codes, logs, successful backup age and restore drills. A successful backup with skipped retention is visible in `status`; it may need attention even if the backup itself is valid.

## Troubleshooting

| Symptom | Action |
| --- | --- |
| Insufficient local space | Free capacity outside protected backups, choose a larger directory, reduce the selected sources or retry a retained upload. No pre-backup pruning is performed. |
| Remote quota insufficient | Increase/free provider storage or reduce retention through an independently reviewed cleanup. Old backups are not preemptively deleted to make room. |
| OAuth `invalid_grant`, revoked access or expired authorization | Run `destination reauthorize NAME`; review app audience/scopes/testing status. Local archives remain. |
| Temporary AWS session credentials expired | Reauthorize the S3 destination with new credentials; automatic IAM-role/STS refresh is not provided. |
| First connection test fails | Check app scopes, endpoint, region, folder/bucket permissions, CA certificates and account policy. The destination is not activated. |
| Known-host mismatch | Investigate the remote server identity. Compare fingerprints independently and deliberately replace the pinned key only after verification. |
| Archive fails because a file changed | Quiesce the relevant workload or narrow sources. The backup is not labeled successful. |
| Missing DB utility or grant privilege | Install a matching native client or adjust the backup account/selection. The tool does not silently substitute raw database files. |
| HTTP 401/403 | Check authorization, provider policy and permission scopes. Routine logs deliberately omit sensitive provider response bodies. |
| Large transfer interrupted | `retry BACKUP_ID` uses retained local files. Google/Dropbox/OneDrive sessions may resume until provider expiry; SFTP resumes partial files. S3 aborts/restarts a multipart job; WebDAV repeats the PUT. |
| Remote cleanup skipped | Check `status`, logging, ledger consistency and provider listing/deletion permissions. Do not edit IDs to guess ownership. |
| State lost or newly installed server | Download by the provider UI/native API. Verify/extract with normal tools. Old remote objects are not automatically adopted for deletion. |
| Power loss or forced `SIGKILL` | Inspect root-owned `work.*`, local `.partial`, and provider partial/multipart objects once no backup is active. Catchable signals are cleaned automatically; uncatchable termination cannot run traps. |
| Scheduled backup missing | Inspect the systemd timer or ensure cron/crond is running. Check the configured timezone, last slot, storage and authentication. |

## Uninstall and update

```bash
sudo automate-backups uninstall
sudo automate-backups uninstall --purge
```

Normal uninstall disables/removes the project's schedule and CLI and stops a recognized active backup safely. It retains configuration, provider tokens, ownership state, logs and **all archives** for reinstall. Purge also removes project configuration/tokens/state/logs. It never targets the configured local archive directory or calls a remote deletion API. The archive location is printed.

After purge, the old server ID/ledger is gone unless independently saved; old remote archives survive but must be accessed manually. Revoking app access at the provider is a separate account-management action.

For an update, download the new `setup.sh` over HTTPS, inspect the diff, run `bash -n setup.sh` and the tests, then run `sudo bash setup.sh` and select **Repair installation**. The installer snapshots the old executable/configuration/schedule and rolls back on activation failure. Packages installed to satisfy missing dependencies are not automatically removed during rollback. Back up the old executable independently if you want a long-term downgrade copy; there is no arbitrary-URL self-updater.

## Testing and contributions

```bash
bash -n setup.sh
bash setup.sh self-test
bash -n tests/contracts.sh
bash tests/contracts.sh
*# If ShellCheck is installed:*
shellcheck setup.sh tests/contracts.sh
```

`self-test` uses private temporary fixtures for config validation, source discovery, archives/checksums, retention counts, failure preservation, interruption cleanup, locking, schedule generation and installer lifecycle. It does not install host packages, activate a host schedule or upload user data. `tests/contracts.sh` blocks accidental real network calls and tests representative protocol responses, token lifecycle, hashes, quota/list failures, native database command adapters and local-zero retention.

Offline fixtures verify local behavior against modeled API contracts. They do not validate real OAuth policies, upload URLs, XML server behavior, provider quotas, database compatibility or recovery correctness in your environment. Live tests and independent review remain necessary before wider deployment.

Contributions are welcome under the MIT license. Include the reason for the change, relevant non-destructive tests and the platforms/provider accounts actually tested. Preserve working code outside the requested scope. Provider additions must include real authorization, upload, verification, list/delete/download, failure handling and public official documentation—never a placeholder menu entry.

## References

- [Google installed-app OAuth / loopback + PKCE](https://developers.google.com/identity/protocols/oauth2/native-app)
- [Google Drive resumable upload](https://developers.google.com/workspace/drive/api/guides/manage-uploads)
- [Dropbox HTTP API](https://www.dropbox.com/developers/documentation/http/documentation)
- [Dropbox content hash](https://www.dropbox.com/developers/reference/content-hash)
- [Microsoft device-code authorization](https://learn.microsoft.com/en-us/entra/identity-platform/v2-oauth2-device-code)
- [Microsoft Graph app folders](https://learn.microsoft.com/en-us/graph/onedrive-sharepoint-appfolder)
- [Microsoft Graph upload sessions](https://learn.microsoft.com/en-us/graph/api/driveitem-createuploadsession?view=graph-rest-1.0)
- [curl AWS SigV4](https://curl.se/libcurl/c/CURLOPT_AWS_SIGV4.html)
- [S3 CompleteMultipartUpload and embedded errors](https://docs.aws.amazon.com/AmazonS3/latest/API/API_CompleteMultipartUpload.html)
- [WebDAV specification](https://www.rfc-editor.org/rfc/rfc4918)

## License

Licensed under the [MIT License](LICENSE).