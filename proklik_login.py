#!/usr/bin/env python3
"""
Native macOS login for NLB ProKlik (NLB corporate e-banking).

Replaces the retired Java applet (PKCS11Signer): signs the login challenge
with the qualified certificate on the Gemalto IDPrime token via PKCS#11,
then POSTs to /Account/LoginSmartCard exactly as the applet did.

  python3 proklik_login.py --test     sign a self-test string using the token (offline)
  python3 proklik_login.py --login    perform the real login and report the result

The PIN is prompted and used only locally; the signed login POST does NOT
contain the PIN (same as the original applet).
"""

import argparse
import base64
import hashlib
import json
import os
import re
import subprocess
import sys
import urllib.parse
import urllib.request
import http.cookiejar
import getpass

BANK_URL = "https://www.nlbproklik.com.mk/LoginModule/LoginUP.aspx?ReturnUrl=%2fdefault.aspx"
LOGIN_POST_URL = "https://www.nlbproklik.com.mk/Account/LoginSmartCard"
UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
      "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15")

PKCS11_TOOL = os.environ.get("PROKLIK_PKCS11_TOOL", "pkcs11-tool")
# Candidate token middlewares, probed in order (first one that sees a token wins).
PKCS11_MODULE_CANDIDATES = [
    os.environ.get("PROKLIK_PKCS11_MODULE"),
    "/usr/local/lib/libeTPkcs11.dylib",           # SafeNet Authentication Client
    "/usr/local/lib/libIDPrimePKCS11.dylib",      # Gemalto IDPrime
    "/usr/local/lib/libClassicClientPKCS11.dylib",# Gemalto Classic Client
]
# The signer's leaf certificate is identified by having a personal serialNumber=
# attribute and no CA/qualified-issuer markers. Override via PROKLIK_CERT_SUBJECT
# (comma-separated, UTF-8) if your CA issues differently, e.g. "SURNAME,ISSUER-CA".
CERT_SUBJECT_MATCH = os.environ.get(
    "PROKLIK_CERT_SUBJECT", "serialNumber=,CA")


def _is_leaf(cert_der: bytes) -> bool:
    """Leaf selection on openssl's SUBJECT TEXT (the literal strings 'serialNumber='
    etc. don't appear in DER bytes)."""
    key, *anti = CERT_SUBJECT_MATCH.split(",")
    with open(f"{TMP}/leaf_probe.cer", "wb") as f:
        f.write(cert_der)
    r = subprocess.run(["openssl", "x509", "-in", f"{TMP}/leaf_probe.cer",
                        "-inform", "DER", "-noout", "-subject"],
                       capture_output=True, text=True)
    subject = (r.stdout or "")
    return key in subject and all(a.lower() not in subject.lower() for a in anti)

# DER prefix: SEQUENCE { SEQUENCE { OID 1.3.14.3.2.26 (sha1), NULL }, OCTET STRING } + 20-byte digest
SHA1_DIGESTINFO_PREFIX = bytes([
    0x30, 0x21, 0x30, 0x09, 0x06, 0x05, 0x2b, 0x0e, 0x03, 0x02, 0x1a,
    0x05, 0x00, 0x04, 0x14,
])

TMP = "/tmp/proklik_work"
os.makedirs(TMP, exist_ok=True)


TOKEN_QUIET = False


def detect_module() -> str:
    """Pick the first installed middleware whose PKCS#11 module sees a token."""
    import subprocess
    for cand in PKCS11_MODULE_CANDIDATES:
        if not cand or not os.path.exists(cand):
            continue
        r = subprocess.run([PKCS11_TOOL, "--module", cand, "--list-slots"],
                           capture_output=True, text=True)
        out = (r.stdout or "") + (r.stderr or "")
        if r.returncode == 0 and ("token present" in out or "token label" in out):
            if not TOKEN_QUIET:
                print(f"Middleware: {cand}")
            return cand
    sys.exit("No PKCS#11 middleware sees a token. Plug in the USB token; if it stays "
             "unseen, install SafeNet Authentication Client for macOS or set PROKLIK_PKCS11_MODULE.")


def get_leaf_cert() -> bytes:
    """Read the signer's leaf certificate off the token (no PIN needed)."""
    import pkcs11
    module = detect_module()
    lib = pkcs11.lib(module)
    slots = [s for s in lib.get_slots(token_present=True) if s.get_token()]
    if not slots:
        sys.exit("No token found. Is the USB reader + token plugged in?")
    token = slots[0].get_token()
    if not TOKEN_QUIET:
        print(f"Token: {token.label!r}  model={token.model}  serial={token.serial}")
    with token.open() as session:
        for obj in session.get_objects():
            try:
                if obj[pkcs11.constants.Attribute.CLASS] != pkcs11.constants.ObjectClass.CERTIFICATE:
                    continue
                value = obj[pkcs11.constants.Attribute.VALUE]
                if _is_leaf(value):
                    return value
            except Exception:
                continue
    sys.exit("Signer leaf certificate not found on token "
             "(tweak PROKLIK_CERT_SUBJECT if your issuer differs).")


def sign_token(pin: str, message: bytes, mechanism: str = "SHA256-RSA-PKCS") -> bytes:
    """
    Sign exactly like the Aseba Crypto Signer does: SHA-256 with RSA (PKCS#1 v1.5),
    computed natively on the card (CKM_SHA256_RSA_PKCS). The key is marked
    always-authenticate, so we go through pkcs11-tool, which performs the required
    context-specific login.
    """
    in_path, sig_path = f"{TMP}/challenge_message.bin", f"{TMP}/challenge_sig.bin"
    with open(in_path, "wb") as f:
        f.write(message)
    if os.path.exists(sig_path):
        os.remove(sig_path)
    r = subprocess.run(
        [PKCS11_TOOL, "--module", detect_module(), "--slot", "0",
         "--login", "--pin", pin,
         "--sign", "--mechanism", mechanism,
         "--input", in_path, "--output", sig_path],
        capture_output=True, text=True)
    if not os.path.exists(sig_path):
        err = (r.stderr or r.stdout or "").strip().splitlines()
        tail = err[-1] if err else "unknown error"
        if "LOGIN" in tail.upper() or "PIN" in tail.upper():
            sys.exit(f"Token login failed with the entered PIN ({tail}). Try again carefully.")
        sys.exit(f"Signing failed: {tail}")
    with open(sig_path, "rb") as f:
        return f.read()


def login_attempt(opener, challenge: str, cert: bytes, sig: bytes,
                  cert_enc: str, sig_enc: str, function: str):
    def enc(b, how):
        return base64.b64encode(b).decode("ascii") if how == "b64" else b.hex()
    fields = {
        "Certificate": enc(cert, cert_enc),
        "Signature": enc(sig, sig_enc),
        "TextToSign": challenge,
    }
    if function:
        fields["Function"] = function
    body = urllib.parse.urlencode(fields).encode()
    resp = http_open(LOGIN_POST_URL, opener, data=body,
                     headers={"X-Requested-With": "XMLHttpRequest",
                              "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8",
                              "Referer": BANK_URL,
                              "Origin": "https://www.nlbproklik.com.mk",
                              "Accept": "*/*"})
    raw = resp.read().decode("utf-8", "replace")
    try:
        return json.loads(raw), raw
    except ValueError:
        return None, raw


def do_probe():
    """Try plausible signing/encoding variants against the real endpoint."""
    import pkcs11  # noqa: F401  (ensures venv has it, consistent with get_leaf_cert)
    jar = http.cookiejar.CookieJar()
    opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))

    resp = http_open(BANK_URL, opener)
    html = resp.read().decode("utf-8", "replace")
    m = re.search(r'id="textToSignField"[^>]*value="([^"]+)"', html)
    if not m:
        sys.exit("TextToSign challenge not found.")
    challenge = m.group(1)
    print(f"challenge: {challenge}")
    cert = get_leaf_cert()
    pin = getpass.getpass("Token PIN (used for signing only, never sent): ")

    variants = [
        # (mechanism, cert_enc, sig_enc, Function)
        ("SHA256-RSA-PKCS", "b64",  "b64", None),   # plain, no Function field
        ("SHA256-RSA-PKCS", "hex",  "b64", "1"),
        ("SHA256-RSA-PKCS", "b64",  "hex", "1"),
        ("SHA256-RSA-PKCS", "hex",  "hex", "1"),
        ("SHA1-RSA-PKCS*",   "b64", "b64", None),   # legacy applet: SHA1 DigestInfo
        ("SHA1-RSA-PKCS*",   "b64", "b64", "1"),
    ]
    for i, (mech, ce, se, fn) in enumerate(variants, 1):
        # Fresh challenge from a clean session for every attempt.
        jar.clear()
        resp = http_open(BANK_URL, opener)
        html = resp.read().decode("utf-8", "replace")
        m = re.search(r'id="textToSignField"[^>]*value="([^"]+)"', html)
        challenge = m.group(1) if m else challenge
        print(f"\n— variant {i}: {mech} cert={ce} sig={se} Function={fn or '-'} "
              f"(challenge {challenge})")
        if mech == "SHA1-RSA-PKCS*":
            digest = hashlib.sha1(challenge.encode()).digest()
            msg_to_sign = SHA1_DIGESTINFO_PREFIX + digest
            mech_real = "RSA-PKCS"
        else:
            msg_to_sign = challenge.encode("utf-8")
            mech_real = mech
        sig = sign_token(pin, msg_to_sign, mech_real)
        data, raw = login_attempt(opener, challenge, cert, sig, ce, se, fn)
        if data is None:
            print(f"   non-JSON response: {raw[:300]}")
        elif data.get("UserAuthenticated"):
            print("   >>> LOGIN SUCCESSFUL with this variant.")
            with open(f"{TMP}/session.json", "w") as f:
                cookies = [{"name": c.name, "value": c.value, "domain": c.domain, "path": c.path}
                           for c in jar]
                json.dump({"cookies": cookies, "key": data.get("Key", ""),
                           "redirect": data.get("RedirectionUrl"),
                           "variant": [mech, ce, se, fn]}, f, indent=2)
            return
        else:
            print(f"   rejected: {data.get('ErrorMessage') or raw[:200]}")
    print("\nAll variants rejected — the server is not complaining about signature format.")


def verify_sig(cert_der: bytes, signature: bytes, message_path: str) -> bool:
    cert, pub, sig = (f"{TMP}/v.cer", f"{TMP}/v_pub.pem", f"{TMP}/v.sig")
    with open(cert, "wb") as f:
        f.write(cert_der)
    with open(sig, "wb") as f:
        f.write(signature)
    subprocess.run(["openssl", "x509", "-in", cert, "-inform", "DER", "-noout",
                    "-pubkey"], stdout=open(pub, "w"), stderr=subprocess.DEVNULL)
    r = subprocess.run(["openssl", "dgst", "-sha256", "-verify", pub,
                        "-signature", sig, message_path],
                       capture_output=True, text=True)
    return "Verified OK" in (r.stdout + r.stderr)


def do_cert():
    """Print ONLY the leaf certificate as base64 DER (consumed by the GUI app)."""
    global TOKEN_QUIET
    TOKEN_QUIET = True
    print(base64.b64encode(get_leaf_cert()).decode())


def do_selftest():
    msg_path = f"{TMP}/selftest.msg"
    msg = b"self-test-of-the-signing-token"
    with open(msg_path, "wb") as f:
        f.write(msg)
    cert = get_leaf_cert()
    print(f"Certificate: {len(cert)} bytes DER OK")
    pin = getpass.getpass("Token PIN: ")
    sig = sign_token(pin, msg)
    print("(selftest used SHA256-RSA-PKCS, the algorithm the portal now expects)")
    print(f"Signature:   {len(sig)} bytes RSA OK")
    if verify_sig(cert, sig, msg_path):
        print("\n>>> Verified OK — token signing works on macOS.")
    else:
        sys.exit("Signature did NOT verify — aborting.")


def http_open(url, opener, data=None, headers=None):
    req = urllib.request.Request(url, data=data)
    req.add_header("User-Agent", UA)
    req.add_header("Accept", "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8")
    for k, v in (headers or {}).items():
        req.add_header(k, v)
    return opener.open(req, timeout=30)


def do_login():
    jar = http.cookiejar.CookieJar()
    opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))

    print(f"1. Fetching login challenge from {BANK_URL}")
    resp = http_open(BANK_URL, opener)
    html = resp.read().decode("utf-8", "replace")

    m = re.search(r'id="textToSignField"[^>]*value="([^"]+)"', html)
    if not m:
        sys.exit("TextToSign challenge not found on the login page.")
    challenge = m.group(1)
    print(f"   challenge (TextToSign): {challenge}")

    cert = get_leaf_cert()
    pin = getpass.getpass("Token PIN: ")
    print("2. Signing challenge with token (SHA-1 DigestInfo + RSA, server-verified scheme)...")
    digest = hashlib.sha1(challenge.encode("utf-8")).digest()
    sig = sign_token(pin, SHA1_DIGESTINFO_PREFIX + digest, "RSA-PKCS")

    body = urllib.parse.urlencode({
        "Certificate": base64.b64encode(cert).decode("ascii"),
        "Signature": base64.b64encode(sig).decode("ascii"),
        "TextToSign": challenge,
    }).encode()
    print("3. POSTing signed login to server...")
    resp = http_open(LOGIN_POST_URL, opener, data=body,
                     headers={"X-Requested-With": "XMLHttpRequest",
                              "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8",
                              "Referer": BANK_URL,
                              "Origin": "https://www.nlbproklik.com.mk",
                              "Accept": "*/*"})
    raw = resp.read().decode("utf-8", "replace")
    try:
        data = json.loads(raw)
    except ValueError:
        print("Server did not return JSON login response; raw output:")
        print(raw[:2000])
        sys.exit(1)

    if data.get("UserAuthenticated"):
        print("\nLOGIN SUCCESSFUL")
        print(f"   RedirectionUrl: {data.get('RedirectionUrl')}")
        key = data.get("Key", "")
        print(f"   window.name key: {key}")
        with open(f"{TMP}/session.json", "w") as f:
            cookies = [{"name": c.name, "value": c.value, "domain": c.domain, "path": c.path}
                       for c in jar]
            json.dump({"cookies": cookies, "key": key,
                       "redirect": data.get("RedirectionUrl")}, f, indent=2)
        print(f"   Session state saved to {TMP}/session.json")
    else:
        print("\nLOGIN REJECTED:")
        print("  " + str(data.get("ErrorMessage") or raw[:500]))
        sys.exit(2)


def main():
    ap = argparse.ArgumentParser(description="Native nlbproklik.com.mk login via USB token")
    ap.add_argument("--test", action="store_true", help="token signing self-test (offline)")
    ap.add_argument("--login", action="store_true", help="real login against the bank")
    ap.add_argument("--probe", action="store_true", help="try format variants against the bank")
    ap.add_argument("--cert", action="store_true",
                    help="print the leaf certificate (base64 DER) and exit")
    args = ap.parse_args()
    if args.test:
        do_selftest()
    elif args.cert:
        do_cert()
    elif args.probe:
        do_probe()
    elif args.login:
        do_login()
    else:
        ap.print_help()


if __name__ == "__main__":
    main()