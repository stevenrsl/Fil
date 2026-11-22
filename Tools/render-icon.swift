// Réduit une image (PNG ou SVG) en PNG carré : swift Tools/render-icon.swift <entrée> <sortie.png> <pixels> [opaque]
// « opaque » retire le canal alpha (exigé pour l'AppIcon iOS). Appelé par Tools/icon.sh.
import AppKit

let arguments = CommandLine.arguments
let size = Int(arguments[3])!
let opaque = arguments.count > 4
guard let image = NSImage(contentsOf: URL(fileURLWithPath: arguments[1])) else { fatalError("image illisible : \(arguments[1])") }
var rect = CGRect(x: 0, y: 0, width: size, height: size)
guard let source = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { fatalError("rendu impossible") }
let info = opaque ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue
let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info)!
context.interpolationQuality = .high
if opaque {
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(rect)
}
context.draw(source, in: rect)
let output = NSBitmapImageRep(cgImage: context.makeImage()!)
try output.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: arguments[2]))
