"""Package only the MoveCertificate runtime; local artifacts are never inputs."""
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile, ZipInfo
import re
import json

ROOT = Path(__file__).resolve().parent.parent
RUNTIME_FILES = (
    'module.prop', 'customize.sh', 'post-fs-data.sh', 'post-mount.sh',
    'service.sh', 'action.sh', 'uninstall.sh', 'system.prop', 'update.json',
    'cert_names.json', 'sh/common.sh', 'sh/runtime.sh', 'sh/activate.sh',
    'sh/mount.sh', 'sh/namespace.sh', 'sh/diagnose.sh', 'sh/delete-cert.sh',
    'sh/set-cert-enabled.sh', 'sh/set-mode.sh',
    'META-INF/com/google/android/update-binary',
    'META-INF/com/google/android/updater-script',
    'LICENSE', 'README.md', 'README.en.md', 'README.tr.md', 'FIXES.md', 'changelog.md',
)
DOCUMENTATION_ASSETS = (
    'README.assets/20221109212126575.png',
    'README.assets/2024-02-19_01.27.27.png',
)


def package(root=ROOT):
    version = re.search(r'^version=(v[0-9]+(?:\.[0-9]+)*)\s*$',
                        (root / 'module.prop').read_text(), re.M)
    if not version:
        raise ValueError('Invalid module version')
    properties = dict(line.split('=', 1) for line in (root / 'module.prop').read_text().splitlines() if '=' in line)
    update = json.loads((root / 'update.json').read_text())
    if (update.get('version') != version[1] or
            update.get('versionCode') != int(properties['versionCode'])):
        raise ValueError('Update metadata does not match module version')
    if not (root / 'webroot/index.html').is_file():
        raise ValueError('Build webroot before packaging')
    entries = list(RUNTIME_FILES) + list(DOCUMENTATION_ASSETS)
    for directory in ('webroot',):
        for path in (root / directory).rglob('*'):
            if path.is_symlink():
                raise ValueError(f'Refusing symlink: {path}')
            if path.is_file():
                if path.suffix not in ('.html', '.js', '.css'):
                    raise ValueError(f'Unexpected WebUI output: {path.name}')
                entries.append(path.relative_to(root).as_posix())
    output = root / 'dist' / f'MoveCertificate-{version[1]}.zip'
    output.parent.mkdir(exist_ok=True)
    temporary = output.with_suffix('.zip.tmp')
    try:
        with ZipFile(temporary, 'w', ZIP_DEFLATED) as archive:
            for relative in sorted(entries):
                path = root / relative
                current = path
                while current != root:
                    if current.is_symlink():
                        raise ValueError(f'Refusing symlink: {current}')
                    current = current.parent
                data = path.read_bytes()
                executable = path.suffix == '.sh' or path.name == 'update-binary'
                if relative in RUNTIME_FILES:
                    data = data.replace(b'\r\n', b'\n')
                info = ZipInfo(relative)
                info.create_system = 3
                info.compress_type = ZIP_DEFLATED
                info.external_attr = (0o100755 if executable else 0o100644) << 16
                archive.writestr(info, data)
        with ZipFile(temporary) as archive:
            if archive.testzip() is not None:
                raise ValueError('Invalid ZIP')
        temporary.replace(output)
    finally:
        temporary.unlink(missing_ok=True)
    return output


if __name__ == '__main__':
    print(package())

