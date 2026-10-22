#!/usr/bin/env python3
"""Export an allowlisted source tree without local history or test evidence."""
import hashlib
import json
import pathlib
import shutil
import sys

base = pathlib.Path(__file__).resolve().parent.parent
if len(sys.argv) != 2:
    raise SystemExit("Usage: python3 scripts/export-public.py NEW_OUTPUT_DIRECTORY")
output = pathlib.Path(sys.argv[1]).resolve()
if output.exists() or output == base or base in output.parents and output.parts[len(base.parts)] not in ["dist", ".build"]:
    raise SystemExit("Choose a new directory outside the source tree, or inside dist/.build.")
files = ["Package.swift", "README.md", "README.ko.md", "LICENSE", "PRIVACY.md", "PRIVACY.ko.md",
         "THIRD_PARTY_NOTICES.md", "CHANGELOG.md", ".gitignore", "docs/ARCHITECTURE.md", "docs/LEGAL.md",
         "docs/LOCALIZATION.md", "docs/RELEASE.md", "docs/VALIDATION-SUMMARY.md"]
trees = ["Sources", "Resources", "Tests", "scripts"]
selected = [base / name for name in files]
for name in trees:
    selected.extend(path for path in (base / name).rglob("*")
                    if path.is_file() and path.name != ".DS_Store" and "__pycache__" not in path.parts)
for path in selected:
    if not path.is_file() or path.is_symlink():
        raise SystemExit("Missing file or symbolic link in public export: " + str(path.relative_to(base)))
    data = path.read_bytes()
    if path.suffix not in [".png", ".icns"]:
        for prefix in [b"/" + b"Users" + b"/", b"/" + b"Volumes" + b"/"]:
            if prefix in data:
                raise SystemExit("Local absolute path in public source: " + str(path.relative_to(base)))
output.mkdir(parents=True)
manifest = {}
for path in selected:
    relative = path.relative_to(base)
    target = output / relative
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(path, target)
    manifest[str(relative)] = hashlib.sha256(target.read_bytes()).hexdigest()
(output / "SOURCE-MANIFEST.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
print("Public export:", output)
print("Files:", len(manifest), "History and local evidence: excluded")
