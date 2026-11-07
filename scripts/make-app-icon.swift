#!/usr/bin/env swift
// App/Design/AppIcon.svg → App/Jamak/Assets.xcassets/AppIcon.appiconset 의 PNG들.
// 사용: swift scripts/make-app-icon.swift   (저장소 루트에서)
import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let svg = root.appendingPathComponent("App/Design/AppIcon.svg")
let set = root.appendingPathComponent("App/Jamak/Assets.xcassets/AppIcon.appiconset")
guard let image = NSImage(contentsOf: svg) else { fatalError("SVG를 읽지 못했어요: \(svg.path)") }
try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)

var entries: [String] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { fatalError() }
        rep.size = NSSize(width: pixels, height: pixels)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        try rep.representation(using: .png, properties: [:])!.write(to: set.appendingPathComponent(name))
        entries.append("""
            { "idiom" : "mac", "size" : "\(points)x\(points)", "scale" : "\(scale)x", "filename" : "\(name)" }
        """)
    }
}
let contents = "{\n  \"images\" : [\n" + entries.joined(separator: ",\n") + "\n  ],\n  \"info\" : { \"author\" : \"xcode\", \"version\" : 1 }\n}\n"
try contents.write(to: set.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
let catalog = set.deletingLastPathComponent().appendingPathComponent("Contents.json")
if !FileManager.default.fileExists(atPath: catalog.path) {
    try "{\n  \"info\" : { \"author\" : \"xcode\", \"version\" : 1 }\n}\n".write(to: catalog, atomically: true, encoding: .utf8)
}
print("PNG \(entries.count)장을 만들었어요: \(set.path)")
