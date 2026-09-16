import AppKit

// MirrorAgent icon: purple gradient + a Mac screen mirroring into a phone.
let output = CommandLine.arguments[1]
let size = CGSize(width: 1024, height: 1024)
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
let gradient = NSGradient(colors: [
    NSColor(srgbRed: 0.74, green: 0.52, blue: 1, alpha: 1),
    NSColor(srgbRed: 0.49, green: 0.25, blue: 0.89, alpha: 1)
])!
gradient.draw(in: NSRect(origin: .zero, size: size), angle: -70)

// Mac display
let display = NSBezierPath(roundedRect: NSRect(x: 130, y: 430, width: 560, height: 400), xRadius: 46, yRadius: 46)
NSColor.white.withAlphaComponent(0.16).setFill()
display.fill()
NSColor.white.withAlphaComponent(0.9).setStroke()
display.lineWidth = 13
display.stroke()
// stand
let stand = NSBezierPath()
stand.move(to: NSPoint(x: 410, y: 430))
stand.line(to: NSPoint(x: 410, y: 372))
stand.lineWidth = 13
stand.lineCapStyle = .round
NSColor.white.withAlphaComponent(0.9).setStroke()
let foot = NSBezierPath()
foot.move(to: NSPoint(x: 320, y: 360))
foot.line(to: NSPoint(x: 500, y: 360))
foot.lineWidth = 13
foot.lineCapStyle = .round
NSColor.white.withAlphaComponent(0.9).setStroke()

// arrow from display to phone
let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 560, y: 420))
arrow.curve(to: NSPoint(x: 700, y: 330), controlPoint1: NSPoint(x: 640, y: 420), controlPoint2: NSPoint(x: 700, y: 400))
arrow.lineWidth = 15
arrow.lineCapStyle = .round
NSColor.white.setStroke()
arrow.stroke()
let head = NSBezierPath()
head.move(to: NSPoint(x: 668, y: 344))
head.line(to: NSPoint(x: 704, y: 326))
head.line(to: NSPoint(x: 702, y: 364))
head.lineWidth = 15
head.lineCapStyle = .round
head.lineJoinStyle = .round
NSColor.white.setStroke()
head.stroke()

// phone
let phone = NSBezierPath(roundedRect: NSRect(x: 640, y: 110, width: 250, height: 480), xRadius: 52, yRadius: 52)
NSColor.white.withAlphaComponent(0.22).setFill()
phone.fill()
NSColor.white.withAlphaComponent(0.95).setStroke()
phone.lineWidth = 13

NSGraphicsContext.restoreGraphicsState()
guard let png = bitmap.representation(using: .png, properties: [:]) else {
    print("png representation failed"); exit(1)
}
try! png.write(to: URL(fileURLWithPath: output))
print("icon written: \(output)")
