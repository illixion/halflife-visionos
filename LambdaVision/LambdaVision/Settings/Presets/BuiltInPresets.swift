//
//  BuiltInPresets.swift
//  LambdaVision
//
//  The presets that ship with the app. Each holds only the categories it is
//  about, and within them only the settings that define it, so applying one
//  leaves your hand, volumes and gamma alone unless you ask for those.
//  The ids are fixed: a saved "last applied" refers to them.
//

import Foundation

nonisolated enum BuiltInPresets {
    static let enhancedID = "builtin.enhanced"
    static let classicID = "builtin.classic"
    static let performanceID = "builtin.performance"

    /// `rayTracingCapable`: the GPU has hardware ray tracing worth
    /// recommending (the M5 headset). Enhanced then picks ray-traced
    /// reflections; elsewhere it picks the engine-rendered mirror, which
    /// every headset runs.
    static func all(rayTracingCapable: Bool) -> [SettingsPreset] {
        [enhanced(rayTracingCapable: rayTracingCapable), classic, performance]
    }

    /// Half-Life as it is in a headset: reflections, your body, the weapon
    /// in your hand and the holographic HUD.
    static func enhanced(rayTracingCapable: Bool) -> SettingsPreset {
        SettingsPreset(
            id: enhancedID,
            name: "Enhanced",
            summary: "The full headset treatment: 4× MSAA with FXAA, reflections in glass and water, your own body and legs, the weapon in your hand, holographic HUD and hand gestures.",
            categories: [
                .graphics: [
                    "foveatedEngine": .bool(true), "fxaaEnabled": .bool(true), "engineMSAA": .bool(true),
                    "linearColor": .bool(true), "reprojectionDepth": .bool(true),
                ],
                .reflections: [
                    "glassReflections": .bool(true), "waterReflections": .bool(true),
                    "sharpGlassReflections": .bool(true), "sharpWaterReflections": .bool(true),
                    "waterMirrorMethod": .text(rayTracingCapable ? "rayTraced" : "rendered"),
                    "waterRipples": .number(1), "reflectionStrength": .number(3),
                ],
                .immersion: [
                    "progressiveImmersion": .bool(true),
                    "avatarBody": .bool(true), "avatarLegs": .bool(true),
                    "weaponExternal": .bool(true), "weaponModel": .text("viewmodel"),
                    "hideParkedParts": .bool(true), "flashlightOnGun": .bool(true),
                    "hevHUD": .bool(true), "aimReticle": .text("dot"),
                ],
                .hands: [
                    "gestureInputEnabled": .bool(true), "altFireGesture": .bool(true),
                    "armSwingEnabled": .bool(true), "handLongJump": .bool(true),
                    "wheelUtilities": .bool(true), "wheelExpand": .bool(true),
                    "fastWeaponSwitch": .bool(true),
                ],
            ],
            isBuiltIn: true)
    }

    /// Half-Life as it was drawn: no reflections, no body, the engine's own
    /// weapon and HUD, the way the game ships. Invisible tech (foveation,
    /// reprojection depth) stays on so it still runs and feels right.
    static let classic = SettingsPreset(
        id: classicID,
        name: "Classic",
        summary: "As close to the original game as a headset allows: no reflections, no body, the engine's own weapon, flashlight and flat HUD.",
        categories: [
            .graphics: [
                "foveatedEngine": .bool(true), "fxaaEnabled": .bool(false), "engineMSAA": .bool(false),
                "linearColor": .bool(true), "reprojectionDepth": .bool(true),
            ],
            .reflections: [
                "glassReflections": .bool(false), "waterReflections": .bool(false),
                "sharpGlassReflections": .bool(false), "sharpWaterReflections": .bool(false),
            ],
            .immersion: [
                "avatarBody": .bool(false), "avatarLegs": .bool(false),
                "weaponExternal": .bool(false), "flashlightOnGun": .bool(false),
                "hevHUD": .bool(false), "aimReticle": .text("off"),
            ],
        ],
        isBuiltIn: true)

    /// The lightest the game goes while still looking like Half-Life.
    static let performance = SettingsPreset(
        id: performanceID,
        name: "Performance",
        summary: "For the smoothest frame rate: no reflections, no extra edge smoothing, reduced resolution away from where you look.",
        categories: [
            .graphics: [
                "foveatedEngine": .bool(true), "fxaaEnabled": .bool(false), "engineMSAA": .bool(false),
                "reprojectionDepth": .bool(true),
            ],
            .reflections: [
                "glassReflections": .bool(false), "waterReflections": .bool(false),
                "sharpGlassReflections": .bool(false), "sharpWaterReflections": .bool(false),
            ],
        ],
        isBuiltIn: true)
}
