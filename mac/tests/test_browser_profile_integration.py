"""Run the actual AppKit import flow and a local HTTP cookie fixture against a Debug build."""
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

ROOT = Path(__file__).resolve().parents[2]
BUILD = Path(os.environ['ZSHELL_TEST_DERIVED_DATA'])
PRODUCTS = BUILD / 'Build/Products/Debug'
LIBRARY = PRODUCTS / 'zshell Debug.app/Contents/MacOS/zshell.debug.dylib'
seen_cookie = threading.Event()

if len(sys.argv) == 1:
    for backend in ('libghostty', 'alacritty'):
        environment = os.environ.copy()
        environment['ZSHELL_PROFILE_TEST_BACKEND'] = backend
        print(f'Testing browser import with {backend}', flush=True)
        subprocess.run([sys.executable, __file__, '--backend'], env=environment, check=True)
    raise SystemExit(0)


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if 'fixture_login=fixture-secret' in self.headers.get('Cookie', ''):
            seen_cookie.set()
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
    tmp = Path(temporary)
    home = tmp / 'home'
    backend = os.environ['ZSHELL_PROFILE_TEST_BACKEND']
    configuration = home / '.config/zshell-dev/config.toml'
    configuration.parent.mkdir(parents=True)
    configuration.write_text(f'ai.enabled = false\nterminal.backend = "{backend}"\n')
    firefox = home / 'Library/Application Support/Firefox'
    profile = firefox / 'Profiles/fixture'
    profile.mkdir(parents=True)
    (firefox / 'profiles.ini').write_text('[Profile0]\nName=Fixture Firefox\nIsRelative=1\nPath=Profiles/fixture\n')
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    worker = threading.Thread(target=server.serve_forever, daemon=True)
    worker.start()
    url = f'http://127.0.0.1:{server.server_port}/fixture'
    with sqlite3.connect(profile / 'cookies.sqlite') as db:
        db.executescript('''CREATE TABLE moz_cookies (host TEXT,name TEXT,value TEXT,path TEXT,expiry INTEGER,
          isSecure INTEGER,isHttpOnly INTEGER,sameSite INTEGER,originAttributes TEXT);
          INSERT INTO moz_cookies VALUES ('127.0.0.1','fixture_login','fixture-secret','/',2000000000,0,1,1,'');''')
    with sqlite3.connect(profile / 'places.sqlite') as db:
        db.execute('CREATE TABLE moz_places (url TEXT,title TEXT,last_visit_date INTEGER)')
        db.execute('INSERT INTO moz_places VALUES (?,?,?)', (url, 'History fixture', 1700000000000000))
    session = {'windows': [{'tabs': [{'entries': [{'url': url, 'title': 'Fixture'}], 'index': 1},
                                     {'entries': [{'url': url + '-second', 'title': 'Second'}], 'index': 1}]}]}
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
    try:
        subprocess.run(args, check=True, cwd=ROOT)
        subprocess.run([str(binary), backend, str(home)], env=environment, check=True, timeout=90)
        assert seen_cookie.wait(10), 'Imported cookie was not received by the local HTTP fixture'
        print('Local HTTP server received the imported fixture cookie')
    finally:
        server.shutdown()
        worker.join(timeout=3)
        server.server_close()
