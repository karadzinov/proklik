// Generates the app icon: rounded blue square, white bank glyph, USB token chip.
import AppKit

let size = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                           isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// Background: vertical gradient in NLB-style blues, rounded corners.
NSColor(srgbRed: 0.008, green: 0.286, blue: 0.482, alpha: 1).set()
let bg = NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896),
                      xRadius: 200, yRadius: 200)
bg.fill()

let grad = NSGradient(colors: [
    NSColor(srgbRed: 0.008, green: 0.286, blue: 0.482, alpha: 1),
    NSColor(srgbRed: 0.012, green: 0.412, blue: 0.631, alpha: 1)])!
grad.draw(in: bg, angle: -70)

// Bank glyph (white, centered).
NSColor.white.setFill()
let cx: CGFloat = 512
// Pediment triangle
let ped = NSBezierPath()
ped.move(to: NSPoint(x: cx - 260, y: 700))
ped.line(to: NSPoint(x: cx, y: 790))
ped.line(to: NSPoint(x: cx + 260, y: 700))
ped.close()
ped.fill()
// Lintel beam
NSRect(x: cx - 280, y: 655, width: 560, height: 34).fill()
// Columns
for i in 0..<4 {
    let w: CGFloat = 78
    let gap: CGFloat = 66
    let x = cx - 2*(w+gap) + gap/2 + CGFloat(i)*(w+gap) + gap/2
    let col = NSBezierPath(roundedRect: NSRect(x: x, y: 400, width: w, height: 240),
                           xRadius: 10, yRadius: 10)
    col.fill()
}
// Base
NSRect(x: cx - 300, y: 330, width: 600, height: 38).fill()
NSRect(x: cx - 330, y: 296, width: 660, height: 30).fill()

// Token chip (gold) with keyhole, overlapping bottom-right — the USB token.
let chip = NSBezierPath(roundedRect: NSRect(x: 600, y: 96, width: 330, height: 150),
                        xRadius: 34, yRadius: 34)
NSColor(srgbRed: 0.86, green: 0.65, blue: 0.13, alpha: 1).set()
chip.fill()
NSColor(srgbRed: 0.35, green: 0.22, blue: 0.05, alpha: 1).set()
let hole = NSBezierPath()
hole.appendArc(withCenter: NSPoint(x: 700, y: 171), radius: 26, startAngle: 0, endAngle: 360)
hole.fill()
NSRect(x: 726, y: 165, width: 40, height: 12).fill()
NSRect(x: 764, y: 149, width: 130, height: 44).fill() // contacts

NSGraphicsContext.restoreGraphicsState()

let png = rep.representation(using: .png, properties: [:])!
let out = URL(fileURLWithPath: CommandLine.arguments.count > 1
    ? CommandLine.arguments[1] : "icon_1024.png")
try! png.write(to: out)
print("wrote \(out.path)")