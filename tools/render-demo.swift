import AppKit
import ImageIO
import UniformTypeIdentifiers

// Generates docs/demo.gif: the real CatSprite cycling through every state, one
// card per state. Frames come from the drawing code, so the demo cannot drift.
//
//   swiftc -O Sources/PetState.swift Sources/CatSprite.swift tools/render-demo.swift \
//     -o /tmp/render-demo && /tmp/render-demo docs/demo.gif

@main
enum RenderDemo {
    static func main() {
        let fps: Double = 15
        let secondsPerState: Double = 1.6
        let framesPerState = Int(fps * secondsPerState)
        let size = NSSize(width: 320, height: 300)
        let states: [PetState] = [.idle, .working, .blocked, .done, .error]
        let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "docs/demo.gif"

        try! FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        guard let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                        UTType.gif.identifier as CFString,
                                                        states.count * framesPerState, nil) else {
            exit(1)
        }
        let fileProperties = [kCGImagePropertyGIFDictionary as String:
                                [kCGImagePropertyGIFLoopCount as String: 0]]
        CGImageDestinationSetProperties(dest, fileProperties as CFDictionary)

        let frameProperties = [kCGImagePropertyGIFDictionary as String:
                                [kCGImagePropertyGIFDelayTime as String: 1.0 / fps]]

        let background = NSColor(calibratedRed: 0.09, green: 0.09, blue: 0.11, alpha: 1)
        var rendered = 0

        for (index, state) in states.enumerated() {
            for frame in 0..<framesPerState {
                let time = Double(index * framesPerState + frame) / fps
                let image = NSImage(size: size)
                image.lockFocus()
                background.setFill()
                NSRect(origin: .zero, size: size).fill()

                let petRect = NSRect(x: 40, y: 60, width: size.width - 80, height: 190)
                CatSprite.draw(in: petRect, state: state, time: time)

                let label = state.rawValue as NSString
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .medium),
                    .foregroundColor: NSColor(calibratedWhite: 0.62, alpha: 1)
                ]
                let labelSize = label.size(withAttributes: attributes)
                label.draw(at: NSPoint(x: (size.width - labelSize.width) / 2, y: 26),
                           withAttributes: attributes)
                image.unlockFocus()

                guard let tiff = image.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff),
                      let cg = rep.cgImage else { continue }
                CGImageDestinationAddImage(dest, cg, frameProperties as CFDictionary)
                rendered += 1
            }
        }

        guard CGImageDestinationFinalize(dest) else { exit(1) }
        let bytes = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
        print("wrote \(path) (\(rendered) frames, \(bytes ?? 0) bytes)")
    }
}
