import AppKit

// Generates the app icon: docs/icon.png (1024) and Resources/RexPet.icns.
//
//   swiftc -O Sources/PetState.swift Sources/CatSprite.swift tools/render-icon.swift \
//     -o /tmp/render-icon && /tmp/render-icon

@main
enum RenderIcon {
    static func main() {
        let image = CatSprite.icon(size: 1024)
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { exit(1) }
        rep.size = NSSize(width: 1024, height: 1024)

        let docs = "docs/icon.png"
        try! FileManager.default.createDirectory(atPath: "docs", withIntermediateDirectories: true)
        try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: docs))

        // iconutil needs every size Apple asks for, each as <name>@<scale>x.png.
        let iconset = "/tmp/RexPet.iconset"
        try? FileManager.default.removeItem(atPath: iconset)
        try! FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)
        let entries: [(String, Int)] = [
            ("icon_16x16", 16), ("icon_16x16@2x", 32),
            ("icon_32x32", 32), ("icon_32x32@2x", 64),
            ("icon_128x128", 128), ("icon_128x128@2x", 256),
            ("icon_256x256", 256), ("icon_256x256@2x", 512),
            ("icon_512x512", 512), ("icon_512x512@2x", 1024)
        ]
        for (name, pixels) in entries {
            guard let scaled = CatSprite.icon(size: CGFloat(pixels)).tiffRepresentation,
                  let scaledRep = NSBitmapImageRep(data: scaled),
                  let png = scaledRep.representation(using: .png, properties: [:]) else { continue }
            try! png.write(to: URL(fileURLWithPath: "\(iconset)/\(name).png"))
        }

        let icns = Process()
        icns.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
        icns.arguments = ["-c", "icns", iconset, "-o", "Resources/RexPet.icns"]
        try! icns.run()
        icns.waitUntilExit()
        print("wrote \(docs) and Resources/RexPet.icns (iconutil exit \(icns.terminationStatus))")
    }
}
