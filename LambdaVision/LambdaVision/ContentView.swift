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

                DisclosureGroup("Diagnostics") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("C bridge: \(bridgeStatus)")
                        Text("Vulkan / MoltenVK: \(vulkanStatus)")
                        Text("VkDevice: \(deviceStatus)")
                        Text("IOSurface clear: \(iosurfaceStatus)")
                        Text("Engine: \(engineStatus)")
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
