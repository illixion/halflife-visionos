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
    @State private var engineStatus: String = "—"

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
                Text("Engine: \(engineStatus)")
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

        // Engine boot smoke test: console + filesystem only, no rendering yet.
        let appSupport = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true))?.path ?? NSTemporaryDirectory()
        let basedir = (appSupport as NSString).appendingPathComponent("xash3d")
        // Read-only game data is bundled into the .app at build time
        // (see "Bundle HalfLifeAssets" build phase). Engine reads PAKs from
        // -rodir, writes configs/saves to basedir.
        let rodir = (Bundle.main.resourcePath ?? "") + "/GameData"
        let extra = ["-dev", "2", "-console", "-noip", "-rodir", rodir, "-game", "valve"]
        let cArgs = extra.map { strdup($0) }
        defer { cArgs.forEach { free($0) } }
        var engineBuf = [CChar](repeating: 0, count: 384)
        let erc = basedir.withCString { dir in
            cArgs.withUnsafeBufferPointer { argv -> Int32 in
                let argvPtrs = argv.baseAddress?.withMemoryRebound(
                    to: UnsafePointer<CChar>?.self, capacity: argv.count) { $0 }
                return engineBuf.withUnsafeMutableBufferPointer { buf in
                    lambda_engine_init(dir, Int32(extra.count), argvPtrs,
                                       buf.baseAddress, Int32(buf.count))
                }
            }
        }
        engineStatus = "rc=\(erc) \(String(cString: engineBuf))"
    }
}

#Preview(windowStyle: .automatic) {
    ContentView()
        .environment(AppModel())
}
