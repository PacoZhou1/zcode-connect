import AppKit

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
let terminal = NSBezierPath(roundedRect: NSRect(x: 194, y: 238, width: 636, height: 548), xRadius: 128, yRadius: 128)
NSColor.white.withAlphaComponent(0.16).setFill()
terminal.fill()
NSColor.white.withAlphaComponent(0.9).setStroke()
terminal.lineWidth = 9
terminal.stroke()
let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 326, y: 583))
arrow.line(to: NSPoint(x: 422, y: 490))
arrow.line(to: NSPoint(x: 326, y: 399))
arrow.lineWidth = 49
arrow.lineCapStyle = .round
arrow.lineJoinStyle = .round
NSColor.white.setStroke()
arrow.stroke()
let cursor = NSBezierPath()
cursor.move(to: NSPoint(x: 503, y: 401))
cursor.line(to: NSPoint(x: 677, y: 401))
cursor.lineWidth = 49
cursor.lineCapStyle = .round
cursor.stroke()
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
