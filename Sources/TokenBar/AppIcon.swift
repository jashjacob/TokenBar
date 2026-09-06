import AppKit
import Foundation

enum AppIconError: LocalizedError {
    case badContext
    case badImage
    case badPNG

    var errorDescription: String? {
        switch self {
        case .badContext: return "could not create icon bitmap"
        case .badImage: return "could not render app icon"
        case .badPNG: return "could not encode app icon PNG"
        }
    }
}

enum AppIcon {
    private static let representations: [(name: String, pixels: Int)] = [
        ("icon_16x16.png", 16),
        ("icon_16x16@2x.png", 32),
        ("icon_32x32.png", 32),
        ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128),
        ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256),
        ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512),
        ("icon_512x512@2x.png", 1024),
    ]

    static func writeIconset(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for spec in representations {
            try png(pixels: spec.pixels).write(to: directory.appendingPathComponent(spec.name))
        }
    }

    static func png(pixels: Int) throws -> Data {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { throw AppIconError.badContext }
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        )
        guard let ctx = CGContext(
            data: nil,
            width: pixels,
            height: pixels,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: bitmapInfo.rawValue
        ) else { throw AppIconError.badContext }

        // Bot drawing is y-down. CGContext is y-up, so flip the CTM.
        ctx.translateBy(x: 0, y: CGFloat(pixels))
        ctx.scaleBy(x: 1, y: -1)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        StripBotView.drawAppIcon(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()

        guard let cgImage = ctx.makeImage() else { throw AppIconError.badImage }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let png = rep.representation(using: .png, properties: [:]) else { throw AppIconError.badPNG }
        return png
    }
}
