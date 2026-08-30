#!/usr/bin/env python3
"""Bootstrap a throwaway Vaultwarden account for the end-to-end tests.

Registers an account, fetches its personal API key and creates an organization,
then prints the credentials as shell assignments. Implements just enough of the
Bitwarden client crypto (PBKDF2 + HKDF + AES-CBC/HMAC EncStrings) to do so
without a browser.

    python3 tests/bootstrap_vault.py https://127.0.0.1:8443 tests/e2e/certs/ca.crt

Requires: pip install cryptography
"""
import base64
import hashlib
import hmac
import json
import os
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import padding, rsa
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.primitives import hashes

EMAIL = os.environ.get("E2E_EMAIL", "e2e@example.com")
PASSWORD = os.environ.get("E2E_PASSWORD", "TestMasterPassw0rd!")
ITER = 600000

BASE = sys.argv[1] if len(sys.argv) > 1 else "https://127.0.0.1:8443"
CA = sys.argv[2] if len(sys.argv) > 2 else None
CTX = ssl.create_default_context(cafile=CA) if CA else None
if CTX:
    CTX.check_hostname = False  # cert is for vw.test, we reach it on 127.0.0.1


def b64(x):
    return base64.b64encode(x).decode()


def hkdf_expand(prk, info, length=32):
    out, t, i = b"", b"", 1
    while len(out) < length:
        t = hmac.new(prk, t + info.encode() + bytes([i]), hashlib.sha256).digest()
        out += t
        i += 1
    return out[:length]


def master_key(password, email):
    return hashlib.pbkdf2_hmac("sha256", password.encode(), email.lower().encode(), ITER, 32)


def password_hash(mk, password):
    return b64(hashlib.pbkdf2_hmac("sha256", mk, password.encode(), 1, 32))


def enc_string(plain, enc_key, mac_key):
    """EncString type 2: AES-256-CBC then HMAC-SHA256 over iv||ct."""
    iv = os.urandom(16)
    pad = 16 - (len(plain) % 16)
    c = Cipher(algorithms.AES(enc_key), modes.CBC(iv)).encryptor()
    ct = c.update(plain + bytes([pad]) * pad) + c.finalize()
    mac = hmac.new(mac_key, iv + ct, hashlib.sha256).digest()
    return "2.%s|%s|%s" % (b64(iv), b64(ct), b64(mac))


def dec_string(s, enc_key, mac_key):
    iv, ct, mac = [base64.b64decode(p) for p in s.split(".", 1)[1].split("|")]
    assert hmac.compare_digest(hmac.new(mac_key, iv + ct, hashlib.sha256).digest(), mac), "bad mac"
    d = Cipher(algorithms.AES(enc_key), modes.CBC(iv)).decryptor()
    out = d.update(ct) + d.finalize()
    return out[: -out[-1]]


def request(path, data=None, form=False, token=None):
    headers = {"Bitwarden-Client-Name": "web", "Bitwarden-Client-Version": "2026.6.0"}
    if token:
        headers["Authorization"] = "Bearer " + token
    body = None
    if data is not None:
        body = urllib.parse.urlencode(data).encode() if form else json.dumps(data).encode()
        headers["Content-Type"] = (
            "application/x-www-form-urlencoded" if form else "application/json"
        )
    req = urllib.request.Request(BASE + path, data=body, headers=headers)
    try:
        with urllib.request.urlopen(req, context=CTX) as r:
            raw = r.read().decode()
            return r.status, (json.loads(raw) if raw.strip() else {})
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()


def main():
    mk = master_key(PASSWORD, EMAIL)
    mph = password_hash(mk, PASSWORD)
    senc, smac = hkdf_expand(mk, "enc"), hkdf_expand(mk, "mac")

    user_key = os.urandom(64)
    priv = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    priv_der = priv.private_bytes(
        serialization.Encoding.DER, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()
    )
    pub_der = priv.public_key().public_bytes(
        serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo
    )

    st, body = request(
        "/identity/accounts/register",
        {
            "email": EMAIL,
            "name": "E2E Test",
            "masterPasswordHash": mph,
            "masterPasswordHint": None,
            "key": enc_string(user_key, senc, smac),
            "kdf": 0,
            "kdfIterations": ITER,
            "keys": {"publicKey": b64(pub_der), "encryptedPrivateKey": enc_string(priv_der, user_key[:32], user_key[32:])},
        },
    )
    if st not in (200, 204):
        sys.exit("register failed: %s %r" % (st, body))

    st, tok = request(
        "/identity/connect/token",
        {
            "grant_type": "password",
            "username": EMAIL,
            "password": mph,
            "scope": "api offline_access",
            "client_id": "web",
            "deviceType": "9",
            "deviceIdentifier": "e2e-bootstrap-0001",
            "deviceName": "e2e",
        },
        form=True,
    )
    if st != 200:
        sys.exit("login failed: %s %r" % (st, tok))
    at = tok["access_token"]

    st, prof = request("/api/accounts/profile", token=at)
    user_id = prof["id"]

    st, key = request("/api/accounts/api-key", {"masterPasswordHash": mph}, token=at)
    if st != 200:
        sys.exit("api-key failed: %s %r" % (st, key))

    # Organization: its symmetric key is wrapped for the user with RSA-OAEP (EncString type 4).
    user_key = dec_string(tok["Key"], senc, smac)
    user_pub = serialization.load_der_private_key(
        dec_string(tok["PrivateKey"], user_key[:32], user_key[32:]), None
    ).public_key()
    org_key = os.urandom(64)
    opriv = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    st, org = request(
        "/api/organizations",
        {
            "name": "E2E Org",
            "billingEmail": EMAIL,
            "planType": 0,
            "collectionName": enc_string(b"Default Collection", org_key[:32], org_key[32:]),
            "key": "4."
            + b64(user_pub.encrypt(org_key, padding.OAEP(padding.MGF1(hashes.SHA1()), hashes.SHA1(), None))),
            "keys": {
                "publicKey": b64(
                    opriv.public_key().public_bytes(
                        serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo
                    )
                ),
                "encryptedPrivateKey": enc_string(
                    opriv.private_bytes(
                        serialization.Encoding.DER,
                        serialization.PrivateFormat.PKCS8,
                        serialization.NoEncryption(),
                    ),
                    org_key[:32],
                    org_key[32:],
                ),
            },
        },
        token=at,
    )
    if st != 200:
        sys.exit("create org failed: %s %r" % (st, org))

    print("BW_CLIENTID=user.%s" % user_id)
    print("BW_CLIENTSECRET=%s" % key["apiKey"])
    print("BW_PASSWORD=%s" % PASSWORD)
    print("EXPORT_PASSWORD=ExportPassw0rd!")
    print("E2E_ORG_ID=%s" % org["id"])


if __name__ == "__main__":
    main()
