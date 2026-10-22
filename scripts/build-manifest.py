#!/usr/bin/env python3
"""Record or verify the runtime inputs used for an application build."""
import hashlib
import json
import pathlib
import sys

if len(sys.argv) != 3 or sys.argv[1] not in ["create", "verify"]:
    raise SystemExit("Usage: python3 scripts/build-manifest.py create|verify MANIFEST")
base = pathlib.Path(__file__).resolve().parent.parent
paths = [base / name for name in ["Package.swift", "LICENSE", "PRIVACY.md",
                                  "scripts/build.sh", "scripts/build-manifest.py"]]
for folder in ["Sources", "Resources"]:
    paths.extend(path for path in (base / folder).rglob("*")
                 if path.is_file() and path.name != ".DS_Store")
if any(path.is_symlink() for path in paths):
    raise SystemExit("Runtime build inputs must not be symbolic links.")
current = {str(path.relative_to(base)): hashlib.sha256(path.read_bytes()).hexdigest()
           for path in paths}
manifest = pathlib.Path(sys.argv[2])
if sys.argv[1] == "create":
    manifest.write_text(json.dumps(current, indent=2, sort_keys=True) + "\n")
elif json.loads(manifest.read_text()) != current:
    raise SystemExit("Runtime inputs changed. Rebuild the app before packaging.")
print("Build source manifest:", sys.argv[1], "PASS")
