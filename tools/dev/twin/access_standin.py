#!/usr/bin/env python3
"""Stands in for Cloudflare Access on the twin, so the services' real JWT validation runs.

The edge asks /auth about every protected request (Traefik forwardAuth). A known service token gets
the same answer Access gives: a signed RS256 JWT in Cf-Access-Jwt-Assertion, with iss, aud and
common_name set the way the origin expects. Anything else gets 403 and never reaches the cell. Cells
fetch the public key from /cdn-cgi/access/certs, the path Access uses. As with real Access policies,
the metrics host admits only the metrics token, and the metrics token opens nothing else.

It proves the origin's checks, not Cloudflare's: real Access claim names must still be confirmed on a
real team domain (docs/runbooks/local-twin.md).
"""
import base64
import hashlib
import hmac
import json
import os
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding, rsa

STATE = Path(os.environ.get("ACCESS_STATE_DIR", "/access"))
ISSUER = os.environ["ACCESS_ISSUER"]
AUDIENCE = os.environ["ACCESS_AUD"]
ADMIN_HOSTS = set(os.environ["ACCESS_ADMIN_HOSTS"].split(","))
METRICS_HOST = os.environ["ACCESS_METRICS_HOST"]
METRICS_CLIENT_ID = os.environ["ACCESS_METRICS_CLIENT_ID"]
TOKEN_LIFETIME_SECONDS = 300


def b64url(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


def load_key() -> rsa.RSAPrivateKey:
    path = STATE / "signing-key.pem"
    if path.exists():
        return serialization.load_pem_private_key(path.read_bytes(), password=None)
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    path.write_bytes(
        key.private_bytes(
            serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()
        )
    )
    path.chmod(0o600)
    return key


KEY = load_key()
NUMBERS = KEY.public_key().public_numbers()
N_BYTES = NUMBERS.n.to_bytes((NUMBERS.n.bit_length() + 7) // 8, "big")
KID = hashlib.sha256(N_BYTES).hexdigest()[:32]
JWKS = json.dumps(
    {
        "keys": [
            {
                "kty": "RSA",
                "use": "sig",
                "alg": "RS256",
                "kid": KID,
                "n": b64url(N_BYTES),
                "e": b64url(NUMBERS.e.to_bytes(3, "big")),
            }
        ]
    }
).encode()


def service_tokens() -> dict[str, str]:
    return json.loads((STATE / "service-tokens.json").read_text())


def sign(client_id: str) -> str:
    now = int(time.time())
    header = {"alg": "RS256", "kid": KID, "typ": "JWT"}
    claims = {
        "iss": ISSUER,
        "aud": [AUDIENCE],
        "common_name": client_id,
        "sub": "",
        "type": "app",
        "iat": now,
        "nbf": now,
        "exp": now + TOKEN_LIFETIME_SECONDS,
        "jti": str(uuid.uuid4()),
    }
    signing_input = f"{b64url(json.dumps(header).encode())}.{b64url(json.dumps(claims).encode())}"
    signature = KEY.sign(signing_input.encode(), padding.PKCS1v15(), hashes.SHA256())
    return f"{signing_input}.{b64url(signature)}"


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        print(f"{self.address_string()} {fmt % args}", flush=True)

    def answer(self, code: int, body: bytes = b"", headers: dict[str, str] | None = None):
        self.send_response(code)
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/cdn-cgi/access/certs":
            self.answer(200, JWKS, {"Content-Type": "application/json"})
        elif self.path == "/auth":
            self.authorize()
        else:
            self.answer(404)

    def authorize(self):
        host = self.headers.get("X-Forwarded-Host", "").split(":")[0]
        client_id = self.headers.get("CF-Access-Client-Id", "")
        secret = self.headers.get("CF-Access-Client-Secret", "")
        # The JWT names the id from the token file, so nothing from the request reaches a response header.
        known = next((k for k, expected in service_tokens().items()
                      if k == client_id and hmac.compare_digest(expected, secret)), None)
        allowed = known == METRICS_CLIENT_ID if host == METRICS_HOST else host in ADMIN_HOSTS and known != METRICS_CLIENT_ID
        if known and allowed:
            self.answer(200, headers={"Cf-Access-Jwt-Assertion": sign(known)})
        else:
            self.answer(403, b"Forbidden by Access\n", {"Content-Type": "text/plain"})


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", 443), Handler).serve_forever()
