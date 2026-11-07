#!/usr/bin/env python3
"""Verify the installed persistent workspace through its combined MCP.

One disposable Calculator is stopped in finally. The user-owned monitor stays on.
No host input, physical-desktop capture, browser, or cloud model is used.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time

from verify_offline import MCP


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', required=True, type=Path)
    args = parser.parse_args()
    os.umask(0o077)
    args.out.mkdir(parents=True, exist_ok=False, mode=0o700)
    binary = Path.home() / '.local/bin/isolated-mcp'
    result = {'status': 'FAIL', 'binary': str(binary),
              'binary_sha256': hashlib.sha256(binary.read_bytes()).hexdigest()}
    client = other = None
    session = None
    try:
        processes = subprocess.check_output(['ps', '-axo', 'pid,comm'], text=True)
        if any(token in processes for token in ('/Calculator.app/', 'qemu-system-', '/vmhost')):
            raise RuntimeError('Existing Calculator or guest; refusing duplicate or borrowed app')
        command = ['/opt/homebrew/bin/node', str(Path.home() / 'tinky-vision-mcp/src/isolated-system.mjs')]
        client = MCP(command, args.out, 'unified')
        setup = client.tool('setup_status')
        result['setup'] = setup
        # Exercise the exact regression safely: these must fail before a host
        # helper is called, including the old target/description form.
        for name in ('os_click', 'os_type', 'os_key'):
            response = client.request('tools/call', {'name': name, 'arguments': {
                'target': 'Calculator', 'description': 'must refuse unscoped input',
                'x': 1, 'y': 1, 'text': 'must not type', 'key': 'w'}})
            if not response.get('isError') or 'sessionId' not in str(response):
                raise RuntimeError('Unscoped input was not refused: ' + name)
        result['host_input_refused'] = True
        workspace = setup.get('workspace', {})
        if not workspace.get('pointerGuard'):
            raise RuntimeError('Persistent workspace and physical-pointer guard are not ready')
        displays = client.tool('list_displays')
        result['displays_before'] = displays
        own = next(d for d in displays if d['displayID'] == workspace['displayID'])
        others = [d for d in displays if d != own]
        if own['isMain'] or own['x'] + own['width'] > min(d['x'] for d in others):
            raise RuntimeError('AI monitor is not left of the unchanged host arrangement')
        result['focus_before'] = client.tool('os_focused_window')
        session = client.tool('create_session', appPath='/System/Applications/Calculator.app',
                              objective='Verify persistent AI monitor, isolated typing/clicking and teardown without host input.')
        result['session'] = session
        sid = session['sessionId']
        if session['displayID'] != own['displayID'] or not session['windowsPlaced']:
            raise RuntimeError('Session did not borrow the existing workspace')
        # A second connection must fail before launching any app or monitor.
        other = MCP(command, args.out, 'second-connection')
        duplicate = other.request('tools/call', {'name': 'create_session', 'arguments': {
            'appPath': '/System/Applications/Calculator.app'}})
        if not duplicate.get('isError') or 'active test-session' not in str(duplicate):
            raise RuntimeError('Cross-connection session lease did not refuse a duplicate')
        result['duplicate_refused'] = True
        other.close(); other = None
        client.tool('os_key', sessionId=sid, key='escape')
        client.tool('os_type', sessionId=sid, text='27+15=')
        observed = None
        for _ in range(8):
            observed = client.tool('observe_session', sessionId=sid)
            if any(m['text'] == '42' for m in observed['vision']['matches']):
                break
            time.sleep(0.5)
        else:
            raise RuntimeError('Isolated keyboard did not produce observed result 42')
        result['typed_result'] = observed
        buttons = client.tool('get_interactive_elements', sessionId=sid)['interactiveElements']
        clear = next(e for e in buttons if e.get('label') == 'All Clear' and e.get('role') == 'AXButton')['frame']
        if not client.tool('click_element', sessionId=sid, x=clear['x'] + clear['width']/2,
                           y=clear['y'] + clear['height']/2)['success']:
            raise RuntimeError('Session accessibility clear did not work')
        cleared = client.tool('observe_session', sessionId=sid)
        seven = next(m['image_px'] for m in cleared['vision']['matches'] if m['text'] == '7')
        client.tool('os_click', sessionId=sid, x=seven['cx'], y=seven['cy'])
        client.tool('os_type', sessionId=sid, text='+8=')
        pointer = client.tool('observe_session', sessionId=sid)
        result['clicked_result'] = pointer
        if not any(m['text'] == '15' and m['image_px']['cy'] < seven['cy'] for m in pointer['vision']['matches']):
            raise RuntimeError('Isolated screenshot click did not produce observed result 15')
        result['focus_after'] = client.tool('os_focused_window')
        result['seal'] = client.tool('seal_session', sessionId=sid)
        if not result['seal']['chainIntact']:
            raise RuntimeError('Session evidence chain is broken')
        client.tool('stop_session', sessionId=sid)
        try:
            os.kill(session['appPID'], 0)
        except ProcessLookupError:
            result['owned_app_exited'] = True
        else:
            raise RuntimeError('Owned Calculator remained after stop')
        session = None
        if client.tool('list_sessions'):
            raise RuntimeError('Owned test session remained after stop')
        after = client.tool('list_displays')
        result['displays_after_stop'] = after
        if after != displays:
            raise RuntimeError('Stopping a test removed or moved a monitor')
        client.close(); client = None
        # Inspect through a new process after every diagnostic MCP disconnected.
        client = MCP(command, args.out, 'after-disconnect')
        result['after_disconnect'] = client.tool('setup_status')
        if result['after_disconnect']['workspace']['displayID'] != own['displayID']:
            raise RuntimeError('Monitor did not survive MCP disconnect')
        result['status'] = 'PASS'
    except Exception as error:
        result['error'] = str(error)
    finally:
        if session and client:
            try:
                client.tool('stop_session', sessionId=session['sessionId'])
            except Exception as error:
                result.update(status='FAIL', cleanup_error=str(error))
        for connection in (other, client):
            if connection:
                try:
                    connection.close()
                except Exception as error:
                    result.update(status='FAIL', cleanup_error=str(error))
        (args.out / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
        print(json.dumps({'status': result['status'], 'error': result.get('error'),
                          'evidence': str(args.out / 'result.json')}))
    return 0 if result['status'] == 'PASS' else 1


if __name__ == '__main__':
    raise SystemExit(main())
