#!/usr/bin/env bash
# Builds the end-to-end environment for issue #21 from nothing:
# TLS material, a Vaultwarden 1.37.2, a registered account with an API key, an
# organization, one personal item with an attachment and one org item.
#
#   bash tests/e2e-setup.sh
#
# Everything lands in tests/e2e/, which is gitignored. Re-running it from
# scratch requires removing that directory first.
set -euo pipefail

cd "$(dirname "$0")"
E2E="$PWD/e2e"
COMPOSE=(docker compose -f "$PWD/compose.test.yml")

mkdir -p "$E2E"/{data,att,secrets,vw,certs,nginx}

if [[ ! -f "$E2E/certs/vw.crt" ]]; then
    echo "==> generating throwaway CA and vw.test certificate"
    # The Bitwarden CLI refuses plain-HTTP servers, so Vaultwarden needs TLS.
    openssl req -x509 -newkey rsa:2048 -nodes -keyout "$E2E/certs/ca.key" \
        -out "$E2E/certs/ca.crt" -days 30 -subj "/CN=E2E Test CA" \
        -addext "basicConstraints=critical,CA:TRUE" \
        -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null
    openssl req -newkey rsa:2048 -nodes -keyout "$E2E/certs/vw.key" \
        -out "$E2E/certs/vw.csr" -subj "/CN=vw.test" 2>/dev/null
    printf 'subjectAltName=DNS:vw.test,DNS:localhost,IP:127.0.0.1\nbasicConstraints=CA:FALSE\nextendedKeyUsage=serverAuth\n' \
        > "$E2E/certs/ext.cnf"
    openssl x509 -req -in "$E2E/certs/vw.csr" -CA "$E2E/certs/ca.crt" -CAkey "$E2E/certs/ca.key" \
        -CAcreateserial -out "$E2E/certs/vw.crt" -days 30 -extfile "$E2E/certs/ext.cnf" 2>/dev/null
    cat "$E2E/certs/vw.crt" "$E2E/certs/ca.crt" > "$E2E/certs/vw-fullchain.crt"
fi

cat > "$E2E/nginx/vw.conf" <<'NGINX'
server {
    listen 443 ssl;
    server_name vw.test;
    ssl_certificate     /certs/vw-fullchain.crt;
    ssl_certificate_key /certs/vw.key;
    client_max_body_size 128M;
    location / {
        proxy_pass http://vaultwarden:80;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
    }
}
NGINX

echo "==> starting vaultwarden + TLS proxy"
# Pulled up front: under podman the compose provider can only pull through the
# API socket, which is not always up.
docker pull -q docker.io/vaultwarden/server:1.37.2 >/dev/null
docker pull -q docker.io/library/nginx:alpine >/dev/null
"${COMPOSE[@]}" up -d vaultwarden vw-tls >/dev/null
for _ in $(seq 1 60); do
    curl -sk --cacert "$E2E/certs/ca.crt" -o /dev/null https://127.0.0.1:8443/alive && break
    sleep 1
done
echo "    vaultwarden is up on https://127.0.0.1:8443"

echo "==> building bw-export image from the repo Dockerfile"
docker build -q -t localhost/bw-export:local .. >/dev/null

if [[ ! -s "$E2E/test.env" ]]; then
    echo "==> registering the test account, API key and organization"
    python3 bootstrap_vault.py https://127.0.0.1:8443 "$E2E/certs/ca.crt" > "$E2E/test.env"
fi
set -a
# shellcheck source=/dev/null
. "$E2E/test.env"
set +a

umask 077
printf '%s' "$BW_CLIENTID"      > "$E2E/secrets/.bwclientid"
printf '%s' "$BW_CLIENTSECRET"  > "$E2E/secrets/.bwsecret"
printf '%s' "$BW_PASSWORD"      > "$E2E/secrets/.bwpassword"
printf '%s' "$EXPORT_PASSWORD"  > "$E2E/secrets/.exportpassword"
umask 022

echo "==> seeding the vault (personal item + attachment, org item)"
# Ask for the network rather than assuming "tests_default": the project name is
# derived from the compose file's directory, and implementations differ.
NETWORK=$(docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{end}}' bwtest-vaultwarden)
[ -n "$NETWORK" ] || { echo "could not determine the compose network" >&2; exit 1; }
docker run --rm --network "$NETWORK" \
    -e BW_CLIENTID="$BW_CLIENTID" -e BW_CLIENTSECRET="$BW_CLIENTSECRET" \
    -e PW="$BW_PASSWORD" -e ORG="$E2E_ORG_ID" \
    -e NODE_EXTRA_CA_CERTS=/certs/ca.crt \
    -e BITWARDENCLI_APPDATA_DIR=/tmp/seed \
    -v "$E2E/certs/ca.crt:/certs/ca.crt:ro,z" \
    --entrypoint bash localhost/bw-export:local -c '
set -e
mkdir -p /tmp/seed
bw config server https://vw.test --nointeraction >/dev/null
bw login --apikey --method 0 --quiet --nointeraction
BW_SESSION=$(bw unlock "$PW" --raw); export BW_SESSION
bw sync >/dev/null
COLL=$(bw list collections --organizationid "$ORG" | jq -r ".[0].id")
bw get template item | jq ".name=\"Personal Login\" | .type=1 | .login={username:\"user1\",password:\"pass1\",totp:null,uris:[]}" \
  | bw encode | bw create item >/dev/null
bw get template item | jq --arg o "$ORG" --arg c "$COLL" ".name=\"Org Login\" | .type=1 | .organizationId=\$o | .collectionIds=[\$c] | .login={username:\"orguser\",password:\"orgpass\",totp:null,uris:[]}" \
  | bw encode | bw create item --organizationid "$ORG" >/dev/null
bw sync >/dev/null
ITEM=$(bw list items --search "Personal Login" | jq -r ".[0].id")
printf "hello attachment from e2e test\n" > /tmp/a.txt
bw create attachment --file /tmp/a.txt --itemid "$ITEM" >/dev/null
bw logout >/dev/null 2>&1 || true
echo "    seeded"
'

echo
echo "Ready. Credentials in tests/e2e/test.env (gitignored)."
echo "Run an export:      docker compose -f tests/compose.test.yml --env-file tests/e2e/test.env up -d bw-export"
echo "Re-run the SAME container (this is what reproduces #21):"
echo "                    docker compose -f tests/compose.test.yml --env-file tests/e2e/test.env start bw-export"
