import AppKit

// Renders docs/states.png: every pet state on a card, drawn with the real CatSprite
// so the image can never drift from the app.
//
//   swiftc -O Sources/PetState.swift Sources/CatSprite.swift tools/render-states.swift \
//     -o /tmp/render-states && /tmp/render-states docs/states.png

@main
enum RenderStates {
    static func main() {
        let tile = NSSize(width: 230, height: 250)
        let states: [PetState] = [.idle, .working, .blocked, .done, .error]
        let canvas = NSRect(x: 0, y: 0, width: tile.width * CGFloat(states.count), height: tile.height)

        let image = NSImage(size: canvas.size)
        image.lockFocus()
        NSColor(calibratedRed: 0.09, green: 0.09, blue: 0.11, alpha: 1).setFill()
        canvas.fill()

        for (index, state) in states.enumerated() {
            let originX = tile.width * CGFloat(index)

            // Pet occupies the upper part of the tile; the label sits at the bottom.
            let petRect = NSRect(x: originX + 15, y: 55, width: tile.width - 30, height: 160)
            CatSprite.draw(in: petRect, state: state, time: 0.8)

            let label = state.rawValue as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .medium),
                .foregroundColor: NSColor(calibratedWhite: 0.62, alpha: 1)
            ]
            let size = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: originX + (tile.width - size.width) / 2, y: 22), withAttributes: attributes)

            if index > 0 {
                NSColor(calibratedWhite: 1, alpha: 0.06).setFill()
                NSRect(x: originX, y: 0, width: 1, height: tile.height).fill()
            }
        }
        image.unlockFocus()

        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            exit(1)
        }
        let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "docs/states.png"
        try! FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        try! png.write(to: URL(fileURLWithPath: path))
        print("wrote \(path)")
    }
}
