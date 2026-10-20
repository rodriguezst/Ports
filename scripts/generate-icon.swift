import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)

        let background = NSBezierPath(roundedRect: NSRect(x: 80, y: 80, width: 864, height: 864), xRadius: 192, yRadius: 192)
        let gradient = NSGradient(starting: NSColor(calibratedRed: 0.14, green: 0.68, blue: 0.86, alpha: 1),
                                  ending: NSColor(calibratedRed: 0.14, green: 0.32, blue: 0.86, alpha: 1))!
        gradient.draw(in: background, angle: -70)

        NSColor.white.setStroke()
        for (y, pointsRight) in [(CGFloat(640), true), (CGFloat(384), false)] {
            let path = NSBezierPath()
            path.lineWidth = 64
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.move(to: NSPoint(x: pointsRight ? 288 : 736, y: y))
            path.line(to: NSPoint(x: pointsRight ? 736 : 288, y: y))
            path.move(to: NSPoint(x: pointsRight ? 608 : 416, y: y + 120))
            path.line(to: NSPoint(x: pointsRight ? 736 : 288, y: y))
            path.line(to: NSPoint(x: pointsRight ? 608 : 416, y: y - 120))
            path.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        let url = output.appendingPathComponent("icon_\(size)x\(size)\(suffix).png")
        try bitmap.representation(using: .png, properties: [:])!.write(to: url)
    }
}
