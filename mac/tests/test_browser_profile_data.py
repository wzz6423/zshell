"""Exercise browser profile parsing with disposable data; no real browser files or keychains."""
import base64
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import struct
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
FIREFOX_SESSION = base64.b64decode(
    "bW96THo0MABfAgAA8gJ7IndpbmRvd3MiOlt7InRhYgkAYmVudHJpZQwA8CJ1cmwiOiJodHRwczovL2V4YW1wbGUudGVzdC9vbmUiLCJ0aXRsZSI6IkZpeHR1cmUgFgAvfSw5AAo/dHdvOQAAABYAwH1dLCJpbmRleCI6MkUADooAx2Fib3V0OmNvbmZpZ0UAiFNldHRpbmdzQgAfMUIAAw/MAAKXY29udGFpbmVyVAAVQxQACFUAYCwidXNlchwAUGV4dElkqQAQXSAARGNvb2s1AXhob3N0IjoiLgFgIiwibmFtKQHnc2Vzc2lvbiIsInZhbHUSACItZkMB8QwiLCJwYXRoIjoiLyIsInNlY3VyZSI6dHJ1ZSyJAURvbmx5EACAc2FtZVNpdGWHAB8seQAManBhcnRpdHsAD3MAEOBvcmlnaW5BdHRyaWJ1dBcCFntLAHFLZXkiOiIoVAHwAixvdGhlci50ZXN0KSJ9fV19"
)


def string(value, utf16=False):
    raw = value.encode("utf-16le" if utf16 else "utf-8")
    return struct.pack("<I", len(value) if utf16 else len(raw)) + raw + b"\0" * (-len(raw) % 4)


def command(kind, payload):
    return struct.pack("<HB", len(payload) + 1, kind) + payload


def encrypted_cookie(host, value):
    key = hashlib.pbkdf2_hmac("sha1", b"fixture-password", b"saltysalt", 1003, 16)
    content = hashlib.sha256(host.encode()).digest() + value.encode()
    result = subprocess.run(["/usr/bin/openssl", "enc", "-aes-128-cbc", "-K", key.hex(),
                             "-iv", (b" " * 16).hex()], input=content, capture_output=True, check=True)
    return b"v10" + result.stdout


def raw_lz4(data):
    remaining = max(0, len(data) - 15)
    block = bytearray([min(len(data), 15) << 4])
    if len(data) >= 15:
        while remaining >= 255:
            block.append(255)
            remaining -= 255
        block.append(remaining)
    return b"mozLz40\0" + len(data).to_bytes(4, "little") + block + data


def prepare(home, expires):
    support = home / "Library/Application Support"
    chrome = support / "Google/Chrome/Default"
    firefox_root = support / "Firefox"
    firefox = firefox_root / "Profiles/fixture"
    chrome.mkdir(parents=True)
    firefox.mkdir(parents=True)
    (chrome.parent / "Local State").write_text('{"profile":{"info_cache":{"Default":{"name":"Fixture Chrome"}}}}')
    (firefox_root / "profiles.ini").write_text('[Profile0]\nName=Fixture Firefox\nIsRelative=1\nPath=Profiles/fixture\n')
    with sqlite3.connect(chrome / "Cookies") as db:
        db.executescript('''CREATE TABLE meta (key TEXT, value TEXT);
          INSERT INTO meta VALUES ('version', '24');
          CREATE TABLE cookies (host_key TEXT, name TEXT, value TEXT, encrypted_value BLOB, path TEXT,
             expires_utc INTEGER, is_secure INTEGER, is_httponly INTEGER, has_expires INTEGER,
             samesite INTEGER, top_frame_site_key TEXT);''')
        encrypted = encrypted_cookie("example.test", "fixture-only")
        db.execute("INSERT INTO cookies VALUES (?,?,?,?,?,?,?,?,?,?,?)", ("example.test", "login", "", encrypted, "/", 0, 0, 1, 0, 1, ""))
        db.execute("INSERT INTO cookies VALUES (?,?,?,?,?,?,?,?,?,?,?)", ("example.test", "partition", "", encrypted, "/", 0, 0, 0, 0, 1, "https://other.test"))
        db.execute("INSERT INTO cookies VALUES (?,?,?,?,?,?,?,?,?,?,?)", ("other.test", "wrong-domain", "", encrypted, "/", 0, 0, 0, 0, 1, ""))
    with sqlite3.connect(chrome / "History") as db:
        db.executescript("CREATE TABLE urls (url TEXT,title TEXT,last_visit_time INTEGER); INSERT INTO urls VALUES ('https://example.test/history','Fixture',13300000000000000),('chrome://settings','Internal',1);")
    sessions = chrome / "Sessions"
    sessions.mkdir()
    navigation = struct.pack("<III", 0, 5, 0) + string("https://example.test/old") + string("Old", True)
    current = struct.pack("<III", 0, 5, 1) + string("https://example.test/current") + string("Current", True)
    stale = struct.pack("<III", 0, 6, 0) + string("https://example.test/stale") + string("Stale", True)
    internal = struct.pack("<III", 0, 6, 1) + string("chrome://settings") + string("Settings", True)
    data = (b"SNSS" + struct.pack("<I", 3) + command(0, struct.pack("<II", 2, 5))
            + command(2, struct.pack("<II", 5, 0)) + command(6, navigation) + command(6, current)
            + command(7, struct.pack("<II", 5, 1)) + command(24, struct.pack("<III", 5, 0, 1))
            + command(0, struct.pack("<II", 2, 7)) + command(16, struct.pack("<I", 7))
            + command(0, struct.pack("<II", 2, 6)) + command(6, stale) + command(6, internal)
            + command(7, struct.pack("<II", 6, 1)))
    (sessions / "Session_123").write_bytes(data)
    with sqlite3.connect(firefox / "cookies.sqlite") as db:
        db.executescript('''CREATE TABLE moz_cookies (host TEXT,name TEXT,value TEXT,path TEXT,expiry INTEGER,
          isSecure INTEGER,isHttpOnly INTEGER,sameSite INTEGER,originAttributes TEXT);
          INSERT INTO moz_cookies VALUES ('example.test','login','fixture-only','/',2000000000000,1,1,2,'');
          INSERT INTO moz_cookies VALUES ('example.test','partition','fixture-only','/',2000000000000,1,1,2,'^userContextId=1');
          PRAGMA user_version = 17;''')
    with sqlite3.connect(firefox / "places.sqlite") as db:
        db.executescript("CREATE TABLE moz_places (url TEXT,title TEXT,last_visit_date INTEGER); INSERT INTO moz_places VALUES ('https://example.test/firefox','Fixture',1700000000000000),('https://example.test/bookmark','Unvisited',NULL);")
    (firefox / "sessionstore.jsonlz4").write_bytes(FIREFOX_SESSION)
    for name, index in (("minimum-index", -(2**63)), ("maximum-index", 2**63 - 1)):
        payload = json.dumps({"windows": [{"tabs": [{"entries": [{"url": "https://example.test/boundary"}],
                                                   "index": index}]}]}).encode()
        (firefox / f"{name}.jsonlz4").write_bytes(raw_lz4(payload))
    same_site = [("unset", 256, False), ("unset_secure", 256, True),
                 ("none_insecure", 0, False), ("none_secure", 0, True),
                 ("lax", 1, False), ("strict", 2, False), ("null", None, False), ("unknown", 99, False)]
    current = home / "same-site-current"
    current.mkdir()
    with sqlite3.connect(current / "cookies.sqlite") as db:
        db.executescript('''CREATE TABLE moz_cookies (host TEXT,name TEXT,value TEXT,path TEXT,expiry INTEGER,
          isSecure INTEGER,isHttpOnly INTEGER,sameSite INTEGER,originAttributes TEXT);
          PRAGMA user_version = 17;''')
        db.executemany("INSERT INTO moz_cookies VALUES (?,?,?,?,?,?,?,?,?)",
                       [("127.0.0.1", "persistent_" + name, "fixture-only", "/", expires * 1000,
                         secure, 1, same, "") for name, same, secure in same_site])
    records = [{"host": "127.0.0.1", "name": "session_" + name, "value": "fixture-only",
                "path": "/", "secure": secure, "httponly": True, "sameSite": same}
               for name, same, secure in same_site]
    records.append({"host": "127.0.0.1", "name": "session_missing", "value": "fixture-only",
                    "path": "/", "secure": False, "httponly": True})
    (current / "sessionstore.jsonlz4").write_bytes(raw_lz4(json.dumps({"cookies": records}).encode()))
    for name, same_column, schema in (("null", ",sameSite INTEGER", 9), ("missing", "", 8)):
        legacy = home / f"same-site-{name}"
        legacy.mkdir()
        with sqlite3.connect(legacy / "cookies.sqlite") as db:
            db.executescript(f'''CREATE TABLE moz_cookies (host TEXT,name TEXT,value TEXT,path TEXT,expiry INTEGER,
              isSecure INTEGER,isHttpOnly INTEGER{same_column}); PRAGMA user_version = {schema};''')
            db.execute("INSERT INTO moz_cookies (host,name,value,path,expiry,isSecure,isHttpOnly) VALUES (?,?,?,?,?,?,?)",
                       ("127.0.0.1", "legacy_" + name, "fixture-only", "/", expires, 0, 1))


with tempfile.TemporaryDirectory(prefix="zshell-browser-profile-test-", dir="/tmp") as temporary:
    root = Path(temporary).resolve()
    expires = int(time.time()) + 30 * 24 * 60 * 60
    prepare(root, expires)
    binary = root / "browser-profile-tests"
    runtime_tmp = root / "tmp"
    runtime_tmp.mkdir()
    environment = os.environ.copy()
    environment.update(HOME=str(root), CFFIXED_USER_HOME=str(root), TMPDIR=str(runtime_tmp))
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-swift-version", "5",
                    "-module-cache-path", str(root / "ModuleCache"),
                    str(ROOT / "mac/zshell/BrowserProfileSessions.swift"),
                    str(ROOT / "mac/zshell/BrowserProfileData.swift"),
                    str(ROOT / "mac/tests/BrowserProfileDataTests.swift"), "-o", str(binary)], env=environment, check=True)
    subprocess.run([str(binary), str(root), str(expires)], env=environment, cwd=root, check=True, timeout=60)
    # Cookie schemas before 16 store expiry in seconds.
    with sqlite3.connect(root / "Library/Application Support/Firefox/Profiles/fixture/cookies.sqlite") as db:
        db.executescript("UPDATE moz_cookies SET expiry = expiry / 1000; PRAGMA user_version = 15;")
    subprocess.run([str(binary), str(root), str(expires)], env=environment, cwd=root, check=True, timeout=60)
