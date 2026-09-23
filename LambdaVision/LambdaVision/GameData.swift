//
//  GameData.swift
//  LambdaVision
//
//  Where the Half-Life game files are on this headset.
//

import Foundation

enum GameData {
    /// The read-only game directory the engine is started with (`-rodir`):
    /// a copy pushed to Documents/GameData (`scripts/push-assets.sh` —
    /// survives plain reinstalls, so code-only installs stay small and fast,
    /// but lives in the data container and is wiped by an uninstall), else
    /// assets bundled into the app (`build-and-sign.sh --set
    /// BUNDLE_HL_ASSETS=1`). Nil when neither is present.
    static var directory: String? {
        let docs = (try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            .map { $0.appendingPathComponent("GameData").path }
        let bundled = (Bundle.main.resourcePath ?? "") + "/GameData"
        return [docs, bundled].compactMap { $0 }
            .first { FileManager.default.fileExists(atPath: $0 + "/valve/liblist.gam") }
    }

    /// The directories studio models are loaded from, most preferred first:
    /// the HD pack's when it is installed, then the stock game's.
    static func modelDirectories(in directory: String) -> [String] {
        ["valve_hd", "valve"].map { directory + "/" + $0 + "/models" }
            .filter { FileManager.default.fileExists(atPath: $0) }
    }
}
