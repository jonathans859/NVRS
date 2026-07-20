#!/usr/bin/env python3
"""Revoke CI-minted Apple Development certificates via the ASC API.

Runners create a fresh Development certificate per build (cloud signing's
archive step) until the account hits Apple's cap and builds fail with
"maximum number of certificates". Certs minted this way are DEVELOPMENT
type with displayName "Created via API"; their private keys died with the
ephemeral runners, so revoking them can never break anything. Distribution
and Developer ID certificates are never touched.
"""

import os
import sys
import time

import jwt
import requests

BASE = "https://api.appstoreconnect.apple.com"


def make_token():
    key_id = os.environ["ASC_KEY_ID"]
    issuer_id = os.environ["ASC_ISSUER_ID"]
    key = os.environ["ASC_KEY_P8"]
    now = int(time.time())
    return jwt.encode(
        {"iss": issuer_id, "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"},
        key,
        algorithm="ES256",
        headers={"kid": key_id, "typ": "JWT"},
    )


def main():
    # The deliberately cached CI cert (see asc_mint_dev_cert.py) is also
    # API-created; never revoke it.
    keep = os.environ.get("KEEP_CERT_ID", "").strip()
    # Read-only inventory: prints the same listing and revokes nothing.
    dry_run = os.environ.get("DRY_RUN", "").strip().lower() in ("1", "true", "yes")
    headers = {"Authorization": f"Bearer {make_token()}"}
    resp = requests.get(f"{BASE}/v1/certificates?limit=200", headers=headers, timeout=30)
    resp.raise_for_status()
    certs = resp.json()["data"]
    print(f"{len(certs)} certificates total")
    victims = []
    for cert in certs:
        attrs = cert["attributes"]
        kind = attrs.get("certificateType")
        name = attrs.get("displayName") or ""
        kept = " (kept: cached CI cert)" if cert["id"] == keep else ""
        expires = attrs.get("expirationDate", "")
        print(f"  {cert['id']}  {kind:<24} {expires:<26} {name}{kept}")
        if kind == "DEVELOPMENT" and name == "Created via API" and cert["id"] != keep:
            victims.append(cert["id"])
    if dry_run:
        print(f"DRY RUN: would revoke {len(victims)} CI-minted DEVELOPMENT certificates")
        return
    print(f"revoking {len(victims)} CI-minted DEVELOPMENT certificates")
    failures = 0
    for cert_id in victims:
        del_resp = requests.delete(f"{BASE}/v1/certificates/{cert_id}", headers=headers, timeout=30)
        if del_resp.status_code == 204:
            print(f"  revoked {cert_id}")
        else:
            failures += 1
            print(f"  FAILED {cert_id}: {del_resp.status_code} {del_resp.text[:200]}")
    if failures:
        sys.exit(1)


if __name__ == "__main__":
    main()
