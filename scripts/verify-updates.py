#!/usr/bin/env python3
"""Signed packaged-app E2E, exercising the real native menu and installer.
Requires Interceptor with Accessibility permission and the update signing key.
Artifacts are retained; only test processes started here are terminated.
"""
import http.server
import json
import os
import signal
import pathlib
import plistlib
import re
import subprocess
import sys
import threading
import time


def run(*args):
    return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT)


def wait_for(probe, timeout=90):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = probe()
        if result:
            return result
        time.sleep(0.5)
    raise RuntimeError('Timed out waiting for observable update behavior')


class Server(http.server.ThreadingHTTPServer):
    allow_reuse_address = True


def scenario(source, action):
    version = {'equal': '0.1.2', 'older': '0.1.1'}.get(action, '0.1.3')
    output = run('bash', 'scripts/prepare-update-e2e.sh', source, version)
    root = pathlib.Path(output.strip().splitlines()[-1])
    app = root / 'installed/Devbar.app'
    info = app / 'Contents/Info.plist'
    identifier = plistlib.loads(info.read_bytes())['CFBundleIdentifier']
    class Handler(http.server.SimpleHTTPRequestHandler):
        def __init__(self, *args, **kwargs):
            super().__init__(*args, directory=str(root / 'feed'), **kwargs)

        def do_GET(self):
            if action == 'offline':
                self.send_error(503)
            elif action == 'interrupted' and self.path.endswith('.zip'):
                self.send_response(200)
                self.send_header('Content-Length', '10000000')
                self.end_headers()
                self.wfile.write(b'incomplete')
                self.close_connection = True
            else:
                super().do_GET()
    handler = Handler
    server = Server(('127.0.0.1', 18765), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    if action == 'invalid-feed':
        feed = root / 'feed/appcast.xml'
        feed.write_bytes(feed.read_bytes().replace(b'0.1.3', b'0.1.4'))
    elif action == 'malformed-feed':
        (root / 'feed/appcast.xml').write_text('invalid xml')
    elif action == 'invalid-archive':
        with (root / 'feed/Devbar-0.1.3-arm64.zip').open('ab') as f:
            f.write(b'corrupt')
    process = subprocess.Popen(['open', '-W', '-n', str(app)],
                               stdout=(root / 'app.log').open('w'), stderr=subprocess.STDOUT)
    trees = []
    def tree():
        try:
            text = run('interceptor', 'macos', 'tree', '--app', identifier,
                       '--filter', 'all', '--depth', '14')
        except subprocess.CalledProcessError:
            return ''
        trees.append(text)
        return text
    def act(label):
        # Refs expire whenever the menu rebuilds, so read a fresh tree and
        # retry; a stale ref delivers nothing.
        def attempt():
            refs = re.findall(r'\[(e\d+)\] (?:menuitem|button) "' + re.escape(label) + '"', tree())
            if not refs:
                return False
            try:
                run('interceptor', 'macos', 'act', refs[-1])
            except subprocess.CalledProcessError:
                return False
            return True
        wait_for(attempt)
    try:
        if action in ('restart', 'quit'):
            wait_for(lambda: 'Restart and update' in tree())
            act('Restart and update' if action == 'restart' else 'Quit Devbar')
            wait_for(lambda: plistlib.loads(info.read_bytes())['CFBundleVersion'] == '0.1.3')
            wait_for(lambda: process.poll() is not None)
            assert run('defaults', 'read', identifier, 'verificationMarker').strip() == 'retained'
            run('codesign', '--verify', '--deep', '--strict', str(app))
            if action == 'restart':
                wait_for(lambda: 'Settings…' in tree())
        else:
            # Checking lives in Settings; the menu only offers a ready update.
            act('Settings…')
            act('Check for updates…')
            expected_title = 'You’re up to date' if action in ('equal', 'older') else 'Update failed — retry'
            wait_for(lambda: expected_title in tree())
            assert plistlib.loads(info.read_bytes())['CFBundleVersion'] == '0.1.2'
            assert process.poll() is None
        return {'scenario': action, 'result': 'passed', 'artifacts': str(root)}
    finally:
        (root / 'menu-trees.txt').write_text('\n'.join(trees))
        # Quit only the isolated test identity; never touch the installed app.
        subprocess.run(['interceptor', 'macos', 'app', 'quit', identifier], capture_output=True)
        # open -W may exit before a relaunched app; target the exact retained
        # fixture path instead of assuming the launcher PID owns the app.
        for line in run('ps', '-axo', 'pid=,command=').splitlines():
            fields = line.strip().split(maxsplit=1)
            if len(fields) == 2 and str(root) in fields[1] and fields[1].endswith('/Contents/MacOS/Devbar'):
                try:
                    os.kill(int(fields[0]), signal.SIGTERM)
                except ProcessLookupError:
                    pass
        if process.poll() is None:
            process.terminate()
            process.wait(timeout=10)
        server.shutdown()
        server.server_close()


if __name__ == '__main__':
    source = sys.argv[1]
    results = []
    for action in sys.argv[2:] or ['restart', 'quit', 'invalid-feed', 'malformed-feed', 'invalid-archive', 'equal', 'older', 'offline', 'interrupted']:
        result = scenario(source, action)
        results.append(result)
        print(json.dumps(result), flush=True)
    artifact = pathlib.Path('dist/verification/update-e2e.json')
    previous = json.loads(artifact.read_text()) if artifact.exists() else []
    by_scenario = {entry['scenario']: entry for entry in previous + results}
    artifact.write_text(json.dumps(list(by_scenario.values()), indent=2))
