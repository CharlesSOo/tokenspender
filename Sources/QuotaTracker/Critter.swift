import AppKit

func hexColor(_ hex: UInt32) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: 1
    )
}

/// Resolves per current appearance; AppKit sets the drawing appearance for views and windows.
private func dynamic(light: UInt32, dark: UInt32) -> NSColor {
    NSColor(name: nil) { appearance in
        hexColor(appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light)
    }
}

enum Palette {
    static let terracotta = hexColor(0xD97757)
    static let background = dynamic(light: 0xFAF9F5, dark: 0x1F1E1D)
    static let primaryText = dynamic(light: 0x141413, dark: 0xF0EEE6)
    static let secondaryText = dynamic(light: 0x73726C, dark: 0xA6A39A)
    static let tertiaryText = dynamic(light: 0xB0AEA5, dark: 0x5E5D59)
}

/// Pixel critter as a template image (eyes and mouth transparent), tinted by whatever draws it.
///
/// Frames are written straight into bitmap reps instead of CG fills in a draw handler: every fill of
/// a profiled color into a fresh image context makes ColorSync build ~350 KB tone-curve LUTs that are
/// never freed (measured 8.7 MB resident with the draw-handler version).
enum Critter {
    // 11-wide grid, 2 pt per cell: eyes on row 2, stub arms on row 3, mouth on row 4 (and 5 when open).
    private static let body = [
        ".#########.",
        ".#########.",
        ".##o###o##.",
        "###########",
        ".#########.",
        ".#########.",
    ]
    private static let legsStanding = [".#.#...#.#.", ".#.#...#.#."]
    private static let legsOuter = [".#.#...#.#.", "#..#...#..#"]
    private static let legsInner = [".#.#...#.#.", "..##...##.."]

    /// Body with the mouth (a 1-px line under the eyes: 3 wide, 5 wide when open) and optionally one arm
    /// swung up and the other down.
    private static func body(mouthOpen: Bool, armsUp: Int?) -> [String] {
        var rows = body.map(Array.init)
        for x in (mouthOpen ? 3...7 : 4...6) { rows[4][x] = "." }
        if let up = armsUp {
            let down = 10 - up
            rows[3][up] = "."; rows[3][down] = "."
            rows[2][up] = "#"; rows[4][down] = "#"
        }
        return rows.map { String($0) }
    }

    /// Monochrome template: eyes and mouth are transparent so they read on light and dark menu bars.
    static let menuBar = image()

    /// Two alternating frames composed from independent toggles; phase 0 and 1 swap each part.
    static func frames(legs: Bool, arms: Bool, mouth: Bool) -> [NSImage] {
        [0, 1].map { phase in
            image(
                body: body(mouthOpen: mouth && phase == 0, armsUp: arms ? (phase == 0 ? 0 : 10) : nil),
                legs: legs ? (phase == 0 ? legsOuter : legsInner) : legsStanding
            )
        }
    }

    private static func image(body: [String] = body(mouthOpen: false, armsUp: nil), legs: [String] = legsStanding) -> NSImage {
        let pixel = 2
        let rows = (body + legs).map(Array.init)
        let pointSize = NSSize(width: CGFloat(rows[0].count * pixel), height: CGFloat(rows.count * pixel))
        let image = NSImage(size: pointSize)
        for scale in [1, 2] {
            let cell = pixel * scale, w = rows[0].count * cell, h = rows.count * cell
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: w * 4, bitsPerPixel: 32
            )!
            let data = rep.bitmapData!
            for (y, row) in rows.enumerated() {
                for (x, c) in row.enumerated() where c == "#" {
                    for dy in 0..<cell {
                        for dx in 0..<cell {
                            let i = ((y * cell + dy) * w + x * cell + dx) * 4
                            data[i] = 0; data[i + 1] = 0; data[i + 2] = 0; data[i + 3] = 255
                        }
                    }
                }
            }
            rep.size = pointSize
            image.addRepresentation(rep)
        }
        image.isTemplate = true
        return image
    }
}

/// What the menu-bar critter does while tokens burn. Raw values are persisted in UserDefaults.
enum CritterAnimation: String, CaseIterable {
    case off, eating, legs, legsArms, legsArmsEating

    static let interval: TimeInterval = 0.5

    var title: String {
        switch self {
        case .off: "Off"
        case .eating: "Eating"
        case .legs: "Legs"
        case .legsArms: "Legs + arms"
        case .legsArmsEating: "Legs + arms + eating"
        }
    }

    /// Pre-rendered once per mode on first use.
    var frames: [NSImage] { Self.cache[self] ?? [] }

    private static let cache: [CritterAnimation: [NSImage]] = [
        .eating: Critter.frames(legs: false, arms: false, mouth: true),
        .legs: Critter.frames(legs: true, arms: false, mouth: false),
        .legsArms: Critter.frames(legs: true, arms: true, mouth: false),
        .legsArmsEating: Critter.frames(legs: true, arms: true, mouth: true),
    ]
}
