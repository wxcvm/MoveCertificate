"""Ensure unrelated local files cannot leak into an installable module."""
import importlib.util
from pathlib import Path
import tempfile
import unittest
from zipfile import ZipFile

spec = importlib.util.spec_from_file_location('module_package', Path(__file__).resolve().parents[1] / 'scripts/package.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class PackageTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for name in module.RUNTIME_FILES:
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b'fixture\r\n')
        (self.root / 'module.prop').write_text('version=v1.6.7\n')
        (self.root / 'webroot').mkdir()
        (self.root / 'webroot/index.html').write_text('<html></html>')

    def test_only_allowlisted_runtime_is_shipped(self):
        for name in ('private.md', 'private.sh', 'sh/local-test.sh', 'diagnostics/device.log', 'driver-fix/lib.so'):
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('must not ship')
        output = module.package(self.root)
        self.assertEqual(output.parent.name, 'dist')
        with ZipFile(output) as archive:
            self.assertEqual(set(archive.namelist()), set(module.RUNTIME_FILES) | {'webroot/index.html'})
            self.assertNotIn(b'\r', archive.read('sh/namespace.sh'))
            self.assertEqual(archive.getinfo('sh/namespace.sh').external_attr >> 16, 0o100755)

    def test_unexpected_webroot_output_is_rejected(self):
        (self.root / 'webroot/private.pem').write_text('must not ship')
        with self.assertRaisesRegex(ValueError, 'Unexpected WebUI output'):
            module.package(self.root)

    def test_missing_runtime_preserves_existing_archive(self):
        output = module.package(self.root)
        original = output.read_bytes()
        (self.root / 'sh/runtime.sh').unlink()
        with self.assertRaises(FileNotFoundError):
            module.package(self.root)
        self.assertEqual(output.read_bytes(), original)
        self.assertFalse(output.with_suffix('.zip.tmp').exists())

    def test_invalid_version_cannot_choose_output_path(self):
        (self.root / 'module.prop').write_text('version=../../private\n')
        with self.assertRaisesRegex(ValueError, 'Invalid module version'):
            module.package(self.root)


if __name__ == '__main__':
    unittest.main()
