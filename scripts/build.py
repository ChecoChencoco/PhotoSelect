#!/usr/bin/env python3
"""Build PhotoSelect locally. Destructive-operation checks are opt-in."""
import argparse
import json
import os
from pathlib import Path
import platform
import plistlib
import shutil
import subprocess
import sys
import time

BASE = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--configuration', choices=['debug', 'release'], default='release')
    parser.add_argument('--work', type=Path, default=BASE / '.build')
    parser.add_argument('--checks', action='store_true',
                        help='Run isolated synthetic file-operation checks (uses macOS Trash).')
    args = parser.parse_args()
    if sys.platform != 'darwin' or platform.machine() != 'arm64':
        parser.error('Requires macOS 15+ on Apple Silicon (arm64).')
    if int(platform.mac_ver()[0].split('.')[0]) < 15:
        parser.error('Requires macOS 15 or later.')
    for command in ['swift', 'xcrun', 'codesign']:
        if not shutil.which(command):
            parser.error(f'Missing {command}; install/select Xcode Command Line Tools first.')
    work = args.work.resolve()
    work.mkdir(parents=True, exist_ok=True)
    logs = work / 'logs'
    logs.mkdir(exist_ok=True)
    history = []
    log_path = logs / f'build-{time.time_ns()}.json'
    env = dict(os.environ, CLANG_MODULE_CACHE_PATH=str(work / 'modules'),
               SWIFTPM_MODULECACHE_OVERRIDE=str(work / 'modules'))

    def run(label, command):
        start = time.monotonic()
        result = subprocess.run(command, cwd=BASE, env=env, capture_output=True, text=True)
        history.append(dict(label=label, command=command, exit_code=result.returncode,
                            seconds=time.monotonic() - start,
                            stdout=result.stdout, stderr=result.stderr))
        log_path.write_text(json.dumps(history, indent=2, ensure_ascii=False))
        print(f'{label}: {result.returncode}', flush=True)
        if result.returncode:
            print(result.stdout[-8000:] + result.stderr[-8000:], file=sys.stderr)
            raise SystemExit(1)
        return result.stdout

    flags = ['--package-path', str(BASE / 'App'), '--scratch-path', str(work / 'products'),
             '--cache-path', str(work / 'cache'), '--config-path', str(work / 'config'),
             '--security-path', str(work / 'security'), '--arch', 'arm64',
             '-c', args.configuration, '-j', '2']
    run('build', ['swift', 'build', *flags])
    binary_dir = Path(run('binary_path', ['swift', 'build', *flags, '--show-bin-path']).strip())
    if args.checks:
        print('Running generated UUID-isolated checks; copy undo uses macOS Trash.', flush=True)
        run('core_checks', [str(binary_dir / 'PhotoSelectChecks')])
    app = BASE / 'Build' / ('PhotoSelect.app' if args.configuration == 'release'
                          else 'Debug/PhotoSelect.app')
    executable = app / 'Contents/MacOS/PhotoSelect'
    executable.parent.mkdir(parents=True, exist_ok=True)
    (app / 'Contents/Resources').mkdir(exist_ok=True)
    temporary = executable.with_suffix('.new')
    shutil.copy2(binary_dir / 'PhotoSelect', temporary)
    os.replace(temporary, executable)
    info = dict(CFBundleExecutable='PhotoSelect', CFBundleIdentifier='local.photoselect.phase1',
                CFBundleName='PhotoSelect', CFBundleDisplayName='PhotoSelect',
                CFBundlePackageType='APPL', CFBundleShortVersionString='0.2.2', CFBundleVersion='4',
                LSMinimumSystemVersion='15.0', LSArchitecturePriority=['arm64'],
                NSHighResolutionCapable=True, NSPrincipalClass='NSApplication')
    (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
    run('sign', ['codesign', '--force', '--sign', '-', '--timestamp=none', str(app)])
    run('verify', ['codesign', '--verify', '--deep', '--strict', str(app)])
    print(f'App: {app}\nLocal log (may contain private paths): {log_path}')


if __name__ == '__main__':
    main()
