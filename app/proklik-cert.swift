// proklik-cert — reads the signer's leaf certificate off a PKCS#11 token.
// Usage: proklik-cert [--all] <path-to-pkcs11-module>
// Prints base64 DER of the chosen leaf certificate to stdout.
//
// Leaf selection: a candidate must contain the first keyword and none of the
// remaining keywords (PROKLIK_CERT_SUBJECT env overrides; default assumes a
// qualified personal certificate with a serialNumber= attribute and no CA
// markers). Falls back to the first certificate found.

import Foundation

typealias CK_RV = UInt64
typealias CK_SLOT_ID = UInt64
typealias CK_SESSION_HANDLE = UInt64
typealias CK_OBJECT_HANDLE = UInt64
typealias CK_ULONG = UInt64
let CKR_OK: CK_RV = 0
let CKF_SERIAL_SESSION: CK_ULONG = 2
let CKF_RW_SESSION: CK_ULONG = 4
let CKA_CLASS: CK_ULONG = 0
let CKA_VALUE: CK_ULONG = 17
let CKO_CERTIFICATE: CK_ULONG = 1

struct CK_TEMPLATE {
    var type: CK_ULONG
    var pValue: UnsafeMutableRawPointer?
    var ulValueLen: CK_ULONG
}

func err(_ msg: String) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(1)
}

func keywords() -> (inKeywords: [String], notKeywords: [String]) {
    let s = ProcessInfo.processInfo.environment["PROKLIK_CERT_SUBJECT"]
    let parts = (s ?? "serialNumber=,CA").split(separator: ",").map(String.init)
    if let first = parts.first {
        return ([first], Array(parts.dropFirst()))
    }
    return (["serialNumber="], ["CA"])
}

/// openssl renders the human-readable subject; the leaf selection works on that text.
func subjectText(_ der: Data) -> String {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nb.cer")
    try? der.write(to: tmp)
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
    proc.arguments = ["x509", "-in", tmp.path, "-inform", "DER", "-noout", "-subject"]
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = Pipe()
    _ = try? proc.run()
    proc.waitUntilExit()
    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                     encoding: .utf8) ?? ""
    return out
}

func isLeaf(_ der: Data, kw: (inKeywords: [String], notKeywords: [String])) -> Bool {
    let subject = subjectText(der)
    return kw.inKeywords.allSatisfy { subject.contains($0) } &&
        kw.notKeywords.allSatisfy { subject.range(of: $0, options: .caseInsensitive) == nil }
}

func certs(_ modulePath: String) -> [Data] {
    guard let lib = dlopen(modulePath, RTLD_NOW) else {
        err("Cannot load module \(modulePath)")
    }
    typealias FInit = @convention(c) (UnsafeMutableRawPointer?) -> CK_RV
    typealias FFinal = @convention(c) (UnsafeMutableRawPointer?) -> CK_RV
    typealias FSlotList = @convention(c) (UInt8, UnsafeMutablePointer<CK_SLOT_ID>?,
                                          UnsafeMutablePointer<CK_ULONG>?) -> CK_RV
    typealias FOpenSession = @convention(c) (CK_SLOT_ID, CK_ULONG,
                                             UnsafeMutableRawPointer?, UnsafeMutableRawPointer?,
                                             UnsafeMutablePointer<CK_SESSION_HANDLE>) -> CK_RV
    typealias FFindInit = @convention(c) (CK_SESSION_HANDLE, UnsafeRawPointer?, CK_ULONG) -> CK_RV
    typealias FFind = @convention(c) (CK_SESSION_HANDLE,
                                      UnsafeMutablePointer<CK_OBJECT_HANDLE>, CK_ULONG,
                                      UnsafeMutablePointer<CK_ULONG>) -> CK_RV
    typealias FFindFinal = @convention(c) (CK_SESSION_HANDLE) -> CK_RV
    typealias FGetAttr = @convention(c) (CK_SESSION_HANDLE, CK_OBJECT_HANDLE,
                                         UnsafeMutableRawPointer?, CK_ULONG) -> CK_RV
    func f<T>(_ name: String) -> T {
        guard let p = dlsym(lib, name) else { err("pkcs11 missing \(name)") }
        return unsafeBitCast(p, to: T.self)
    }
    let cInit: FInit = f("C_Initialize")
    let cFinal: FFinal = f("C_Finalize")
    let cSlots: FSlotList = f("C_GetSlotList")
    let cOpen: FOpenSession = f("C_OpenSession")
    let cFindInit: FFindInit = f("C_FindObjectsInit")
    let cFind: FFind = f("C_FindObjects")
    let cFindFinal: FFindFinal = f("C_FindObjectsFinal")
    let cAttr: FGetAttr = f("C_GetAttributeValue")

    // Tolerate CKR_CRYPTOKI_ALREADY_INITIALIZED (other middleware may be loaded).
    let rv = cInit(nil)
    if rv != CKR_OK && rv != 0x191 {
        err("C_Initialize failed: \(rv)")
    }
    defer { _ = cFinal(nil) }

    var slots = [CK_SLOT_ID](repeating: 0, count: 16)
    var slotCount = CK_ULONG(0)
    // Two-phase call: SafeNet middleware returns CKR_BUFFER_TOO_SMALL if the
    // size query (nil buffer) hasn't run first.
    _ = cSlots(1, nil, &slotCount)
    let listRv = cSlots(1, &slots, &slotCount)
    if ProcessInfo.processInfo.environment["PROKLIK_DEBUG"] != nil {
        FileHandle.standardError.write("debug: init=\(rv) list=\(listRv) slots=\(slotCount)\n".data(using: .utf8)!)
    }
    guard listRv == CKR_OK, slotCount > 0 else {
        err("No token present — is the reader + token plugged in?")
    }
    var session = CK_SESSION_HANDLE(0)
    // SafeNet middleware rejects a plain serial-only session; open R/W like
    // pkcs11-tool does.
    guard cOpen(slots[0], CKF_SERIAL_SESSION | CKF_RW_SESSION, nil, nil, &session) == CKR_OK else {
        err("C_OpenSession failed")
    }
    let classBuf = UnsafeMutableRawPointer.allocate(byteCount: MemoryLayout<CK_ULONG>.size,
                                                    alignment: MemoryLayout<CK_ULONG>.alignment)
    classBuf.storeBytes(of: CKO_CERTIFICATE, as: CK_ULONG.self)
    defer { classBuf.deallocate() }
    var tmpl = CK_TEMPLATE(type: CKA_CLASS, pValue: classBuf,
                           ulValueLen: CK_ULONG(MemoryLayout<CK_ULONG>.size))
    guard cFindInit(session, &tmpl, 1) == CKR_OK else { err("C_FindObjectsInit failed") }
    defer { _ = cFindFinal(session) }

    var handles = [CK_OBJECT_HANDLE](repeating: 0, count: 64)
    var found = CK_ULONG(0)
    guard cFind(session, &handles, CK_ULONG(64), &found) == CKR_OK, found > 0 else {
        err("No certificates found on token")
    }
    var out = [Data]()
    for h in handles.prefix(Int(found)) {
        var lenTpl = CK_TEMPLATE(type: CKA_VALUE, pValue: nil, ulValueLen: 0)
        _ = cAttr(session, h, &lenTpl, 1)
        let len = Int(lenTpl.ulValueLen)
        if len <= 0 || len > 1_000_000 { continue }
        let buf = UnsafeMutableRawPointer.allocate(byteCount: len, alignment: 1)
        defer { buf.deallocate() }
        lenTpl.pValue = buf
        lenTpl.ulValueLen = CK_ULONG(len)
        guard cAttr(session, h, &lenTpl, 1) == CKR_OK else { continue }
        out.append(Data(bytes: buf, count: len))
    }
    return out
}

let args = CommandLine.arguments
let all = args.contains("--all")
guard let module = args.last(where: { !$0.hasPrefix("-") }) else {
    err("usage: proklik-cert [--all] <path-to-pkcs11-module>")
}

let list = certs(module)
guard !list.isEmpty else { err("No certificates found on token") }
let kw = keywords()
let leaf = list.first { isLeaf($0, kw: kw) } ?? list[0]

if all {
    // Debug listing: one base64 DER per line.
    for c in list { print(c.base64EncodedString()) }
    exit(0)
}
print(leaf.base64EncodedString())