import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".")
let resources = output.appendingPathComponent("Resources")
let iconset = output.appendingPathComponent(".build/FolderBackup.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)

func render(_ size: Int) -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let context = NSGraphicsContext.current!.cgContext
    context.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    let tile = NSBezierPath(roundedRect: NSRect(x: 42, y: 42, width: 940, height: 940), xRadius: 210, yRadius: 210)
    NSGradient(starting: NSColor(red: 0.99, green: 0.995, blue: 1, alpha: 1), ending: NSColor(red: 0.87, green: 0.93, blue: 1, alpha: 1))!.draw(in: tile, angle: -90)
    NSColor(red: 0.80, green: 0.86, blue: 0.94, alpha: 1).setStroke()
    tile.lineWidth = 2; tile.stroke()

    let folder = NSBezierPath()
    folder.move(to: NSPoint(x: 198, y: 302))
    folder.line(to: NSPoint(x: 198, y: 685))
    folder.curve(to: NSPoint(x: 247, y: 734), controlPoint1: NSPoint(x: 198, y: 719), controlPoint2: NSPoint(x: 214, y: 734))
    folder.line(to: NSPoint(x: 402, y: 734))
    folder.curve(to: NSPoint(x: 451, y: 711), controlPoint1: NSPoint(x: 427, y: 734), controlPoint2: NSPoint(x: 437, y: 726))
    folder.line(to: NSPoint(x: 482, y: 678))
    folder.line(to: NSPoint(x: 779, y: 678))
    folder.curve(to: NSPoint(x: 828, y: 629), controlPoint1: NSPoint(x: 812, y: 678), controlPoint2: NSPoint(x: 828, y: 662))
    folder.line(to: NSPoint(x: 828, y: 302)); folder.close()
    NSColor(red: 0.83, green: 0.57, blue: 0.18, alpha: 1).setFill(); folder.fill()
    let front = NSBezierPath(roundedRect: NSRect(x: 190, y: 276, width: 646, height: 354), xRadius: 48, yRadius: 48)
    NSGradient(starting: NSColor(red: 1, green: 0.84, blue: 0.41, alpha: 1), ending: NSColor(red: 0.96, green: 0.69, blue: 0.23, alpha: 1))!.draw(in: front, angle: -90)
    let seam = NSBezierPath(); seam.move(to: NSPoint(x: 232, y: 605)); seam.line(to: NSPoint(x: 790, y: 605))
    seam.lineWidth = 5; seam.lineCapStyle = .round
    NSColor.white.withAlphaComponent(0.45).setStroke(); seam.stroke()

    let badge = NSBezierPath(ovalIn: NSRect(x: 601, y: 204, width: 244, height: 244))
    NSColor(red: 0.06, green: 0.27, blue: 0.56, alpha: 1).setFill(); badge.fill()
    NSColor(red: 0.94, green: 0.97, blue: 1, alpha: 1).setStroke(); badge.lineWidth = 16; badge.stroke()
    let check = NSBezierPath(); check.move(to: NSPoint(x: 664, y: 327)); check.line(to: NSPoint(x: 707, y: 283)); check.line(to: NSPoint(x: 782, y: 365))
    check.lineWidth = 23; check.lineCapStyle = .round; check.lineJoinStyle = .round
    NSColor.white.setStroke(); check.stroke()
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try render(size).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(size * 2).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
try render(1024).write(to: resources.appendingPathComponent("FolderBackupMark.png"))
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", resources.appendingPathComponent("FolderBackup.icns").path]
try iconutil.run(); iconutil.waitUntilExit()
precondition(iconutil.terminationStatus == 0)
print("Folder Backup icon generated")
