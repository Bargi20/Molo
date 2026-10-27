// Crea le immagini del README a partire dai fotogrammi di `Molo --record`.
// Uso: swift scripts/readme-media.swift <cartella-fotogrammi> <cartella-output>
// Produce: dock.png (a riposo), dock-wave.png (onda sulle app), dock-widgets.png (onda sui widget), dock.gif.
import AppKit
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count == 3 else {
    print("Uso: swift scripts/readme-media.swift <fotogrammi> <output>")
    exit(1)
}
let input = URL(fileURLWithPath: args[1])
let output = URL(fileURLWithPath: args[2])
try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

let frameURLs = (try FileManager.default.contentsOfDirectory(at: input, includingPropertiesForKeys: nil))
    .filter { $0.pathExtension == "png" }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }
let frames: [CGImage] = frameURLs.compactMap { url in
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}
guard let first = frames.first else { fatalError("Nessun fotogramma in \(input.path)") }

/// Rettangolo che contiene i pixel non trasparenti di tutti i fotogrammi.
func opaqueBounds(_ images: [CGImage]) -> CGRect {
    var minX = Int.max, minY = Int.max, maxX = 0, maxY = 0
    for image in images {
        let w = image.width, h = image.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        for y in stride(from: 0, to: h, by: 2) {
            for x in stride(from: 0, to: w, by: 2) where pixels[(y * w + x) * 4 + 3] > 8 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
    }
    return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
}

let pad: CGFloat = 60
// Le righe del bitmap partono dall'alto, come le coordinate di `cropping(to:)`.
let bounds = opaqueBounds(frames).insetBy(dx: -pad, dy: -pad)
    .intersection(CGRect(x: 0, y: 0, width: first.width, height: first.height))

/// Disegna il fotogramma ritagliato sopra uno sfondo sfumato, a scala `scale`.
func compose(_ frame: CGImage, scale: CGFloat) -> CGImage {
    let width = Int(bounds.width * scale), height = Int((bounds.height + pad) * scale)
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let colors = [
        CGColor(red: 0.36, green: 0.29, blue: 0.85, alpha: 1),
        CGColor(red: 0.20, green: 0.52, blue: 0.95, alpha: 1),
        CGColor(red: 0.27, green: 0.78, blue: 0.82, alpha: 1),
    ] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: CGFloat(height)),
                           end: CGPoint(x: CGFloat(width), y: 0), options: [])
    ctx.interpolationQuality = .high
    if let crop = frame.cropping(to: bounds) {
        let drawn = CGRect(x: 0, y: pad * scale,
                           width: CGFloat(crop.width) * scale, height: CGFloat(crop.height) * scale)
        ctx.draw(crop, in: drawn)
    }
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, _ name: String) {
    let url = output.appendingPathComponent(name)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
    print("Scritto \(url.path)")
}

// Immagini statiche (risoluzione Retina).
writePNG(compose(frames[0], scale: 1), "dock.png")
writePNG(compose(frames[frames.count * 2 / 3], scale: 1), "dock-wave.png")
writePNG(compose(frames[frames.count / 5], scale: 1), "dock-widgets.png")

// GIF animata a metà risoluzione, un fotogramma ogni due.
let gifURL = output.appendingPathComponent("dock.gif")
let gifFrames = stride(from: 0, to: frames.count, by: 2).map { frames[$0] }
let gif = CGImageDestinationCreateWithURL(gifURL as CFURL, UTType.gif.identifier as CFString, gifFrames.count, nil)!
CGImageDestinationSetProperties(gif, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
for frame in gifFrames {
    CGImageDestinationAddImage(gif, compose(frame, scale: 0.5),
                               [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.08]] as CFDictionary)
}
CGImageDestinationFinalize(gif)
print("Scritto \(gifURL.path)")
