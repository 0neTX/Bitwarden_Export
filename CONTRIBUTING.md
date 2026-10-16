# Contributing

Thanks for wanting to help.

## Pull requests go to `dev`

**Target `dev`, not `main`.** `main` is the release branch: it is updated by
merging `dev` into it and tagging, which publishes `:latest` to Docker Hub. A
pull request opened against `main` cannot be merged there and has to be
retargeted.

`dev` is the repository's default branch, so a pull request from a fork proposes
it for you.

## Running the tests

The unit suite is fast, needs no network and no containers:

```bash
SCRIPT=$PWD/bw_export.sh bash tests/run_tests.sh
```

Expect `PASS=80 FAIL=0`. `tests/README.md` covers the rest, including the
end-to-end suite that runs a real Vaultwarden behind TLS, and the two
`entrypoint.sh` behaviours that can only be checked against a container.

A suite is only worth something if it fails on the code it was written against.
`tests/README.md` shows how to run it against earlier versions of the script as
a control; if you add assertions, check they actually discriminate.

## shellcheck

CI runs shellcheck **at a pinned version**, because versions disagree about
which findings exist. A change that is clean against the shellcheck on your
machine can still fail CI. Use the same container:

```bash
docker run --rm -v "$PWD:/mnt:ro" koalaman/shellcheck:v0.11.0 \
  bw_export.sh entrypoint.sh \
  tests/mock/bw tests/run_tests.sh tests/e2e-setup.sh tests/e2e-verify.sh
```

If a suppression is unavoidable, put it at the top of the file with a comment
saying why, as the existing scripts do.

## Conventions

- Shell is bash, with LF line endings — `.gitattributes` enforces that, so
  Windows contributors do not need to do anything special.
- The image version is declared in the `Dockerfile`. Bump it there.
- Versions of the Bitwarden CLI and Shoutrrr are pinned on purpose. Changing one
  means saying what it was tested against.
- Comments explain *why* something is the way it is. What the code does is
  already in the code.

## Reporting a bug instead

Use the issue template. It asks for the image tag, the server version, the log,
and whether the container is reused or recreated. That last one decided issue
no. 21, which only reproduced on a restarted container.

Security issues go through [SECURITY.md](SECURITY.md), never a public issue.
