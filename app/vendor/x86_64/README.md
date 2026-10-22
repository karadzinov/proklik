# Vendored Intel runtime

These x86_64 binaries let the universal ProKlik app use `pkcs11-tool` natively on
Intel Macs. They are copied into `ProKlik.app/Contents/MacOS/tools/x86_64` by
`app/build.sh`.

Provenance:

- `pkcs11-tool` and `libopensc.8.dylib`: Homebrew `opensc` 0.23.0 Ventura bottle,
  SHA-256 `cb74b08610f26136891fc4f039712c29138d2b347b19bf9cbb3b2659b153e2a8`.
- `libcrypto.3.dylib`: Homebrew `openssl@3` 3.1.4 Ventura bottle,
  SHA-256 `92ca3dee40d93846740172ef9d7e64587a57d2948289c2015e0373eab5140f82`.
- Load paths were changed to `@loader_path`, and the binaries were ad-hoc re-signed.

OpenSC is distributed under LGPL-2.1-or-later; OpenSSL 3 is distributed under the
Apache-2.0 license.
