// Composes labelled image grids for QC sheets (this ffmpeg build has no drawtext).
// Usage: xcrun swift scripts/qc/compose-sheet.swift spec.json out.png
// spec: {"cols": 6, "cellW": 384, "cellH": 216, "title": "...", "items": [{"path": "...", "label": "..."}]}
import AppKit
import Foundation

struct Item: Decodable { let path: String; let label: String }
struct Spec: Decodable { let cols: Int; let cellW: Int; let cellH: Int; let title: String; let items: [Item] }

let args = CommandLine.arguments
let spec = try JSONDecoder().decode(Spec.self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
let pad = 6, header = 44
let rows = (spec.items.count + spec.cols - 1) / spec.cols
let W = spec.cols * (spec.cellW + pad) + pad, H = header + rows * (spec.cellH + pad) + pad
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H, bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSColor(white: 0.12, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: W, height: H).fill()
let titleAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 20, weight: .semibold), .foregroundColor: NSColor.white]
(spec.title as NSString).draw(at: NSPoint(x: pad + 4, y: H - header + 12), withAttributes: titleAttrs)
let labelAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.white]
for (i, item) in spec.items.enumerated() {
    let col = i % spec.cols, row = i / spec.cols
    let x = pad + col * (spec.cellW + pad)
    let y = H - header - (row + 1) * (spec.cellH + pad)
    let cell = NSRect(x: x, y: y, width: spec.cellW, height: spec.cellH)
    if let img = NSImage(contentsOfFile: item.path) { img.draw(in: cell) }
    let text = item.label as NSString
    let size = text.size(withAttributes: labelAttrs)
    NSColor(white: 0, alpha: 0.6).setFill()
    NSRect(x: x + 4, y: y + spec.cellH - Int(size.height) - 10, width: Int(size.width) + 10, height: Int(size.height) + 6).fill()
    text.draw(at: NSPoint(x: x + 9, y: y + spec.cellH - Int(size.height) - 7), withAttributes: labelAttrs)
}
NSGraphicsContext.restoreGraphicsState()
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
print("wrote", args[2], "\(W)x\(H)")
