# Tests

Two layers:

- **`run_tests.sh`** — 59 assertions against `bw_export.sh` using a stateful mock
  of the Bitwarden CLI (`mock/bw`). Fast, no network, no containers.
- **`compose.test.yml` + `e2e-setup.sh`** — a real Vaultwarden 1.37.2 and a
  bw-export image built from the repo `Dockerfile`, used to validate issue #21
  end to end.

## Unit suite

```bash
SCRIPT=$PWD/bw_export.sh bash tests/run_tests.sh
```

Expect `PASS=59 FAIL=0`. The suite is only worth anything if it fails on the
code it was written against, so as a control:

```bash
git show 57aa29d:bw_export.sh > /tmp/orig.sh       # before the #21 fixes
SCRIPT=/tmp/orig.sh bash tests/run_tests.sh        # PASS=29 FAIL=30

git show ae34553:bw_export.sh > /tmp/preattach.sh  # #21 fixed, attachments not yet
SCRIPT=/tmp/preattach.sh bash tests/run_tests.sh   # PASS=45 FAIL=14
```

T15–T19 cover the attachment block: the guard that never fired, and the fact
that item and file names used to be pasted into generated shell and executed.

> `mock/bw` must be executable. On a filesystem that ignores the exec bit
> (NTFS/exFAT via FUSE, some network mounts) copy `tests/` to a native Linux
> filesystem first, or every test fails with "permission denied".

## End-to-end suite

```bash
bash tests/e2e-setup.sh
```

That generates a throwaway CA, starts Vaultwarden behind TLS, builds the image,
registers a test account with an API key and an organization, and seeds one
personal item (with an attachment) plus one organization item. Everything lands
in `tests/e2e/`, which is gitignored.

TLS is not optional: the Bitwarden CLI rejects plain-HTTP servers with
`Insecure URL not allowed. All URLs must use HTTPS.`, so Vaultwarden sits behind
an nginx proxy on `vw.test` and the container trusts the test CA through
`NODE_EXTRA_CA_CERTS`.

Run an export:

```bash
docker compose -f tests/compose.test.yml --env-file tests/e2e/test.env up -d bw-export
docker logs -f bwtest-bw-export
```

### Reproducing issue #21

The bug only appears when the **same** container is restarted — recreating it
discards the CLI state in `/app/data.json` and the stale session goes with it.
Use `start`, never `up --force-recreate`:

```bash
docker compose -f tests/compose.test.yml --env-file tests/e2e/test.env start bw-export
```

To create the dirty state the issue describes, kill a run mid-export so the
cleanup trap never fires, then restart:

```bash
docker start bwtest-bw-export
until docker logs bwtest-bw-export 2>&1 | grep -q 'Vault unlocked'; do sleep 1; done
docker kill bwtest-bw-export
docker start bwtest-bw-export      # logs "Existing session detected. Logging out before starting..."
```

The fixed script recovers. To see the original fail instead, build an image with
the pre-fix script and repeat:

```bash
git show 57aa29d:bw_export.sh > /tmp/bw_export.orig.sh
```

Add a stale master password on top (change it server-side between two runs,
update `tests/e2e/secrets/.bwpassword`) and the original reproduces the reported
log exactly:

```
Setting custom server...
Logout required before server config update.
Unlocking the vault...
ERROR: Failed to unlock vault with BW_PASSWORD.
```

### Teardown

```bash
docker rm -f bwtest-bw-export bwtest-vaultwarden bwtest-vw-tls
rm -rf tests/e2e
```

Remove the containers before deleting `tests/e2e/` — Vaultwarden holds its
SQLite files open and the directory will not delete while it is running.
