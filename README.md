<div align="center">

<img src="docs/assets/logo.svg" width="120" alt="">

# Bitwarden_Export

**Never lose your passwords.**

[![CI](https://github.com/0neTX/Bitwarden_Export/actions/workflows/ci.yml/badge.svg?branch=dev)](https://github.com/0neTX/Bitwarden_Export/actions/workflows/ci.yml)
[![Release](https://github.com/0neTX/Bitwarden_Export/actions/workflows/docker-publishhub-latest.yml/badge.svg)](https://github.com/0neTX/Bitwarden_Export/actions/workflows/docker-publishhub-latest.yml)
[![Latest release](https://img.shields.io/github/v/release/0neTX/Bitwarden_Export?label=release)](https://github.com/0neTX/Bitwarden_Export/releases)
[![Docker pulls](https://img.shields.io/docker/pulls/0netx/bw-export?logo=docker&label=pulls)](https://hub.docker.com/r/0netx/bw-export)
[![Image size](https://img.shields.io/docker/image-size/0netx/bw-export/latest?logo=docker&label=size)](https://hub.docker.com/r/0netx/bw-export/tags)
[![License](https://img.shields.io/badge/license-GPL--3.0--only-blue)](LICENSE)

</div>

---

Your vault holds every password you have. Bitwarden_Export keeps an encrypted copy of it on your own disk — passwords, organizations and attachments — day after day, without you having to remember. Set it up once, and it tells you if a backup ever fails.

## Table of contents

- [Features](#features)
- [Requirements](#requirements)
- [Quick start](#quick-start)
- [Examples](#examples)
- [What it produces](#what-it-produces)
- [Configuration](#configuration)
- [Several vaults](#several-vaults)
- [Handling secrets](#handling-secrets)
- [Notifications](#notifications)
- [Monitoring](#monitoring)
- [Scheduling](#scheduling)
- [Retention](#retention)
- [Encrypted attachments](#encrypted-attachments)
- [Permissions of the backups](#permissions-of-the-backups)
- [Off-site copy (3-2-1)](#off-site-copy-3-2-1)
- [File ownership: PUID and PGID](#file-ownership-puid-and-pgid)
- [Hardened setup](#hardened-setup)
- [Platform notes](#platform-notes)
- [Image tags](#image-tags)
- [Troubleshooting](#troubleshooting)
- [Upgrade notes](#upgrade-notes)
- [Development](#development)
- [Contributing](#contributing)
- [Security](#security)
- [Credits](#credits)
- [Disclaimer](#disclaimer)
- [License](#license)

## Features

- Exports your **personal vault** to JSON, plain or password-encrypted.
- Exports your **organization vaults** (every one you own or administer, or the ones you list).
- Exports **several accounts in one container**, even on different servers, each into a folder of its own ([details](#several-vaults)).
- Downloads **file attachments**, one subfolder per vault item, or packs them into **one encrypted archive** with `ENCRYPT_ATTACHMENTS` ([details](#encrypted-attachments)).
- Keeps **passwords off the command line**, so other users on the host cannot read them with `ps` ([details](#passwords-stay-off-the-command-line)).
- Reads its credentials from **Docker secrets** or from **[Infisical](#option-b-infisical)** instead of the compose file.
- Sends the outcome to any platform supported by **[Shoutrrr](https://shoutrrr.nickfedor.com/latest/services/overview/)** (Telegram, Gotify, and about thirty more), with a **summary** of what was backed up.
- Pings a **watchdog** (healthchecks, uptime-kuma, any dead man's switch) at start and on completion.
- **Prunes old exports** automatically: the last N with `KEEP_LAST_BACKUPS`, or daily/weekly/monthly with `KEEP_GFS` ([details](#retention)).
- Pairs with an **rclone sidecar** for an off-site copy ([details](#off-site-copy-3-2-1)).
- Runs **without root**, with a read-only filesystem and no capabilities, for a container that stays up with `CRON` ([details](#hardened-setup)).
- Exits with the export's own status code, so `restart: on-failure`, cron and orchestrators see a failed backup as a failure.

## Requirements

- [Docker](https://docker.com) or Podman. Linux, macOS and Windows all work; adapt the compose file to your host.
- **Personal API key** for CLI authentication: [how to get it](https://bitwarden.com/help/personal-api-key/).
- If you self-host, a server reachable over **HTTPS**. The Bitwarden CLI refuses plain-HTTP URLs.
- **Vaultwarden 1.37.4 or later.** The bundled Bitwarden CLI (2026.11.0) calls an endpoint older Vaultwarden releases do not have, and the export then fails with `Failed to unlock vault with BW_PASSWORD` even though the password is right ([vaultwarden#7693](https://github.com/dani-garcia/vaultwarden/pull/7693)). bitwarden.com is not affected.

## Quick start

### Docker Compose (recommended)

Copy [`docker-compose.yml`](docker-compose.yml) from this repository, fill in the three credentials and the export password, and run it:

```yaml
services:
  bw-export:
    container_name: bw-export
    image: 0netx/bw-export:latest
    volumes:
      - ./export/data:/var/data
      - ./export/attachments:/var/attachments
    environment:
      - BW_CLIENTID=<CLIENT ID FROM BITWARDEN API>
      - BW_CLIENTSECRET=<CLIENT SECRET FROM BITWARDEN API>
      - BW_PASSWORD=<BITWARDEN PASSWORD>
      - EXPORT_PASSWORD=<EXPORT PASSWORD>
      # Server: leave commented out for bitwarden.com.
      # - BW_URL_SERVER=https://vault.example.com
```

The file lists every other option, commented out.

```bash
docker compose up
```

The container performs one export and exits with the export's status code.

### Docker Compose with built-in CRON

If you want the container to stay running and run backups on a schedule (for example daily at 03:00), use [`docker-compose.cron.sample.yml`](docker-compose.cron.sample.yml):

```yaml
services:
  bw-export:
    container_name: bw-export
    image: 0netx/bw-export:latest
    restart: unless-stopped
    volumes:
      - ./export/data:/var/data
      - ./export/attachments:/var/attachments
    environment:
      - BW_CLIENTID=<CLIENT ID FROM BITWARDEN API>
      - BW_CLIENTSECRET=<CLIENT SECRET FROM BITWARDEN API>
      - BW_PASSWORD=<BITWARDEN PASSWORD>
      - EXPORT_PASSWORD=<EXPORT PASSWORD>
      # Server: leave commented out for bitwarden.com.
      # - BW_URL_SERVER=https://vault.example.com
      - CRON=0 3 * * *
      - TZ=Europe/Madrid
      - KEEP_LAST_BACKUPS=5
      - FILE_LOG=/var/data/bw-export-logfile.log
```

```bash
docker compose -f docker-compose.cron.sample.yml up -d
```

The container validates the `CRON` expression, runs an initial backup immediately on startup, and keeps running to execute scheduled backups.

### Plain `docker run`

```bash
docker run --name bw-export \
  -v ./export/data:/var/data \
  -v ./export/attachments:/var/attachments \
  -e BW_CLIENTID=<CLIENT ID FROM BITWARDEN API> \
  -e BW_CLIENTSECRET=<CLIENT SECRET FROM BITWARDEN API> \
  -e BW_PASSWORD=<BITWARDEN PASSWORD> \
  -e EXPORT_PASSWORD=<EXPORT PASSWORD> \
  0netx/bw-export:latest
```

### Without Docker

The script can also be run directly from a terminal, which prompts for what it needs:

```bash
bash bw_export.sh
```

## Examples

Each example is a complete compose file. They go from the simplest to the most complete; start with the first and move on when you need what the next one adds.

| File | What it adds | Start with |
|---|---|---|
| [`docker-compose.yml`](docker-compose.yml) | One backup, then exit. Lists every option, commented out. | `docker compose up` |
| [`docker-compose.cron.sample.yml`](docker-compose.cron.sample.yml) | Backups on a schedule, with retention. See [Scheduling](#scheduling). | `docker compose -f docker-compose.cron.sample.yml up -d` |
| [`docker-compose.secrets.sample.yml`](docker-compose.secrets.sample.yml) | Credentials as Docker secrets. See [Option A](#option-a-docker-secrets). | `docker compose -f docker-compose.secrets.sample.yml up` |
| [`docker-compose.multi.sample.yml`](docker-compose.multi.sample.yml) | Several accounts, on bitwarden.com or self-hosted servers, each into a subfolder. See [Several vaults](#several-vaults). | `docker compose -f docker-compose.multi.sample.yml up` |
| [`docker-compose.infisical.sample.yml`](docker-compose.infisical.sample.yml) | Credentials from Infisical. See [Option B](#option-b-infisical). | `docker compose -f docker-compose.infisical.sample.yml up` |
| [`docker-compose.hardened.sample.yml`](docker-compose.hardened.sample.yml) | Schedule and secrets, without root, capabilities or a writable image. See [Hardened setup](#hardened-setup). | `docker compose -f docker-compose.hardened.sample.yml up -d` |
| [`docker-compose.offsite.sample.yml`](docker-compose.offsite.sample.yml) | A second copy off the host with an rclone sidecar. See [Off-site copy](#off-site-copy-3-2-1). | `docker compose -f docker-compose.offsite.sample.yml up -d` |
| [`compose.podman.yml`](compose.podman.yml) | Not standalone: an override for rootless Podman, added to any of the above. See [Rootless Podman](#rootless-podman). | `podman compose -f docker-compose.yml -f compose.podman.yml up` |

All of them write the exports to `./export/data` and the attachments to `./export/attachments`, next to the compose file, and leave `BW_URL_SERVER` commented out, which means bitwarden.com.

## What it produces

Every run writes a dated folder, `<DateTime>-bw-export`, into the output path:

- a JSON file with your **personal vault** (password-encrypted when `EXPORT_PASSWORD` is set — recommended),
- a JSON file per **organization vault**, if you export any,
- a folder with your **attachments**, one subfolder per vault item, or a single `attachments.tar.gz.gpg` when `ENCRYPT_ATTACHMENTS` is on.

The log ends with a summary of the run, which is also what the [notification](#notifications) carries:

```text
----- Summary -----
Duration: 41s
Personal vault: exported (encrypted)
Organizations: 1 exported, 1 skipped, 0 failed
Attachments: 14 saved, 0 failed (encrypted archive)
Backup size: 3.2MiB
Old backups deleted: 1
-------------------
```

The Bitwarden CLI cannot export items in your **Trash** or your **password history**, so neither is included.

## Configuration

Every variable below that carries a secret (`BW_CLIENTID`, `BW_CLIENTSECRET`, `BW_PASSWORD`, `EXPORT_PASSWORD`, `NOTIFICATION_URL`, `PING_URL`) can be given instead as `NAME_FILE`, the path of a file holding it. See [Option A: Docker secrets](#option-a-docker-secrets).

### Required

| Variable | Description |
|---|---|
| `BW_CLIENTID` | The `client_id` of your [personal API key](https://bitwarden.com/help/personal-api-key/). |
| `BW_CLIENTSECRET` | The `client_secret` of that API key. |
| `BW_PASSWORD` | Your Bitwarden/Vaultwarden master password. |

### Recommended

| Variable | Description |
|---|---|
| `EXPORT_PASSWORD` | Encrypts the export files. Use a strong password you can remember, and **do not store it only inside Bitwarden**: if you get locked out of your account you could not decrypt your own backups. Left unset, the exports are written in plain text. |

### Optional

| Variable | Default | Description |
|---|---|---|
| `BW_URL_SERVER` | bitwarden.com | URL of your self-hosted Vaultwarden/Bitwarden server. Must be HTTPS. |
| `BW_ORGANIZATIONS_LIST` | every organization you own or administer | Comma-separated organization IDs to export, or `none` to export no organization. |
| `OUTPUT_PATH` | `/var/data/` | Where the vault exports are written. The path must exist in the container, normally as a mounted volume. |
| `ATTACHMENTS_PATH` | `/var/attachments/` | Where the attachments are written, same condition. |
| `KEEP_LAST_BACKUPS` | keep everything | Keep only the N newest export folders, delete the rest. See [Retention](#retention). |
| `KEEP_GFS` | — | Keep the newest export of each recent day, week, month and year, e.g. `7d:4w:6m`. Can be combined with `KEEP_LAST_BACKUPS`. See [Retention](#retention). |
| `BACKUP_PERMISSIONS` | `default` | `private` makes each run's folders `700` and its files `600`, so only their owner can read them. See [Permissions of the backups](#permissions-of-the-backups). |
| `ENCRYPT_ATTACHMENTS` | `false` | `true` packs the attachments into one archive encrypted with `EXPORT_PASSWORD`, which must then be set. See [Encrypted attachments](#encrypted-attachments). |
| `FILE_LOG` | container-only log | Path of the run log, e.g. `/var/data/bw-export-logfile.log`. Point it inside a mounted volume or it is lost with the container. When `CRON` is enabled, appends across runs and rotates to `<FILE_LOG>.1` at 100 MiB. |
| `CRON` | — (one-shot) | Standard 5-field cron expression (e.g. `0 3 * * *`) or macro (`@daily`, `@hourly`, etc., powered by `supercronic`). Validates the expression on startup (exiting `1` if invalid), runs an initial backup immediately, and keeps running for scheduled backups (skipping overlapping runs; if the initial backup fails, the scheduler keeps running). Recommended: set `restart: unless-stopped`. |
| `TZ` | `UTC` | Timezone for logs and `CRON` schedules (e.g. `Europe/Madrid`, `America/New_York`). |
| `NOTIFICATION_URL` | — | Shoutrrr URL for the start/success/failure messages. See [Notifications](#notifications). |
| `NOTIFICATION_LEVEL` | `all` | `failure` sends a message only when a run fails. See [Notifications](#notifications). |
| `PING_URL` | — | Watchdog endpoint pinged at start and on completion. See [Monitoring](#monitoring). |
| `INFISICAL_TOKEN` | — | Infisical service token, to read the credentials from Infisical. See [Option B](#option-b-infisical). |
| `INFISICAL_PATH` | token's own path | *Secrets Path* of that service token. |
| `PUID` / `PGID` | `0` (root) | Host user and group the exported files should belong to. See [PUID and PGID](#file-ownership-puid-and-pgid). |

### Volumes

| Path | Contents |
|---|---|
| `/var/data` | Vault exports. |
| `/var/attachments` | Attachments. |

## Several vaults

One container can back up several accounts, on bitwarden.com or on different self-hosted servers. List them in `BW_VAULTS` and give each one its settings with its name in capitals after `VAULT_`:

```yaml
environment:
  - BW_VAULTS=personal,work
  - VAULT_PERSONAL_BW_CLIENTID=<client id>
  - VAULT_PERSONAL_BW_CLIENTSECRET=<client secret>
  - VAULT_PERSONAL_BW_PASSWORD=<master password>
  - VAULT_WORK_BW_URL_SERVER=https://vault.example.com
  - VAULT_WORK_BW_CLIENTID=<client id>
  - VAULT_WORK_BW_CLIENTSECRET=<client secret>
  - VAULT_WORK_BW_PASSWORD_FILE=/run/secrets/work_password
  - EXPORT_PASSWORD=<export password>     # for every vault without its own
```

See [`docker-compose.multi.sample.yml`](docker-compose.multi.sample.yml).

- **Names** may use letters, digits and `_`, because they become part of variable names. Each vault writes into a subfolder named after it in lower case: `/var/data/personal/<DateTime>-bw-export` and `/var/attachments/personal/…`.
- **Credentials and server belong to each vault and are never shared:** `BW_CLIENTID`, `BW_CLIENTSECRET`, `BW_PASSWORD` (or their `_FILE` forms) and `BW_URL_SERVER`. Without a server, a vault uses bitwarden.com.
- **These options apply to every vault unless a vault sets its own:** `EXPORT_PASSWORD` (or `EXPORT_PASSWORD_FILE`), `BW_ORGANIZATIONS_LIST`, `ENCRYPT_ATTACHMENTS`, `BACKUP_PERMISSIONS`, `KEEP_LAST_BACKUPS` and `KEEP_GFS`. An empty value turns an option off for that vault, e.g. `VAULT_WORK_KEEP_GFS=`.
- **Everything else is shared by the whole run:** `CRON`, `TZ`, `FILE_LOG`, the notification, `PING_URL`, `PUID`/`PGID` and Infisical.
- **One mode or the other.** With `BW_VAULTS`, setting `BW_CLIENTID`, `BW_CLIENTSECRET`, `BW_PASSWORD` or `BW_URL_SERVER` without a prefix is an error and nothing is exported. A `VAULT_` variable that matches no vault, such as a typo, is reported as a warning.
- **The vaults are exported one after another**, each with its own CLI session. A vault that fails does not stop the others, and the run then exits `1`.
- **One notification and one ping** cover the whole run. The summary has a line per vault with its duration and size, and leaves out counts that are 0:

  ```text
  Vaults: 1 of 2 failed, 1 exported, in 19s

  ✅ personal (7s, 772KiB)
     Personal vault: exported (encrypted)
     Organizations: 1 exported
     Attachments: none

  ❌ work (failed with exit 1, 12s, 0B)
     Personal vault: FAILED
     Organizations: 2 failed
     Attachments: none
  ```

Without `BW_VAULTS` nothing changes: the single vault is configured as before and writes straight into `/var/data`.

## Handling secrets

This container automates the official [Bitwarden CLI](https://bitwarden.com/help/cli/). **It does not save, trace or store any information of its own**, and the CLI session is closed once the backup is done.

### Passwords stay off the command line

Any user on the host can read the command line of any process with `ps`, including processes inside a container, under Docker as under Podman. So the script never passes a password as an argument:

- the master password (`BW_PASSWORD`) reaches `bw unlock` through an environment variable (`--passwordenv`), which only the process owner and root can read;
- the export password (`EXPORT_PASSWORD`) reaches `bw export` through stdin, answering the CLI's own prompt. That prompt is kept out of the log, since it is redrawn once per character and would give away the password's length.

Nothing has to be configured for this. Each of the six secret-carrying variables (`BW_CLIENTID`, `BW_CLIENTSECRET`, `BW_PASSWORD`, `EXPORT_PASSWORD`, `NOTIFICATION_URL` and `PING_URL`) also has a **`_FILE` variant**, such as `BW_PASSWORD_FILE`, that holds the path of a file with the value: the convention of the official Docker images (`POSTGRES_PASSWORD_FILE` and the like). With files, the container's configuration holds only paths, so `docker inspect` shows no secret. A value is read only when it is used, and handed only to the program that needs it.

- **`NAME_FILE`** is always a path. A file that does not exist, cannot be read or is empty is reported: for a credential the run stops, and a notification or ping URL is skipped with a warning. Setting both `NAME` and `NAME_FILE` is the same kind of error.
- **`NAME`** keeps working as before: the value itself, or the path of a file holding it. A path under `/run/secrets` that does not exist is treated as a secret that was not mounted, never as a literal value.
- If `EXPORT_PASSWORD` or `EXPORT_PASSWORD_FILE` is set but no password can be read from it, the run fails: the vault is never exported unencrypted in its place.

### Option A: Docker secrets

```bash
mkdir -p ./.secrets && chmod 700 ./.secrets
echo '<client id>'        > ./.secrets/.bwclientid
echo '<client secret>'    > ./.secrets/.bwsecret
echo '<master password>'  > ./.secrets/.bwpassword
echo '<export password>'  > ./.secrets/.exportpassword
# Optional, only if you use them:
echo '<shoutrrr url>'     > ./.secrets/.notificationurl
echo '<ping url>'         > ./.secrets/.pingurl
chmod 400 ./.secrets/.*
```

The notification and ping secrets are optional. Leave their lines commented out unless you created their files: Compose refuses to start with a secret whose file does not exist.

```yaml
services:
  bw-export:
    container_name: bw-export
    image: 0netx/bw-export:latest
    volumes:
      - ./export/data:/var/data
      - ./export/attachments:/var/attachments
    environment:
      - BW_CLIENTID_FILE=/run/secrets/bwclientid
      - BW_CLIENTSECRET_FILE=/run/secrets/bwsecret
      - BW_PASSWORD_FILE=/run/secrets/bwpassword
      - EXPORT_PASSWORD_FILE=/run/secrets/exportpassword
      # Optional:
      # - NOTIFICATION_URL_FILE=/run/secrets/notificationurl
      # - PING_URL_FILE=/run/secrets/pingurl
    secrets:
      - bwclientid
      - bwsecret
      - bwpassword
      - exportpassword
      # - notificationurl
      # - pingurl

secrets:
  bwclientid:
    file: ./.secrets/.bwclientid
  bwsecret:
    file: ./.secrets/.bwsecret
  bwpassword:
    file: ./.secrets/.bwpassword
  exportpassword:
    file: ./.secrets/.exportpassword
  # notificationurl:
  #   file: ./.secrets/.notificationurl
  # pingurl:
  #   file: ./.secrets/.pingurl
```

Mount `/var/data` and `/var/attachments` separately, never a parent such as `/var`: the image declares both as volumes, so Docker would put anonymous volumes over them and the exports would never reach your folder.

See [`docker-compose.secrets.sample.yml`](docker-compose.secrets.sample.yml). Reference: [Docker secrets in Compose](https://docs.docker.com/compose/use-secrets/).

### Option B: Infisical

1. Create a [free Infisical account](https://app.infisical.com/signup) and a project.
2. Add the secrets `BW_CLIENTID`, `BW_CLIENTSECRET`, `BW_PASSWORD` and, optionally, `EXPORT_PASSWORD`.

   ![Secret values](docs/assets/infisical1.png)

3. Create a [service token](https://infisical.com/docs/internals/service-tokens) under *Project → Access Control → Service Tokens*, with the name and *Secrets Path* you need.

   ![Service token](docs/assets/infisical2.png)
   ![Service token](docs/assets/infisical3.png)

4. Set `INFISICAL_TOKEN` to that token, then start the container as usual. `INFISICAL_PATH` is optional: the token's own *Secrets Path* always applies (see below).

   ![Compose sample](docs/assets/infisical4.png)

See also [`docker-compose.infisical.sample.yml`](docker-compose.infisical.sample.yml).

> [!IMPORTANT]
> A service token carries its own environment and *Secrets Path*, and Infisical always applies them: `INFISICAL_PATH` cannot point a token anywhere else, and a wrong value is not reported as an error. If a run uses the wrong secrets, check the token's scope in Infisical, not `INFISICAL_PATH`.
>
> When a variable is set both in the compose file and in Infisical, the Infisical value wins.
>
> If the secrets cannot be fetched, the container exits with code 1 and, when notifications are on, sends a message carrying Infisical's own error.

## Notifications

Set `NOTIFICATION_URL` to any [Shoutrrr service URL](https://shoutrrr.nickfedor.com/latest/services/overview/) and you get a message when the run starts, succeeds or fails. Both outcomes carry the [run summary](#what-it-produces) (duration, what was exported, organizations skipped, attachments saved, size), so a drop in the numbers shows without opening the log; a failure also carries the last lines of the log. The URL usually holds a token, so the container never prints it and hands it to Shoutrrr through the environment rather than on its command line. A notification that cannot be sent is logged without the address and does not change the backup's exit code.

By default you get a message at the start and another at the end of every run, which on a daily schedule is two a day when all goes well. `NOTIFICATION_LEVEL=failure` sends only the failures, with the same summary and the last lines of the log; pair it with [`PING_URL`](#monitoring) so a run that never started is still noticed. Any other value is reported in the log and treated as `all`, since a typo should never be why an alert does not arrive.

### Telegram

```bash
NOTIFICATION_URL=telegram://$BOT_TOKEN@telegram/?channels=$CHAT_ID
# e.g.
NOTIFICATION_URL=telegram://1009999999:AAaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa@telegram/?channels=19599999999
```

![Telegram notification](docs/assets/bot-notification-1.png)

### Gotify

The URL is the Gotify host followed by an **application token**:

```bash
NOTIFICATION_URL=gotify://$GOTIFY_HOST/$GOTIFY_TOKEN
# e.g.
NOTIFICATION_URL=gotify://gotify.example.com/gtfya.AbCdEf0123456789AbCdEf0123456789AbCdEf01234
```

If Gotify runs under a subpath, add it before the token (`gotify://example.com/gotify/$GOTIFY_TOKEN`). If it is served over plain HTTP, append `?disabletls=yes`.

Both token formats work: the legacy one from Gotify below 3.0.0 (15 characters starting with `A`) and the one issued by Gotify 3.0.0 and later (`gtfya.` prefix, around 50 characters). Support for the newer format is why this image builds Shoutrrr from the [nicholas-fedor fork](https://github.com/nicholas-fedor/shoutrrr): the original `containrrr` project stopped at v0.8.0, which rejects any token that is not exactly 15 characters starting with `A`.

## Monitoring

`NOTIFICATION_URL` tells a person what happened; `PING_URL` tells a machine. It is pinged when the export starts and again when it finishes, carrying the outcome, so a watchdog can tell a successful run from a failed one — and notice a run that never happened at all.

```bash
PING_URL=https://hc-ping.com/<your-uuid>
```

That is all healthchecks needs: the outcome is appended as a path segment, `/start` at the beginning, `/0` on success and `/<exit code>` on failure. Services that expect the outcome elsewhere use a placeholder:

| Placeholder | Start | Success | Failure |
|---|---|---|---|
| `{code}` | `start` | `0` | the export's exit code |
| `{status}` | *not pinged* | `up` | `down` |

A URL using `{status}` is not pinged at start: that vocabulary has no value meaning "starting", and a push monitor has no concept of one.

```bash
# healthchecks, written out explicitly — same behaviour as the example above
PING_URL=https://hc-ping.com/<your-uuid>/{code}

# uptime-kuma push monitor
PING_URL=https://kuma.example.com/api/push/<token>?status={status}

# uptime-kuma, with the exit code in the message
PING_URL=https://kuma.example.com/api/push/<token>?status={status}&msg=exit-{code}
```

A trailing slash is removed before anything is appended, so `https://hc-ping.com/<uuid>` and `https://hc-ping.com/<uuid>/` behave the same. A failed ping never fails the backup: it is logged as a warning and the container still exits with the export's own status code. An unreachable monitor cannot hold the container open for long either — a refused connection or a name that does not resolve fails in about a second, a host that silently drops packets costs at most eleven, and there are two pings per run.

## Scheduling

The container runs one export and exits, so the schedule lives on the host. With cron:

```cron
# every day at 03:30
30 3 * * * cd /opt/bw-export && docker compose run --rm bw-export >> /var/log/bw-export.log 2>&1
```

A systemd timer, Unraid's own scheduler or a container scheduler such as [Ofelia](https://github.com/mcuadros/ofelia) work just as well. Because the container exits with the export's status code, cron and your orchestrator see a failed backup as a failure; pair it with [`PING_URL`](#monitoring) so a run that never started is noticed too.

## Retention

```yaml
environment:
  - KEEP_LAST_BACKUPS=5
```

Each run writes its own `<DateTime>-bw-export` folder. With `KEEP_LAST_BACKUPS` set, the container sorts those folders and deletes the oldest ones, keeping the number you ask for.

![Keep last sample](docs/assets/keep-last.png)

A fixed window has a weakness: with daily backups and `KEEP_LAST_BACKUPS=7`, an item deleted by mistake and noticed two weeks later is gone from every backup. `KEEP_GFS` keeps backups spread over time instead (grandfather-father-son):

```yaml
environment:
  - KEEP_GFS=7d:4w:6m
```

| Unit | Keeps |
|---|---|
| `d` | the newest backup of each of the last N days that have one |
| `w` | the newest of each of the last N weeks (ISO weeks, Monday to Sunday) |
| `m` | the newest of each of the last N months |
| `y` | the newest of each of the last N years |

With one backup a day, `7d:4w:6m` holds about 15 backups that reach six months back. Units can come in any order and any can be left out (`30d`, `4w:12m:2y`). When both variables are set, a backup either of them keeps is kept.

Either way:

- only folders named `<14 digits>-bw-export` directly inside the output and attachments paths are ever deleted;
- the backup the run has just written is always kept, even with `KEEP_LAST_BACKUPS=0`;
- when the run is incomplete, nothing is deleted, so a broken export never pushes a good one out;
- an invalid value deletes nothing and makes the run exit `1` after the backup has been written.

## Encrypted attachments

`EXPORT_PASSWORD` encrypts the vault exports, but attachments (SSH keys, certificates, recovery codes, scanned documents) are saved as plain files. With `ENCRYPT_ATTACHMENTS=true` each run instead writes one `attachments.tar.gz.gpg` into its attachments folder, encrypted with `EXPORT_PASSWORD` (AES-256, OpenPGP format).

```yaml
environment:
  - EXPORT_PASSWORD=<EXPORT PASSWORD>
  - ENCRYPT_ATTACHMENTS=true
```

- The attachments are downloaded to a private temporary folder **inside the container** and only the encrypted archive reaches your volume, so no plain copy lands on the NAS or in its snapshots. That folder needs room for one run's attachments; it is deleted however the run ends.
- Each archive is decrypted once after it is written, to prove it can be restored.
- If encryption fails, the run fails and nothing is kept in the clear.
- `EXPORT_PASSWORD` is required: without it the container stops before exporting anything.

To restore, on any machine with GnuPG ([Gpg4win](https://www.gpg4win.org/) on Windows, [GPG Suite](https://gpgtools.org/) on macOS):

```bash
gpg -d attachments.tar.gz.gpg | tar -xz
```

GnuPG asks for the password, and the folders are recreated in the current directory, one per vault item.

On **Windows**, install [Gpg4win](https://www.gpg4win.org/) and use two steps in PowerShell, because Windows PowerShell corrupts binary data sent through a pipe:

```powershell
gpg -o attachments.tar.gz -d attachments.tar.gz.gpg
tar -xzf attachments.tar.gz
```

`tar` is part of Windows 10 and later. Kleopatra, which comes with Gpg4win, does the first step from the file's right-click menu (*Decrypt and verify*), and 7-Zip opens the resulting `.tar.gz`.

## Permissions of the backups

The Bitwarden CLI already writes what it saves with restricted modes: the exports and the attachments are `600` and each vault item's folder is `700`, so another user of the host cannot read them. What is left open is what the container itself creates, with its `umask` (normally `022`):

- each run's `<DateTime>-bw-export` folder, in the data and attachments paths, is `755`. Anyone who can reach the volume can list what is inside: the names of your vault items and of their attachments, and the export files;
- the encrypted attachments archive (`ENCRYPT_ATTACHMENTS`) is `644`. It is encrypted, but anyone can copy it.

```yaml
environment:
  - BACKUP_PERMISSIONS=private
```

| | Default | `private` |
|---|---|---|
| Each run's folders (`<DateTime>-bw-export`) | `755` | `700` |
| The encrypted attachments archive | `644` | `600` |
| Exports and attachments written by the CLI, and each item's folder | `600` / `700` | `600` / `700` (the CLI's own modes) |

- It applies from before the first file of the run exists, and is checked again at the end for filesystems that ignore the `umask` (shares with default ACLs). The folders you mount, `/var/data` and `/var/attachments`, are never changed.
- **It takes access away from anyone who is not the owner.** The owner is `root` by default, the `PUID` user if you set one, or the `user:` of the [hardened setup](#hardened-setup). A script or a share that lists or copies the backups as another user stops working: give it the same user or leave this off.
- It is not applied to the log (`FILE_LOG`), which keeps its own mode.
- A filesystem without Unix modes, such as an NTFS share, cannot be restricted: the run still works and says so in a warning.
- Backups written earlier are not changed. Change them once with `chmod -R go-rwx <folder>`.

## Off-site copy (3-2-1)

All backups live on one volume, so a failed disk, a stolen server or ransomware takes them all. The image does not upload anything itself; [`docker-compose.offsite.sample.yml`](docker-compose.offsite.sample.yml) adds an [rclone](https://rclone.org/) sidecar that copies the export folders to any of rclone's remotes (S3, Backblaze B2, WebDAV/Nextcloud, SFTP, Google Drive, …), keeping the remote's credentials out of the bw-export container.

- Set `EXPORT_PASSWORD` and `ENCRYPT_ATTACHMENTS=true`, so everything that leaves the host is encrypted.
- The sidecar mounts the backups **read-only** and uses `rclone copy`, which never deletes on the remote: a backup lost locally is still there. Expire old copies with the provider's lifecycle rules (ideally with versioning or object lock), not with `rclone sync`, which would mirror local deletions.

## File ownership: PUID and PGID

Processes inside a container run as `root` by default, so every file created in a mounted volume ends up owned by `root` and out of your reach. `PUID` and `PGID` map the container's internal user onto a user on the host:

```yaml
environment:
  - PUID=1000
  - PGID=1000
```

```bash
docker create ... -e PUID=1000 -e PGID=1000 ...
```

Use your own ids, which `id $user` reports as `uid` and `gid`.

### Rootless Podman

Rootless Podman maps the container's uids onto your subordinate uid range, so `PUID=1000` inside the container is **not** uid 1000 on the host: exports end up owned by an unknown user, or cannot be written at all. Add the [`compose.podman.yml`](compose.podman.yml) override, which uses `keep-id` so your uid means the same inside and outside the container:

```bash
podman compose -f docker-compose.yml -f compose.podman.yml up
```

With it, `PUID`/`PGID` behave exactly as under Docker. Without `PUID`, rootless Podman already writes the files as you, since the container's root is your user. The override is Podman only: Docker rejects `keep-id`.

On SELinux hosts (Fedora, RHEL) also add `:z` to the bind mounts, e.g. `./export:/var/data:z`, or the container cannot read them.

## Hardened setup

With `CRON` the container stays up around the clock, holding everything needed to open your vault. [`docker-compose.hardened.sample.yml`](docker-compose.hardened.sample.yml) runs it with as little as possible:

| Setting | Effect |
|---|---|
| `user: "1000:1000"` | Never root. The user setup and `su` are skipped, and the files are created as that uid:gid. |
| `read_only: true` | Nothing in the image can be modified. |
| `tmpfs: /tmp` | The only writable place outside the volumes, in memory: the CLI's session data (so its tokens never touch the disk), the default log and, with `ENCRYPT_ATTACHMENTS`, one run's attachments before they are encrypted. Size it to fit them. |
| `cap_drop: [ALL]`, `no-new-privileges` | No kernel capabilities, and no way to gain any. |
| `secrets:` | `BW_CLIENTID`, `BW_CLIENTSECRET`, `BW_PASSWORD` and `EXPORT_PASSWORD` are read from files through their `_FILE` variables instead of environment variables, so `docker inspect` does not show them. |

What changes when the container does not start as root:

- **`PUID`/`PGID` are ignored**: the `user:` setting already decides who owns the files, and the container says so if they are set.
- **The mounted folders must be writable by that user**, e.g. `sudo chown -R 1000:1000 export`. A folder it cannot write to stops the run before anything is exported, naming the folder and the uid.
- When the image's own folder cannot be written to (`read_only`, or any user other than the image's), the CLI's data and the default log move to `/tmp`. Set `FILE_LOG` inside a volume to keep the log across restarts.

> [!NOTE]
> **Rootless Podman** cannot start this file as is: with `read_only: true` it has nowhere to create the mount points for the Docker secrets under `/run/secrets`, and stops with `crun: open …/run/secrets/<name>: No such file or directory`. Under Podman set `read_only: false`; every other setting in the file works.

`read_only` and `cap_drop: [ALL]` need `user:` as well. Started as root, the container sets its user up with `usermod` and `chown` and then switches to it with `su`, which a read-only filesystem and a capability-less container both prevent.

## Platform notes

- **Unraid**: see the [Bitwarden_Export Unraid template README](https://github.com/0neTX/UnRAID_Template/blob/main/bw-export/README.md).
- **SELinux hosts**: add `:z` to the bind mounts.
- **Windows / macOS**: adapt the volume paths in the compose file.

## Image tags

| Tag | Published from | Use it for |
|---|---|---|
| `0netx/bw-export:latest` | a `v*` release tag | production |
| `0netx/bw-export:beta` | the `dev` branch | testing what is coming next |
| `0netx/bw-export:<commit sha>` | each build | pinning one exact build |

## Troubleshooting

### Reading the log

Each line is `<date> <time> LEVEL: message`, where the level is `INFO`, `WARNING`, `ERROR`, or `HINT` (what to do about the line above). The first lines of every run say what it is about to do, which is what a support request needs before anything else:

```text
2026-11-20 17:54:10 INFO: bw-export 1.12, Bitwarden CLI 2026.11.0
2026-11-20 17:54:10 INFO: Mode: one backup, then exit, timezone UTC
2026-11-20 17:54:10 INFO: Runs as uid 1000, gid 1000
2026-11-20 17:54:10 INFO: Vaults: one; notifications: on; monitoring ping: off; Infisical: off; log file: on
2026-11-20 17:54:10 INFO: Server: self-hosted, Vaultwarden 1.37.4
2026-11-20 17:54:10 INFO: Credentials: BW_CLIENTID set, BW_CLIENTSECRET set, BW_PASSWORD from a file
2026-11-20 17:54:10 INFO: Vault export: encrypted with EXPORT_PASSWORD (from a Docker secret)
...
```

Messages from the Bitwarden CLI itself appear indented under the error they explain, prefixed with `bw:`.

**The log is safe to share.** It never contains a password, API key, token or notification URL, a self-hosted server's address (only its kind and Vaultwarden version), or anything from inside your vault: no item, folder, organization or attachment names. Organizations and failed attachments are named by their IDs. When asking for help, paste the whole log of a failing run, from the `bw-export` line to `Run finished with exit code`.

### Common problems


| Symptom | Cause and fix |
|---|---|
| `Failed to unlock vault with BW_PASSWORD`, but the password is right | Vaultwarden older than 1.37.4. Upgrade the server; see [Requirements](#requirements). |
| The CLI refuses your server URL | `BW_URL_SERVER` must be HTTPS. Plain HTTP is rejected. |
| `Failed to export the organization vault`, then `You are not logged in.` | Only a confirmed Owner or Admin, or a custom role allowed to, can export an organization; the server refuses anyone else and the CLI logs itself out. Left unset, `BW_ORGANIZATIONS_LIST` already skips those organizations and logs `Skipping organization`. If you listed one by hand, remove it, or set `BW_ORGANIZATIONS_LIST=none`. |
| `Could not find the folder in which to save the files` | `OUTPUT_PATH` or `ATTACHMENTS_PATH` points somewhere that is not mounted in the container. |
| The export works, but no attachments appear on the host | The old `/var/attachment` mount. See [Upgrade notes](#upgrade-notes). |
| The run uses the wrong secrets with Infisical | The service token's own scope, not `INFISICAL_PATH`. See [Option B](#option-b-infisical). |
| Exported files belong to `root`, or to nobody you recognise | Set `PUID`/`PGID`; under rootless Podman add `compose.podman.yml`. See [PUID and PGID](#file-ownership-puid-and-pgid). |
| The log disappears with the container | Point `FILE_LOG` inside a mounted volume. |
| No notification arrives | A failed notification is logged without the address and does not change the exit code. Check the log and the Shoutrrr URL. |
| `Saved …` lines with item and file names are gone | From the release after 1.12, the log names no attachment: it says how many were saved, and names a failed one by its position and item ID. |

## Upgrade notes

### Moving to several vaults

A single-vault setup keeps working unchanged. To back up a second account, move the existing one into `BW_VAULTS` too: its `BW_CLIENTID` becomes `VAULT_<NAME>_BW_CLIENTID`, and so on.

From then on its new backups go to `/var/data/<name>/`. The ones already at the top of `/var/data` stay where they are and are no longer rotated by `KEEP_LAST_BACKUPS` or `KEEP_GFS`, which now look inside each vault's folder. Nothing is lost; to keep them under rotation, move them into the vault's folder once, with the container stopped:

```bash
mkdir -p export/data/personal && mv export/data/*-bw-export export/data/personal/
mkdir -p export/attachments/personal && mv export/attachments/*-bw-export export/attachments/personal/
```

### Organizations you do not own or administer

Only a confirmed Owner or Admin, or a custom role allowed to, can export an organization. Without `BW_ORGANIZATIONS_LIST`, the image used to try every organization you belong to, and the server refused the others. The CLI then logged itself out, so the attachments, and any organization tried after it, were lost too. Before 1.12 all of this was reported as a successful backup. Those organizations are now skipped, each one with a `Skipping organization` line in the log.

- **You own or administer every organization you belong to, or you set `BW_ORGANIZATIONS_LIST`:** nothing changes.
- **You belong to an organization as User or Manager:** the run stops failing, and your attachments and the organizations you do own are saved again. That organization's backup is the job of whoever owns it.
- **You use bitwarden.com with a Custom role that may export:** the CLI does not show a custom role's permissions, so that organization is no longer exported on its own. Add its ID to `BW_ORGANIZATIONS_LIST`.

### Rotation of old backups

`KEEP_LAST_BACKUPS` works as before, with three safety fixes. Most setups see no difference.

- Only `<14 digits>-bw-export` folders **directly** inside the output and attachments paths are deleted. Before, any folder whose name ended in `-bw-export` counted, at any depth, including a vault item's attachments folder with such a name.
- A folder name with spaces no longer breaks the rotation.
- `KEEP_LAST_BACKUPS=0` keeps the backup just written instead of deleting it.

### Attachments path

Earlier versions of this README and of `docker-compose.yml` mounted the attachments folder on `/var/attachment`, but the image saves attachments to `/var/attachments`. With that mount the export succeeded and **the attachments never reached the host folder**: they went to an anonymous Docker volume instead. Unraid's template already uses `/var/attachments` and is not affected.

- **You mount `/var/attachment` and do not set `ATTACHMENTS_PATH`:** nothing breaks. The image notices the old mount, saves the attachments there and logs a warning. Change the mount when convenient:

  ```yaml
  volumes:
    - ./export:/var/data
    - ./export:/var/attachments
  ```

- **You mount `/var/attachments`, or set `ATTACHMENTS_PATH`:** nothing changes. That includes mounting both paths to different folders — `/var/attachments` keeps being used.
- **You set `ATTACHMENTS_PATH=/var/attachment` without mounting it:** the run now fails with `Could not find the folder in which to save the attachments`. Before, the files were written inside the container and lost with it. Mount a folder there, or drop the variable.

**Recovering the attachments saved so far.** They are in the anonymous volume of your existing container, as long as it has not been removed with `docker rm -v` or run with `--rm` (`docker compose` keeps anonymous volumes when it recreates a container). Copy them out before recreating it, replacing `bw-export` with your container's name and `./export` with your host folder:

```bash
docker run --rm --volumes-from bw-export -v ./export:/restore \
    --entrypoint cp 0netx/bw-export:latest -a /var/attachments/. /restore/
```

Each run's attachments land in the same dated folder as its vault export. Under Docker the copied files belong to root; add `--user "$(id -u):$(id -g)"` if you need them to be yours (on SELinux hosts, also `:z` on the `/restore` mount).

## Development

```bash
git clone https://github.com/0neTX/Bitwarden_Export.git
cd Bitwarden_Export
docker build --no-cache -t bw-export --progress=plain .
```

The unit suite needs no network and no containers:

```bash
SCRIPT=$PWD/bw_export.sh bash tests/run_tests.sh
```

See [`tests/README.md`](tests/README.md) for the rest of the suite, including the end-to-end tests.

## Contributing

Pull requests go to **`dev`**, not `main`. The full guide is in [CONTRIBUTING.md](CONTRIBUTING.md).

Bug reports: [open an issue](https://github.com/0neTX/Bitwarden_Export/issues/new/choose).

## Security

To report a vulnerability, follow [SECURITY.md](SECURITY.md). Please do not open a public issue for one.

## Credits

Based on the script from [@dh024/Bitwarden_Export](https://github.com/dh024/Bitwarden_Export), used as a base and inspiration. Thank you very much.

## Disclaimer

This image creates a copy of all the passwords and secrets stored in your vault. Inspect it carefully to make sure it does what you need and behaves as you expect. No guarantee is given that it will work for you.

## License

GPL-3.0-only. See [LICENSE](LICENSE).
