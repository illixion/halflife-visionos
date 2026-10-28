//
//  ContentView.swift
//  LambdaVision
//
//  Created by Ixion on 10/05/2026.
//

import SwiftUI
import RealityKit
import RealityKitContent
import IOSurface
import GameLibrary
import UniformTypeIdentifiers

struct ContentView: View {

    @Environment(AppModel.self) private var appModel
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    @State private var showImporter = false
    @State private var showWiFi = false
    @State private var cheatsEnabled = false
    @State private var bridgeStatus: String = "—"
    @State private var vulkanStatus: String = "—"
    @State private var deviceStatus: String = "—"
    @State private var iosurfaceStatus: String = "—"
    @State private var engineStatus: String = "—"

    var body: some View {
        NavigationStack {
            ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if let message = appModel.engineFailureMessage {
                    engineFailureBanner(message)
                }

                let library = appModel.library
                if library.scan == nil {
                    ProgressView("Looking for games…")
                        .frame(maxWidth: .infinity)
                } else if library.games.isEmpty {
                    GameOnboarding(onImport: { showImporter = true }, onWiFi: { showWiFi = true })
                } else if let game = library.selectedGame {
                    LauncherBanner(game: game)
                    QuickActions()
                    ChapterPicker(game: game)
                    SavedGames(game: game)
                    ConsoleCard()
                    GameLibraryList()
                }

                if library.isImporting || !library.importLog.isEmpty {
                    ImportStatusView()
                }

                // The chapter list and cheats are Half-Life's.
                if (GameData.runningGame ?? library.selectedGame)?.kind == .base {
                    cheatsSection
                }

                DisclosureGroup("Diagnostics") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("C bridge: \(bridgeStatus)")
                        Text("Vulkan / MoltenVK: \(vulkanStatus)")
                        Text("VkDevice: \(deviceStatus)")
                        Text("IOSurface clear: \(iosurfaceStatus)")
                        Text("Engine: \(engineStatus)")

                        Divider()
                        // Live aim readout — polled ~4×/s while the game runs,
                        // so it's visible without leaving the immersive space.
                        // Aim the weapon / fire and watch which gate drops.
                        Text("Aim").font(.caption2).foregroundStyle(.secondary)
                        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(Renderer.aimDiagLines(), id: \.self) { line in
                                    Text(line)
                                }
                            }
                        }
                    }
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(28)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showImporter = true
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                    }
                    .help("Import a game or mod")
                    .disabled(appModel.library.isImporting)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showWiFi = true
                    } label: {
                        Image(systemName: "wifi")
                    }
                    .help("Manage over Wi-Fi")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        openWindow(id: SettingsView.windowID)
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .help("Settings")
                }
            }
            // The server runs exactly as long as this sheet is up.
            .sheet(isPresented: $showWiFi) {
                WiFiManageView(library: appModel.library)
            }
            .onAppear { runSmokeTests() }
            // The mouse-capture window opens and closes from here.
            .capturesInputCatcherActions()
            // Library scan + weapon warm-up; rerun the warm-up when the
            // selection or the installed games change before the game starts.
            .task {
                // The debug API (DebugEndpoints); this window owns the
                // immersive-space actions its `immersive` command drives.
                DebugEndpoints.register(appModel: appModel,
                                        openImmersive: { [openImmersiveSpace, appModel] in
                                            await openImmersiveSpace(id: appModel.immersiveSpaceID) == .opened
                                        },
                                        dismissImmersive: { [dismissImmersiveSpace] in await dismissImmersiveSpace() },
                                        openWindow: { [openWindow] in openWindow(id: $0) },
                                        dismissWindow: { [dismissWindow] in dismissWindow(id: $0) })
                appModel.launcher.bind(appModel: appModel,
                                       openImmersive: { [openImmersiveSpace, appModel] in
                                           await openImmersiveSpace(id: appModel.immersiveSpaceID) == .opened
                                       },
                                       dismissImmersive: { [dismissImmersiveSpace] in await dismissImmersiveSpace() })
                InputCatcher.shared.start(appModel: appModel)
                await appModel.prepare()
                appModel.library.watchForAssetUploads()
            }
            .onChange(of: appModel.library.selectionVersion) {
                appModel.refreshSaves()
                Task { await appModel.warmUp() }
            }
            .onChange(of: appModel.immersiveSpaceState) { appModel.refreshSaves() }
            // A settings preset opened from AirDrop or Files.
            .alert("Preset added", isPresented: Binding(
                get: { appModel.presets.openedPreset != nil },
                set: { if !$0 { appModel.presets.openedPreset = nil } })
            ) {
                Button("Show it") {
                    appModel.presets.openedPreset = nil
                    appModel.settingsPageRequest = .presets
                    openWindow(id: SettingsView.windowID)
                }
                Button("Later", role: .cancel) { appModel.presets.openedPreset = nil }
            } message: {
                Text("“\(appModel.presets.openedPreset?.name ?? "")” is in your presets. Choose which parts to apply in Settings.")
            }
            // Saved games: the engine writes them while you play.
            .task {
                while !Task.isCancelled {
                    appModel.refreshSaves()
                    try? await Task.sleep(for: .seconds(4))
                }
            }
            .onChange(of: appModel.library.scanVersion) { Task { await appModel.warmUp() } }
            // Zips (AirDrop'd or in Files) and unpacked folders.
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.zip, .folder],
                          allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { appModel.library.importPicked(urls) }
            }
            // The engine can only fail this way from inside the (full,
            // passthrough-blocking) immersive space, where the player can't
            // see this window's banner. Drop back to it so they do.
            .onChange(of: appModel.engineFailureMessage) { _, message in
                guard message != nil, appModel.immersiveSpaceState != .closed else { return }
                Task { @MainActor in
                    appModel.immersiveSpaceState = .inTransition
                    await dismissImmersiveSpace()
                    appModel.immersiveSpaceState = .closed
                }
            }
        }
    }

    // Dev-only quick access to sv_cheats-gated console commands. Half-Life
    // ignores noclip/god/impulse 101/etc. unless `sv_cheats 1` is set, so the
    // toggle drives that first and the cheat buttons are disabled until it's on
    // (and until the engine is up — sending a worker cmd pre-init deadlocks).
    // The chapter picker (ChapterPicker) replaced the old "Warp to chapter" menu.
    @ViewBuilder
    private var cheatsSection: some View {
        let settings = appModel.gameSettings
        DisclosureGroup("Cheats") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Enable cheats (sv_cheats 1)", isOn: $cheatsEnabled)
                    .disabled(!settings.isEngineReady)
                    .onChange(of: cheatsEnabled) { _, on in
                        settings.command("sv_cheats \(on ? 1 : 0)")
                    }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)],
                          spacing: 8) {
                    cheatButton("Noclip", "noclip")
                    cheatButton("God mode", "god")
                    cheatButton("Notarget", "notarget")
                    cheatButton("All weapons + ammo", "impulse 101")
                    cheatButton("HEV suit", "impulse 82")
                    cheatButton("Spawn grunt", "impulse 76")
                    cheatButton("Show entity info", "impulse 106")
                    cheatButton("Suicide", "kill")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
        }
        .padding(.top, 8)
    }

    /// Shown in place of the game when the engine couldn't start — most
    /// commonly missing Half-Life assets (see Renderer.ensureEngineInitialized).
    private func engineFailureBanner(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Game data not ready", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.yellow)
            Text(message)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.yellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
    }

    private func cheatButton(_ label: String, _ command: String) -> some View {
        let settings = appModel.gameSettings
        // `kill` works without sv_cheats; everything else is gated on it.
        let needsCheats = command != "kill"
        return Button(label) { settings.command(command) }
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity)
            .disabled(!settings.isEngineReady || (needsCheats && !cheatsEnabled))
    }

    private func runSmokeTests() {
        let bridge = lambda_bridge_smoke_test()
        bridgeStatus = String(format: "0x%X", bridge)

        var nameBuf = [CChar](repeating: 0, count: 256)
        let count = nameBuf.withUnsafeMutableBufferPointer { buf in
            lambda_vulkan_smoke_test(buf.baseAddress, Int32(buf.count))
        }
        if count > 0 {
            let name = String(cString: nameBuf)
            vulkanStatus = "\(count) device(s) — \(name)"
        } else {
            vulkanStatus = "error \(count)"
        }

        var statusBuf = [CChar](repeating: 0, count: 384)
        let rc = statusBuf.withUnsafeMutableBufferPointer { buf in
            lambda_vulkan_create_device(buf.baseAddress, Int32(buf.count))
        }
        if rc == 0 {
            deviceStatus = String(cString: statusBuf)
        } else {
            deviceStatus = "error \(rc)"
        }

        if rc == 0 {
            var ioBuf = [CChar](repeating: 0, count: 256)
            let surfacePtr = ioBuf.withUnsafeMutableBufferPointer { buf in
                lambda_vulkan_clear_iosurface(1024, 1024, 0.2, 0.7, 0.95,
                                              buf.baseAddress, Int32(buf.count))
            }
            iosurfaceStatus = String(cString: ioBuf)
            if let p = surfacePtr {
                let s = Unmanaged<IOSurfaceRef>.fromOpaque(p).takeRetainedValue()
                iosurfaceStatus += " (\(IOSurfaceGetWidth(s))x\(IOSurfaceGetHeight(s)))"
            }
        }

        // Device + queue stay alive; immersive Renderer reuses them.

        // Engine init is deferred to the render thread (Renderer.swift) so
        // that R_Init's GLES calls run on the same thread holding the EGL
        // context. Status updates back to UI happen via the same path.
        engineStatus = "deferred to render thread"
    }
}

#Preview(windowStyle: .automatic) {
    ContentView()
        .environment(AppModel())
}
