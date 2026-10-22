# ProKlik — native macOS login for NLB corporate e-banking

**What is this for?** NLB Macedonia's corporate internet banking
([ProKlik](https://www.nlbproklik.com.mk/LoginModule/LoginUP.aspx?ReturnUrl=%2fdefault.aspx))
uses the same Windows-only **Aseba Crypto Signer** component as several Asseco/Asseco SEE
banking portals. This project replaces that component with a native macOS implementation:
the portal runs in a small WebKit window, and signing operations go directly to your
**USB certificate token** (Gemalto IDPrime MD, SafeNet eToken, or Gemalto Classic).

The implementation is based on the proven native signing flow from the original
`netbanking` project and is configured for ProKlik's URLs and branding.

## How it works

1. ProKlik presents a one-time challenge (`TextToSign`).
2. The app signs it with the private key on the token and returns the certificate and
   signature to the portal's JavaScript.
3. ProKlik posts the values to `/Account/LoginSmartCard` and returns its normal JSON
   login handshake/redirect.
4. The token PIN is used only locally to unlock the token. It is never sent to NLB.

The native bridge implements the same `window.TokenSigning` JavaScript API expected by
ProKlik's signer checks. No Java, Windows, or browser extension is required.

## Requirements

- macOS 13 or newer
- A ProKlik USB certificate token
- Token middleware for macOS — normally **SafeNet Authentication Client** from Thales
  or your bank/CA. Common supported modules are probed automatically:
  - `/usr/local/lib/libeTPkcs11.dylib`
  - `/usr/local/lib/libIDPrimePKCS11.dylib`
  - `/usr/local/lib/libClassicClientPKCS11.dylib`
- To build from source: Xcode Swift compiler, Homebrew OpenSC, OpenSSL, and standard
  packaging tools (`pkgbuild`, `hdiutil`, `codesign`)

## Build and install

```bash
git clone https://github.com/karadzinov/proklik.git
cd proklik
cd app
./build.sh
open ProKlik.app
```

The script creates:

- `app/ProKlik.app`
- `app/dist/ProKlik-1.1.pkg`
- `app/dist/ProKlik-1.1.dmg`

The app is ad-hoc signed. On first launch, macOS may require
**right-click → Open → Open** once, or **System Settings → Privacy & Security → Open Anyway**.

## CLI helper

```bash
python3 -m venv venv
venv/bin/pip install -r requirements.txt

# Offline signing self-test (prompts for the token PIN)
./venv/bin/python proklik_login.py --test

# Print the selected leaf certificate as base64 DER
./venv/bin/python proklik_login.py --cert

# Headless login experiment (prompts for the token PIN)
./venv/bin/python proklik_login.py --login
```

The GUI app is the supported path. The CLI is useful for diagnosing the token and the
server response.

## Environment overrides

| Variable | Purpose |
|---|---|
| `PROKLIK_PKCS11_TOOL` | Path to `pkcs11-tool` |
| `PROKLIK_PKCS11_MODULE` | Path to a specific PKCS#11 module |
| `PROKLIK_CERT_SUBJECT` | Comma-separated include/exclude subject keywords for leaf-certificate selection |

## Troubleshooting

- **No PKCS#11 middleware sees a token** — plug in the reader/token and install the
  token middleware supplied by NLB or KIBS.
- **Always-authenticate key errors** — the project intentionally uses `pkcs11-tool`
  for signing because it handles context-specific login correctly.
- **Wrong PIN / token locked** — repeated incorrect PIN attempts can lock the token.
  Contact NLB support (`ebank@nlb.mk` or 02/5100-440).
- **Portal cannot see the signer** — use the bundled ProKlik app, not a normal browser;
  the app injects the signer API and uses a Chrome user agent as ProKlik expects.

## Security notes

- The PIN is prompted once per app launch and kept in memory only.
- The private key never leaves the token; only signatures and the public certificate
  are returned to ProKlik.
- The app talks only to `www.nlbproklik.com.mk` over TLS.
- Token middleware remains licensed software and is not bundled with this project.

## Disclaimer

This is a personal utility for macOS access to a bank portal. It is not affiliated
with or endorsed by NLB Macedonia, Asseco SEE, KIBS AD Skopje, Thales, or Gemalto.
Use official supported channels whenever available. Use at your own risk.
