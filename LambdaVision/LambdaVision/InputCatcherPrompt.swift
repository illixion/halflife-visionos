//
//  InputCatcherPrompt.swift
//  LambdaVision
//
//  "Click to lock mouse": the small pane InputCatcher shows before its
//  invisible window takes the mouse, like a browser's pointer lock, so the
//  player knows what is about to happen and how to undo it. A click with
//  the mouse (or a pinch) on it locks; InputCatcher decides when it's up.
//

import GameController
import SwiftUI

/// The prompt's scene: a compact glass window with no system controls (the
/// player dismisses it by locking, or it goes away on its own).
struct InputCatcherPromptWindow: Scene {
    var body: some Scene {
        Window("Lock Mouse", id: InputCatcher.promptWindowID) {
            InputCatcherPromptView()
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .persistentSystemOverlays(.hidden)
    }
}

struct InputCatcherPromptView: View {
    private var catcher = InputCatcher.shared
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(spacing: 14) {
            Button {
                catcher.lock(via: "click")
            } label: {
                Label("Click to lock mouse", systemImage: "computermouse.fill")
                    .font(.title2.weight(.semibold))
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.extraLarge)
            // Obvious under the pointer: the button lifts and highlights.
            .hoverEffect(.lift)

            Text("Esc or move the pointer off the game to release")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(28)
        .fixedSize()
        .background(SceneReader { catcher.attachPrompt(scene: $0) })
        .persistentSystemOverlays(.hidden)
        .handlesGameControllerEvents(matching: .gamepad)
        .onAppear { catcher.promptAppeared() }
        .onDisappear { catcher.promptDisappeared() }
        .onChange(of: catcher.promptCloseRequests) { dismissWindow() }
    }
}
