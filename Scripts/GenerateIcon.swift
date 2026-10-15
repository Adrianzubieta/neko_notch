import AppKit
let folder = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let transform = NSAffineTransform(); transform.scale(by: CGFloat(pixels) / 1024); transform.concat()
        let background = NSBezierPath(roundedRect: NSRect(x: 62, y: 62, width: 900, height: 900), xRadius: 210, yRadius: 210)
        NSGradient(starting: NSColor(calibratedRed: 0.12, green: 0.18, blue: 0.23, alpha: 1), ending: NSColor(calibratedWhite: 0.035, alpha: 1))!.draw(in: background, angle: -90)
        let cat = NSBezierPath()
        cat.move(to: NSPoint(x: 260, y: 525))
        cat.line(to: NSPoint(x: 255, y: 775)); cat.line(to: NSPoint(x: 414, y: 669))
        cat.curve(to: NSPoint(x: 610, y: 669), controlPoint1: NSPoint(x: 475, y: 690), controlPoint2: NSPoint(x: 549, y: 690))
        cat.line(to: NSPoint(x: 769, y: 775)); cat.line(to: NSPoint(x: 764, y: 525))
        cat.curve(to: NSPoint(x: 512, y: 280), controlPoint1: NSPoint(x: 795, y: 365), controlPoint2: NSPoint(x: 670, y: 280))
        cat.curve(to: NSPoint(x: 260, y: 525), controlPoint1: NSPoint(x: 354, y: 280), controlPoint2: NSPoint(x: 229, y: 365)); cat.close()
        NSColor(calibratedRed: 0.4, green: 0.9, blue: 0.79, alpha: 1).setFill(); cat.fill()
        NSColor(calibratedWhite: 0.06, alpha: 1).setFill()
        for x in [385, 590] { NSBezierPath(roundedRect: NSRect(x: x, y: 465, width: 48, height: 95), xRadius: 24, yRadius: 24).fill() }
        let nose = NSBezierPath(); nose.move(to: NSPoint(x: 485, y: 420)); nose.line(to: NSPoint(x: 539, y: 420)); nose.line(to: NSPoint(x: 512, y: 394)); nose.close(); nose.fill()
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent(name))
    }
}
// Modern ICNS stores PNG representations in a tagged, big-endian container.
func number(_ value: Int) -> Data {
    var encoded = UInt32(value).bigEndian
    return withUnsafeBytes(of: &encoded) { Data($0) }
}
var representations = Data()
for (tag, file) in [("icp4", "icon_16x16.png"), ("icp5", "icon_32x32.png"), ("icp6", "icon_32x32@2x.png"), ("ic07", "icon_128x128.png"), ("ic08", "icon_256x256.png"), ("ic09", "icon_512x512.png"), ("ic10", "icon_512x512@2x.png")] {
    let png = try Data(contentsOf: folder.appendingPathComponent(file))
    representations.append(Data(tag.utf8)); representations.append(number(png.count + 8)); representations.append(png)
}
var icon = Data("icns".utf8); icon.append(number(representations.count + 8)); icon.append(representations)
try icon.write(to: folder.deletingLastPathComponent().appendingPathComponent("AppIcon.icns"))
