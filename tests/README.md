# Tests

Two layers:

- **`run_tests.sh`** — 80 assertions against `bw_export.sh` using a stateful mock
  of the Bitwarden CLI (`mock/bw`). Fast, no network, no containers.
- **`run_ping_tests.sh`** — 33 assertions against the `PING_URL` helpers in
  `root/usr/local/lib/bw-export/ping.sh`. Also fast, and needs no mock beyond a
  three-line stub for `curl`.
- **`compose.test.yml` + `e2e-setup.sh`** — a real Vaultwarden 1.37.2 and a
  bw-export image built from the repo `Dockerfile`, used to validate issue #21
  end to end.

## Unit suite

```bash
SCRIPT=$PWD/bw_export.sh bash tests/run_tests.sh
```

Expect `PASS=80 FAIL=0`. The suite is only worth anything if it fails on the
code it was written against, so as a control:

```bash
git show 57aa29d:bw_export.sh > /tmp/orig.sh       # before the #21 fixes
SCRIPT=/tmp/orig.sh bash tests/run_tests.sh        # PASS=39 FAIL=41

git show ae34553:bw_export.sh > /tmp/preattach.sh  # #21 fixed, attachments not yet
SCRIPT=/tmp/preattach.sh bash tests/run_tests.sh   # PASS=55 FAIL=25
```

T15–T19 cover the attachment block: the guard that never fired, and the fact
that item and file names used to be pasted into generated shell and executed.
T20–T22 cover a download that fails: it has to be counted and reported, not
folded into a run that claims success. T23–T24 cover rotation, which must not
delete a complete backup to make room for an incomplete one.

> `mock/bw` must be executable. On a filesystem that ignores the exec bit
> (NTFS/exFAT via FUSE, some network mounts) copy `tests/` to a native Linux
> filesystem first, or every test fails with "permission denied".

## Ping suite

```bash
bash tests/run_ping_tests.sh
```

Expect `PASS=33 FAIL=0`. It covers the URL building (both placeholders, the
appended path segment when there is none, the trailing slash, and the start ping
that `{status}` omits) and `send_ping`'s two guarantees: it logs the event
without the URL, because that carries the monitor's token, even when the shell
is tracing with `set -x` as `send_notification` leaves it, and it returns 0 even
when `curl` fails.

The last one is the guard for #22. `entrypoint.sh` pings from an `EXIT` trap, and
`send_notification` leaves `set -e` on in that shell, so a `curl` failure allowed
to escape would make the container exit with curl's status instead of the
export's.

The library is sourced through `$LIB`, so the suite can be pointed at another
implementation as a control. The obvious wrong one — append the event and trust
`curl` — fails 30 of the 33:

```bash
cat > /tmp/naive.sh <<'EOF'
build_ping_url() { printf '%s\n' "$1/$2"; }
send_ping() { curl -fsS --retry 3 "${PING_URL}/$1"; }
EOF
LIB=/tmp/naive.sh bash tests/run_ping_tests.sh   # PASS=3 FAIL=30
```

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

### Checking the entrypoint

`entrypoint.sh` is too coupled to the image (`su`, `pkill`, `shoutrrr`) to cover
with the mock, so its two behaviours are verified against a container:

**It reports failure.** Run with credentials that cannot work and read the exit
code, not the log:

```bash
docker run --name t -e BW_CLIENTID=bogus -e BW_CLIENTSECRET=bogus \
    -e BW_PASSWORD=bogus localhost/bw-export:local
docker inspect -f '{{.State.ExitCode}}' t     # 1, and 0 before this was fixed
```

**It passes stop signals on.** Interrupt a run and check the export got to clean
up after itself:

```bash
docker start bwtest-bw-export
until docker logs bwtest-bw-export 2>&1 | grep -q 'Vault unlocked'; do sleep 1; done
docker stop -t 30 bwtest-bw-export
docker logs bwtest-bw-export | grep 'Closing Bitwarden CLI session'   # must appear
docker inspect -f '{{.State.ExitCode}}' bwtest-bw-export              # 143, not 137
```

143 means it was asked to stop and did; 137 means it ignored the request and was
killed. The next run should then start without logging `Existing session
detected`, because nothing was left behind.

The cleanup only runs once the `bw` command in flight returns, so on a large
vault give `docker stop` more than its default 10 seconds (`-t`, or
`stop_grace_period` in compose).

**It pings the monitor.** The URL building is unit tested; that the container
really reaches out is not. Point it at a listener that records what it is asked
for:

```bash
python3 -m http.server 8111 &

docker run --rm --network host \
    -e PING_URL=http://127.0.0.1:8111/ping \
    -e BW_CLIENTID=bogus -e BW_CLIENTSECRET=bogus -e BW_PASSWORD=bogus \
    localhost/bw-export:local
```

The listener logs `GET /ping/start` and then `GET /ping/1`, in that order. It
answers 404 to both, which is useful rather than a problem: the container must
log `Warning: monitoring ping (...) failed; continuing.` and still exit 1, not 0
and not 22. That is the non-fatal guarantee, seen from outside.

### Teardown

```bash
docker rm -f bwtest-bw-export bwtest-vaultwarden bwtest-vw-tls
rm -rf tests/e2e
```

Remove the containers before deleting `tests/e2e/` — Vaultwarden holds its
SQLite files open and the directory will not delete while it is running.
