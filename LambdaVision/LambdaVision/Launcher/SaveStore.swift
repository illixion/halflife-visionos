//
//  SaveStore.swift
//  LambdaVision
//
//  The saved games of the selected game, read from where the engine writes
//  them (Application Support/xash3d/<gamedir>/save): the file's name, its
//  date, the picture the engine saved beside it, and the map it was made
//  on, found in the file's header (ChapterCatalog.mapName).
//

import SwiftUI
import ImageIO

struct SaveSlot: Identifiable {
    /// The file name without `.sav`: what `load` takes.
    let name: String
    let date: Date
    let map: String?
    let thumbnail: UIImage?
    var id: String { name }

    /// "Quick save", "Autosave", else the file's name. The engine keeps a few
    /// older ones as quick01, quick02: "earlier".
    var title: String {
        let lower = name.lowercased()
        let stem = String(lower.prefix { !$0.isNumber })
        let older = lower.count > stem.count
        switch stem {
        case "quick": return older ? "Quick save (earlier)" : "Quick save"
        case "autosave": return older ? "Autosave (earlier)" : "Autosave"
        default: return name
        }
    }
}

@MainActor
@Observable
final class SaveStore {
    private(set) var slots: [SaveSlot] = []

    private static func directory(for gamedir: String) -> URL {
        let support = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                    appropriateFor: nil, create: false))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return support.appendingPathComponent("xash3d/\(gamedir)/save", isDirectory: true)
    }

    func refresh(gamedir: String?) {
        guard let gamedir else { slots = []; return }
        let dir = Self.directory(for: gamedir)
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        slots = urls
            .filter { $0.pathExtension.lowercased() == "sav" }
            .compactMap { url -> SaveSlot? in
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                let name = url.deletingPathExtension().lastPathComponent
                let map = (try? Data(contentsOf: url, options: .mappedIfSafe))
                    .flatMap(ChapterCatalog.mapName(inSave:))
                return SaveSlot(name: name, date: date, map: map,
                                thumbnail: Self.thumbnail(beside: url))
            }
            .sorted { $0.date > $1.date }
    }

    /// The `.tga` the engine writes next to a save (any case), decoded by ImageIO.
    private static func thumbnail(beside save: URL) -> UIImage? {
        let base = save.deletingPathExtension()
        for ext in ["tga", "TGA"] {
            let url = base.appendingPathExtension(ext)
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }
            return UIImage(cgImage: image)
        }
        return nil
    }
}
