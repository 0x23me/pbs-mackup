// Draws Resources/AppIcon.icns: a clock whose rim runs backwards, on a disk-blue square.
//   swift Scripts/icon.swift
import AppKit

func draw(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    // The macOS icon grid: an 824/1024 rounded square, centred.
    let inset = s * 100 / 1024
    let box = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let shape = NSBezierPath(roundedRect: box, xRadius: box.width * 0.225, yRadius: box.width * 0.225)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowBlurRadius = s * 0.02
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.008)
    shadow.set()
    NSColor.white.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()
    shape.addClip()
    NSGradient(colors: [NSColor(srgbRed: 0.16, green: 0.42, blue: 0.56, alpha: 1),
                        NSColor(srgbRed: 0.07, green: 0.20, blue: 0.33, alpha: 1)])!.draw(in: box, angle: -90)

    let centre = NSPoint(x: box.midX, y: box.midY)
    let radius = box.width * 0.30
    let ink = NSColor(srgbRed: 0.96, green: 0.97, blue: 0.95, alpha: 1)
    ink.setStroke()
    ink.setFill()
    // The rim: three quarters of a circle from the upper left round by the right to the lower
    // left, with an arrowhead at the upper left end that points the way a clock does not go.
    let rim = NSBezierPath()
    rim.appendArc(withCenter: centre, radius: radius, startAngle: 130, endAngle: 220, clockwise: true)
    rim.lineWidth = box.width * 0.075
    rim.lineCapStyle = .round
    rim.stroke()
    let tip = NSPoint(x: centre.x + radius * cos(130 * .pi / 180), y: centre.y + radius * sin(130 * .pi / 180))
    let head = NSBezierPath()
    let size = box.width * 0.105
    // The head points anticlockwise: along the tangent at 130 degrees plus a quarter turn.
    let along = (130.0 + 90) * .pi / 180
    func at(_ forward: CGFloat, _ sideways: CGFloat) -> NSPoint {
        NSPoint(x: tip.x + forward * cos(along) - sideways * sin(along), y: tip.y + forward * sin(along) + sideways * cos(along))
    }
    head.move(to: at(size * 1.05, 0))
    head.line(to: at(-size * 0.35, size))
    head.line(to: at(-size * 0.35, -size))
    head.close()
    head.fill()
    // The hands.
    let hands = NSBezierPath()
    hands.move(to: NSPoint(x: centre.x, y: centre.y + radius * 0.58))
    hands.line(to: centre)
    hands.line(to: NSPoint(x: centre.x + radius * 0.42, y: centre.y - radius * 0.24))
    hands.lineWidth = box.width * 0.065
    hands.lineCapStyle = .round
    hands.lineJoinStyle = .round
    hands.stroke()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let set = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "AppIcon.iconset")
try? FileManager.default.removeItem(at: set)
try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    try! draw(size).write(to: set.appending(path: "icon_\(size)x\(size).png"))
    try! draw(size * 2).write(to: set.appending(path: "icon_\(size)x\(size)@2x.png"))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", set.path, "-o", "Resources/AppIcon.icns"]
try! iconutil.run()
iconutil.waitUntilExit()
try! draw(1024).write(to: URL(fileURLWithPath: "Resources/AppIcon.png"))
