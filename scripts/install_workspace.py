#!/usr/bin/env python3
"""Install the persistent local AI monitor and a user-opened, view-only icon.

Does not reconfigure MCP clients or start any test application.
"""
import argparse
from datetime import datetime, timezone
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile


def run(*args):
    return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT)


def atomic_copy(source, target):
    target.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix='.workspace-install-', dir=target.parent)
    os.close(descriptor)
    try:
        shutil.copy2(source, temporary)
        os.replace(temporary, target)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def main():
    repo = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build-dir', type=Path, default=repo / '.build/release')
    args = parser.parse_args()
    home = Path.home()
    label = 'com.isolatedtester.workspace'
    agent = home / 'Library/LaunchAgents' / (label + '.plist')
    workspace = home / '.isolated-tester/workspace'
    binaries = ['isolated', 'isolated-mcp', 'isolated-http']
    binary_dir = home / '.local/bin'
    viewer = home / 'Applications/AI Workspace.app'
    desktop = home / 'Desktop/AI Workspace.app'
    for binary in binaries:
        if not (args.build_dir / binary).is_file():
            raise RuntimeError('Build release binaries first: ' + binary)
    if agent.exists():
        existing = plistlib.loads(agent.read_bytes())
        if existing.get('ProgramArguments') != [str(binary_dir / 'isolated-mcp'), '--workspace-host']:
            raise RuntimeError('Existing workspace LaunchAgent differs; refusing to overwrite')
    if viewer.exists() and not (viewer / 'Contents/Info.plist').is_file():
        raise RuntimeError('Unexpected existing AI Workspace app; refusing overwrite')
    if desktop.exists() and (not desktop.is_symlink() or desktop.resolve() != viewer):
        raise RuntimeError('Existing Desktop item differs; refusing overwrite')
    identities = run('/usr/bin/security', 'find-identity', '-v', '-p', 'codesigning')
    identity = next((line.split('"')[1] for line in identities.splitlines()
                     if 'Developer ID Application:' in line), None)
    if not identity:
        raise RuntimeError('Stable Developer ID signing identity unavailable; preserving installed TCC grants')

    stamp = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    backup = home / '.isolated-tester/repair-evidence' / stamp / 'installed-before'
    backup.mkdir(parents=True, mode=0o700)
    for binary in binaries:
        installed = binary_dir / binary
        if installed.exists():
            shutil.copy2(installed, backup / binary)
    if agent.exists():
        shutil.copy2(agent, backup / agent.name)

    # Sign staged binaries before touching any installed executable. Atomic
    # replacement preserves the inode in existing MCP connections.
    with tempfile.TemporaryDirectory(prefix='isolated-workspace-install-') as temporary:
        stage = Path(temporary)
        for binary in binaries:
            shutil.copy2(args.build_dir / binary, stage / binary)
            run('/usr/bin/codesign', '--force', '--sign', identity, str(stage / binary))
            run('/usr/bin/codesign', '--verify', '--strict', str(stage / binary))
        app = stage / 'AI Workspace.app'
        executable = app / 'Contents/MacOS/isolated-mcp'
        executable.parent.mkdir(parents=True)
        shutil.copy2(stage / 'isolated-mcp', executable)
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': 'com.isolatedtester.workspace-viewer',
            'CFBundleName': 'AI Workspace', 'CFBundleDisplayName': 'AI Workspace',
            'CFBundleExecutable': 'isolated-mcp', 'CFBundlePackageType': 'APPL',
            'CFBundleShortVersionString': '1.2.1', 'CFBundleVersion': '1',
            'NSHighResolutionCapable': True, 'LSMinimumSystemVersion': '14.0',
            'NSScreenCaptureUsageDescription': 'View the dedicated AI virtual monitor when you open this app.',
        }))
        run('/usr/bin/codesign', '--force', '--sign', identity, str(app))
        run('/usr/bin/codesign', '--verify', '--strict', str(app))
        for binary in binaries:
            atomic_copy(stage / binary, binary_dir / binary)
            atomic_copy(stage / binary, repo / 'bin' / binary)
        if viewer.exists():
            viewer.rename(backup / 'AI Workspace.app')
        viewer.parent.mkdir(parents=True, exist_ok=True)
        shutil.copytree(app, viewer)

    workspace.mkdir(parents=True, exist_ok=True, mode=0o700)
    agent.parent.mkdir(parents=True, exist_ok=True)
    config = {
        'Label': label,
        'ProgramArguments': [str(binary_dir / 'isolated-mcp'), '--workspace-host'],
        'RunAtLoad': True, 'KeepAlive': True, 'ThrottleInterval': 10,
        'LimitLoadToSessionType': 'Aqua',
        'ProcessType': 'Interactive',
        'StandardOutPath': str(workspace / 'host-stdout.log'),
        'StandardErrorPath': str(workspace / 'host-stderr.log'),
    }
    agent.write_bytes(plistlib.dumps(config))
    os.chmod(agent, 0o600)
    if not desktop.is_symlink():
        desktop.symlink_to(viewer)
    domain = 'gui/' + str(os.getuid())
    job = domain + '/' + label
    loaded = subprocess.run(['/bin/launchctl', 'print', job], capture_output=True).returncode == 0
    if loaded:
        run('/bin/launchctl', 'bootout', job)
    run('/bin/launchctl', 'enable', job)
    run('/bin/launchctl', 'bootstrap', domain, str(agent))
    print('Installed persistent monitor: ' + str(agent))
    print('View-only desktop icon: ' + str(desktop))
    print('Prior signed binaries preserved: ' + str(backup))
    print('Existing MCP connections keep old loaded code until reconnected.')


if __name__ == '__main__':
    main()
