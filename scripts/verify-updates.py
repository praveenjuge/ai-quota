#!/usr/bin/env python3
"""Signed packaged-app E2E, exercising the real native menu and installer.
Requires Interceptor with Accessibility permission and the update signing key.
Artifacts are retained; only test processes started here are terminated.
"""
import http.server
import json
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
    output = run('bash', 'scripts/prepare-update-e2e.sh', source)
    root = pathlib.Path(output.strip().splitlines()[-1])
    app = root / 'installed/AIQuota.app'
    info = app / 'Contents/Info.plist'
    identifier = plistlib.loads(info.read_bytes())['CFBundleIdentifier']
    handler = lambda *args, **kwargs: http.server.SimpleHTTPRequestHandler(
        *args, directory=str(root / 'feed'), **kwargs)
    server = Server(('127.0.0.1', 18765), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    if action == 'invalid-feed':
        feed = root / 'feed/appcast.xml'
        feed.write_bytes(feed.read_bytes().replace(b'0.1.3', b'0.1.4'))
    elif action == 'malformed-feed':
        (root / 'feed/appcast.xml').write_text('invalid xml')
    elif action == 'invalid-archive':
        with (root / 'feed/AIQuota-0.1.3-arm64.zip').open('ab') as f:
            f.write(b'corrupt')
    process = subprocess.Popen(['open', '-W', '-n', str(app)],
                               stdout=(root / 'app.log').open('w'), stderr=subprocess.STDOUT)
    trees = []
    def tree():
        try:
            text = run('interceptor', 'macos', 'tree', '--app', identifier,
                       '--filter', 'all', '--depth', '8')
        except subprocess.CalledProcessError:
            return ''
        trees.append(text)
        return text
    try:
        if action in ('restart', 'quit'):
            text = wait_for(lambda: (t if 'Restart and update' in (t := tree()) else None))
            label = 'Restart and update' if action == 'restart' else 'Quit AIQuota'
            ref = re.findall(r'\[(e\d+)\] (?:menuitem|button) "' + label + '"', text)[-1]
            run('interceptor', 'macos', 'act', ref)
            wait_for(lambda: plistlib.loads(info.read_bytes())['CFBundleVersion'] == '0.1.3')
            wait_for(lambda: process.poll() is not None)
            assert run('defaults', 'read', identifier, 'verificationMarker').strip() == 'retained'
            run('codesign', '--verify', '--deep', '--strict', str(app))
            if action == 'restart':
                wait_for(lambda: 'Check for updates' in tree())
        else:
            wait_for(lambda: (t if 'Check for updates…' in (t := tree()) else None))
            text = tree()
            ref = re.findall(r'\[(e\d+)\] (?:menuitem|button) "Check for updates…"', text)[-1]
            run('interceptor', 'macos', 'act', ref)
            wait_for(lambda: 'Update failed — retry' in tree())
            assert plistlib.loads(info.read_bytes())['CFBundleVersion'] == '0.1.2'
            assert process.poll() is None
        return {'scenario': action, 'result': 'passed', 'artifacts': str(root)}
    finally:
        (root / 'menu-trees.txt').write_text('\n'.join(trees))
        # Quit only the isolated test identity; never touch the installed app.
        subprocess.run(['interceptor', 'macos', 'app', 'quit', identifier], capture_output=True)
        if process.poll() is None:
            process.terminate()
            process.wait(timeout=10)
        server.shutdown()
        server.server_close()


if __name__ == '__main__':
    source = sys.argv[1]
    results = []
    for action in sys.argv[2:] or ['restart', 'quit', 'invalid-feed', 'malformed-feed', 'invalid-archive']:
        result = scenario(source, action)
        results.append(result)
        print(json.dumps(result), flush=True)
    pathlib.Path('dist/verification/update-e2e.json').write_text(json.dumps(results, indent=2))
