import json
import pathlib
import subprocess
import sys
import uuid

base = pathlib.Path(__file__).resolve().parent.parent
manifest = base / ".build" / ("build-manifest-check-" + uuid.uuid4().hex + ".json")
command = [sys.executable, str(base / "scripts/build-manifest.py")]
subprocess.run(command + ["create", str(manifest)], check=True)
subprocess.run(command + ["verify", str(manifest)], check=True)
values = json.loads(manifest.read_text())
values["Package.swift"] = "0" * 64
manifest.write_text(json.dumps(values))
assert subprocess.run(command + ["verify", str(manifest)], capture_output=True).returncode != 0
print("Build manifest PASS: current source accepted; stale or mismatched inputs rejected")
