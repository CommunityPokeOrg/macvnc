// Minimal RFB (VNC) server for the local console display.
// Serves RFB 3.8 with VNC-auth (security type 2) on 127.0.0.1.
// Captures the real screen via CGDisplayCreateImage, injects input via CGEvent.
// Usage: rfbvnc <port> <password>
import Foundation
import CoreGraphics
import AppKit
import CommonCrypto
import ScreenCaptureKit
import CoreMedia
import CoreVideo

let port = UInt16(CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "") ?? 5901
let vncPassword = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "changeme"

signal(SIGPIPE, SIG_IGN)

// MARK: - socket helpers

func readAll(_ fd: Int32, _ n: Int) -> Data? {
    var buf = Data(count: n)
    var got = 0
    let ok = buf.withUnsafeMutableBytes { ptr -> Bool in
        while got < n {
            let r = read(fd, ptr.baseAddress!.advanced(by: got), n - got)
            if r <= 0 { return false }
            got += r
        }
        return true
    }
    return ok ? buf : nil
}

func writeAll(_ fd: Int32, _ data: Data) -> Bool {
    var sent = 0
    return data.withUnsafeBytes { ptr -> Bool in
        while sent < data.count {
            let w = send(fd, ptr.baseAddress!.advanced(by: sent), data.count - sent, MSG_NOSIGNAL)
            if w <= 0 { return false }
            sent += w
        }
        return true
    }
}

// MARK: - DES VNC auth

func vncKey(_ password: String) -> [UInt8] {
    func bitrev(_ b: UInt8) -> UInt8 {
        var r: UInt8 = 0, v = b
        for _ in 0..<8 { r = (r << 1) | (v & 1); v >>= 1 }
        return r
    }
    var k = [UInt8](repeating: 0, count: 8)
    let bytes = Array(password.utf8)
    for i in 0..<8 { if i < bytes.count { k[i] = bitrev(bytes[i]) } }
    return k
}

func desEncrypt(_ key: [UInt8], _ block: [UInt8]) -> [UInt8]? {
    let outCap = block.count + kCCBlockSizeDES
    var out = [UInt8](repeating: 0, count: outCap)
    var outLen = 0
    let status = key.withUnsafeBytes { kp in
        block.withUnsafeBytes { bp in
            out.withUnsafeMutableBytes { op in
                CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmDES), CCOptions(kCCOptionECBMode),
                        kp.baseAddress, key.count, nil, bp.baseAddress, block.count,
                        op.baseAddress, outCap, &outLen)
            }
        }
    }
    guard status == kCCSuccess else { return nil }
    return Array(out.prefix(outLen))
}

// MARK: - screen capture

struct Frame {
    let width: Int, height: Int, pixels: Data // BGRA
}

final class FrameGrabber: NSObject, SCStreamOutput {
    var latest = Data()
    var w = 0, h = 0
    private let lock = NSLock()

    func current() -> Frame? {
        lock.lock(); defer { lock.unlock() }
        guard w > 0, !latest.isEmpty else { return nil }
        return Frame(width: w, height: h, pixels: latest)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen, let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        let pw = CVPixelBufferGetWidth(pb), ph = CVPixelBufferGetHeight(pb)
        var data = Data(count: pw * ph * 4)
        data.withUnsafeMutableBytes { dst in
            for y in 0..<ph {
                memcpy(dst.baseAddress!.advanced(by: y * pw * 4),
                       base.advanced(by: y * bpr), pw * 4)
            }
        }
        lock.lock(); latest = data; w = pw; h = ph; lock.unlock()
    }
}

let grabber = FrameGrabber()
var gStream: SCStream? // retained for process lifetime — dealloc stops capture

func startCapture() throws {
    let disp = CGMainDisplayID()
    let w = CGDisplayPixelsWide(disp), h = CGDisplayPixelsHigh(disp)
    let sem = DispatchSemaphore(value: 0)
    var startError: Error?
    Task {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false,
                                                                               onScreenWindowsOnly: false)
            guard let d = content.displays.first else {
                startError = NSError(domain: "rfbvnc", code: 1,
                                     userInfo: [NSLocalizedDescriptionKey: "no displays"])
                sem.signal(); return
            }
            let filter = SCContentFilter(display: d, excludingWindows: [])
            let cfg = SCStreamConfiguration()
            cfg.width = w; cfg.height = h
            cfg.pixelFormat = kCVPixelFormatType_32BGRA
            cfg.showsCursor = true
            cfg.queueDepth = 3
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: 15)
            let stream = SCStream(filter: filter, configuration: cfg, delegate: nil)
            try stream.addStreamOutput(grabber, type: .screen,
                                       sampleHandlerQueue: DispatchQueue(label: "rfbvnc.cap"))
            gStream = stream
            try await stream.startCapture()
        } catch { startError = error }
        sem.signal()
    }
    sem.wait()
    if let e = startError { throw e }
}

func captureFrame() -> Frame? { grabber.current() }

// MARK: - input

var curFlags: CGEventFlags = []

func postMouse(x: Int, y: Int, mask: UInt8) {
    let pt = CGPoint(x: x, y: y)
    struct Btn { let cg: CGMouseButton; let down: CGEventType; let up: CGEventType }
    // RFB mask bits: 1=left, 2=middle, 4=right
    let btns = [Btn(cg: .left, down: .leftMouseDown, up: .leftMouseUp),
                Btn(cg: .center, down: .otherMouseDown, up: .otherMouseUp),
                Btn(cg: .right, down: .rightMouseDown, up: .rightMouseUp)]
    for (i, b) in btns.enumerated() {
        let pressed = mask & UInt8(1 << i) != 0
        if let e = CGEvent(mouseEventSource: nil, mouseType: pressed ? b.down : b.up,
                           mouseCursorPosition: pt, mouseButton: b.cg) {
            e.flags = curFlags
            e.post(tap: .cghidEventTap)
        }
    }
    if mask & 8 != 0, let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 12, wheel2: 0, wheel3: 0) { e.post(tap: .cghidEventTap) }
    if mask & 16 != 0, let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -12, wheel2: 0, wheel3: 0) { e.post(tap: .cghidEventTap) }
    if let e = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: pt, mouseButton: .left) {
        e.flags = curFlags
        e.post(tap: .cghidEventTap)
    }
}

let keysymToCode: [UInt32: CGKeyCode] = [
    0xFF08: 51, 0xFF09: 48, 0xFF0D: 36, 0xFF1B: 53, 0xFFFF: 117,
    0xFF50: 115, 0xFF57: 119, 0xFF55: 116, 0xFF56: 121,
    0xFF51: 123, 0xFF52: 126, 0xFF53: 124, 0xFF54: 125,
    0xFFBE: 122, 0xFFBF: 120, 0xFFC0: 99, 0xFFC1: 118, 0xFFC2: 96, 0xFFC3: 97,
    0xFFC4: 98, 0xFFC5: 100, 0xFFC6: 101, 0xFFC7: 109, 0xFFC8: 103, 0xFFC9: 111,
    0xFFE1: 56, 0xFFE2: 60,
    0xFFE3: 59, 0xFFE4: 62,
    0xFFE9: 58, 0xFFEA: 61,
    0xFFEB: 55, 0xFFEC: 54,
]

func postKey(down: Bool, keysym: UInt32) {
    var ev: CGEvent?
    if let code = keysymToCode[keysym] {
        ev = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
    } else if keysym >= 0x20, let scalar = Unicode.Scalar(keysym) {
        ev = CGEvent(keyboardEventSource: nil, virtualKey: 49, keyDown: down)
        var utf16 = Array(String(scalar).utf16)
        ev?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
    }
    switch keysym {
    case 0xFFE1, 0xFFE2: if down { curFlags.insert(.maskShift) } else { curFlags.remove(.maskShift) }
    case 0xFFE3, 0xFFE4: if down { curFlags.insert(.maskControl) } else { curFlags.remove(.maskControl) }
    case 0xFFE9, 0xFFEA: if down { curFlags.insert(.maskAlternate) } else { curFlags.remove(.maskAlternate) }
    case 0xFFEB, 0xFFEC: if down { curFlags.insert(.maskCommand) } else { curFlags.remove(.maskCommand) }
    default: break
    }
    ev?.flags = curFlags
    ev?.post(tap: .cghidEventTap)
}

// MARK: - RFB protocol

func be32(_ v: UInt32) -> Data { Data([UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]) }
func be16(_ v: UInt16) -> Data { Data([UInt8(v >> 8), UInt8(v & 0xFF)]) }
func intBe(_ d: Data, _ off: Int) -> Int { Int(d[off]) << 24 | Int(d[off + 1]) << 16 | Int(d[off + 2]) << 8 | Int(d[off + 3]) }

func serverInit(w: Int, h: Int) -> Data {
    var d = Data()
    d.append(be16(UInt16(w))); d.append(be16(UInt16(h)))
    d.append(contentsOf: [32, 24, 0, 1])
    d.append(be16(255)); d.append(be16(255)); d.append(be16(255))
    d.append(contentsOf: [16, 8, 0, 0, 0, 0]) // rgb shifts + 3 pad = 16-byte pixelformat
    let name = "PokeVNC".data(using: .utf8)!
    d.append(be32(UInt32(name.count))); d.append(name)
    return d
}

func diffRects(prev: Frame?, cur: Frame) -> [CGRect] {
    guard let p = prev, p.width == cur.width, p.height == cur.height else {
        return [CGRect(x: 0, y: 0, width: cur.width, height: cur.height)]
    }
    let tile = 64
    let cols = (cur.width + tile - 1) / tile, rows = (cur.height + tile - 1) / tile
    var rects: [CGRect] = []
    p.pixels.withUnsafeBytes { pb in
        cur.pixels.withUnsafeBytes { cb in
            let a = pb.bindMemory(to: UInt32.self), b = cb.bindMemory(to: UInt32.self)
            var runStart = -1
            for r in 0..<rows {
                let y0 = r * tile, y1 = min(y0 + tile, cur.height)
                for c in 0..<cols {
                    let x0 = c * tile, x1 = min(x0 + tile, cur.width)
                    var dirty = false
                    for y in stride(from: y0, to: y1, by: 4) where !dirty {
                        var i = y * cur.width + x0
                        let end = y * cur.width + x1
                        while i < end { if a[i] != b[i] { dirty = true; break }; i += 1 }
                    }
                    if dirty {
                        if runStart < 0 { runStart = c }
                    } else if runStart >= 0 {
                        rects.append(CGRect(x: runStart * tile, y: y0,
                                            width: c * tile - runStart * tile, height: y1 - y0))
                        runStart = -1
                    }
                }
                if runStart >= 0 {
                    rects.append(CGRect(x: runStart * tile, y: y0,
                                        width: cur.width - runStart * tile, height: y1 - y0))
                    runStart = -1
                }
            }
        }
    }
    return rects
}

func sendFrame(_ fd: Int32, rects: [CGRect], frame: Frame) -> Bool {
    var d = Data()
    d.append(0); d.append(0)
    d.append(be16(UInt16(rects.count)))
    frame.pixels.withUnsafeBytes { raw in
        let px = raw.bindMemory(to: UInt8.self)
        for r in rects {
            let x0 = Int(r.minX), y0 = Int(r.minY), w = Int(r.width), h = Int(r.height)
            d.append(be16(UInt16(x0))); d.append(be16(UInt16(y0)))
            d.append(be16(UInt16(w))); d.append(be16(UInt16(h)))
            d.append(be32(0))
            for y in y0..<(y0 + h) {
                let off = y * frame.width * 4 + x0 * 4
                d.append(px.baseAddress!.advanced(by: off), count: w * 4)
            }
        }
    }
    return writeAll(fd, d)
}

func dbg(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

func handleClient(_ fd: Int32) {
    defer { close(fd) }
    dbg("client \(fd): connected")
    guard writeAll(fd, "RFB 003.008\n".data(using: .ascii)!) else { return }
    guard let _ = readAll(fd, 12) else { return }
    guard writeAll(fd, Data([1, 2])) else { return }
    guard let choice = readAll(fd, 1), choice[0] == 2 else { return }
    var challenge = [UInt8](repeating: 0, count: 16)
    _ = SecRandomCopyBytes(kSecRandomDefault, 16, &challenge)
    guard writeAll(fd, Data(challenge)) else { return }
    guard let response = readAll(fd, 16) else { return }
    let key = vncKey(vncPassword)
    var ok = true
    for half in 0..<2 {
        let ch = Array(challenge[half * 8..<half * 8 + 8])
        guard let enc = desEncrypt(key, ch),
              enc == Array(response[half * 8..<half * 8 + 8]) else { ok = false; break }
    }
    guard writeAll(fd, be32(ok ? 0 : 1)) else { return }
    dbg("client \(fd): auth=\(ok)")
    if !ok {
        let r = "auth failed".data(using: .utf8)!
        _ = writeAll(fd, be32(UInt32(r.count))); _ = writeAll(fd, r)
        return
    }
    guard let _ = readAll(fd, 1) else { return }
    let disp = CGMainDisplayID()
    let W = CGDisplayPixelsWide(disp), H = CGDisplayPixelsHigh(disp)
    guard writeAll(fd, serverInit(w: W, h: H)) else { return }

    var prev: Frame? = nil

    while true {
        guard let hdr = readAll(fd, 1) else { return }
        switch hdr[0] {
        case 0:
            guard let _ = readAll(fd, 19) else { return }
        case 1:
            guard let p = readAll(fd, 5) else { return }
            let count = Int(p[3]) << 8 | Int(p[4])
            guard let _ = readAll(fd, count * 6) else { return }
        case 2:
            guard let _ = readAll(fd, 1) else { return }
            guard let n = readAll(fd, 2) else { return }
            let count = Int(n[0]) << 8 | Int(n[1])
            if count > 0 { guard let _ = readAll(fd, count * 4) else { return } }
        case 3:
            guard let p = readAll(fd, 9) else { return }
            if let f = captureFrame() {
                let rects = diffRects(prev: p[0] == 0 ? nil : prev, cur: f)
                dbg("client \(fd): fbu \(rects.count) rects")
                if !sendFrame(fd, rects: rects, frame: f) { return }
                prev = f
            } else {
                dbg("client \(fd): capture nil")
                if !sendFrame(fd, rects: [], frame: Frame(width: W, height: H, pixels: Data())) { return }
            }
        case 4:
            guard let p = readAll(fd, 7) else { return }
            let keysym = UInt32(p[3]) << 24 | UInt32(p[4]) << 16 | UInt32(p[5]) << 8 | UInt32(p[6])
            postKey(down: p[0] == 1, keysym: keysym)
        case 5:
            guard let p = readAll(fd, 5) else { return }
            let x = Int(p[1]) << 8 | Int(p[2]), y = Int(p[3]) << 8 | Int(p[4])
            postMouse(x: x, y: y, mask: p[0])
        case 6:
            guard let p = readAll(fd, 7) else { return }
            let len = intBe(p, 3)
            guard let t = readAll(fd, len) else { return }
            if let s = String(data: t, encoding: .utf8) ?? String(data: t, encoding: .isoLatin1) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(s, forType: .string)
            }
        default:
            return
        }
    }
}

// MARK: - listener

do { try startCapture() } catch { fatalError("screen capture: \(error)") }

let lsock = socket(AF_INET, SOCK_STREAM, 0)
guard lsock >= 0 else { fatalError("socket") }
var one: Int32 = 1
setsockopt(lsock, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout.size(ofValue: one)))
var addr = sockaddr_in()
addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
addr.sin_family = sa_family_t(AF_INET)
addr.sin_port = port.bigEndian
addr.sin_addr.s_addr = UInt32(0x7F000001).bigEndian // 127.0.0.1 only
let bindOK = withUnsafePointer(to: &addr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(lsock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
    }
}
guard bindOK == 0 else { fatalError("bind 127.0.0.1:\(port): errno \(errno)") }
guard listen(lsock, 5) == 0 else { fatalError("listen") }
print("rfbvnc listening on 127.0.0.1:\(port)")
while true {
    let c = accept(lsock, nil, nil)
    if c >= 0 { Thread { handleClient(c) }.start() }
}
