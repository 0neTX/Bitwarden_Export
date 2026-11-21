# Versions and checksums of every binary the build downloads, declared once
# here for both stages below. Each can be overridden with --build-arg.
#
# shoutrrr. Pinned rather than resolved through the GitHub API: that
# call is unauthenticated, so every build competed for the 60-requests-per-hour
# quota shared by everything on the same IP. On a CI runner it is usually spent,
# and because "-q" hid the error the build failed with "wget: missing URL".
#
# Source is the nicholas-fedor fork: containrrr/shoutrrr stopped at v0.8.0,
# whose Gotify token check is "exactly 15 chars starting with A", so it rejects
# every token issued by Gotify 3.0.0+ ("gtfya."/"gtfyc." prefix, ~50 chars).
# The checksum is verified because this image handles a full vault; it comes
# from the release's own checksums.txt and must be updated with the version.
ARG SHOUTRRR_VERSION="0.25.0"
ARG SHOUTRRR_SHA256="44028e84b65965d4819c9383b41f9246185e7b0f982480f7e7f3e7eafe0ea41b"

# supercronic, for optional in-container cron scheduling (CRON env var).
ARG SUPERCRONIC_VERSION="0.2.51"
ARG SUPERCRONIC_SHA256="cc232108374e8e2b537045f2d5eaa1229f619db314c3ba6a14d38b35dc0aa123"

# The Bitwarden CLI.
# ARG so a build can override it (--build-arg BW_CLI_VERSION=...), ENV so the
# version stays readable in the image. The default is the pinned, tested one.
# From cli-v2026.11.0 Bitwarden renamed bw-linux-<ver>.zip to
# bw-bit-linux-<ver>.zip, the same full build under a new name; bw-oss-linux is
# the open-source-only build and is not used. Try the new name, then the old one,
# so older pinned versions still build. curl -f fails on a 404 instead of saving
# the error page as the zip.
#
# The zip is checked against BW_CLI_SHA256 before it is unpacked, as shoutrrr
# and supercronic are: the CLI is what handles the master password. The value
# is GitHub's own digest of the release asset (its "digest" field), and must
# change together with BW_CLI_VERSION; a build of another version passes both,
# as the dev CD does.
ARG BW_CLI_VERSION="2026.11.0"
ARG BW_CLI_SHA256="bfc7643cbc20f970bf04b994f96489703fcf77217a2384f1743e43848363b0ba"

# Pinned by digest, so the base cannot change between two builds of the same
# commit. Dependabot proposes a new digest when Ubuntu republishes 24.04 with
# security fixes, never a newer release (see .github/dependabot.yml).
#
# The downloads are fetched and checked in a stage of their own, and only the
# verified binaries are copied into the image. Done in the image itself, every
# archive stayed in a layer of its own even after it was deleted (shoutrrr's
# tarball), a chmod in a later step stored a second copy of the binary
# (supercronic), and unzip was installed for a single use.
FROM ubuntu:24.04@sha256:9c7f200c07e3d4a03e7249d2c16bf66a51120fb876aa2242cf31451412543289 AS fetch
ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates curl unzip && \
    rm -rf /var/lib/apt/lists/*
WORKDIR /fetch

ARG SHOUTRRR_VERSION
ARG SHOUTRRR_SHA256
ADD https://github.com/nicholas-fedor/shoutrrr/releases/download/v${SHOUTRRR_VERSION}/shoutrrr_linux_amd64_${SHOUTRRR_VERSION}.tar.gz shoutrrr.tar.gz
RUN echo "${SHOUTRRR_SHA256}  shoutrrr.tar.gz" | sha256sum -c - && \
    # --no-same-owner: run as root, tar keeps the archive's owner (uid 1001),
    # COPY --from carries it into the image, and a container user with that uid
    # could then change a binary root runs.
    tar --no-same-owner -xzf shoutrrr.tar.gz shoutrrr LICENSE.md && \
    mv LICENSE.md shoutrrr-LICENSE.md && \
    chmod 755 shoutrrr && \
    chmod 644 shoutrrr-LICENSE.md

ARG SUPERCRONIC_VERSION
ARG SUPERCRONIC_SHA256
ADD https://github.com/aptible/supercronic/releases/download/v${SUPERCRONIC_VERSION}/supercronic-linux-amd64 supercronic
RUN echo "${SUPERCRONIC_SHA256}  supercronic" | sha256sum -c - && \
    chmod 755 supercronic

ARG BW_CLI_VERSION
ARG BW_CLI_SHA256
RUN base="https://github.com/bitwarden/clients/releases/download/cli-v${BW_CLI_VERSION}" && \
    (curl -fsSL "${base}/bw-bit-linux-${BW_CLI_VERSION}.zip" -o bw.zip || \
     curl -fsSL "${base}/bw-linux-${BW_CLI_VERSION}.zip" -o bw.zip) && \
    { echo "${BW_CLI_SHA256}  bw.zip" | sha256sum -c - || \
      { echo "Bitwarden CLI ${BW_CLI_VERSION}: checksum mismatch. Pass the BW_CLI_SHA256 that matches BW_CLI_VERSION." >&2; exit 1; }; } && \
    unzip bw.zip bw && \
    chmod 755 bw

FROM ubuntu:24.04@sha256:9c7f200c07e3d4a03e7249d2c16bf66a51120fb876aa2242cf31451412543289

# The image's own version. ARG so a release build can stamp it
# (--build-arg IMAGE_VERSION=...), with the pinned value as the default, the
# same way BW_CLI_VERSION and SHOUTRRR_VERSION do below.
ARG IMAGE_VERSION="1.12"

# Both sets of keys on purpose. "description" and "version" are what this image
# has always published. The org.opencontainers.image.* ones are the standard
# keys that Portainer and other tools actually read, and ubuntu:24.04 sets
# org.opencontainers.image.version=24.04 on itself. Labels are inherited, so
# without these the image reports the base distro's version as its own: the
# published 1.9 image announces 24.04, with ref.name=ubuntu beside it.
LABEL description="Bitwarden exporter docker container"
LABEL version="${IMAGE_VERSION}"
LABEL org.opencontainers.image.title="bw-export"
LABEL org.opencontainers.image.description="Bitwarden exporter docker container"
LABEL org.opencontainers.image.version="${IMAGE_VERSION}"
LABEL org.opencontainers.image.source="https://github.com/0neTX/Bitwarden_Export"
LABEL org.opencontainers.image.url="https://github.com/0neTX/Bitwarden_Export"
# Readable at run time too, for the first line of every run's log.
ENV BW_EXPORT_VERSION="${IMAGE_VERSION}"
LABEL org.opencontainers.image.documentation="https://github.com/0neTX/Bitwarden_Export#readme"
LABEL org.opencontainers.image.vendor="0neTX"
LABEL org.opencontainers.image.authors="0neTX (https://github.com/0neTX)"
# SPDX expression. GPL-3.0-only is the current identifier; plain GPL-3.0 is
# deprecated in the SPDX list.
LABEL org.opencontainers.image.licenses="GPL-3.0-only"
# Fully qualified, with no assumed default registry, as the spec asks. It has to
# agree with the FROM above, so CI checks that it does.
LABEL org.opencontainers.image.base.name="docker.io/library/ubuntu:24.04"
# Set deliberately, though the spec reserves ref.name for descriptors in an image
# layout rather than for an image's own labels. Left unset it comes back
# inherited: :latest reports ref.name=ubuntu to this day.
LABEL org.opencontainers.image.ref.name="bw-export"

# Not declared here on purpose: created and revision are build-time facts, and a
# hardcoded value for either would simply be false; they need to be stamped by
# the workflow. base.digest is left out too: the digest is pinned in the FROM
# above, and a copy here would go stale every time Dependabot bumps that FROM.

# Create a volume for storing vault exporting data
VOLUME /var/data
# Create a volume for storing attachments files in vault
VOLUME /var/attachments

# Disable Prompt During Packages Installation
ARG DEBIAN_FRONTEND=noninteractive


# Update Ubuntu Software repository
# procps provides pkill, which the entrypoint needs to pass a container stop on
# to the export. ca-certificates backs the TLS downloads below. The base image
# happens to ship both; declare them so a slimmer base cannot drop them
# silently. gpg and gpg-agent encrypt the attachments when ENCRYPT_ATTACHMENTS
# is on; the gnupg metapackage would add dirmngr (a network service), gpgsm and
# the LDAP and SASL libraries, none of which is used.
#
# The Infisical installer is fetched to a file instead of piped into bash: the
# old Cloudsmith endpoint now answers 404, and in a pipeline curl's failure was
# swallowed (no pipefail under /bin/sh), so bash ran an empty script, exited 0,
# and the build died two lines later on a misleading "package not found".
# apt-get upgrade applies the Ubuntu security fixes published since the base
# image was built: about two thirds of the vulnerabilities a scan found in it
# had one. --no-install-recommends and no wget keep out what nothing here uses.
RUN apt-get update && \
    apt-get upgrade -y && \
    apt-get install -y --no-install-recommends bash curl jq procps ca-certificates tzdata gpg gpg-agent && \
    curl -fsSL 'https://artifacts-cli.infisical.com/setup.deb.sh' \
        -o /tmp/infisical-setup.sh && \
    bash /tmp/infisical-setup.sh && \
    apt-get update && \
    apt-get install -y --no-install-recommends infisical && \
    # The Infisical installer pulls in the whole gnupg suite to import its
    # repository key; apt then checks that repository against a key file. Only
    # gpg and gpg-agent are used here, so the rest goes again.
    apt-mark manual gpg gpg-agent && \
    apt-get purge -y gnupg dirmngr gpgsm gpg-wks-client gnupg-utils keyboxd gnupg-l10n && \
    apt-get autoremove -y && \
    echo "**** cleanup ****" && \
    apt-get clean && \
    rm -rf \
        /tmp/* \
        /var/lib/apt/lists/* \
        /var/tmp/*



WORKDIR /app

# The binaries fetched and verified in the first stage. Their modes were set
# there; root owns them, like everything else in /app.
COPY --from=fetch /fetch/shoutrrr /fetch/shoutrrr-LICENSE.md /app/
COPY --from=fetch /fetch/supercronic /usr/local/bin/supercronic
COPY --from=fetch /fetch/bw /usr/local/bin/bw
# The CLI version stays readable in the image.
ARG BW_CLI_VERSION
ENV BW_CLI_VERSION="${BW_CLI_VERSION}"

# Copy script
COPY bw_export.sh /app/bw_export.sh
COPY entrypoint.sh /entrypoint.sh
COPY root/ /

# Run multiple tasks
RUN chmod +x /etc/cont-init.d/10-adduser && \
    chmod +x /app/bw_export.sh && \
    chmod +x /entrypoint.sh && \
    echo "**** create abc user and make our folders ****" && \
    useradd -u 911 -U bitwarden && \
    usermod -G users bitwarden && \
    mkdir -p /home/bitwarden && \
    mkdir -p /var/data && \
    mkdir -p /var/attachments && \
    chown -R bitwarden:bitwarden /home/bitwarden && \
    # /app holds code root runs (shoutrrr for every notification): it stays
    # root's. The export user gets only the CLI's data folder.
    mkdir -m 700 /app/data && \
    chown bitwarden:bitwarden /app/data && \
    chown -R bitwarden:bitwarden /var/data && \
    chown -R bitwarden:bitwarden /var/attachments && \
    mkdir -p \
        /app \
        /var/attachments \
        /var/data

ENTRYPOINT ["/entrypoint.sh"]
