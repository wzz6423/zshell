#!/usr/bin/env python3
"""Create Zshell's release identity once; never replace an existing signing key."""

import argparse
import datetime
import getpass
import os
from pathlib import Path
import secrets
import subprocess
import tempfile


def run(args, **kwargs):
    result = subprocess.run(args, capture_output=True, **kwargs)
    if result.returncode:
        # Some security commands include credentials in their arguments or errors.
        raise RuntimeError(f"{args[0]} {args[1]} failed (exit {result.returncode})")
    return result.stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--backup-directory", required=True, type=Path)
    args = parser.parse_args()
    os.umask(0o077)
    keychain = Path.home() / "Library/Keychains/zshell-release-signing.keychain-db"
    service = "sh.zshell.release-signing-keychain"
    identity = "zshell Release Signing"
    if keychain.exists():
        raise RuntimeError("Release keychain already exists; reuse it instead of rotating the identity")
    saved = subprocess.run(
        ["security", "find-generic-password", "-a", getpass.getuser(), "-s", service],
        capture_output=True,
    )
    if saved.returncode == 0:
        raise RuntimeError("Release credentials already exist; recover the original keychain")
    backup = args.backup_directory.resolve()
    if not backup.is_dir():
        raise RuntimeError("The private backup directory must already exist")
    date = datetime.date.today().strftime("%Y%m%d")
    key = backup / f"zshell-release-signing-key-{date}.pem"
    certificate = backup / f"zshell-release-signing-certificate-{date}.pem"
    pkcs12 = backup / f"zshell-release-signing-identity-{date}.p12"
    if any(path.exists() for path in (key, certificate, pkcs12)):
        raise RuntimeError("Signing backups already exist; refusing to overwrite them")
    password = secrets.token_urlsafe(48)
    with tempfile.TemporaryDirectory(prefix="zshell-signing-") as directory:
        password_file = Path(directory) / "password"
        # OpenSSL consumes separate lines when passin and passout share a file.
        password_file.write_text(password + "\n" + password + "\n")
        config = Path(directory) / "certificate.cnf"
        config.write_text("""[req]
prompt = no
distinguished_name = subject
x509_extensions = signing
[subject]
CN = zshell Release Signing
[signing]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
""")
        run(["security", "add-generic-password", "-a", getpass.getuser(), "-s", service,
             "-w", password])
        run(["openssl", "req", "-new", "-x509", "-newkey", "rsa:3072", "-sha256",
             "-days", "3650", "-config", str(config), "-keyout", str(key),
             "-out", str(certificate), "-passout", f"file:{password_file}"])
        run(["openssl", "pkcs12", "-export", "-legacy", "-name", identity, "-inkey", str(key),
             "-in", str(certificate), "-out", str(pkcs12),
             "-passin", f"file:{password_file}", "-passout", f"file:{password_file}"])
        run(["security", "create-keychain", "-p", password, str(keychain)])
        run(["security", "set-keychain-settings", "-lut", "21600", str(keychain)])
        run(["security", "unlock-keychain", "-p", password, str(keychain)])
        run(["security", "import", str(pkcs12), "-k", str(keychain), "-P", password,
             "-T", "/usr/bin/codesign", "-T", "/usr/bin/security"])
        run(["security", "set-key-partition-list", "-S", "apple-tool:,apple:,codesign:",
             "-s", "-k", password, str(keychain)])
    for path in (key, certificate, pkcs12):
        path.chmod(0o600)
    print(f"Created {identity}; encrypted backups saved with mode 600.")
    print("The existing Sparkle Ed25519 key was not changed.")


if __name__ == "__main__":
    try:
        main()
    except RuntimeError as error:
        raise SystemExit(str(error)) from None
