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

    @State private var bridgeStatus: String = "—"
    @State private var vulkanStatus: String = "—"
    @State private var deviceStatus: String = "—"
    @State private var iosurfaceStatus: String = "—"

    var body: some View {
        VStack(spacing: 16) {
            Model3D(named: "Scene", bundle: realityKitContentBundle)
                .padding(.bottom, 30)

            Text("Lambda VisionPro").font(.largeTitle)

            VStack(alignment: .leading, spacing: 8) {
                Text("C bridge: \(bridgeStatus)")
                Text("Vulkan / MoltenVK: \(vulkanStatus)")
                Text("VkDevice: \(deviceStatus)")
                Text("IOSurface clear: \(iosurfaceStatus)")
            }
            .font(.system(.body, design: .monospaced))

            ToggleImmersiveSpaceButton()
        }
        .padding()
        .onAppear { runSmokeTests() }
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
    }
}

#Preview(windowStyle: .automatic) {
    ContentView()
        .environment(AppModel())
}
