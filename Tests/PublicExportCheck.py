import hashlib
import json
import pathlib
import subprocess
import sys
import uuid

base = pathlib.Path(__file__).resolve().parent.parent
fixture = base / ".build" / ("PublicExportCheck-" + uuid.uuid4().hex)
fixture.mkdir(parents=True)
export = fixture / "source"
command = [sys.executable, str(base / "scripts/export-public.py"), str(export)]
subprocess.run(command, check=True)
manifest = json.loads((export / "SOURCE-MANIFEST.json").read_text())
for required in ["LICENSE", "Package.swift", "README.md", "README.ko.md", "PRIVACY.ko.md",
                 "THIRD_PARTY_NOTICES.md", "docs/LEGAL.md", "docs/ARCHITECTURE.md"]:
    assert required in manifest, required
assert not any(part in [".git", "Evidence", "dist", "__pycache__"]
               for name in manifest for part in pathlib.Path(name).parts)
for name, expected in manifest.items():
    assert hashlib.sha256((export / name).read_bytes()).hexdigest() == expected, name
assert subprocess.run(command, capture_output=True).returncode != 0
assert subprocess.run(command[:-1] + [str(base)], capture_output=True).returncode != 0
readme = export / "README.md"
readme.write_bytes(readme.read_bytes() + b"\n/" + b"Users" + b"/example/private\n")
private_output = fixture / "private-rejected"
result = subprocess.run([sys.executable, str(export / "scripts/export-public.py"), str(private_output)], capture_output=True)
assert result.returncode != 0 and not private_output.exists()
readme.write_bytes((base / "README.md").read_bytes())
package = export / "Package.swift"
saved = export / "Package-original.swift"
package.rename(saved)
package.symlink_to(saved)
symlink_output = fixture / "symlink-rejected"
result = subprocess.run([sys.executable, str(export / "scripts/export-public.py"), str(symlink_output)], capture_output=True)
assert result.returncode != 0 and not symlink_output.exists()
print("Public export PASS: allowlist, SHA-256 manifest, no history/evidence, existing-directory protection, private-path and symbolic-link rejection")
