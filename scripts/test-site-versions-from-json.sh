#!/bin/sh
# The download page must not know the current version. Those numbers live in
# site/version.json; index.html fetches them. A hardcoded href is how the
# buttons stayed on 1.2.9 after two Pages deploys of newer DMGs.
set -eu
REPO_ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"
python3 - <<'PY'
import json, pathlib, re, sys

html = pathlib.Path("site/index.html").read_text()
ver = json.loads(pathlib.Path("site/version.json").read_text())
need = [
    "mac", "macUrlArm", "macUrlIntel", "macSha256Arm", "macSha256Intel",
    "win", "winUrl", "winSha256",
]
missing = [k for k in need if not ver.get(k)]
if missing:
    print(f"FAIL site-versions-from-json version.json missing {missing}")
    sys.exit(1)

if 'fetch("version.json"' not in html and "fetch('version.json'" not in html:
    print("FAIL site-versions-from-json index.html does not fetch version.json")
    sys.exit(1)

for slot in (
    "kicker", "gallery-ver", "mac-arm-ver", "mac-intel-ver", "win-ver",
    "win-setup-name", "win-faq", "footer-ver",
):
    if f'data-fill="{slot}"' not in html:
        print(f"FAIL site-versions-from-json missing data-fill={slot}")
        sys.exit(1)
for href in ("macUrlArm", "macUrlIntel", "winUrl", "winPortable"):
    if f'data-fill-href="{href}"' not in html:
        print(f"FAIL site-versions-from-json missing data-fill-href={href}")
        sys.exit(1)

# The live version numbers must not be baked into the page. Past numbers in
# feature copy (e.g. Pixelate 1.2.11) are allowed until they become current.
for v in (ver["mac"], ver["win"]):
    if v in html:
        print(f"FAIL site-versions-from-json index.html still contains live version {v}")
        sys.exit(1)

if re.search(r'href="Snippr-\d', html) or re.search(
    r'href="https://github.com/[^"]*SnipprSetup', html
):
    print("FAIL site-versions-from-json download href is a hardcoded artifact")
    sys.exit(1)

if "failVisible" not in html:
    print("FAIL site-versions-from-json missing fail-visible path")
    sys.exit(1)

# No-JS has no fetch, so the buttons stay href="#". A noscript without a
# real Releases link leaves those people with nothing to click.
blocks = re.findall(r"<noscript>(.*?)</noscript>", html, flags=re.S)
if not any(
    'href="https://github.com/fantasy9876/snippr/releases"' in b
    for b in blocks
):
    print("FAIL site-versions-from-json noscript must link to GitHub Releases")
    sys.exit(1)

print("PASS site-versions-from-json")
PY
