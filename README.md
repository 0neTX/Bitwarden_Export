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
- [What it produces](#what-it-produces)
- [Configuration](#configuration)
- [Handling secrets](#handling-secrets)
- [Notifications](#notifications)
- [Monitoring](#monitoring)
- [Scheduling](#scheduling)
- [Retention](#retention)
- [File ownership: PUID and PGID](#file-ownership-puid-and-pgid)
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
- Exports your **organization vaults** (all of them, or the ones you list).
- Downloads **file attachments**, one subfolder per vault item. Attachments are never encrypted.
- Keeps **passwords off the command line**, so other users on the host cannot read them with `ps` ([details](#passwords-stay-off-the-command-line)).
- Reads its credentials from **Docker secrets** or from **[Infisical](#option-b-infisical)** instead of the compose file.
- Sends the outcome to any platform supported by **[Shoutrrr](https://shoutrrr.nickfedor.com/latest/services/overview/)** (Telegram, Gotify, and about thirty more).
- Pings a **watchdog** (healthchecks, uptime-kuma, any dead man's switch) at start and on completion.
- **Prunes old exports** automatically with `KEEP_LAST_BACKUPS`.
- Exits with the export's own status code, so `restart: on-failure`, cron and orchestrators see a failed backup as a failure.

## Requirements

- [Docker](https://docker.com) or Podman. Linux, macOS and Windows all work; adapt the compose file to your host.
- **Personal API key** for CLI authentication: [how to get it](https://bitwarden.com/help/personal-api-key/).
- If you self-host, a server reachable over **HTTPS**. The Bitwarden CLI refuses plain-HTTP URLs.
- **Vaultwarden 1.37.4 or later.** The bundled Bitwarden CLI (2026.10.0) calls an endpoint older Vaultwarden releases do not have, and the export then fails with `Failed to unlock vault with BW_PASSWORD` even though the password is right ([vaultwarden#7693](https://github.com/dani-garcia/vaultwarden/pull/7693)). bitwarden.com is not affected.

## Quick start

### Docker Compose (recommended)

Copy [`docker-compose.yml`](docker-compose.yml) from this repository, fill in the three credentials and run it:

```yaml
services:
  bw-export:
    container_name: bw-export
    image: 0netx/bw-export:latest
    volumes:
      - ./export:/var/data
      - ./export:/var/attachments
    environment:
      - BW_CLIENTID=<CLIENT ID FROM BITWARDEN API>
      - BW_CLIENTSECRET=<CLIENT SECRET FROM BITWARDEN API>
      - BW_PASSWORD=<BITWARDEN PASSWORD>
      - EXPORT_PASSWORD=<password the export will be encrypted with>
      # Optional: your own Vaultwarden/Bitwarden server
      # - BW_URL_SERVER=https://vault.example.com
```

```bash
docker compose up
```

The container performs one export and exits with the export's status code.

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

## What it produces

Every run writes a dated folder, `<DateTime>-bw-export`, into the output path:

- a JSON file with your **personal vault** (password-encrypted when `EXPORT_PASSWORD` is set — recommended),
- a JSON file per **organization vault**, if you export any,
- a folder with your **attachments**, one subfolder per vault item.

The Bitwarden CLI cannot export items in your **Trash** or your **password history**, so neither is included.

## Configuration

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
| `BW_ORGANIZATIONS_LIST` | all organizations | Comma-separated organization IDs to export. |
| `OUTPUT_PATH` | `/var/data/` | Where the vault exports are written. The path must exist in the container, normally as a mounted volume. |
| `ATTACHMENTS_PATH` | `/var/attachments/` | Where the attachments are written, same condition. |
| `KEEP_LAST_BACKUPS` | keep everything | Keep only the N newest export folders, delete the rest. See [Retention](#retention). |
| `FILE_LOG` | container-only log | Path of the run log, e.g. `/var/data/bw-export-logfile.log`. Point it inside a mounted volume or it is lost with the container. |
| `NOTIFICATION_URL` | — | Shoutrrr URL for the start/success/failure messages. See [Notifications](#notifications). |
| `PING_URL` | — | Watchdog endpoint pinged at start and on completion. See [Monitoring](#monitoring). |
| `INFISICAL_TOKEN` | — | Infisical service token, to read the credentials from Infisical. See [Option B](#option-b-infisical). |
| `INFISICAL_PATH` | token's own path | *Secrets Path* of that service token. |
| `PUID` / `PGID` | `0` (root) | Host user and group the exported files should belong to. See [PUID and PGID](#file-ownership-puid-and-pgid). |

### Volumes

| Path | Contents |
|---|---|
| `/var/data` | Vault exports. |
| `/var/attachments` | Attachments. |

## Handling secrets

This container automates the official [Bitwarden CLI](https://bitwarden.com/help/cli/). **It does not save, trace or store any information of its own**, and the CLI session is closed once the backup is done.

### Passwords stay off the command line

Any user on the host can read the command line of any process with `ps`, including processes inside a container, under Docker as under Podman. So the script never passes a password as an argument:

- the master password (`BW_PASSWORD`) reaches `bw unlock` through an environment variable (`--passwordenv`), which only the process owner and root can read;
- the export password (`EXPORT_PASSWORD`) reaches `bw export` through stdin, answering the CLI's own prompt. That prompt is kept out of the log, since it is redrawn once per character and would give away the password's length.

Nothing has to be configured for this. Every credential variable accepts either the value itself or **the path of a file holding it**, which is what makes the two options below work.

### Option A: Docker secrets

```bash
mkdir ./.secrets
echo '<client id>'     > ./.secrets/.bwclientid
echo '<client secret>' > ./.secrets/.bwsecret
echo '<password>'      > ./.secrets/.bwpassword
```

Then configure and run [`docker-compose.secrets.sample.yml`](docker-compose.secrets.sample.yml). Reference: [Docker secrets in Compose](https://docs.docker.com/compose/use-secrets/).

### Option B: Infisical

1. Create a [free Infisical account](https://app.infisical.com/signup) and a project.
2. Add the secrets `BW_CLIENTID`, `BW_CLIENTSECRET`, `BW_PASSWORD` and, optionally, `EXPORT_PASSWORD`.

   ![Secret values](docs/assets/infisical1.png)

3. Create a [service token](https://infisical.com/docs/internals/service-tokens) under *Project → Access Control → Service Tokens*, with the name and *Secrets Path* you need.

   ![Service token](docs/assets/infisical2.png)
   ![Service token](docs/assets/infisical3.png)

4. Set `INFISICAL_TOKEN` to that token and `INFISICAL_PATH` to its *Secrets Path*, then start the container as usual.

   ![Compose sample](docs/assets/infisical4.png)

See also [`docker-compose.infisical.sample.yml`](docker-compose.infisical.sample.yml).

> [!IMPORTANT]
> A service token carries its own environment and *Secrets Path*, and Infisical always applies them: `INFISICAL_PATH` cannot point a token anywhere else, and a wrong value is not reported as an error. If a run uses the wrong secrets, check the token's scope in Infisical, not `INFISICAL_PATH`.
>
> When a variable is set both in the compose file and in Infisical, the Infisical value wins.
>
> If the secrets cannot be fetched, the container exits with code 1 and, when notifications are on, sends a message carrying Infisical's own error.

## Notifications

Set `NOTIFICATION_URL` to any [Shoutrrr service URL](https://shoutrrr.nickfedor.com/latest/services/overview/) and you get a message when the run starts, succeeds or fails; a failure carries the last lines of the log. The URL usually holds a token, so the container never prints it and hands it to Shoutrrr through the environment rather than on its command line. A notification that cannot be sent is logged without the address and does not change the backup's exit code.

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

| Symptom | Cause and fix |
|---|---|
| `Failed to unlock vault with BW_PASSWORD`, but the password is right | Vaultwarden older than 1.37.4. Upgrade the server; see [Requirements](#requirements). |
| The CLI refuses your server URL | `BW_URL_SERVER` must be HTTPS. Plain HTTP is rejected. |
| `Could not find the folder in which to save the files` | `OUTPUT_PATH` or `ATTACHMENTS_PATH` points somewhere that is not mounted in the container. |
| The export works, but no attachments appear on the host | The old `/var/attachment` mount. See [Upgrade notes](#upgrade-notes). |
| The run uses the wrong secrets with Infisical | The service token's own scope, not `INFISICAL_PATH`. See [Option B](#option-b-infisical). |
| Exported files belong to `root`, or to nobody you recognise | Set `PUID`/`PGID`; under rootless Podman add `compose.podman.yml`. See [PUID and PGID](#file-ownership-puid-and-pgid). |
| The log disappears with the container | Point `FILE_LOG` inside a mounted volume. |
| No notification arrives | A failed notification is logged without the address and does not change the exit code. Check the log and the Shoutrrr URL. |

## Upgrade notes

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
