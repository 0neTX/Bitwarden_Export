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
# to the export. The base image happens to ship it; declare it so a slimmer base
# cannot drop it silently.
RUN apt-get update && apt-get install -y  bash curl unzip jq wget procps && curl -1sLf \
'https://dl.cloudsmith.io/public/infisical/infisical-cli/setup.deb.sh' | bash \
&& apt-get update && apt-get install -y infisical  \
&& echo "**** cleanup ****" && \
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
ARG SHOUTRRR_VERSION="0.8.0"
ADD https://github.com/containrrr/shoutrrr/releases/download/v${SHOUTRRR_VERSION}/shoutrrr_linux_amd64.tar.gz /app/shoutrrr_linux_amd64.tar.gz
RUN tar -xf shoutrrr_linux_amd64.tar.gz && \
        chmod +x shoutrrr
        
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
    chown -R  bitwarden:bitwarden /home/bitwarden  && \    
    chown -R  bitwarden:bitwarden /app  && \
    chown -R  bitwarden:bitwarden /var/data  && \
    chown -R  bitwarden:bitwarden /var/attachment  && \
    mkdir -p \
        /app \
        /var/attachment \
        /var/data
ENTRYPOINT [ "/entrypoint.sh" ]
