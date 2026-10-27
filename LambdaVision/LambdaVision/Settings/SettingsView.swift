//
//  SettingsView.swift
//  LambdaVision
//
//  Player-facing settings, in a window of their own opened from the
//  launcher's gear button (LambdaVisionApp, id "settings"). A short first
//  page of rows, each opening a page of its own, the way Hypnos's Settings
//  is laid out: one scrolling sheet had grown to six sections and footers
//  longer than the controls above them.
//
//  Controls bind straight to the @Observable GameSettings; each property's
//  didSet persists to AppSettingsStore and pushes the change to the running
//  game, so there's no separate save step here. The pages are in this
//  folder; SettingsPage.swift has the page shape and the slider row.
//
//  Foveated rendering and render scale only take effect when the immersive
//  space restarts. The window snapshots both when it opens and, while the
//  game is running, offers the reload: on Done, as the sheet did, and as a
//  row at the top of this page, since a window can stay up while playing.
//

import SwiftUI

struct SettingsView: View {
    static let windowID = "settings"

    @Environment(AppModel.self) private var appModel
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    // Snapshot of the reload-requiring settings when the window opened (or
    // the game last reloaded from here), so we can offer a reload if they
    // changed.
    @State private var snapScale = 0.0
    @State private var snapFoveated = true
    @State private var snapMSAA = false
    @State private var snapProgressive = false
    @State private var showReloadPrompt = false

    enum Page: Hashable {
        case graphics, reflections, body, audio
        case hands, keyboardMouse
        case gameMenu, developer
    }

    var body: some View {
        let settings = appModel.gameSettings

        NavigationStack {
            Form {
                if reloadPending {
                    Section {
                        Button {
                            Task { await reloadImmersiveSpace() }
                        } label: {
                            Label("Reload game to apply", systemImage: "arrow.clockwise")
                        }
                    } footer: {
                        Text("Foveated rendering and render scale only take effect when the immersive space restarts.")
                    }
                }

                Section {
                    row(.graphics, "Graphics", systemImage: "sparkles.tv",
                        value: settings.foveatedEngine ? "Foveated" : SettingsSlider.percent(settings.renderScale))
                    row(.reflections, "Reflections & Water", systemImage: "drop")
                    row(.body, "Body & Weapon", systemImage: "figure.stand")
                    row(.audio, "Audio", systemImage: "speaker.wave.2")
                }

                Section("Input") {
                    row(.hands, "Hands", systemImage: "hand.raised",
                        value: "\(settings.dominantHand.label) hand")
                    row(.keyboardMouse, "Keyboard, Mouse & Gamepad", systemImage: "gamecontroller",
                        value: settings.inputMode.label)
                }

                Section {
                    row(.gameMenu, "Menu, Maps & Console", systemImage: "list.bullet.rectangle",
                        value: settings.isEngineReady ? "" : "Game not running")
                }

                Section {
                    row(.developer, "Developer", systemImage: "hammer")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Settings")
            .navigationDestination(for: Page.self, destination: page)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { done() }
                }
            }
        }
        .onAppear { takeSnapshot() }
        .alert("Reload game to apply changes?", isPresented: $showReloadPrompt) {
            Button("Reload") {
                Task {
                    await reloadImmersiveSpace()
                    dismissWindow(id: Self.windowID)
                }
            }
            Button("Later", role: .cancel) { dismissWindow(id: Self.windowID) }
        } message: {
            Text("Foveated rendering and render scale only take effect when the immersive space restarts.")
        }
    }

    private func row(_ page: Page, _ title: String, systemImage: String, value: String = "") -> some View {
        NavigationLink(value: page) {
            LabeledContent {
                Text(value)
            } label: {
                Label(title, systemImage: systemImage)
            }
        }
    }

    @ViewBuilder
    private func page(_ page: Page) -> some View {
        switch page {
        case .graphics: GraphicsSettingsPage()
        case .reflections: ReflectionSettingsPage()
        case .body: BodySettingsPage()
        case .audio: AudioSettingsPage()
        case .hands: HandSettingsPage()
        case .keyboardMouse: KeyboardMouseSettingsPage()
        case .gameMenu: GameMenuSettingsPage()
        case .developer: DeveloperSettingsPage()
        }
    }

    // MARK: - Reload

    /// A render-target setting changed since the snapshot and the game is
    /// running (otherwise the next launch/open picks it up anyway).
    private var reloadPending: Bool {
        let s = appModel.gameSettings
        let changed = s.renderScale != snapScale || s.foveatedEngine != snapFoveated
            || s.engineMSAA != snapMSAA || s.progressiveImmersion != snapProgressive
        return changed && appModel.immersiveSpaceState == .open
    }

    private func takeSnapshot() {
        snapScale = appModel.gameSettings.renderScale
        snapFoveated = appModel.gameSettings.foveatedEngine
        snapMSAA = appModel.gameSettings.engineMSAA
        snapProgressive = appModel.gameSettings.progressiveImmersion
    }

    private func done() {
        if reloadPending {
            showReloadPrompt = true
        } else {
            dismissWindow(id: Self.windowID)
        }
    }

    // The hide/show "dance": dismiss + reopen the immersive space so a fresh
    // Renderer reallocates the render targets at the new scale. Awaited
    // before this window closes: the scene actions are this window's, and
    // one captured from a window that has gone may not open anything
    // (InputCatcher's capturesInputCatcherActions).
    private func reloadImmersiveSpace() async {
        appModel.immersiveSpaceState = .inTransition
        await dismissImmersiveSpace()
        switch await openImmersiveSpace(id: appModel.immersiveSpaceID) {
        case .opened: break
        default: appModel.immersiveSpaceState = .closed
        }
        takeSnapshot()
    }
}

#Preview(windowStyle: .automatic) {
    SettingsView()
        .environment(AppModel())
}
