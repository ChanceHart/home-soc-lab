"""Guided Oracle Cloud API key setup (step 2 of the cloud guide). Run once on your PC:  python cloud/setup_oci_key.py

It creates the key pair, tells you exactly what to click in the Oracle console, checks what you paste back,
writes ~/.oci/config and waits until Oracle accepts the key (a brand-new key can be rejected for a few minutes).
Your private key never leaves this PC. Needs: pip install oci
"""
import argparse
import hashlib
import os
import subprocess
import sys
import time
from pathlib import Path

try:
    import oci
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric import rsa
except ImportError:
    sys.exit("First run: pip install oci")

CONSOLE_STEPS = """
In the Oracle Cloud console (https://cloud.oracle.com, signed in):
  1. Click your profile picture (top right) > "My profile"  (or "User settings").
  2. Open the "Tokens and keys" tab, find "API keys", click "Add API key".
  3. Choose "Paste a public key" (NOT "Generate API key pair"), paste the key shown above, click "Add".
  4. Oracle shows a "Configuration file preview". Copy ALL of it (starts with [DEFAULT]).
"""


def fingerprint(public_key):
    der = public_key.public_bytes(serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo)
    return ":".join(f"{b:02x}" for b in hashlib.md5(der).digest())


def lock_down(path):
    """Private key readable by you only."""
    if os.name == "nt":
        user = os.environ.get("USERNAME", "")
        subprocess.run(["icacls", str(path), "/inheritance:r", "/grant:r", f"{user}:F"], capture_output=True, check=True)
    else:
        os.chmod(path, 0o600)


def read_preview():
    print("Paste the Configuration file preview here, then press Enter on an empty line:")
    lines = []
    while True:
        line = input()
        if not line.strip():
            if lines:
                break
            continue
        lines.append(line.strip())
    values = {}
    for line in lines:
        if "=" in line:
            k, v = line.split("=", 1)
            values[k.strip()] = v.split("#")[0].strip()
    missing = [k for k in ("user", "fingerprint", "tenancy", "region") if not values.get(k)]
    if missing:
        sys.exit(f"The pasted text is missing: {', '.join(missing)}. Copy the whole preview, starting with [DEFAULT].")
    return values


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", default=str(Path.home() / ".oci"), help="where to keep the key and config")
    ap.add_argument("--force", action="store_true", help="replace an existing key/config")
    ap.add_argument("--no-test", action="store_true", help="don't call Oracle to test the key")
    args = ap.parse_args()

    d = Path(args.dir)
    key_file, pub_file, cfg = d / "oci_api_key.pem", d / "oci_api_key_public.pem", d / "config"
    if (key_file.exists() or cfg.exists()) and not args.force:
        sys.exit(f"{d} already has a key or config. Use --force to replace them (the old key stops working).")
    d.mkdir(parents=True, exist_ok=True)

    # 1. Key pair (2048-bit RSA, the format Oracle expects)
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    key_file.write_bytes(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                           serialization.NoEncryption()))
    lock_down(key_file)
    pub = key.public_key().public_bytes(serialization.Encoding.PEM, serialization.PublicFormat.SubjectPublicKeyInfo)
    pub_file.write_bytes(pub)
    fp = fingerprint(key.public_key())
    print("\nYour PUBLIC key (safe to paste into Oracle):\n")
    print(pub.decode().strip())
    print(f"\nIts fingerprint: {fp}")
    print(CONSOLE_STEPS)

    # 2. What the user pastes back must belong to this key
    values = read_preview()
    if values["fingerprint"].lower() != fp:
        sys.exit(f"That preview is for a different key ({values['fingerprint']}), not this one ({fp}). "
                 "Add the key shown above and copy the preview Oracle shows right after.")
    cfg.write_text("[DEFAULT]\n" + "".join(f"{k}={values[k]}\n" for k in ("user", "fingerprint", "tenancy", "region"))
                   + f"key_file={key_file.as_posix()}\n", encoding="utf-8")
    print(f"\nSaved {cfg}")

    # 3. A brand-new key can be rejected (401) for a few minutes while Oracle spreads it around
    if args.no_test:
        return
    config = oci.config.from_file(str(cfg))
    ident = oci.identity.IdentityClient(config)
    for attempt in range(1, 21):
        try:
            ads = ident.list_availability_domains(config["tenancy"]).data
            print(f"Oracle accepted the key. Region {config['region']}, {len(ads)} availability domain(s). "
                  "Next: python cloud/launch_vm.py --fallback-after 1")
            return
        except oci.exceptions.ServiceError as e:
            if e.status != 401:
                raise
            print(f"Not accepted yet (normal for a new key), retry {attempt}/20 in 30 s...")
            time.sleep(30)
    sys.exit("Still rejected after 10 minutes: check the key was added to the same user and region as the preview.")


if __name__ == "__main__":
    main()
