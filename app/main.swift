// ProKlik — NLB ProKlik corporate portal in a WebKit window with native
// USB-token signing (replaces the Windows-only "Aseba Crypto Signer").
//
// The portal's JS calls window.TokenSigning().certAndSign({type, hex}, opts) where
// hex is a JSON string of MessageField_N values. We sign each value with SHA-1/RSA
// (server-verified scheme, identical to the retired Java applet) using the Gemalto
// IDPrime token and return {hex: JSON{SignatureField_N...}, cert: base64-DER}.

import Cocoa
import WebKit
import CryptoKit

let PORTAL_URL = URL(string: "https://www.nlbproklik.com.mk/LoginModule/LoginUP.aspx?ReturnUrl=%2fdefault.aspx")!

// DER prefix: SEQUENCE { SEQUENCE { OID 1.3.14.3.2.26 (sha1), NULL }, OCTET STRING }
let SHA1_DIGESTINFO_PREFIX: [UInt8] = [
    0x30, 0x21, 0x30, 0x09, 0x06, 0x05, 0x2b, 0x0e, 0x03, 0x02, 0x1a,
    0x05, 0x00, 0x04, 0x14,
]

var cachedPin: String?
var leafCertB64 = ""
var pkcs11Module: String = ""
var pkcs11ToolPath: String = ""

func fail(_ msg: String) -> NSError {
    NSError(domain: "ProKlik", code: 1,
            userInfo: [NSLocalizedDescriptionKey: msg])
}

// MARK: - Bundled tool discovery + middleware auto-detection

// Candidate PKCS#11 middlewares, in the order the bank's tokens are typically issued.
let MODULE_CANDIDATES = [
    "/usr/local/lib/libeTPkcs11.dylib",        // SafeNet Authentication Client (eToken/IDPrime MD)
    "/usr/local/lib/libIDPrimePKCS11.dylib",   // Gemalto IDPrime middleware
    "/usr/local/lib/libClassicClientPKCS11.dylib", // Gemalto Classic Client
    "/usr/local/lib/libgclib.dylib",
]

func bundledToolsDir() -> URL {
    let exec = Bundle.main.executableURL!.deletingLastPathComponent()
#if arch(arm64)
    let arch = "arm64"
#elseif arch(x86_64)
    let arch = "x86_64"
#else
    #error("Unsupported CPU architecture")
#endif
    return exec.appendingPathComponent("tools").appendingPathComponent(arch)
}

func resolveTools() throws {
    // pkcs11-tool: prefer the architecture-specific bundled copy, then fall back
    // to the Homebrew path used on that architecture.
    let bundled = bundledToolsDir().appendingPathComponent("pkcs11-tool")
#if arch(arm64)
    let fallbackTool = "/opt/homebrew/bin/pkcs11-tool"
#elseif arch(x86_64)
    let fallbackTool = "/usr/local/bin/pkcs11-tool"
#endif
    pkcs11ToolPath = FileManager.default.fileExists(atPath: bundled.path)
        ? bundled.path : fallbackTool
    guard FileManager.default.fileExists(atPath: pkcs11ToolPath) else {
        throw fail("pkcs11-tool not found (install with:  brew install opensc)")
    }
    // Module: env override, else probe candidates for one that sees a token.
    if let env = ProcessInfo.processInfo.environment["PROKLIK_PKCS11_MODULE"] {
        pkcs11Module = env
        return
    }
    for cand in MODULE_CANDIDATES where FileManager.default.fileExists(atPath: cand) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: pkcs11ToolPath)
        proc.arguments = ["--module", cand, "--list-slots"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        try? proc.run()
        proc.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                         encoding: .utf8) ?? ""
        if proc.terminationStatus == 0,
           out.contains("token present") || out.contains("token label") {
            pkcs11Module = cand
            return
        }
    }
    throw fail("No PKCS#11 middleware sees a token.\n"
             + "Plug in the USB token and install SafeNet Authentication Client "
             + "using the helper included in the ProKlik disk image. "
             + "If your bank supplied different middleware, set PROKLIK_PKCS11_MODULE "
             + "to its PKCS#11 library path.")
}

// MARK: - Token leaf certificate via the bundled proklik-cert CLI

func readLeafCertB64() throws -> String {
    let exec = Bundle.main.executableURL!.deletingLastPathComponent()
    let cert = exec.appendingPathComponent("proklik-cert")
    let proc = Process()
    proc.executableURL = FileManager.default.fileExists(atPath: cert.path)
        ? cert : URL(fileURLWithPath: "/usr/local/bin/proklik-cert")
    proc.arguments = [pkcs11Module]
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = Pipe()
    try proc.run()
    proc.waitUntilExit()
    let raw = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                     encoding: .utf8) ?? ""
    let out = raw.split(separator: "\n")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .last ?? ""
    guard proc.terminationStatus == 0, out.count > 100 else {
        throw fail("Cannot read the USB token. Is it plugged in?\n(\(raw.prefix(300)))")
    }
    return out
}

// MARK: - Signing

func askPin() -> String? {
    let a = NSAlert()
    a.messageText = "USB Token PIN"
    a.informativeText = "Used only on this Mac to unlock the token.\nIt is never sent to the bank."
    a.addButton(withTitle: "OK")
    a.addButton(withTitle: "Cancel")
    let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
    a.accessoryView = field
    a.window.initialFirstResponder = field
    return a.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
}

func tokenSign(_ message: Data, pin: String) throws -> Data {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
    let inFile = tmp.appendingPathComponent("proklik_msg.bin")
    let outFile = tmp.appendingPathComponent("proklik_sig.bin")
    try message.write(to: inFile)
    try? FileManager.default.removeItem(at: outFile)

    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: pkcs11ToolPath)
    proc.arguments = ["--module", pkcs11Module, "--slot", "0",
                      "--login", "--pin", pin,
                      "--sign", "--mechanism", "RSA-PKCS",
                      "--input", inFile.path, "--output", outFile.path]
    try proc.run()
    proc.waitUntilExit()
    guard proc.terminationStatus == 0, FileManager.default.fileExists(atPath: outFile.path) else {
        throw fail("Token signing failed (wrong PIN or token removed?)")
    }
    let sig = try Data(contentsOf: outFile)
    try? FileManager.default.removeItem(at: outFile)
    return sig
}

func signOne(_ message: String) throws -> String {
    let sha1 = Insecure.SHA1.hash(data: Data(message.utf8))
    let digestinfo = Data(SHA1_DIGESTINFO_PREFIX) + Data(sha1)
    guard let pin = cachedPin, let sig = try? tokenSign(digestinfo, pin: pin) else {
        throw fail("Token signing failed (wrong PIN or token removed?)")
    }
    return sig.base64EncodedString()
}

// MARK: - Bridge

final class SignerBridge: NSObject, WKScriptMessageHandler {
    weak var webView: WKWebView?

    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        if message.name == "asebaLog" {
            NSLog("%@", String(describing: message.body))
            return
        }
        guard let body = message.body as? [String: Any],
              let cb = body["cb"] as? String else { return }

        if body["kind"] as? String == "getCertificate" {
            resolve(cb, payload: ["hex": leafCertB64])
            return
        }
        guard let spec = body["spec"] as? [String: Any],
              let hexStr = spec["hex"] as? String,
              let fields = try? JSONSerialization.jsonObject(with: Data(hexStr.utf8))
                  as? [String: String] else {
            reject(cb, why: "bad_request")
            return
        }
        var replies = [String: String]()
        do {
            for (key, value) in fields.sorted(by: { $0.key < $1.key }) {
                let sigField = key.replacingOccurrences(of: "MessageField", with: "SignatureField")
                replies[sigField] = try signOne(value)
            }
        } catch {
            reject(cb, why: "sign_error")
            return
        }
        guard let replyJSON = String(data: try! JSONSerialization.data(withJSONObject: replies),
                                     encoding: .utf8) else {
            reject(cb, why: "encode_error")
            return
        }
        // "func" must be present-but-empty: the page posts Function=1 if it's
        // undefined, but the server-verified login has no Function field.
        resolve(cb, payload: ["hex": replyJSON, "cert": leafCertB64, "func": ""])
    }

    private func resolve(_ cb: String, payload: [String: String]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        webView?.evaluateJavaScript(
            "window.__aseba.resolve['\(cb)'](\(json)); void 0", completionHandler: nil)
    }

    private func reject(_ cb: String, why: String) {
        webView?.evaluateJavaScript(
            "window.__aseba.reject['\(cb)']({message:'\(why)'}); void 0",
            completionHandler: nil)
    }
}

// MARK: - JS injected before page scripts

// Version claimed to the portal's component check — must match its latestVersion
// ("1.0.1.15"); claiming "1.0.1.16" would flip the portal into SHA-256 mode (hf cookie),
// which the server does not accept.
let SIGNER_VERSION = "1.0.1.15"

let TOKEN_SIGNING_JS = """
window.__aseba = {resolve:{}, reject:{}, n:0};
function TokenSigning() {}
TokenSigning.prototype.certAndSign = function(spec, opts) {
  var id = 'cb' + (++window.__aseba.n);
  return new Promise(function(resolve, reject) {
    window.__aseba.resolve[id] = resolve;
    window.__aseba.reject[id] = reject;
    window.webkit.messageHandlers.asebaSign.postMessage({spec: spec, cb: id});
  });
};
TokenSigning.prototype.getCertificate = function(opts) {
  var id = 'cb' + (++window.__aseba.n);
  return new Promise(function(resolve, reject) {
    window.__aseba.resolve[id] = resolve;
    window.__aseba.reject[id] = reject;
    window.webkit.messageHandlers.asebaSign.postMessage({kind: 'getCertificate', cb: id});
  });
};
TokenSigning.prototype.getVersion = function() {
  return Promise.resolve('Aseba Crypto Signer/\(SIGNER_VERSION)');
};

// Diagnostics: tee console + login form responses to the native logger.
( function() {
  var _log = console.log;
  console.log = function() {
    try { webkit.messageHandlers.asebaLog.postMessage('[js] ' + Array.prototype.join.call(arguments, ' ')); } catch (e) {}
    _log.apply(console, arguments);
  };
  var _ls;
  Object.defineProperty(window, 'LoginSuccess', {
    configurable: true,
    get: function() { return _ls; },
    set: function(f) {
      _ls = function(r) {
        try { webkit.messageHandlers.asebaLog.postMessage('[login] response=' + JSON.stringify(r)); } catch (e) {}
        return f.apply(this, arguments);
      };
    }
  });
  window.addEventListener('unhandledXhrResponse', function() {});
  document.addEventListener('readystatechange', function() {
    try { webkit.messageHandlers.asebaLog.postMessage('[page] ' + document.readyState + ' winname=' + window.name.slice(0, 40)); } catch (e) {}
  });
  // Tap the login POST regardless of page internals.
  document.addEventListener('DOMContentLoaded', function() {
    var origSend = XMLHttpRequest.prototype.send;
    XMLHttpRequest.prototype.send = function(body) {
      var xhr = this;
      if (body && typeof body === 'string' && body.indexOf('TextToSign') !== -1) {
        try { webkit.messageHandlers.asebaLog.postMessage('[xhr] sent len=' + body.length); } catch (e) {}
        xhr.addEventListener('load', function() {
          try { webkit.messageHandlers.asebaLog.postMessage('[xhr] ' + xhr.status + ' ' + String(xhr.responseText).slice(0, 600)); } catch (e) {}
        });
        xhr.addEventListener('error', function() {
          try { webkit.messageHandlers.asebaLog.postMessage('[xhr] network error'); } catch (e) {}
        });
      }
      return origSend.apply(this, arguments);
    };
  });
} )();

// The portal verifies the "extension" by looking for a DOM element with the
// extension id, and the native component via chrome.runtime probing.
(function ensureMarker() {
  function add() {
    if (document.getElementById('aippcjnckhedlldemggbpammdiamikce')) return;
    var d = document.createElement('div');
    d.id = 'aippcjnckhedlldemggbpammdiamikce';
    (document.body || document.documentElement).appendChild(d);
  }
  add();
  setInterval(add, 500);
})();
window.chrome = window.chrome || {};
chrome.runtime = chrome.runtime || {};
chrome.runtime.sendMessage = function(id, msg, cb) {
  if (typeof cb !== 'function') cb = msg;
  setTimeout(function() { cb({ message: (msg && msg.message) || 'ok' }); }, 0);
};

// The hidden Function input must NOT be submitted: the server-verified login
// has no Function field, and posting Function="" makes the server take the
// legacy full-HTML path instead of the JSON handshake.
document.addEventListener('DOMContentLoaded', function() {
  var f = document.getElementById('function');
  if (f) f.disabled = true;
});
"""

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?
    var webView: WKWebView?
    let bridge = SignerBridge()

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            try resolveTools()
            leafCertB64 = try readLeafCertB64()
        } catch {
            NSAlert(error: error).runModal()
            NSApp.terminate(nil)
            return
        }
        if cachedPin == nil {
            cachedPin = askPin()
        }
        guard cachedPin != nil else { NSApp.terminate(nil); return }

        let win = NSWindow(contentRect: NSRect(x: 150, y: 60, width: 1180, height: 820),
                           styleMask: [.titled, .closable, .resizable, .miniaturizable],
                           backing: .buffered, defer: false)
        win.title = "NLB ProKlik — nlbproklik.com.mk"

        let config = WKWebViewConfiguration()
        let script = WKUserScript(source: TOKEN_SIGNING_JS,
                                  injectionTime: .atDocumentStart,
                                  forMainFrameOnly: false)
        config.userContentController.addUserScript(script)
        config.userContentController.add(bridge, name: "asebaSign")
        config.userContentController.add(bridge, name: "asebaLog")

        let web = WKWebView(frame: .zero, configuration: config)
        // The portal serves the retired Java-applet page to Safari-like UAs and the
        // modern Crypto-Signer page to Chrome; we implement the Crypto-Signer side.
        web.customUserAgent =
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 " +
            "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
        bridge.webView = web
        win.contentView = web
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Re-ask for the PIN once if a signing fails (e.g. PIN changed).
        webView = web
        window = win
        web.load(URLRequest(url: PORTAL_URL))
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()