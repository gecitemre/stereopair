// Draws the app icon and writes an .icns. Two cones facing outward from a
// shared centre: the whole idea of the app in a shape that still reads at 16pt,
// which is why there is no text in it.

import AppKit
import CoreGraphics
import Foundation

let sizes = [16, 32, 64, 128, 256, 512, 1024]

func draw(size: Int) -> Data {
    let dimension = CGFloat(size)
    let image = NSImage(size: NSSize(width: dimension, height: dimension))
    image.lockFocus()
    guard let context = NSGraphicsContext.current?.cgContext else { fatalError("no context") }

    let rect = CGRect(x: 0, y: 0, width: dimension, height: dimension)

    // Rounded-square background, the shape macOS expects, with a soft gradient.
    let inset = dimension * 0.06
    let body = rect.insetBy(dx: inset, dy: inset)
    let corner = dimension * 0.225
    let path = CGPath(roundedRect: body, cornerWidth: corner, cornerHeight: corner,
                      transform: nil)
    context.saveGState()
    context.addPath(path)
    context.clip()
    let colours = [
        CGColor(red: 0.13, green: 0.17, blue: 0.28, alpha: 1),
        CGColor(red: 0.05, green: 0.06, blue: 0.11, alpha: 1),
    ] as CFArray
    if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                 colors: colours, locations: [0, 1]) {
        context.drawLinearGradient(gradient,
                                   start: CGPoint(x: 0, y: dimension),
                                   end: CGPoint(x: 0, y: 0),
                                   options: [])
    }
    context.restoreGState()

    let centre = CGPoint(x: dimension / 2, y: dimension / 2)

    // Two cones, mirrored. Small sizes lose fine detail, so these are big,
    // solid shapes rather than anything intricate.
    // A wide gap down the middle is the point: two separate machines, not one
    // speaker. It also survives being scaled to 16pt, where the arcs blur away.
    let coneHeight = dimension * 0.26
    let coneWidth = dimension * 0.13
    let gap = dimension * 0.115

    for side in [-1.0, 1.0] as [CGFloat] {
        let tip = CGPoint(x: centre.x + side * gap, y: centre.y)
        let base = centre.x + side * (gap + coneWidth)
        context.beginPath()
        context.move(to: tip)
        context.addLine(to: CGPoint(x: base, y: centre.y + coneHeight / 2))
        context.addLine(to: CGPoint(x: base, y: centre.y - coneHeight / 2))
        context.closePath()
        context.setFillColor(CGColor(red: 0.96, green: 0.97, blue: 1, alpha: 1))
        context.fillPath()

        // Two arcs each, reading as sound leaving the cone.
        for step in 1 ... 2 {
            let radius = coneWidth + CGFloat(step) * dimension * 0.075
            let width = dimension * 0.038
            context.setStrokeColor(CGColor(red: 0.45, green: 0.72, blue: 1,
                                           alpha: 1 - CGFloat(step) * 0.28))
            context.setLineWidth(width)
            context.setLineCap(.round)
            let start = side > 0 ? -CGFloat.pi / 4 : CGFloat.pi * 3 / 4
            let end = side > 0 ? CGFloat.pi / 4 : CGFloat.pi * 5 / 4
            context.addArc(center: CGPoint(x: centre.x + side * gap, y: centre.y),
                           radius: radius, startAngle: start, endAngle: end,
                           clockwise: false)
            context.strokePath()
        }
    }

    image.unlockFocus()

    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:])
    else { fatalError("could not encode \(size)") }
    return png
}

let iconset = URL(fileURLWithPath: "build/StereoPair.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// iconutil wants both the plain and @2x name for each logical size.
let names: [(Int, String)] = [
    (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
]

var rendered: [Int: Data] = [:]
for size in sizes { rendered[size] = draw(size: size) }
for (size, name) in names {
    try rendered[size]!.write(to: iconset.appendingPathComponent(name))
}

print("wrote \(iconset.path)")
