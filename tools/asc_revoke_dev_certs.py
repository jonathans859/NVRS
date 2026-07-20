#!/usr/bin/env python3
"""Revoke CI-minted Apple Development certificates via the ASC API.

Runners create a fresh Development certificate per build (cloud signing's
archive step) until the account hits Apple's cap and builds fail with
"maximum number of certificates". Certs minted this way are DEVELOPMENT
type with displayName "Created via API"; their private keys died with the
ephemeral runners, so revoking them can never break anything. Distribution
and Developer ID certificates are never touched.

Two guards, both learned the hard way (2026-07-19/20):

* Certificates are **account-wide**, and a deliberately cached CI cert is
  indistinguishable by name from runner litter — it is also DEVELOPMENT
  and also "Created via API". A sweep run from one repo therefore deletes
  another repo's cached cert, which does NOT self-heal (its private key
  is alive in that repo's secrets). KEEP_CERT_IDS must list the cached
  cert of *every* repo on the account.
* A sweep can race an in-flight build on another repo and revoke the cert
  it just minted, so anything younger than MIN_AGE_MINUTES is skipped.
"""

import datetime as dt
import os
import sys
import time

import jwt
import requests

BASE = "https://api.appstoreconnect.apple.com"
DEFAULT_MIN_AGE_MINUTES = 60


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


def keep_ids():
    """Cached cert ids to spare, from KEEP_CERT_IDS (comma/space separated).
    KEEP_CERT_ID stays accepted so older workflow files keep working."""
    raw = os.environ.get("KEEP_CERT_IDS") or os.environ.get("KEEP_CERT_ID") or ""
    return {part for part in raw.replace(",", " ").split() if part}


def issued_at(attrs):
    """When the certificate was issued, as an aware UTC datetime, or None.

    Prefers notBefore parsed out of the DER, which is exact; falls back to
    expiry minus one year (Apple Development certs are 1-year) when the
    content or the x509 parser is unavailable.
    """
    content = attrs.get("certificateContent")
    if content:
        try:
            import base64

            from cryptography import x509

            cert = x509.load_der_x509_certificate(base64.b64decode(content))
            try:
                return cert.not_valid_before_utc
            except AttributeError:  # cryptography < 42
                return cert.not_valid_before.replace(tzinfo=dt.timezone.utc)
        except Exception:
            pass
    expires = attrs.get("expirationDate")
    if expires:
        try:
            return dt.datetime.fromisoformat(expires) - dt.timedelta(days=365)
        except ValueError:
            pass
    return None


def main():
    keep = keep_ids()
    # Read-only inventory: prints the same listing and revokes nothing.
    dry_run = os.environ.get("DRY_RUN", "").strip().lower() in ("1", "true", "yes")
    min_age = int(os.environ.get("MIN_AGE_MINUTES") or DEFAULT_MIN_AGE_MINUTES)
    cutoff = dt.datetime.now(dt.timezone.utc) - dt.timedelta(minutes=min_age)

    if keep:
        print(f"sparing cached cert ids: {', '.join(sorted(keep))}")
    else:
        print("WARNING: no KEEP_CERT_IDS set — any cached CI certificate on this")
        print("         account will be revoked. See the note in this file.")
    print(f"skipping certificates issued in the last {min_age} minutes")

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
        expires = attrs.get("expirationDate", "")
        issued = issued_at(attrs)

        note = ""
        revoke = kind == "DEVELOPMENT" and name == "Created via API"
        if revoke and cert["id"] in keep:
            revoke, note = False, "  (kept: cached CI cert)"
        elif revoke and issued is not None and issued > cutoff:
            revoke, note = False, "  (kept: too new, may be an in-flight build)"
        elif revoke and issued is None:
            revoke, note = False, "  (kept: issue date unknown)"

        issued_text = issued.isoformat(timespec="seconds") if issued else "issued unknown"
        print(f"  {cert['id']}  {kind:<24} issued {issued_text:<26} {name}{note}")
        if revoke:
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
