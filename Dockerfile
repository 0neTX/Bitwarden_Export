FROM ubuntu:24.04

LABEL description="Bitwarden exporter docker container"
LABEL version="1.9"

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
# silently.
#
# The Infisical installer is fetched to a file instead of piped into bash: the
# old Cloudsmith endpoint now answers 404, and in a pipeline curl's failure was
# swallowed (no pipefail under /bin/sh), so bash ran an empty script, exited 0,
# and the build died two lines later on a misleading "package not found".
RUN apt-get update && \
    apt-get install -y bash curl unzip jq wget procps ca-certificates && \
    curl -fsSL 'https://artifacts-cli.infisical.com/setup.deb.sh' \
        -o /tmp/infisical-setup.sh && \
    bash /tmp/infisical-setup.sh && \
    apt-get update && \
    apt-get install -y infisical && \
    echo "**** cleanup ****" && \
    apt-get clean && \
    rm -rf \
        /tmp/* \
        /var/lib/apt/lists/* \
        /var/tmp/*



WORKDIR /app

# Installing shoutrrr. Pinned rather than resolved through the GitHub API: that
# call is unauthenticated, so every build competed for the 60-requests-per-hour
# quota shared by everything on the same IP. On a CI runner it is usually spent,
# and because "-q" hid the error the build failed with "wget: missing URL".
#
# Source is the nicholas-fedor fork: containrrr/shoutrrr stopped at v0.8.0,
# whose Gotify token check is "exactly 15 chars starting with A", so it rejects
# every token issued by Gotify 3.0.0+ ("gtfya."/"gtfyc." prefix, ~50 chars).
# The checksum is verified because this image handles a full vault; it comes
# from the release's own checksums.txt and must be updated with the version.
ARG SHOUTRRR_VERSION="0.22.0"
ARG SHOUTRRR_SHA256="789c80a72013dea424d1f4ef896101164b240883ecef142f561dd6a118320dad"
ADD https://github.com/nicholas-fedor/shoutrrr/releases/download/v${SHOUTRRR_VERSION}/shoutrrr_linux_amd64_${SHOUTRRR_VERSION}.tar.gz /app/shoutrrr.tar.gz
RUN echo "${SHOUTRRR_SHA256}  shoutrrr.tar.gz" | sha256sum -c - && \
    tar -xzf shoutrrr.tar.gz shoutrrr LICENSE.md && \
    mv LICENSE.md shoutrrr-LICENSE.md && \
    chmod +x shoutrrr && \
    rm shoutrrr.tar.gz

# Installing BW_CLI_VERSION version of Bitwarden CLI.
# ARG so a build can override it (--build-arg BW_CLI_VERSION=...), ENV so the
# version stays readable in the image. The default is the pinned, tested one.
ARG BW_CLI_VERSION="2026.8.0"
ENV BW_CLI_VERSION="${BW_CLI_VERSION}"
ADD https://github.com/bitwarden/clients/releases/download/cli-v${BW_CLI_VERSION}/bw-linux-${BW_CLI_VERSION}.zip /tmp/bw.zip

# Copy script
COPY bw_export.sh /app/bw_export.sh
COPY entrypoint.sh /entrypoint.sh
COPY root/ /

# Run multiple tasks
RUN unzip /tmp/bw.zip && \
    chmod +x /app/bw && \
    install /app/bw /usr/local/bin/ && \
    chmod +x /etc/cont-init.d/10-adduser && \
    chmod +x /app/bw_export.sh && \
    chmod +x /entrypoint.sh && \
    echo "**** create abc user and make our folders ****" && \
    useradd -u 911 -U bitwarden && \
    usermod -G users bitwarden && \
    mkdir -p /home/bitwarden && \
    mkdir -p /var/data && \
    mkdir -p /var/attachment && \
    chown -R bitwarden:bitwarden /home/bitwarden && \
    chown -R bitwarden:bitwarden /app && \
    chown -R bitwarden:bitwarden /var/data && \
    chown -R bitwarden:bitwarden /var/attachment && \
    mkdir -p \
        /app \
        /var/attachment \
        /var/data

ENTRYPOINT ["/entrypoint.sh"]
