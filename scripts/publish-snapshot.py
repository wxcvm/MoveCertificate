"""Emit a reviewed text-only Git tree for the authenticated GitHub connector."""
from pathlib import Path
import json
import subprocess
import sys

sys.stdout.reconfigure(encoding="utf-8")

root = Path(__file__).resolve().parent.parent
changed = subprocess.check_output(["git", "diff", "--name-only"], cwd=root, text=True).splitlines()
new = subprocess.check_output(["git", "ls-files", "--others", "--exclude-standard"], cwd=root, text=True).splitlines()
entries = []
for name in sorted(set(changed + new)):
    assert not name.startswith(("diagnostics/", "webroot/", "webdev/node_modules/", ".git/"))
    assert not name.endswith((".zip", ".so", ".log"))
    path = root / name
    if not path.exists():
        entries.append({"path": name, "mode": "100644", "type": "blob", "sha": None})
        continue
    assert not path.is_symlink()
    content = path.read_text(encoding="utf-8").replace("\r\n", "\n")
    assert ("-----BEGIN " + "PRIVATE KEY-----") not in content and ("-----BEGIN " + "RSA PRIVATE KEY-----") not in content
    entries.append({"path": name, "mode": "100755" if path.suffix == ".sh" else "100644", "type": "blob", "content": content})
print(json.dumps(entries, ensure_ascii=False))
