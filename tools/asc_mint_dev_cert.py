#!/usr/bin/env python3
"""Mint one Apple Development certificate from a CSR via the ASC API.

Used to create the cached CI signing certificate: the RSA key and CSR are
generated on the developer's machine (the private key never leaves it),
only the CSR travels here, and the returned certificate is public
material. The resulting cert id must be stored in the CACHED_DEV_CERT_ID
repo variable so the revoke script never deletes the cached cert.

Env: ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_P8, CSR_B64 (base64 of PEM CSR).
Writes: dev-cert.cer (DER), dev-cert-id.txt.
"""

import base64
import os

import requests

from asc_revoke_dev_certs import BASE, make_token


def main():
    csr_pem = base64.b64decode(os.environ["CSR_B64"]).decode()
    csr_body = "".join(
        line for line in csr_pem.splitlines() if line and "-----" not in line
    )
    payload = {
        "data": {
            "type": "certificates",
            "attributes": {
                "certificateType": "DEVELOPMENT",
                "csrContent": csr_body,
            },
        }
    }
    resp = requests.post(
        f"{BASE}/v1/certificates",
        headers={"Authorization": f"Bearer {make_token()}"},
        json=payload,
        timeout=30,
    )
    resp.raise_for_status()
    data = resp.json()["data"]
    attrs = data["attributes"]
    print(f"minted certificate {data['id']}")
    print(f"  type:   {attrs.get('certificateType')}")
    print(f"  name:   {attrs.get('displayName')}")
    print(f"  serial: {attrs.get('serialNumber')}")
    print(f"  expires: {attrs.get('expirationDate')}")
    with open("dev-cert.cer", "wb") as f:
        f.write(base64.b64decode(attrs["certificateContent"]))
    with open("dev-cert-id.txt", "w") as f:
        f.write(data["id"] + "\n")


if __name__ == "__main__":
    main()
