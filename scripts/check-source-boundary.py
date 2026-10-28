#!/usr/bin/env python3
"""Prevent accidental publication of private EDR implementation material."""
from pathlib import Path, PurePosixPath
import argparse
import hashlib
import json
import os
import plistlib
import re
import subprocess
import sys
import zipfile

ROOT = Path(__file__).resolve().parents[1]
IGNORED = {'.git', '.build', '.swiftpm', '.work', 'dist', '__pycache__'}
PATTERNS = [re.compile(rb'kernel\s+vec4\s+edr\w*\s*\(', re.I),
            re.compile(rb'float4\s+edr(?:Optical|Composite)\s*\(', re.I)]

def normalized(line):
    return re.sub(rb'\s+', b'', line)

class Boundary:
    def __init__(self, policy):
        self.hashes = set(policy['private_line_sha256'])
        self.calls = set(policy.get('private_call_sha256', []))
        self.private_names = set(policy['private_filenames'])
        self.count = 0

    def entry(self, name, data):
        path = PurePosixPath(name)
        if path.is_absolute() or '..' in path.parts:
            raise ValueError(f'Unsafe publication path: {name}')
        if (any(p.lower() in {'private', '.work', 'research'} or p.endswith('.dSYM') for p in path.parts)
                or path.name in self.private_names
                or path.suffix.lower() in {'.metal', '.air', '.zip', '.tar', '.gz', '.tgz', '.7z', '.rar'}):
            raise ValueError(f'Private/development artifact in publication: {name}')
        if any(pattern.search(data) for pattern in PATTERNS):
            raise ValueError(f'EDR shader source text in publication: {name}')
        if any(hashlib.sha256(normalized(line)).hexdigest() in self.hashes for line in data.splitlines()):
            raise ValueError(f'Private implementation line in publication: {name}')
        if b'smoothstep' in data and any(hashlib.sha256(call).hexdigest() in self.calls
                for call in re.findall(rb'smoothstep\([^()]*\)', normalized(data))):
            raise ValueError(f'Private implementation fragment in publication: {name}')
        self.count += 1

def validate_binary(entries):
    manifest_path = 'Binaries/LightTableEDR.manifest.json'
    package = entries.get('Package.swift', b'')
    if manifest_path not in entries:
        if b'.binaryTarget(name: "LightTableEDR"' in package:
            raise ValueError('EDR dependency is missing its binary manifest')
        return
    manifest = json.loads(entries[manifest_path])
    prefix = 'Binaries/LightTableEDR.xcframework/'
    expected = {prefix + p: digest for p, digest in manifest['files'].items()}
    for path, digest in expected.items():
        if path not in entries or hashlib.sha256(entries[path]).hexdigest() != digest:
            raise ValueError(f'EDR binary does not match its reviewed manifest: {path}')
    # Framework symlinks contain relative targets rather than file data in Git.
    for path in entries:
        if path.startswith(prefix) and path not in expected:
            if '/Versions/' not in path and Path(path).name in {'Headers', 'Modules', 'Resources', 'LightTableEDR'}:
                continue
            if path.endswith('/Versions/Current'):
                continue
            raise ValueError(f'Unexpected EDR module file: {path}')

def tree_entries(root):
    root = root.resolve()
    entries = {}
    for directory, dirs, files in os.walk(root, followlinks=False):
        dirs[:] = [d for d in dirs if d not in IGNORED]
        for name in list(dirs) + files:
            path = Path(directory) / name
            if path.is_symlink():
                if not path.resolve().is_relative_to(root):
                    raise ValueError(f'Publication symlink escapes its root: {path.relative_to(root)}')
                entries[str(path.relative_to(root))] = os.readlink(path).encode()
            elif path.is_file() and name != '.DS_Store':
                entries[str(path.relative_to(root))] = path.read_bytes()
    return entries

def git(root, *args):
    return subprocess.check_output(['git', '-C', str(root), *args])

def object_entries(root, records):
    if not records:
        return {}
    output = subprocess.check_output(['git', '-C', str(root), 'cat-file', '--batch'],
                                     input=b''.join(sha + b'\n' for _, sha in records))
    cursor = 0
    entries = {}
    for path, _ in records:
        end = output.index(b'\n', cursor)
        header = output[cursor:end].split()
        if len(header) != 3 or header[1] != b'blob':
            raise ValueError(f'Expected a published file: {path}')
        length = int(header[2]); cursor = end + 1
        entries[path] = output[cursor:cursor + length]; cursor += length + 1
    return entries

def index_entries(root):
    records = []
    for row in git(root, 'ls-files', '--stage', '-z').split(b'\0'):
        if not row:
            continue
        meta, path = row.split(b'\t', 1)
        mode, sha, stage = meta.split()
        if stage != b'0' or mode == b'160000':
            raise ValueError('Unmerged entries or submodules require separate publication review')
        records.append((os.fsdecode(path), sha))
    return object_entries(root, records)

def revision_entries(root, revision):
    records = []
    for row in git(root, 'ls-tree', '-r', '-z', revision).split(b'\0'):
        if row:
            meta, path = row.split(b'\t', 1)
            mode, kind, sha = meta.split()
            if kind != b'blob':
                raise ValueError('Submodule requires separate publication review')
            records.append((os.fsdecode(path), sha))
    return object_entries(root, records)

def scan(boundary, entries):
    for name, data in entries.items():
        boundary.entry(name, data)
    validate_binary(entries)

def check_app(boundary, app):
    entries = tree_entries(app)
    scan(boundary, entries)
    info = plistlib.loads(entries['Contents/Info.plist'])
    version = tuple(int(v) for v in info['CFBundleShortVersionString'].split('.'))
    if version >= (0, 1, 103):
        base = 'Contents/Frameworks/LightTableEDR.framework/'
        for file in ['Versions/A/LightTableEDR', 'Versions/A/Resources/LightTableEDR.metallib',
                     'Versions/A/Resources/EDR-LICENSE.txt']:
            if base + file not in entries:
                raise ValueError(f'Packaged EDR resource missing: {file}')
        manifest = json.loads((ROOT / 'Binaries/LightTableEDR.manifest.json').read_text())
        prefix = 'macos-arm64_x86_64/LightTableEDR.framework/'
        for path, digest in manifest['files'].items():
            if path.startswith(prefix):
                target = base + path[len(prefix):]
                if hashlib.sha256(entries.get(target, b'')).hexdigest() != digest:
                    raise ValueError(f'Packaged EDR differs from reviewed binary: {target}')

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tree', type=Path)
    parser.add_argument('--git-index', type=Path)
    parser.add_argument('--git-range', nargs=2, metavar=('REPOSITORY', 'RANGE'))
    parser.add_argument('--app', type=Path)
    parser.add_argument('--archive', type=Path)
    args = parser.parse_args()
    if not any(vars(args).values()):
        parser.error('Choose --tree, --git-index, --git-range, --app, or --archive')
    boundary = Boundary(json.loads((ROOT / 'Distribution/source-boundary.json').read_text()))
    if args.tree:
        scan(boundary, tree_entries(args.tree))
    if args.git_index:
        scan(boundary, index_entries(args.git_index))
    if args.git_range:
        repo, revisions = args.git_range
        for revision in git(repo, 'rev-list', revisions).decode().splitlines():
            scan(boundary, revision_entries(repo, revision))
    if args.app:
        check_app(boundary, args.app)
    if args.archive:
        with zipfile.ZipFile(args.archive) as archive:
            for entry in archive.infolist():
                if not entry.is_dir():
                    boundary.entry(entry.filename, archive.read(entry))
    print(f'Source boundary passed: {boundary.count} files checked')

if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        print(f'Source boundary FAILED: {error}', file=sys.stderr)
        sys.exit(1)
