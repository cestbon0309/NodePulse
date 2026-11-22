import AppKit

let size = 1024
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
let rect = NSRect(x: 0, y: 0, width: size, height: size)
NSGradient(colors: [NSColor(red: 0.025, green: 0.12, blue: 0.18, alpha: 1), NSColor(red: 0.04, green: 0.34, blue: 0.37, alpha: 1)])!.draw(in: rect, angle: 45)
let glow = NSBezierPath(ovalIn: NSRect(x: 160, y: 160, width: 704, height: 704))
NSColor.white.withAlphaComponent(0.035).setFill(); glow.fill()
let path = NSBezierPath()
path.move(to: NSPoint(x: 180, y: 500))
for p in [(340,500),(414,680),(510,310),(610,590),(670,500),(844,500)] { path.line(to: NSPoint(x: p.0, y: p.1)) }
path.lineWidth = 48; path.lineCapStyle = .round; path.lineJoinStyle = .round
NSColor(red: 0.35, green: 0.98, blue: 0.79, alpha: 1).setStroke(); path.stroke()
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "NodePulse/Assets.xcassets/AppIcon.appiconset/icon.png"))
