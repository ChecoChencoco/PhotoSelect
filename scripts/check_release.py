#!/usr/bin/env python3
"""Check Git-visible files before publication; never upload anything."""
import re
import subprocess
from pathlib import Path

base = Path(__file__).resolve().parents[1]
result = subprocess.run(['git', 'ls-files', '-z', '--cached', '--others', '--exclude-standard'],
                        cwd=base, check=True, capture_output=True)
paths = sorted(set(p for p in result.stdout.decode().split('\0') if p))
issues = []
patterns = [r'/Users/' + r'[^\s"\'/]+/',
            r'-----BEGIN ' + r'(?:RSA |EC |OPENSSH )?PRIVATE KEY-----',
            r'gh[pousr]_' + r'[A-Za-z0-9]{30,}',
            r'github_pat_' + r'[A-Za-z0-9_]{30,}',
            r'AKIA' + r'[A-Z0-9]{16}']
allowed = {'.swift', '.py', '.md', '.yml', '.yaml', '.json', '.txt'}
for name in paths:
    path = base / name
    if path.is_symlink():
        issues.append(f'{name}: symlink requires manual review')
        continue
    if not path.is_file():
        issues.append(f'{name}: missing or not a regular file')
        continue
    if path.stat().st_size > 1_000_000:
        issues.append(f'{name}: unexpectedly large')
        continue
    if path.suffix not in allowed and path.name not in {
            '.gitignore', '.gitattributes', '.editorconfig', 'LICENSE', 'NOTICE'}:
        issues.append(f'{name}: unexpected file type')
    try:
        text = path.read_text()
    except UnicodeError:
        issues.append(f'{name}: binary data')
        continue
    for pattern in patterns:
        if re.search(pattern, text):
            issues.append(f'{name}: private-path or credential pattern; inspect locally')
            break
if issues:
    print('\n'.join(issues))
    raise SystemExit(1)
print(f'PASS: {len(paths)} Git-visible files checked. No matched private paths or credential patterns.')
if not (base / 'LICENSE').is_file():
    print('PENDING: owner must select and approve a license before open-source publication.')
print('This bounded scan does not replace manual review or Git history review.')
