# Security policy

## Reporting a vulnerability

Please report security issues **privately**, not as a public issue.

Use GitHub's private reporting: the **Security** tab of this repository, then
**Report a vulnerability**. That opens a draft advisory only the maintainer can
see.

If that button is not there, open a normal issue saying only that you have found
a security problem and asking for a private channel — no details in it.

## Supported versions

Fixes land on `dev` first, reach the `:beta` image, and are released as
`:latest` with a version tag. There are no backports.

| Image | Supported |
|---|---|
| `0netx/bw-export:latest` | yes |
| `0netx/bw-export:beta` | yes, pre-release |
| a specific version tag | only the most recent |

## What this image handles

Context worth having when assessing a report:

- **Vault credentials** reach the container as environment variables, Docker
  secrets or through Infisical, and are handed to the Bitwarden CLI. The CLI
  keeps its own state under `BITWARDENCLI_APPDATA_DIR`; the script logs out when
  a run ends, including when the container is stopped mid-run.
- **The export is written to a mounted volume.** It is encrypted only if
  `EXPORT_PASSWORD` is set. Attachments are never encrypted.
- **Notification URLs contain tokens.** The failure notification is the tail of
  the run log, so anything printed during a run can reach the notification
  service.
- **The container runs as root** to set up permissions, then drops to the
  `bitwarden` user (uid 911 by default, `PUID`/`PGID`) to perform the export.

## Out of scope

- Vulnerabilities in the Bitwarden CLI, Vaultwarden, Shoutrrr or Infisical.
  Those belong to their own projects.
- An unencrypted export when `EXPORT_PASSWORD` is unset. That is documented
  behaviour, not a defect.
