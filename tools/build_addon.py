#!/usr/bin/env python3
"""Package addon/ into dist/nvrs-<version>.nvda-addon (a plain zip)."""

import re
import zipfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
ADDON_DIR = REPO_ROOT / "addon"
DIST_DIR = REPO_ROOT / "dist"


def main():
    manifest = (ADDON_DIR / "manifest.ini").read_text(encoding="utf-8")
    name = re.search(r"^name = (.+)$", manifest, re.M).group(1).strip()
    version = re.search(r"^version = (.+)$", manifest, re.M).group(1).strip()
    DIST_DIR.mkdir(exist_ok=True)
    out = DIST_DIR / f"{name}-{version}.nvda-addon"
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as zf:
        for path in sorted(ADDON_DIR.rglob("*")):
            if path.is_dir() or "__pycache__" in path.parts:
                continue
            zf.write(path, path.relative_to(ADDON_DIR).as_posix())
    print(f"Built {out}")


if __name__ == "__main__":
    main()
