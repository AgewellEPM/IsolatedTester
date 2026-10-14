#!/usr/bin/env python3
"""Exercise installed MCP capture/control/OCR/video with no network in the servers.

Uses one disposable Calculator session, never a browser or an API test provider.
The caller must first check other MCP connections for existing sessions/guests.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import selectors
import signal
import subprocess
import time


class MCP:
    def __init__(self, command, output, label, block_network=True):
        self.log = (output / (label + '-stderr.log')).open('wb')
        self.events = (output / (label + '-rpc.jsonl')).open('w')
        prefix = (
            # macOS capture uses local IPC. Block IP traffic while retaining
            # Unix-domain/Mach connections to WindowServer and capture services.
            ['/usr/bin/sandbox-exec', '-p', '(version 1)(allow default)(deny network* (remote ip "*:*"))']
            if block_network else [])
        self.proc = subprocess.Popen([*prefix, *command],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.log)
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.proc.stdout, selectors.EVENT_READ)
        self.buffer = b''
        self.seq = 0
        try:
            self.request('initialize', {'protocolVersion': '2024-11-05', 'capabilities': {},
                         'clientInfo': {'name': 'offline-integration', 'version': '1'}})
            self.proc.stdin.write(b'{"jsonrpc":"2.0","method":"notifications/initialized"}\n')
            self.proc.stdin.flush()
        except BaseException:
            self.close()
            raise

    def request(self, method, params=None, timeout=30):
        self.seq += 1
        request = dict(jsonrpc='2.0', id=self.seq, method=method, params=params or {})
        self.events.write(json.dumps({'request': request})+'\n'); self.events.flush()
        self.proc.stdin.write((json.dumps(request)+'\n').encode()); self.proc.stdin.flush()
        deadline = time.monotonic()+timeout
        while time.monotonic() < deadline:
            if b'\n' not in self.buffer:
                if not self.selector.select(max(0, deadline-time.monotonic())):
                    break
                chunk = os.read(self.proc.stdout.fileno(), 65536)
                if not chunk:
                    raise RuntimeError('MCP exited before replying')
                self.buffer += chunk
            while b'\n' in self.buffer:
                line, self.buffer = self.buffer.split(b'\n', 1)
                reply = json.loads(line)
                self.events.write(json.dumps({'reply': reply})+'\n'); self.events.flush()
                if reply.get('id') == self.seq:
                    if 'error' in reply: raise RuntimeError(str(reply['error']))
                    return reply['result']
        raise TimeoutError(f'MCP {method} exceeded {timeout}s')

    def tool(self, name, **arguments):
        response = self.request('tools/call', dict(name=name, arguments=arguments))
        if response.get('isError'): raise RuntimeError(str(response['content']))
        return json.loads(response['content'][0]['text'])

    def close(self):
        try:
            self.proc.stdin.close()
            self.proc.wait(timeout=15)
        except subprocess.TimeoutExpired:
            self.proc.terminate()
            try: self.proc.wait(timeout=5)
            except subprocess.TimeoutExpired: self.proc.kill(); self.proc.wait()
        finally:
            self.selector.close(); self.log.close(); self.events.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--binary', default=str(Path.home()/'.local/bin/isolated-mcp'))
    parser.add_argument('--tinky-server', default=str(Path.home()/'tinky-vision-mcp/src/server.mjs'))
    parser.add_argument('--diagnose-with-network', action='store_true',
                        help='Diagnose OS capture without the extra network sandbox; not offline proof')
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=False, mode=0o700)
    os.umask(0o077)
    processes = subprocess.check_output(['ps', '-axo', 'pid,comm'], text=True)
    if any(token in processes for token in ('/Calculator.app/', 'qemu-system-', '/vmhost')):
        raise RuntimeError('Existing Calculator/guest process; refusing duplicate or borrowed app')
    result = {'status': 'FAIL', 'network_policy': 'deny IP network traffic for both MCP servers and inherited helpers; local OS IPC allowed',
              'binary': args.binary, 'binary_sha256': hashlib.sha256(Path(args.binary).read_bytes()).hexdigest()}
    if args.diagnose_with_network: result['network_policy'] = 'unrestricted diagnostic; offline not proven'
    isolated = vision = None
    session = None
    try:
        isolated = MCP([args.binary], args.out, 'isolated', not args.diagnose_with_network)
        vision = MCP(['/opt/homebrew/bin/node', args.tinky_server], args.out, 'tinky', not args.diagnose_with_network)
        result['setup'] = isolated.tool('setup_status')
        result['displays_before'] = isolated.tool('list_displays')
        if isolated.tool('list_sessions'): raise RuntimeError('An isolated session is already active')
        session = isolated.tool('create_session', appPath='/System/Applications/Calculator.app',
                                displayWidth=1024, displayHeight=768,
                                objective='Offline integration: typed 27+15=42, screenshot-clicked 7 then +8=15, local OCR, recording pause/resume, finalized video.')
        result['session'] = session
        sid = session['sessionId']
        # Luke's intended setup is a second local virtual monitor. A working
        # off-screen window fallback does not satisfy that specific criterion.
        active_displays = isolated.tool('list_displays')
        result['displays_during'] = active_displays
        display = next((d for d in active_displays if d['displayID'] == session['displayID']), None)
        if (not display or display['isMain'] or session['displayID'] == 0
                or display['width'] != 1024 or display['height'] != 768
                or any(d['displayID'] == session['displayID'] for d in result['displays_before'])):
            raise RuntimeError('A new local 1024x768 virtual monitor was not created')
        result['virtual_monitor_verified'] = True
        if not session['windowsPlaced']: raise RuntimeError('App was not isolated')
        isolated.tool('key_press', sessionId=sid, key='escape')
        isolated.tool('type_text', sessionId=sid, text='27+15=')
        # Wait for an actual rendered frame rather than assuming dispatch is synchronous.
        for _ in range(10):
            frame = isolated.tool('session_frame', sessionId=sid)
            ocr = vision.tool('vision_find_text', inPath=frame['path'])
            if any(m['text'] == '42' for m in ocr['matches']): break
            time.sleep(0.5)
        else: raise RuntimeError('The captured Calculator result was not 42')
        result.update(frame=frame, ocr=ocr)
        buttons = isolated.tool('get_interactive_elements', sessionId=sid)['interactiveElements']
        clear = next(e for e in buttons if e.get('label') == 'All Clear' and e.get('role') == 'AXButton')
        bounds = clear['frame']
        result['clear_button'] = clear
        # AX element coordinates are global; click_element performs AXPress on
        # the session's own application, preserving target ownership.
        pressed = isolated.tool('click_element', sessionId=sid, x=bounds['x']+bounds['width']/2,
                                y=bounds['y']+bounds['height']/2)
        if not pressed['success']: raise RuntimeError('Accessibility clear was rejected')
        time.sleep(0.5)
        cleared = isolated.tool('session_frame', sessionId=sid)
        cleared_ocr = vision.tool('vision_find_text', inPath=cleared['path'])
        result.update(cleared_frame=cleared, cleared_ocr=cleared_ocr)
        # Use the screenshot's actual pixels, not global AX/display coordinates.
        # A subsequent 7+8 result distinguishes a delivered click from an ACK.
        seven = next(m['image_px'] for m in cleared_ocr['matches'] if m['text'] == '7')
        isolated.tool('click', sessionId=sid, x=seven['cx'], y=seven['cy'])
        isolated.tool('type_text', sessionId=sid, text='+8=')
        time.sleep(0.5)
        pointer_frame = isolated.tool('session_frame', sessionId=sid)
        pointer_ocr = vision.tool('vision_find_text', inPath=pointer_frame['path'])
        result.update(pointer_frame=pointer_frame, pointer_ocr=pointer_ocr)
        if not any(m['text'] == '15' and m['image_px']['cy'] < seven['cy']
                   for m in pointer_ocr['matches']):
            raise RuntimeError('Screenshot-based click did not produce the observed result 15')
        paused = isolated.tool('stop_recording', sessionId=sid)
        time.sleep(1.2)
        frozen = isolated.tool('frame_history', sessionId=sid, limit=2)
        if paused['count'] != frozen['count'] or frozen['active']:
            raise RuntimeError('Recording did not pause')
        isolated.tool('start_recording', sessionId=sid)
        time.sleep(2.2)
        resumed = isolated.tool('frame_history', sessionId=sid, limit=3)
        if resumed['count'] <= frozen['count'] or resumed['capacity'] != 300:
            raise RuntimeError('Recording did not resume with a 300-frame ring')
        result.update(paused=paused, resumed=resumed)
        result['seal'] = isolated.tool('seal_session', sessionId=sid)
        if not result['seal']['chainIntact']:
            raise RuntimeError('Recorded evidence chain is broken')
        result['stream'] = vision.tool('portal_state')
        result['stream_snapshot'] = vision.tool('portal_snapshot', lane='full')
        result['status'] = 'PASS'
    except Exception as error:
        result['error'] = str(error)
    finally:
        if session and isolated:
            try:
                isolated.tool('stop_session', sessionId=session['sessionId'])
                result['remaining_sessions'] = isolated.tool('list_sessions')
                result['displays_after'] = isolated.tool('list_displays')
                detail = Path.home()/'.isolated-tester/sessions'/session['sessionId']/'session.json'
                result['recording'] = json.loads(detail.read_text())
                video = result['recording']['video']
                if not video: raise RuntimeError('No video finalized; inspect the capture failure')
                probe = subprocess.check_output(['ffprobe', '-v', 'error', '-show_entries',
                    'stream=codec_name,width,height,nb_frames,r_frame_rate', '-show_entries',
                    'format=duration,size', '-of', 'json', video], text=True, timeout=15)
                result['video_probe'] = json.loads(probe)
                if float(result['video_probe']['format']['duration']) <= 0:
                    raise RuntimeError('Video has no duration')
                subprocess.run(['ffmpeg', '-v', 'error', '-xerror', '-i', video,
                                '-f', 'null', '-'], check=True, timeout=20,
                               stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
                result['video_decoded'] = True
            except Exception as error:
                result.update(status='FAIL', cleanup_error=str(error))
        if vision: vision.close()
        if isolated: isolated.close()
        try:
            inventory = MCP([args.binary], args.out, 'cleanup-inventory', not args.diagnose_with_network)
            try: result['fresh_displays_after'] = inventory.tool('list_displays')
            finally: inventory.close()
            before = {d['displayID'] for d in result.get('displays_before', [])}
            after = {d['displayID'] for d in result['fresh_displays_after']}
            if after - before: raise RuntimeError('A test display remains in fresh process inventory')
        except Exception as error:
            result.update(status='FAIL', cleanup_error=str(error))
        if session:
            try:
                os.kill(session['appPID'], 0)
                result.update(status='FAIL', cleanup_error='Owned Calculator process remains')
                os.kill(session['appPID'], signal.SIGTERM)
            except ProcessLookupError: result['app_exited'] = True
        (args.out/'result.json').write_text(json.dumps(result, indent=2)+'\n')
    print(json.dumps({'status': result['status'], 'evidence': str(args.out),
                      'error': result.get('error'), 'cleanup_error': result.get('cleanup_error')}))
    return 0 if result['status'] == 'PASS' else 1


if __name__ == '__main__':
    raise SystemExit(main())
