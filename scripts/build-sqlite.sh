#!/bin/bash
# SQLite 3.54.1, verified against the official amalgamation and source hash.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 - <<'PY'
from pathlib import Path
import hashlib, tempfile, urllib.request, zipfile
out = Path("Vendor/sqlite")
source_hash = "e2b869d3003b33c942b7dd7063604fbc53553e1b66609570df39b9b7b558ee81"
archive_hash = "0a9c8e34352dad46006aa82836d5383bff9dc6bc9ce5a60553c05aa30e6ad1f9"
if (out/"sqlite3.c").exists() and (out/"include/sqlite3.h").exists():
    if hashlib.sha3_256((out/"sqlite3.c").read_bytes()).hexdigest() == source_hash:
        raise SystemExit(0)
with tempfile.TemporaryDirectory(prefix="digup-sqlite-") as temporary:
    archive = Path(temporary)/"sqlite.zip"
    urllib.request.urlretrieve("https://sqlite.org/2026/sqlite-amalgamation-3540100.zip",archive)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != archive_hash:
        raise SystemExit("SQLite archive checksum mismatch")
    with zipfile.ZipFile(archive) as bundle:
        source = bundle.read("sqlite-amalgamation-3540100/sqlite3.c")
        if hashlib.sha3_256(source).hexdigest() != source_hash:
            raise SystemExit("SQLite source checksum mismatch")
        (out/"include").mkdir(parents=True,exist_ok=True)
        (out/"sqlite3.c").write_bytes(source)
        (out/"include/sqlite3.h").write_bytes(bundle.read("sqlite-amalgamation-3540100/sqlite3.h"))
PY
