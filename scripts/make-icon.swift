#!/usr/bin/env swift
// Generates the app icon PNGs. Run from the repository root:
//   swift scripts/make-icon.swift
import AppKit
import Foundation

let size = 1024.0
let outputDirectory = URL(fileURLWithPath: "GameSaveSync/Resources/Assets.xcassets/AppIcon.appiconset")
try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

func makeIcon() -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    guard let context = NSGraphicsContext.current?.cgContext else { return image }

    // Background: rounded square with a vertical gradient.
    let rect = CGRect(x: 0, y: 0, width: size, height: size)
    let path = CGPath(roundedRect: rect.insetBy(dx: 40, dy: 40), cornerWidth: 220, cornerHeight: 220, transform: nil)
    context.saveGState()
    context.addPath(path)
    context.clip()
    let colors = [
        NSColor(srgbRed: 0.19, green: 0.33, blue: 0.86, alpha: 1).cgColor,
        NSColor(srgbRed: 0.36, green: 0.60, blue: 0.98, alpha: 1).cgColor,
    ] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
    context.drawLinearGradient(gradient,
                               start: CGPoint(x: 0, y: size),
                               end: CGPoint(x: size, y: 0),
                               options: [])
    context.restoreGState()

    // Cloud shape.
    let cloud = CGMutablePath()
    cloud.addEllipse(in: CGRect(x: 210, y: 430, width: 300, height: 300))
    cloud.addEllipse(in: CGRect(x: 380, y: 490, width: 380, height: 380))
    cloud.addEllipse(in: CGRect(x: 560, y: 420, width: 290, height: 290))
    cloud.addRect(CGRect(x: 350, y: 470, width: 400, height: 250))
    context.setFillColor(NSColor.white.withAlphaComponent(0.96).cgColor)
    context.addPath(cloud)
    context.fillPath()

    // Two opposing arrows underneath: the "sync" half of the mark.
    context.setFillColor(NSColor.white.cgColor)
    context.setStrokeColor(NSColor.white.cgColor)
    context.setLineWidth(40)
    context.setLineCap(.round)

    let forwardShaft = CGMutablePath()
    forwardShaft.move(to: CGPoint(x: 300, y: 356))
    forwardShaft.addLine(to: CGPoint(x: 630, y: 356))
    context.addPath(forwardShaft)
    context.strokePath()

    let forwardHead = CGMutablePath()
    forwardHead.move(to: CGPoint(x: 704, y: 356))
    forwardHead.addLine(to: CGPoint(x: 612, y: 414))
    forwardHead.addLine(to: CGPoint(x: 612, y: 298))
    forwardHead.closeSubpath()
    context.addPath(forwardHead)
    context.fillPath()

    let backwardShaft = CGMutablePath()
    backwardShaft.move(to: CGPoint(x: 724, y: 216))
    backwardShaft.addLine(to: CGPoint(x: 394, y: 216))
    context.addPath(backwardShaft)
    context.strokePath()

    let backwardHead = CGMutablePath()
    backwardHead.move(to: CGPoint(x: 320, y: 216))
    backwardHead.addLine(to: CGPoint(x: 412, y: 274))
    backwardHead.addLine(to: CGPoint(x: 412, y: 158))
    backwardHead.closeSubpath()
    context.addPath(backwardHead)
    context.fillPath()

    image.unlockFocus()
    return image
}

let image = makeIcon()
guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("Could not render the icon")
}
try png.write(to: outputDirectory.appendingPathComponent("icon-1024.png"))
print("wrote icon-1024.png")

// Downscale for macOS icon slots.
let sizes: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
let source = outputDirectory.appendingPathComponent("icon-1024.png")
for (name, dimension) in sizes {
    let target = outputDirectory.appendingPathComponent(name)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
    process.arguments = ["-z", "\(dimension)", "\(dimension)", source.path, "--out", target.path]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
}
print("wrote macOS icon sizes")

// Normalise the master to exactly 1024 px (lockFocus can render at 2x).
do {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
    process.arguments = ["-z", "1024", "1024", source.path, "--out", source.path]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
}
print("normalised master icon")
