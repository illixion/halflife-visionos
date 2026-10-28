//
//  ChapterArt.swift
//  LambdaVision
//
//  The picture on a chapter card (and the launcher's banner). The one the
//  engine made on this device (ChapterPictureRunner) wins, then a file named
//  `chapter-<gamedir>-<map>` in Previews (see docs/settings-previews.md);
//  without either the card draws its own art: the
//  game's colour, the chapter's number and the lambda, so a fresh install
//  already looks like a game and nothing of Valve's is shipped.
//

import SwiftUI

struct ChapterArt: View {
    let gamedir: String
    let chapter: Chapter
    /// The big chapter number in the corner: on the cards, not the banner.
    var showsNumber = true

    var body: some View {
        // Clear takes whatever size it is offered, so the art (a large λ, a
        // picture of any shape) is clipped to the card instead of making it.
        Color.clear
            .overlay {
                // The picture the engine made on this device, then one named in Previews.
                if let made = madePicture {
                    PreviewMediaFile(found: .image(made))
                        .id(ChapterPictures.shared.version)
                } else if let found = PreviewAssets.find("chapter-\(gamedir.lowercased())-\(chapter.map)") {
                    PreviewMediaFile(found: found)
                } else {
                    generated
                }
            }
            .clipped()
    }

    /// Reads `version` so the card redraws when a picture is written.
    private var madePicture: URL? {
        _ = ChapterPictures.shared.version
        return ChapterPictures.existing(gamedir: gamedir, map: chapter.map)
    }

    private var accent: Color { Self.accent(for: gamedir) }

    private var generated: some View {
        ZStack {
            LinearGradient(colors: [accent.opacity(0.85), .black],
                           startPoint: UnitPoint(x: 0.1 + 0.04 * Double(chapter.number % 8), y: 0),
                           endPoint: .bottomTrailing)
            Text("λ")
                .font(.system(size: 220, weight: .heavy, design: .rounded))
                .foregroundStyle(.white.opacity(0.08))
                .offset(x: 70, y: 20)
            if showsNumber {
                Text("\(chapter.number)")
                    .font(.system(size: 120, weight: .black, design: .rounded))
                    .foregroundStyle(.white.opacity(0.22))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.leading, 14)
            }
        }
    }

    static func accent(for gamedir: String) -> Color {
        switch gamedir.lowercased() {
        case "gearbox": Color(red: 0.25, green: 0.62, blue: 0.35)
        case "bshift": Color(red: 0.2, green: 0.5, blue: 0.85)
        default: Color(red: 0.95, green: 0.5, blue: 0.15)
        }
    }
}
