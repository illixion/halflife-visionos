//
//  GameLauncher.swift
//  LambdaVision
//
//  Starting, leaving and steering the game from the launcher window: open
//  the immersive space, and, for a chapter or a saved game, run the console
//  command that loads it as soon as the engine is up. The window hands over
//  the scene actions it owns (`bind`); the debug API and the launcher's
//  buttons share this.
//

import SwiftUI

@MainActor
@Observable
final class GameLauncher {
    private weak var appModel: AppModel?
    private var openImmersive: (@MainActor () async -> Bool)?
    private var dismissImmersive: (@MainActor () async -> Void)?

    /// Commands typed or sent from the launcher, newest first, for the
    /// console card's history.
    private(set) var history: [String] = []

    func bind(appModel: AppModel,
              openImmersive: @escaping @MainActor () async -> Bool,
              dismissImmersive: @escaping @MainActor () async -> Void) {
        self.appModel = appModel
        self.openImmersive = openImmersive
        self.dismissImmersive = dismissImmersive
    }

    /// The game is up: the immersive space is open and the engine answers.
    var isRunning: Bool {
        guard let appModel else { return false }
        return appModel.immersiveSpaceState == .open && appModel.gameSettings.isEngineReady
    }

    /// Opens the immersive space, then runs `command` (a console line) once
    /// the engine is ready. With the game already running the command goes
    /// straight in.
    func start(then command: String? = nil) {
        Task { @MainActor in
            guard let appModel else { return }
            if appModel.immersiveSpaceState == .closed {
                guard !appModel.isPreparing, !appModel.library.isImporting,
                      let openImmersive else { return }
                appModel.immersiveSpaceState = .inTransition
                // The space reports .open itself (ImmersiveView.onAppear).
                if await !openImmersive() { appModel.immersiveSpaceState = .closed; return }
            }
            guard let command else { return }
            // Up to 30 s for the engine's first start.
            for _ in 0..<120 where !(appModel.immersiveSpaceState == .open && appModel.gameSettings.isEngineReady) {
                try? await Task.sleep(for: .milliseconds(250))
            }
            run(command)
        }
    }

    /// Hides the game (the immersive space); the launcher comes back.
    func leave() {
        Task { @MainActor in
            guard let appModel, appModel.immersiveSpaceState == .open, let dismissImmersive else { return }
            appModel.immersiveSpaceState = .inTransition
            await dismissImmersive()
            // ImmersiveView.onDisappear sets .closed.
        }
    }

    /// A console line, once the engine is up; nothing before.
    func run(_ command: String) {
        guard let appModel else { return }
        let line = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard appModel.gameSettings.isEngineReady, !line.isEmpty else { return }
        appModel.gameSettings.command(line)
        history.removeAll { $0 == line }
        history.insert(line, at: 0)
        if history.count > 8 { history.removeLast() }
    }
}
