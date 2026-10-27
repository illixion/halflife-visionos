//
//  GraphicsSettingsPages.swift
//  LambdaVision
//
//  Settings › Graphics (resolution, edge smoothing, colour, depth) and
//  Settings › Reflections & Water (the modern-lighting prototypes).
//
//  Foveated rendering and render scale size the render targets, so they take
//  effect when the immersive space reopens; SettingsView offers the reload.
//  Everything else here is read per frame and applies live.
//

import SwiftUI

struct GraphicsSettingsPage: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var settings = appModel.gameSettings
        SettingsPage("Graphics") {
            Section {
                Toggle("Foveated rendering", isOn: $settings.foveatedEngine)
                SettingsSlider("Render scale", $settings.renderScale, 0.5...1.0, 0.05) {
                    String(format: "%.0f%%", $0 * 100)
                }
                .disabled(settings.foveatedEngine)
            } header: {
                Text("Resolution")
            } footer: {
                Text("Render scale resizes the render targets, so it applies when the immersive space restarts — you'll be offered a reload on closing.")
            }

            // Anti-aliasing: every way of smoothing edges belongs in this
            // section, with its explanation in the footer.
            Section {
                // No MetalFX toggle here on purpose: the optional
                // FXAA-pass → MetalFX-spatial chain added two
                // full-logical-resolution passes per eye and measured
                // ~13-14 ms GPU/frame (~50 FPS), and its upscale to the
                // full drawable fought the compositor's own foveated
                // upsampling. GameSettings.metalFXEnabled forces it off
                // at startup; the scaler code stays compiled in case a
                // cheaper configuration brings it back. Edge smoothing is
                // the toggle below, folded into the composite pass.
                Toggle("Edge smoothing (FXAA)", isOn: $settings.fxaaEnabled)
            } header: {
                Text("Edge smoothing")
            } footer: {
                Text("Edge smoothing runs inside the pass that already draws the game to the display, so it applies immediately and costs no extra pass; turn it off if distant HUD or console text looks soft.")
            }

            Section {
                Toggle("Linear colour", isOn: $settings.linearColor)
                SettingsSlider("Gamma", $settings.gamma, 1.8...3.6, 0.1) {
                    String(format: "%.1f", $0)
                }
                SettingsSlider("Brightness", $settings.brightness, 0.0...1.0, 0.05) {
                    String(format: "%.2f", $0)
                }
            } header: {
                Text("Colour")
            } footer: {
                Text("Linear colour shows the game's shading as it was drawn for a CRT, with true darks; off is the older, lifted look. Gamma may want retuning after switching it.")
            }

            Section {
                Toggle("Per-pixel reprojection depth", isOn: $settings.reprojectionDepth)
            } header: {
                Text("Depth")
            } footer: {
                Text("Per-pixel reprojection depth tells the headset how far away each pixel is, so near walls and the gun hold still when you move your head between frames; off treats the whole image as distant, as before.")
            }
        }
    }
}

struct ReflectionSettingsPage: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var settings = appModel.gameSettings
        SettingsPage("Reflections & Water") {
            Section {
                Toggle("Glass reflections (prototype)", isOn: $settings.glassReflections)
                Toggle("Water reflections (prototype)", isOn: $settings.waterReflections)
                Toggle("Sharp water reflections", isOn: $settings.sharpWaterReflections)
                    .disabled(!settings.waterReflections)
                Toggle("Sharp glass reflections", isOn: $settings.sharpGlassReflections)
                    .disabled(!settings.glassReflections)
                Picker("Sharp reflection method", selection: $settings.waterMirrorMethod) {
                    ForEach(WaterMirrorMethod.allCases) { Text($0.label).tag($0) }
                }
                .disabled(!(settings.waterReflections && settings.sharpWaterReflections)
                          && !(settings.glassReflections && settings.sharpGlassReflections))
            } footer: {
                Text("Glass reflections add a reflection to windows and glass, strongest at glancing angles, like real glass; water reflections do the same for water, with gentle ripples (Water ripples; 0 is a still mirror), and Sharp water reflections mirror what you see in flat water instead of only the room's general shape. Sharp glass reflections do the same for windows when the method is Rendered or Ray traced: Rendered draws the view again from your mirror image for the window or water filling most of your view, Ray traced follows every reflected ray (fast on chips with ray-tracing hardware). Otherwise glass reflects a snapshot of the room around you, which bends what is close to the pane. Both are prototypes of modern lighting.")
            }

            Section {
                SettingsSlider("Water ripples", $settings.waterRipples, 0.0...3.0, 0.25) {
                    String(format: "%.2g×", $0)
                }
                SettingsSlider("Reflection strength", $settings.reflectionStrength, 0.5...4.0, 0.25) {
                    String(format: "%.2g×", $0)
                }
            } footer: {
                Text("Reflection strength scales both: 1× is close to physical and faint in this art.")
            }
        }
    }
}
