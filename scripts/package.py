"""Package separate installable modules. Diagnostics and test CAs are never included."""
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile
import re

ROOT = Path(__file__).resolve().parent.parent
version = re.search(r"^version=(\S+)$", (ROOT / "module.prop").read_text(), re.M)[1]


def write_archive(name, entries):
    with ZipFile(ROOT / name, "w", ZIP_DEFLATED) as archive:
        for path, relative in sorted(entries, key=lambda entry: entry[1]):
            if path.is_symlink():
                raise ValueError(f"Refusing symlink: {path}")
            data = path.read_bytes()
            if path.suffix in (".sh", ".prop", ".conf") or path.name == "update-binary":
                data = data.replace(b"\r\n", b"\n")
            archive.writestr(relative, data)
    with ZipFile(ROOT / name) as archive:
        assert "module.prop" in archive.namelist()
        assert archive.testzip() is None
        assert not any(p.startswith(("diagnostics/", "tests/", "driver-fix/")) for p in archive.namelist())
    print(name)


if not (ROOT / "webroot/index.html").is_file():
    raise SystemExit("Build webroot before packaging")
module = []
for directory in ("META-INF", "webroot", "sh", "README.assets"):
    module.extend((p, p.relative_to(ROOT).as_posix()) for p in (ROOT / directory).rglob("*") if p.is_file())
for p in ROOT.iterdir():
    if p.is_file() and ((p.suffix in (".sh", ".md") and p.name != "buildzip.sh") or
                        p.name in ("LICENSE", "module.prop", "system.prop", "update.json", "cert_names.json")):
        module.append((p, p.name))
write_archive(f"MoveCertificate-{version}.zip", module)

driver = [(p, p.relative_to(ROOT / "driver-fix").as_posix()) for p in (ROOT / "driver-fix").rglob("*")
          if p.is_file() and p.name != "vulkan.mali.so"]
driver.extend((p, p.relative_to(ROOT).as_posix()) for p in (ROOT / "META-INF").rglob("*") if p.is_file())
write_archive("PanVK-guarded-launcher-v1.0.1.zip", driver)
