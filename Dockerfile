FROM ubuntu:24.04

LABEL description="Bitwarden exporter docker container"
LABEL version="1.2"

# Create a volume for storing vault exporting data
VOLUME /var/data
# Create a volume for storing attachments files in vault
VOLUME /var/attachments

# Disable Prompt During Packages Installation
ARG DEBIAN_FRONTEND=noninteractive

# Update Ubuntu Software repository
RUN apt-get update && \
    apt-get install -y unzip jq  && \
    echo "**** cleanup ****" && \
    apt-get clean && \
    rm -rf \
        /tmp/* \
        /var/lib/apt/lists/* \
        /var/tmp/*

WORKDIR /app

# Installing last version of Bitwarden CLI
ADD https://vault.bitwarden.com/download/?app=cli&platform=linux /tmp/bw.zip

# Copy script
COPY bw_export.sh /app/bw_export.sh 
COPY entrypoint.sh /entrypoint.sh
COPY root/ /

# Run multiple tasks
RUN unzip /tmp/bw.zip && \
    chmod +x /app/bw && \
    install /app/bw /usr/local/bin/ && \
    chmod +x /app/bw_export.sh && \
    chmod +x /entrypoint.sh && \
    echo "**** create abc user and make our folders ****" && \
    useradd -u 911 -U bitwarden && \
    usermod -G users bitwarden && \
    mkdir /home/bitwarden && \
    mkdir /var/data && \
    mkdir /var/attachment && \
    chown -R  bitwarden:bitwarden /home/bitwarden  && \    
    chown -R  bitwarden:bitwarden /app  && \
    chown -R  bitwarden:bitwarden /var/data  && \
    chown -R  bitwarden:bitwarden /var/attachment  && \
    mkdir -p \
        /app \
        /var/attachment \
        /var/data

ENTRYPOINT ["/entrypoint.sh"]

