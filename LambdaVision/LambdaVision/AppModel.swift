//
//  AppModel.swift
//  LambdaVision
//
//  Created by Ixion on 10/05/2026.
//

import SwiftUI

/// Maintains app-wide state
@MainActor
@Observable
class AppModel {
    let immersiveSpaceID = "ImmersiveSpace"
    enum ImmersiveSpaceState {
        case closed
        case inTransition
        case open
    }
    var immersiveSpaceState = ImmersiveSpaceState.closed

    /// Player-facing settings (Graphics/Audio/Input), shared by SettingsView
    /// and the render startup. Created here so its init pushes the stored
    /// Renderer-static knobs before the immersive space opens.
    let gameSettings = GameSettings()

    /// Set by Renderer.ensureEngineInitialized() when the Xash engine can't
    /// start — most commonly the Half-Life assets aren't on this device yet
    /// (push-assets.sh copies them to Documents/GameData separately from the
    /// app binary so code-only rebuilds stay fast, but that copy lives in the
    /// app's data container and is lost on an uninstall/reinstall). Shown as
    /// a banner in ContentView; nil means no problem to report.
    var engineFailureMessage: String?

    /// The warm-up before the game starts (WeaponWarmup): true until it has
    /// run, and the play button waits for it, so nothing is computed on first
    /// sight once in the immersive space. `preparationProgress` is fits done
    /// out of fits needed — (0, 0) while the models are still being read, and
    /// usually stays there on later launches, when everything is cached.
    var isPreparing = true
    var preparationProgress = (done: 0, total: 0)

    /// Runs the warm-up once. Called when the main window first appears.
    func prepare() async {
        guard isPreparing else { return }
        if let dir = GameData.directory {
            await WeaponWarmup.run(gameDirectory: dir) { [weak self] done, total in
                self?.preparationProgress = (done, total)
            }
        }
        isPreparing = false
    }
}
