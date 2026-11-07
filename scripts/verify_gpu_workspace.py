#!/usr/bin/env python3
"""Dogfood installed Safari/native apps with scoped input and host GPU counters.

One owned app at a time; no physical-screen screenshots or host input. The
existing guarded monitor is borrowed and must survive all app teardown. A local
browser page avoids depending on a remote website. Evidence stays owner-private.
"""
import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import signal
import statistics
import subprocess
import threading
import time

from verify_offline import MCP


class Point(ctypes.Structure):
    _fields_ = [('x', ctypes.c_double), ('y', ctypes.c_double)]


def cursor():
    cg = ctypes.CDLL('/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics')
    cf = ctypes.CDLL('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
    cg.CGEventCreate.argtypes = [ctypes.c_void_p]
    cg.CGEventCreate.restype = ctypes.c_void_p
    cg.CGEventGetLocation.argtypes = [ctypes.c_void_p]
    cg.CGEventGetLocation.restype = Point
    cf.CFRelease.argtypes = [ctypes.c_void_p]
    event = cg.CGEventCreate(None)
    if not event:
        raise RuntimeError('Cannot read physical pointer location')
    try:
        point = cg.CGEventGetLocation(event)
        return dict(x=point.x, y=point.y)
    finally:
        cf.CFRelease(event)


def processes():
    rows = []
    for line in subprocess.check_output(['ps', '-axo', 'pid,ppid,pcpu,rss,comm'], text=True).splitlines()[1:]:
        fields = line.split(None, 4)
        if len(fields) == 5:
            pid, parent, cpu, rss, command = fields
            rows.append(dict(pid=int(pid), parent=int(parent), cpu=float(cpu), rss_kib=int(rss), command=command))
    return rows


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False


def window_inventory(owner):
    cg = ctypes.CDLL('/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics')
    cf = ctypes.CDLL('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
    cg.CGWindowListCopyWindowInfo.argtypes = [ctypes.c_uint32, ctypes.c_uint32]
    cg.CGWindowListCopyWindowInfo.restype = ctypes.c_void_p
    cf.CFPropertyListCreateData.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_long,
                                          ctypes.c_ulong, ctypes.c_void_p]
    cf.CFPropertyListCreateData.restype = ctypes.c_void_p
    cf.CFDataGetLength.argtypes = [ctypes.c_void_p]
    cf.CFDataGetLength.restype = ctypes.c_long
    cf.CFDataGetBytePtr.argtypes = [ctypes.c_void_p]
    cf.CFDataGetBytePtr.restype = ctypes.c_void_p
    cf.CFRelease.argtypes = [ctypes.c_void_p]
    windows = cg.CGWindowListCopyWindowInfo(16, 0)  # exclude desktop, include hidden
    data = cf.CFPropertyListCreateData(None, windows, 100, 0, None)
    try:
        if not data:
            raise RuntimeError('Cannot serialize window inventory')
        rows = plistlib.loads(ctypes.string_at(cf.CFDataGetBytePtr(data), cf.CFDataGetLength(data)))
        return [r for r in rows if r.get('kCGWindowOwnerName') == owner]
    finally:
        if data:
            cf.CFRelease(data)
        cf.CFRelease(windows)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--apps', nargs='+', choices=['Safari', 'Calculator', 'TextEdit'],
                        default=['Safari', 'Calculator', 'TextEdit'])
    args = parser.parse_args()
    os.umask(0o077)
    args.out.mkdir(parents=True, exist_ok=False, mode=0o700)
    binary = Path.home() / '.local/bin/isolated-mcp'
    monitor = Path.home() / '.isolated-tester/workspace/monitor.json'
    result = dict(status='FAIL', binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),
                  apps=[], input_checks=[], samples=[], errors=[])
    client = session = None
    stop = threading.Event()
    phase = 'baseline'
    sampler = None

    def sample():
        while not stop.is_set():
            try:
                raw = subprocess.check_output(['/usr/sbin/ioreg', '-r', '-c', 'AGXAccelerator', '-l'], text=True)
                device = re.search(r'"Device Utilization %"\s*=\s*(\d+)', raw)
                renderer = re.search(r'"Renderer Utilization %"\s*=\s*(\d+)', raw)
                if not device:
                    raise RuntimeError('GPU utilization counter unavailable')
                rows = processes()
                relevant = [p for p in rows if any(t in p['command'] for t in
                            ('isolated-mcp', 'WindowServer', '/Safari.app/', '/Calculator.app/', '/TextEdit.app/'))]
                windows = subprocess.run([str(Path.home() / 'tinky-vision-mcp/bin/tinky-os'),
                    'find-window', '--query', phase.split('-')[0]], capture_output=True, text=True, timeout=3)
                result['samples'].append(dict(at=time.monotonic(), phase=phase, gpu=int(device[1]),
                    renderer=int(renderer[1]) if renderer else None, processes=relevant,
                    windows=json.loads(windows.stdout) if windows.returncode == 0 else windows.stderr,
                    all_app_windows=window_inventory(phase.split('-')[0]),
                    monitor=json.loads(monitor.read_text()), state_mtime_ns=monitor.stat().st_mtime_ns))
            except Exception as error:
                result['errors'].append('sampler: ' + str(error))
            stop.wait(1)

    def focus():
        return client.tool('os_focused_window').get('focused')

    def scoped(name, **arguments):
        before, pointer = focus(), cursor()
        response = client.tool(name, sessionId=session['sessionId'], **arguments)
        after, pointer_after = focus(), cursor()
        row = dict(action=name, app_pid=session['appPID'], before=before, after=after,
                   pointer_before=pointer, pointer_after=pointer_after)
        result['input_checks'].append(row)
        if any(f and f.get('pid') == session['appPID'] for f in (before, after)):
            raise RuntimeError('Test app acquired host foreground focus')
        if not any(d['x'] <= pointer_after['x'] < d['x'] + d['width'] and
                   d['y'] <= pointer_after['y'] < d['y'] + d['height']
                   for d in result['displays_before'] if d['displayID'] != session['displayID']):
            raise RuntimeError('Physical pointer left the host displays')
        return response

    def observe(text):
        last = None
        for _ in range(8):
            last = client.tool('observe_session', sessionId=session['sessionId'])
            if any(text.lower() in m['text'].lower() for m in last['vision']['matches']):
                return last
            time.sleep(1)
        raise RuntimeError('Isolated OCR did not observe: ' + text)

    def rest(seconds):
        for _ in range(seconds):
            time.sleep(1)
            recent = result['samples'][-5:]
            if len(recent) == 5 and all(s['gpu'] >= 90 for s in recent):
                raise RuntimeError('GPU stayed at or above 90%; stopping owned test')

    def close_app():
        nonlocal session
        if session is None:
            return
        client.tool('stop_session', sessionId=session['sessionId'])
        for _ in range(50):
            if not alive(session['appPID']):
                session = None
                return
            time.sleep(0.1)
        raise RuntimeError('Owned app survived session teardown')

    try:
        for p in processes():
            if any(t in p['command'] for t in ('qemu-system-', '/vmhost', '/Safari.app/', '/Calculator.app/', '/TextEdit.app/')):
                raise RuntimeError('Existing guest/test app; refusing duplicate or borrowed process: ' + p['command'])
        client = MCP(['/opt/homebrew/bin/node', str(Path.home() / 'tinky-vision-mcp/src/isolated-system.mjs')], args.out, 'dogfood')
        result['setup'] = client.tool('setup_status')
        if client.tool('list_sessions'):
            raise RuntimeError('Existing test session')
        result['displays_before'] = client.tool('list_displays')
        result['host_focus_before'] = focus()
        result['workspace_before'] = json.loads(monitor.read_text())
        result['launchd_before'] = subprocess.check_output(['/bin/launchctl', 'print', f'gui/{os.getuid()}/com.isolatedtester.workspace'], text=True)
        sampler = threading.Thread(target=sample, daemon=True)
        sampler.start()
        print('Measuring idle baseline', flush=True)
        rest(8)

        page = args.out / 'browser-check.html'
        page.write_text('''<!doctype html><meta charset="utf-8"><title>Isolated Browser Check</title>
<style>body{font:28px system-ui;padding:40px;background:#eef3fa;color:#122a44}input,button{font:26px system-ui;padding:16px;margin:16px 0}button{display:block}</style>
<h1>Isolated Browser Check</h1><p>Keyboard and mouse remain inside this workspace.</p>
<input autofocus aria-label="Isolated keyboard input" placeholder="Type here">
<button onclick="document.querySelector('#count').textContent='Count: '+(++window.n)">Increment</button>
<p id="count">Count: 0</p><script>window.n=0;</script>''')
        app_paths = [('Safari', '/Applications/Safari.app'), ('Calculator', '/System/Applications/Calculator.app'),
                     ('TextEdit', '/System/Applications/TextEdit.app')]
        for name, path in app_paths:
            if name not in args.apps:
                continue
            phase = name + '-opening'
            print('Opening isolated ' + name, flush=True)
            session = client.tool('create_session', appPath=path,
                objective='Dogfood GPU load, session-scoped keyboard/mouse, host focus and persistent display.')
            app_result = dict(name=name, session=session)
            result['apps'].append(app_result)
            if not session['windowsPlaced'] or session['displayID'] != result['workspace_before']['displayID']:
                raise RuntimeError('App did not borrow the existing isolated display')
            if name == 'Safari':
                scoped('os_key', cmd=True, key='l')
                scoped('os_type', text=page.as_uri())
                scoped('os_key', key='return')
                observe('Isolated Browser Check')
                scoped('os_type', text='isolated-input-42')
                app_result['keyboard'] = observe('isolated-input-42')
                button = next(m for m in app_result['keyboard']['vision']['matches'] if m['text'].strip() == 'Increment')
                scoped('os_click', x=button['image_px']['cx'], y=button['image_px']['cy'])
                app_result['mouse'] = observe('Count: 1')
            elif name == 'Calculator':
                scoped('os_key', key='escape')
                scoped('os_type', text='27+15=')
                app_result['keyboard'] = observe('42')
                elements = client.tool('get_interactive_elements', sessionId=session['sessionId'])['interactiveElements']
                clear = next(e for e in elements if e.get('role') == 'AXButton' and e.get('label') == 'All Clear')['frame']
                scoped('click_element', x=clear['x'] + clear['width']/2, y=clear['y'] + clear['height']/2)
                cleared = client.tool('observe_session', sessionId=session['sessionId'])
                seven = next(m for m in cleared['vision']['matches'] if m['text'] == '7' and
                             m['image_px']['cy'] > cleared['frame']['height']/3)
                scoped('os_click', x=seven['image_px']['cx'], y=seven['image_px']['cy'])
                scoped('os_type', text='+8=')
                app_result['mouse'] = observe('15')
            else:
                scoped('os_key', key='escape')
                scoped('os_key', cmd=True, key='n')
                scoped('os_type', text='Isolated TextEdit keyboard check 20261107')
                app_result['keyboard'] = observe('Isolated TextEdit keyboard check')
            phase = name + '-idle'
            rest(15)
            app_result['history'] = client.tool('frame_history', sessionId=session['sessionId'], limit=300)
            sid = session['sessionId']
            close_app()
            app_result['owned_app_exited'] = True
            receipts = Path.home() / '.isolated-tester/sessions' / sid / 'receipts.jsonl'
            frames = [json.loads(line)['atUptime'] for line in receipts.read_text().splitlines()
                      if json.loads(line)['kind'] == 'frame']
            gaps = [b-a for a, b in zip(frames, frames[1:])]
            app_result['recording'] = dict(frames=len(frames), minimum_gap=min(gaps) if gaps else None,
                                            mean_gap=statistics.mean(gaps) if gaps else None)
            if not gaps or min(gaps) < 1:
                raise RuntimeError('Continuous recording exceeded 1 FPS or had insufficient frames')
            phase = name + '-stopped'
            rest(4)
        phase = 'final-idle'
        rest(8)
        result['displays_after'] = client.tool('list_displays')
        result['host_focus_after'] = focus()
        result['sessions_after'] = client.tool('list_sessions')
        result['launchd_after'] = subprocess.check_output(['/bin/launchctl', 'print', f'gui/{os.getuid()}/com.isolatedtester.workspace'], text=True)
        if result['displays_before'] != result['displays_after'] or result['sessions_after']:
            raise RuntimeError('Display arrangement changed or test session survived')
        if any(s['monitor'] != result['workspace_before'] for s in result['samples']):
            raise RuntimeError('Workspace owner/display/guard changed during app tests')
        if len({s['state_mtime_ns'] for s in result['samples']}) != 1:
            raise RuntimeError('Unchanged workspace state was repeatedly rewritten')
        if result['errors']:
            raise RuntimeError('Sampler errors recorded')
        result['status'] = 'PASS'
    except BaseException as error:
        result['errors'].append(type(error).__name__ + ': ' + str(error))
    finally:
        if client:
            try:
                try:
                    close_app()
                finally:
                    client.close()
            except BaseException as error:
                result['errors'].append('cleanup: ' + str(error))
                result['status'] = 'FAIL'
        stop.set()
        if sampler:
            sampler.join(timeout=5)
        summaries = {}
        for label in sorted({s['phase'] for s in result['samples']}):
            values = [s['gpu'] for s in result['samples'] if s['phase'] == label]
            summaries[label] = dict(samples=len(values), median=statistics.median(values), maximum=max(values))
        result['gpu_summary'] = summaries
        (args.out / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
        print(json.dumps(dict(status=result['status'], errors=result['errors'], gpu=summaries,
                              evidence=str(args.out / 'result.json'))), flush=True)
    return 0 if result['status'] == 'PASS' else 1


if __name__ == '__main__':
    def interrupt(_number, _frame):
        raise KeyboardInterrupt('Interrupted; cleaning up owned app')
    signal.signal(signal.SIGTERM, interrupt)
    raise SystemExit(main())
