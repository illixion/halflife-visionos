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

struct ContentView: View {

    @Environment(AppModel.self) private var appModel

    @State private var showSettings = false
    @State private var cheatsEnabled = false
    @State private var bridgeStatus: String = "—"
    @State private var vulkanStatus: String = "—"
    @State private var deviceStatus: String = "—"
    @State private var iosurfaceStatus: String = "—"
    @State private var engineStatus: String = "—"

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                // Half-Life lambda mark (placeholder logo; swap a real HL
                // asset later). Replaced the RealityKit demo globe, which
                // rendered a volumetric sphere on top of the window content.
                ZStack {
                    Circle()
                        .fill(Color.orange.gradient)
                    Text("λ")
                        .font(.system(size: 76, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }
                .frame(width: 132, height: 132)
                .padding(.bottom, 20)

                Text("Lambda VisionPro").font(.largeTitle)

                ToggleImmersiveSpaceButton()

                cheatsSection

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
                .padding(.top, 8)
            }
            .padding()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .help("Settings")
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView().environment(appModel)
            }
            .onAppear { runSmokeTests() }
        }
    }

    // Dev-only quick access to sv_cheats-gated console commands. Half-Life
    // ignores noclip/god/impulse 101/etc. unless `sv_cheats 1` is set, so the
    // toggle drives that first and the cheat buttons are disabled until it's on
    // (and until the engine is up — sending a worker cmd pre-init deadlocks).
    // Full-game chapter starts (map id → title), taken from valve/titles.txt as
    // shipped in this build. `map <id>` does a clean load, so this doesn't need
    // sv_cheats — just a live engine.
    private static let chapters: [(id: String, name: String)] = [
        ("c0a0", "Black Mesa Inbound"),
        ("c1a0", "Anomalous Materials"),
        ("c1a1", "Unforeseen Consequences"),
        ("c1a2", "Office Complex"),
        ("c1a3", "\"We've Got Hostiles\""),
        ("c1a4", "Blast Pit"),
        ("c2a1", "Power Up"),
        ("c2a2", "On A Rail"),
        ("c2a3", "Apprehension"),
        ("c2a4", "Residue Processing"),
        ("c2a5", "Surface Tension"),
        ("c3a1", "\"Forget About Freeman!\""),
        ("c3a2", "Lambda Core"),
        ("c4a1", "Xen"),
        ("c4a2", "Gonarch's Lair"),
        ("c4a3", "Nihilanth"),
        ("c5a1", "Endgame"),
    ]

    @ViewBuilder
    private var cheatsSection: some View {
        let settings = appModel.gameSettings
        DisclosureGroup("Cheats") {
            VStack(alignment: .leading, spacing: 10) {
                Menu("Warp to chapter") {
                    ForEach(Self.chapters, id: \.id) { c in
                        Button("\(c.id) — \(c.name)") { settings.command("map \(c.id)") }
                    }
                }
                .disabled(!settings.isEngineReady)

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
