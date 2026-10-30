#!/usr/bin/env python3
"""Fetch the pinned upstream executables used when packaging Music Drop."""
import argparse
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
import time
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
HELPERS = ROOT / 'Resources' / 'Helpers'
MANIFEST = HELPERS / 'dependencies.json'
MAX_DOWNLOAD = 200_000_000


def digest(path):
    result = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            result.update(chunk)
    return result.hexdigest()


def valid(path, expected):
    return path.is_file() and digest(path) == expected


def download(item, destination):
    last_error = None
    for attempt in range(3):
        partial = destination.with_suffix('.partial')
        try:
            request = urllib.request.Request(item['url'], headers={'User-Agent': 'MusicDrop-dependency-setup/1'})
            size = 0
            with urllib.request.urlopen(request, timeout=30) as response, partial.open('wb') as output:
                for chunk in iter(lambda: response.read(1024 * 1024), b''):
                    size += len(chunk)
                    if size > MAX_DOWNLOAD:
                        raise RuntimeError('Dependency exceeds the download size limit')
                    output.write(chunk)
            if not valid(partial, item['sha256']):
                raise RuntimeError('Upstream download SHA-256 mismatch: ' + item['name'])
            os.replace(partial, destination)
            return
        except Exception as error:
            last_error = error
            partial.unlink(missing_ok=True)
            if attempt < 2:
                time.sleep(attempt + 1)
    raise RuntimeError('Cannot download ' + item['name'] + ': ' + str(last_error))


def install(item, cache):
    target = HELPERS / item['name']
    if valid(target, item['executableSHA256']):
        target.chmod(0o755)
        return item['name'] + ': verified'
    cached = cache / (item['sha256'] + '.download')
    if not valid(cached, item['sha256']):
        download(item, cached)
    # Extract only the explicitly pinned member; archive paths never become destinations.
    with tempfile.TemporaryDirectory(prefix='.download-', dir=HELPERS) as work:
        staged = Path(work) / item['name']
        if 'archiveMember' in item:
            with zipfile.ZipFile(cached) as archive:
                info = archive.getinfo(item['archiveMember'])
                if info.file_size > MAX_DOWNLOAD:
                    raise RuntimeError('Archive member exceeds the size limit')
                with archive.open(info) as source, staged.open('wb') as output:
                    shutil.copyfileobj(source, output)
        else:
            shutil.copyfile(cached, staged)
        if not valid(staged, item['executableSHA256']):
            raise RuntimeError('Executable SHA-256 mismatch: ' + item['name'])
        staged.chmod(0o755)
        os.replace(staged, target)
    return item['name'] + ': installed and verified'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true', help='Check local executables without downloading')
    parser.add_argument('--cache-dir', type=Path, default=Path.home() / 'Library/Caches/MusicDropDependencies')
    args = parser.parse_args()
    manifest = json.loads(MANIFEST.read_text())
    if manifest.get('version') != 1:
        raise RuntimeError('Unsupported dependency manifest')
    items = manifest['binaries']
    for item in items:
        if Path(item['name']).name != item['name'] or item['name'] not in {'yt-dlp', 'deno-arm64', 'deno-x86_64'}:
            raise RuntimeError('Invalid dependency name')
        if not item['url'].startswith('https://github.com/'):
            raise RuntimeError('Dependencies must come from their pinned GitHub releases')
    if args.check:
        missing = [item['name'] for item in items if not valid(HELPERS / item['name'], item['executableSHA256'])
                   or not os.access(HELPERS / item['name'], os.X_OK)]
        if missing:
            print('Missing or invalid: ' + ', '.join(missing), file=sys.stderr)
            return 1
        print('All pinned dependencies verified')
        return 0
    HELPERS.mkdir(parents=True, exist_ok=True)
    args.cache_dir.mkdir(parents=True, exist_ok=True)
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
        for result in pool.map(lambda item: install(item, args.cache_dir), items):
            print(result)
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except Exception as error:
        print('Dependency setup failed: ' + str(error), file=sys.stderr)
        sys.exit(1)
