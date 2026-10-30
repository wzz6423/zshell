"""Run the AppKit import flow with local/project-isolated cookies against a Debug build."""
import http.server
import json
import os
from pathlib import Path
import platform
import sqlite3
import subprocess
import sys
import tempfile
import threading

sys.dont_write_bytecode = True
from test_browser_remote_routing import Fixture

ROOT = Path(__file__).resolve().parents[2]
BUILD = Path(os.environ['ZSHELL_TEST_DERIVED_DATA'])
PRODUCTS = BUILD / 'Build/Products/Debug'
LIBRARY = PRODUCTS / 'zshell Debug.app/Contents/MacOS/zshell.debug.dylib'
seen_cookie = threading.Event()
seen_localhost_cookie = threading.Event()
requests = []

if len(sys.argv) == 1:
    for backend in ('libghostty', 'alacritty'):
        for mode in ('local', 'no-project', 'remote-switch', 'remote-close-before', 'remote-close-writing'):
            environment = os.environ.copy()
            environment.update(ZSHELL_PROFILE_TEST_BACKEND=backend, ZSHELL_PROFILE_TEST_MODE=mode)
            print(f'Testing browser import with {backend}: {mode}', flush=True)
            subprocess.run([sys.executable, __file__, '--backend'], env=environment, check=True)
    raise SystemExit(0)


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        cookie = self.headers.get('Cookie', '')
        requests.append((self.path, self.headers.get('Host', ''), cookie))
        if 'fixture_login=fixture-secret' in cookie:
            seen_cookie.set()
        if 'fixture_localhost=fixture-localhost-secret' in cookie:
            seen_localhost_cookie.set()
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b'<title>Fixture</title>')

    def log_message(self, *_):
        pass


def raw_lz4(data):
    size = len(data)
    block = bytearray([min(size, 15) << 4])
    if size >= 15:
        remaining = size - 15
        while remaining >= 255:
            block.append(255)
            remaining -= 255
        block.append(remaining)
    return b'mozLz40\0' + size.to_bytes(4, 'little') + bytes(block) + data


with tempfile.TemporaryDirectory(prefix='zshell-browser-integration-', dir='/tmp') as temporary:
    tmp = Path(temporary).resolve()
    home = tmp / 'home'
    backend = os.environ['ZSHELL_PROFILE_TEST_BACKEND']
    mode = os.environ['ZSHELL_PROFILE_TEST_MODE']
    remote = mode.startswith('remote-')
    configuration = home / '.config/zshell-dev/config.toml'
    configuration.parent.mkdir(parents=True)
    configuration.write_text(f'ai.enabled = false\nterminal.backend = "{backend}"\n')
    firefox = home / 'Library/Application Support/Firefox'
    profile = firefox / 'Profiles/fixture'
    profile.mkdir(parents=True)
    (firefox / 'profiles.ini').write_text('[Profile0]\nName=Fixture Firefox\nIsRelative=1\nPath=Profiles/fixture\n')
    # An unreadable Chrome folder stands in for macOS App Data Protection; Firefox must still be listed.
    chrome = home / 'Library/Application Support/Google/Chrome'
    chrome.mkdir(parents=True)
    chrome.chmod(0)
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    worker = threading.Thread(target=server.serve_forever, daemon=True)
    worker.start()
    url = f'http://127.0.0.1:{server.server_port}/fixture'
    if remote:
        url = f'http://localhost:{server.server_port}/fixture'
    rows = [('127.0.0.1', 'fixture_login', 'fixture-secret', '/', 2000000000000, 0, 1, 1, '')]
    if remote:
        rows += [('localhost', 'fixture_localhost', 'fixture-localhost-secret', '/', 2000000000000, 0, 1, 1, ''),
                 ('127.0.0.2', 'fixture_loopback2', 'fixture-loopback2-secret', '/', 2000000000000, 0, 1, 1, ''),
                 ('.example.test', 'fixture_public', 'fixture-public-secret', '/', 2000000000000, 0, 0, 1, ''),
                 ('localhost', '__Host-fixture_secure', 'fixture-secure-secret', '/', 2000000000000, 1, 1, 0, '')]
    if mode == 'remote-close-writing':
        rows += [('localhost', f'fixture_batch_{index}', 'fixture-batch-secret', '/', 2000000000000, 0, 1, 1, '')
                 for index in range(256)]
    with sqlite3.connect(profile / 'cookies.sqlite') as db:
        db.executescript('''CREATE TABLE moz_cookies (host TEXT,name TEXT,value TEXT,path TEXT,expiry INTEGER,
          isSecure INTEGER,isHttpOnly INTEGER,sameSite INTEGER,originAttributes TEXT);
          PRAGMA user_version = 17;''')
        db.executemany('INSERT INTO moz_cookies VALUES (?,?,?,?,?,?,?,?,?)', rows)
    with sqlite3.connect(profile / 'places.sqlite') as db:
        db.execute('CREATE TABLE moz_places (url TEXT,title TEXT,last_visit_date INTEGER)')
        db.execute('INSERT INTO moz_places VALUES (?,?,?)', (url, 'History fixture', 1700000000000000))
    session = {'windows': [{'tabs': [{'entries': [{'url': url, 'title': 'Fixture'}], 'index': 1},
                                     {'entries': [{'url': (f'http://127.0.0.1:{server.server_port}/fixture-second' if remote else url + '-second'), 'title': 'Second'}], 'index': 1}]}]}
    (profile / 'sessionstore.jsonlz4').write_bytes(raw_lz4(json.dumps(session).encode()))
    binary = tmp / 'integration-tests'
    args = ['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '5',
            '-target', f'{platform.machine()}-apple-macos15.6', '-module-cache-path', str(tmp / 'ModuleCache'),
            '-I', str(PRODUCTS), '-I', str(PRODUCTS / 'include'), '-F', str(PRODUCTS)]
    for modulemap in (BUILD / 'Build/Intermediates.noindex/GeneratedModuleMaps').glob('*.modulemap'):
        args += ['-Xcc', f'-fmodule-map-file={modulemap}']
    for include in ('STTextView/Sources/STObjCLandShim/include', 'swift-cmark/src/include',
                    'swift-cmark/extensions/include', 'swift-markdown/Sources/CAtomic/include'):
        path = ROOT / 'mac/Vendor' / include
        args += ['-I', str(path), '-Xcc', f'-fmodule-map-file={path / "module.modulemap"}']
    args += ['-I', str(ROOT / 'mac/Vendor/alacritty-bridge/include'),
             '-I', str(ROOT / 'mac/Vendor/tree-sitter/lib/include'), str(LIBRARY),
             '-Xlinker', '-rpath', '-Xlinker', str(PRODUCTS),
             '-Xlinker', '-rpath', '-Xlinker', str(LIBRARY.parent),
             str(ROOT / 'mac/tests/BrowserProfileImportIntegrationTests.swift'), '-o', str(binary)]
    environment = {key: value for key, value in os.environ.items() if not key.startswith('ZSHELL_')}
    environment.update(HOME=str(home), CFFIXED_USER_HOME=str(home), LC_ALL='en_US.UTF-8',
                       ZSHELL_PTY_MUX_DIRECTORY=str(tmp / 'pty'))
    fixture_directory = tmp / 'ssh-fixture'
    fixture_directory.mkdir()
    fixture = Fixture(fixture_directory)
    try:
        subprocess.run(args, check=True, cwd=ROOT)
        with fixture:
            environment.update(ZSHELL_SSH_CONFIG_FILE=str(fixture.config), ZSHELL_SSH_AGENT_RESOLVED='1')
            subprocess.run(['/usr/bin/defaults', 'delete', binary.name], capture_output=True)
            try:
                subprocess.run([str(binary), backend, str(home), mode, str(fixture.ssh_port),
                                str(len(rows)), str(server.server_port)], env=environment, check=True, timeout=120)
            finally:
                subprocess.run(['/usr/bin/defaults', 'delete', binary.name], capture_output=True)
            if mode.startswith('remote-close-'):
                assert not requests, 'A closed destination opened an imported browser tab'
            else:
                assert seen_cookie.wait(10), 'Imported cookie was not received by the HTTP fixture'
            if mode == 'remote-switch':
                assert seen_localhost_cookie.wait(10), 'Remote localhost cookie was not received through SSH'
                assert any(path == '/fixture' and host.startswith('zshell-remote.localhost:')
                           and 'fixture_localhost=fixture-localhost-secret' in cookie for path, host, cookie in requests), requests
                assert any(path == '/fixture-second' and host.startswith('127-0-0-1.zshell-remote.localhost:')
                           and 'fixture_login=fixture-secret' in cookie for path, host, cookie in requests), requests
                assert any(path == '/isolation-local' and not cookie for path, _, cookie in requests), requests
                assert 'direct-tcpip' in fixture.ssh_log.read_text(), 'Remote cookies did not travel through SSH'
            print(f'PASS HTTP cookie fixture: {mode}')
    finally:
        fixture.__exit__()
        chrome.chmod(0o700)
        server.shutdown()
        worker.join(timeout=3)
        server.server_close()
