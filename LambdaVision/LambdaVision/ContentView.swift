//
//  ContentView.swift
//  LambdaVision
//
//  Created by Ixion on 10/05/2026.
//

import SwiftUI
import RealityKit
import RealityKitContent

struct ContentView: View {

    @State private var bridgeStatus: String = "—"
    @State private var vulkanStatus: String = "—"

    var body: some View {
        VStack(spacing: 16) {
            Model3D(named: "Scene", bundle: realityKitContentBundle)
                .padding(.bottom, 30)

            Text("Lambda VisionPro").font(.largeTitle)

            VStack(alignment: .leading, spacing: 8) {
                Text("C bridge: \(bridgeStatus)")
                Text("Vulkan / MoltenVK: \(vulkanStatus)")
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
    }
}

#Preview(windowStyle: .automatic) {
    ContentView()
        .environment(AppModel())
}
