"""Isolated synthetic publication-policy fixtures; never real private material."""
from pathlib import Path
import hashlib
import importlib.util
import json
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('boundary', ROOT / 'scripts/check-source-boundary.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class SourceBoundaryChecks(unittest.TestCase):
    def boundary(self):
        return module.Boundary({'private_line_sha256': [], 'private_filenames': ['SyntheticPrivate.m']})

    def test_public_header_allowed(self):
        self.boundary().entry('Binaries/Module.h', b'extern double PublicValue(void);')

    def test_private_directory_rejected(self):
        with self.assertRaises(ValueError):
            self.boundary().entry('Private/example.txt', b'synthetic fixture')

    def test_shader_text_rejected_even_inside_binary(self):
        text = b'kernel ' + b'vec4 ' + b'edrSynthetic' + b'(value) {}'
        with self.assertRaises(ValueError):
            self.boundary().entry('App/Executable', b'\0' + text + b'\0')

    def test_line_fingerprint_ignores_spacing(self):
        digest = hashlib.sha256(b'synthetic=fixture;').hexdigest()
        boundary = module.Boundary({'private_line_sha256': [digest], 'private_filenames': []})
        with self.assertRaises(ValueError):
            boundary.entry('public.swift', b'  synthetic = fixture;\n')

    def test_unreviewed_binary_file_rejected(self):
        entries = {'Binaries/LightTableEDR.manifest.json': json.dumps({'files': {}}).encode(),
                   'Binaries/LightTableEDR.xcframework/unreviewed.txt': b'synthetic fixture'}
        with self.assertRaises(ValueError):
            module.validate_binary(entries)

    def test_missing_module_rejected(self):
        with self.assertRaises(ValueError):
            module.validate_binary({'Package.swift': b'.binaryTarget(name: "LightTableEDR"'})

    def test_nested_source_archives_require_review(self):
        with self.assertRaises(ValueError):
            self.boundary().entry('source-backup.zip', b'isolated synthetic fixture')

    def test_fingerprint_matches_fragment_inside_a_document(self):
        call = b'smoothstep' + b'(1,2,example)'
        boundary = module.Boundary({'private_line_sha256': [], 'private_filenames': [],
            'private_call_sha256': [hashlib.sha256(call).hexdigest()]})
        with self.assertRaises(ValueError):
            boundary.entry('notes.md', b'example: `' + call + b'`')

    def test_symlink_cannot_copy_external_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / 'public'; root.mkdir()
            outside = Path(tmp) / 'synthetic.txt'; outside.write_text('synthetic fixture')
            (root / 'file.txt').symlink_to(outside)
            with self.assertRaises(ValueError):
                module.tree_entries(root)

    def test_index_reads_staged_content_instead_of_worktree(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            subprocess.run(['git', 'init', '-q', str(root)], check=True)
            (root / 'example.txt').write_text('synthetic staged version')
            subprocess.run(['git', '-C', str(root), 'add', 'example.txt'], check=True)
            (root / 'example.txt').write_text('synthetic unstaged version')
            self.assertEqual(module.index_entries(root)['example.txt'], b'synthetic staged version')

if __name__ == '__main__':
    unittest.main()
