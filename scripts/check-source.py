#!/usr/bin/env python3
"""Check frozen dependency bytes and keep private/runtime artifacts out of source."""
from pathlib import Path
import hashlib
import json
import re
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
snapshot = json.loads((root / 'vendor/FluidAudio.snapshot.json').read_text())
errors = []
for relative, expected in snapshot['files'].items():
    path = root / 'vendor/FluidAudio' / relative
    if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != expected:
        errors.append('Frozen dependency missing or changed: ' + relative)
expected_paths = set(snapshot['files'])
actual_paths = {str(p.relative_to(root / 'vendor/FluidAudio')) for p in (root / 'vendor/FluidAudio').rglob('*') if p.is_file()}
for extra in sorted(actual_paths - expected_paths):
    errors.append('Unexpected dependency file: ' + extra)

tracked = subprocess.run(['git', 'ls-files', '-z'], cwd=root, check=True, capture_output=True).stdout.decode().split('\0')
if '--tracked' in sys.argv and not any(tracked):
    errors.append('No tracked source files; stage the reviewed source before a publication check.')
paths = [root / p for p in tracked if p] if '--tracked' in sys.argv else [
    p for p in root.rglob('*') if p.is_file() and not any(part in {'.git', '.build', '.swiftpm', 'dist', 'work'} for part in p.relative_to(root).parts)
]
for path in paths:
    relative = path.relative_to(root)
    parts = relative.parts
    suffix = path.suffix.lower()
    if any(p in {'.build', '.swiftpm', 'dist', 'work', '__pycache__'} or p.endswith(('.app', '.mlmodelc', '.mlpackage')) for p in parts) or suffix in {'.wav', '.caf', '.m4a', '.mp3', '.aiff', '.aif', '.flac', '.aac', '.safetensors', '.p12', '.pem', '.key', '.log', '.dmg', '.zip', '.pyc'}:
        errors.append('Private/runtime artifact in source: ' + str(relative))
    if path.name.startswith('.env'):
        errors.append('Environment/credential file in source: ' + str(relative))
    if path.name.endswith(('.transcript.json', '.localaudio.json', '.voices.json')) or path.name in {'jobs.json', 'settings.json', 'model-selection.json', 'voice-library.json'}:
        errors.append('Private app state in source: ' + str(relative))
    if suffix in {'.bin', '.mil', '.mlmodel', '.onnx'} and parts[0] != 'vendor':
        errors.append('Model asset in source: ' + str(relative))
    if path.stat().st_size > 10_000_000:
        errors.append('Unexpected large source file: ' + str(relative))
    try:
        text = path.read_text()
    except (UnicodeError, OSError):
        continue
    patterns = [r'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----', r'github_pat_[A-Za-z0-9_]{35,}', r'gh[pousr]_[A-Za-z0-9]{30,}']
    if any(re.search(pattern, text) for pattern in patterns):
        errors.append('Possible credential in: ' + str(relative))
if errors:
    print('\n'.join(errors), file=sys.stderr)
    sys.exit(1)
print(f'Source check passed: {len(paths)} files; {len(expected_paths)} frozen dependency hashes match.')
