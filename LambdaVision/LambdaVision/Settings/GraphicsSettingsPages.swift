//
//  GraphicsSettingsPages.swift
//  LambdaVision
//
//  Settings › Graphics (resolution, edge smoothing, colour, depth) and
//  Settings › Reflections & Water (the modern-lighting prototypes). What
//  each control does is said in the preview column (SettingHelp), so the
//  footers here are one line at most.
//
//  Foveated rendering, render scale and MSAA size or format the render
//  targets, so they take effect when the immersive space reopens;
//  SettingsView offers the reload.
//  Everything else here is read per frame and applies live.
//

import SwiftUI

struct GraphicsSettingsPage: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var settings = appModel.gameSettings
        SettingsPage("Graphics", preview: "foveatedEngine") {
            Section("Resolution") {
                Toggle("Foveated rendering", isOn: $settings.foveatedEngine)
                    .previews("foveatedEngine", value: settings.foveatedEngine)
                SettingsSlider("Render scale", $settings.renderScale, 0.5...1.0, 0.05) {
                    String(format: "%.0f%%", $0 * 100)
                }
                .disabled(settings.foveatedEngine)
                .previews("renderScale", value: settings.renderScale)
            }

            // Anti-aliasing: every way of smoothing edges belongs in this
            // section. No MetalFX toggle here on purpose: the optional
            // FXAA-pass → MetalFX-spatial chain added two
            // full-logical-resolution passes per eye and measured
            // ~13-14 ms GPU/frame (~50 FPS), and its upscale to the
            // full drawable fought the compositor's own foveated
            // upsampling. GameSettings.metalFXEnabled forces it off
            // at startup; the scaler code stays compiled in case a
            // cheaper configuration brings it back. Edge smoothing is
            // the FXAA choice below, folded into the composite pass.
            Section("Edge smoothing") {
                Picker("Edge smoothing", selection: $settings.edgeSmoothing) {
                    ForEach(EdgeSmoothing.allCases) { Text($0.label).tag($0) }
                }
                .previews("edgeSmoothing", value: settings.edgeSmoothing)
            }

            Section("Colour") {
                Toggle("Linear colour", isOn: $settings.linearColor)
                    .previews("linearColor", value: settings.linearColor)
                SettingsSlider("Gamma", $settings.gamma, 1.8...3.6, 0.1) {
                    String(format: "%.1f", $0)
                }
                .previews("gamma", value: settings.gamma)
                SettingsSlider("Brightness", $settings.brightness, 0.0...1.0, 0.05) {
                    String(format: "%.2f", $0)
                }
                .previews("brightness", value: settings.brightness)
            }

            Section("Depth") {
                Toggle("Per-pixel reprojection depth", isOn: $settings.reprojectionDepth)
                    .previews("reprojectionDepth", value: settings.reprojectionDepth)
            }
        }
    }
}

struct ReflectionSettingsPage: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var settings = appModel.gameSettings
        SettingsPage("Reflections & Water", preview: "glassReflections") {
            Section {
                Toggle("Glass reflections (prototype)", isOn: $settings.glassReflections)
                    .previews("glassReflections", value: settings.glassReflections)
                Toggle("Water reflections (prototype)", isOn: $settings.waterReflections)
                    .previews("waterReflections", value: settings.waterReflections)
                Toggle("Sharp water reflections", isOn: $settings.sharpWaterReflections)
                    .disabled(!settings.waterReflections)
                    .previews("sharpWaterReflections", value: settings.sharpWaterReflections)
                Toggle("Sharp glass reflections", isOn: $settings.sharpGlassReflections)
                    .disabled(!settings.glassReflections)
                    .previews("sharpGlassReflections", value: settings.sharpGlassReflections)
                Picker("Sharp reflection method", selection: $settings.waterMirrorMethod) {
                    ForEach(WaterMirrorMethod.allCases) { Text($0.label).tag($0) }
                }
                .disabled(!(settings.waterReflections && settings.sharpWaterReflections)
                          && !(settings.glassReflections && settings.sharpGlassReflections))
                .previews("waterMirrorMethod", value: settings.waterMirrorMethod)
            } footer: {
                Text("Both are prototypes of modern lighting.")
            }

            Section {
                SettingsSlider("Water ripples", $settings.waterRipples, 0.0...3.0, 0.25) {
                    String(format: "%.2g×", $0)
                }
                .previews("waterRipples", value: settings.waterRipples)
                SettingsSlider("Reflection strength", $settings.reflectionStrength, 0.5...4.0, 0.25) {
                    String(format: "%.2g×", $0)
                }
                .previews("reflectionStrength", value: settings.reflectionStrength)
            }
        }
    }
}
