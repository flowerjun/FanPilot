// Renders the app icon (fan symbol on a rounded square) to a 1024px PNG.
import AppKit

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let box = NSRect(x: 100, y: 100, width: 824, height: 824)
NSGradient(starting: NSColor(calibratedRed: 0.16, green: 0.55, blue: 0.95, alpha: 1),
           ending: NSColor(calibratedRed: 0.05, green: 0.20, blue: 0.55, alpha: 1))!
    .draw(in: NSBezierPath(roundedRect: box, xRadius: 185, yRadius: 185), angle: -90)
let cfg = NSImage.SymbolConfiguration(pointSize: 470, weight: .regular).applying(.init(paletteColors: [.white]))
let fan = NSImage(systemSymbolName: "fan.fill", accessibilityDescription: nil)!.withSymbolConfiguration(cfg)!
let s = fan.size
fan.draw(in: NSRect(x: (1024 - s.width) / 2, y: (1024 - s.height) / 2, width: s.width, height: s.height))
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
