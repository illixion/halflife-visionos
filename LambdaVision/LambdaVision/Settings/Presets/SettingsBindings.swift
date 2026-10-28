//
//  SettingsBindings.swift
//  LambdaVision
//
//  Ties each id in PresetSchema to its property on GameSettings, so a preset
//  can be read from and written to the live settings. Writing goes through
//  the properties, so each one persists and reaches the running game the
//  way a tap in Settings does (and the settings that only apply when the
//  immersive space restarts are noticed by SettingsView's reload prompt).
//

import Foundation

@MainActor
enum SettingsBindings {
    struct Access {
        let read: (GameSettings) -> PresetValue
        let write: (GameSettings, PresetValue) -> Void
    }

    private static func flag(_ keyPath: ReferenceWritableKeyPath<GameSettings, Bool>) -> Access {
        Access(read: { .bool($0[keyPath: keyPath]) },
               write: { if case .bool(let b) = $1 { $0[keyPath: keyPath] = b } })
    }
    private static func number(_ keyPath: ReferenceWritableKeyPath<GameSettings, Double>) -> Access {
        Access(read: { .number($0[keyPath: keyPath]) },
               write: { if case .number(let n) = $1 { $0[keyPath: keyPath] = n } })
    }
    private static func choice<E: RawRepresentable>(
        _ keyPath: ReferenceWritableKeyPath<GameSettings, E>) -> Access where E.RawValue == String {
        Access(read: { .text($0[keyPath: keyPath].rawValue) },
               write: { settings, value in
                   if case .text(let s) = value, let e = E(rawValue: s) { settings[keyPath: keyPath] = e }
               })
    }

    /// Keyed by PresetSchema id; `verify()` checks the two agree.
    static let table: [String: Access] = [
        "renderScale": number(\.renderScale),
        "foveatedEngine": flag(\.foveatedEngine),
        "fxaaEnabled": flag(\.fxaaEnabled),
        "engineMSAA": flag(\.engineMSAA),
        "linearColor": flag(\.linearColor),
        "gamma": number(\.gamma),
        "brightness": number(\.brightness),
        "reprojectionDepth": flag(\.reprojectionDepth),
        "glassReflections": flag(\.glassReflections),
        "waterReflections": flag(\.waterReflections),
        "sharpGlassReflections": flag(\.sharpGlassReflections),
        "sharpWaterReflections": flag(\.sharpWaterReflections),
        "waterMirrorMethod": choice(\.waterMirrorMethod),
        "waterRipples": number(\.waterRipples),
        "reflectionStrength": number(\.reflectionStrength),
        "progressiveImmersion": flag(\.progressiveImmersion),
        "avatarBody": flag(\.avatarBody),
        "avatarLegs": flag(\.avatarLegs),
        "weaponExternal": flag(\.weaponExternal),
        "weaponModel": choice(\.weaponModel),
        "hideParkedParts": flag(\.hideParkedParts),
        "flashlightOnGun": flag(\.flashlightOnGun),
        "hevHUD": flag(\.hevHUD),
        "aimReticle": choice(\.aimReticle),
        "dominantHand": choice(\.dominantHand),
        "fireAimMode": choice(\.fireAimMode),
        "gestureInputEnabled": flag(\.gestureInputEnabled),
        "altFireGesture": flag(\.altFireGesture),
        "altFireSensitivity": number(\.altFireSensitivity),
        "armSwingEnabled": flag(\.armSwingEnabled),
        "armSwingDirection": choice(\.armSwingDirection),
        "armSwingSensitivity": number(\.armSwingSensitivity),
        "handLongJump": flag(\.handLongJump),
        "wheelUtilities": flag(\.wheelUtilities),
        "wheelExpand": flag(\.wheelExpand),
        "fastWeaponSwitch": flag(\.fastWeaponSwitch),
        "inputMode": choice(\.inputMode),
        "flatHUDPlacement": choice(\.flatHUDPlacement),
        "mouseSensitivity": number(\.mouseSensitivity),
        "mouseSmoothing": flag(\.mouseSmoothing),
        "mouseSmoothingMs": number(\.mouseSmoothingMs),
        "snapTurnDegrees": number(\.snapTurnDegrees),
        "stickSmoothTurn": flag(\.stickSmoothTurn),
        "stickTurnSpeed": number(\.stickTurnSpeed),
        "lookPitch": flag(\.lookPitch),
        "freeAim": flag(\.freeAim),
        "freeAimYaw": number(\.freeAimYaw),
        "freeAimPitch": number(\.freeAimPitch),
        "freeAimShape": choice(\.freeAimShape),
        "freeAimAnchor": choice(\.freeAimAnchor),
        "freeAimFollow": number(\.freeAimFollow),
        "freeAimRealign": flag(\.freeAimRealign),
        "freeAimRealignAngle": number(\.freeAimRealignAngle),
        "freeAimRealignTime": number(\.freeAimRealignTime),
        "freeAimPivot": choice(\.freeAimPivot),
        "freeAimRecenter": flag(\.freeAimRecenter),
        "freeAimRecenterTime": number(\.freeAimRecenterTime),
        "freeAimUse": flag(\.freeAimUse),
        "inputCatcher": flag(\.inputCatcher),
        "inputCatcherAskBeforeLock": flag(\.inputCatcherAskBeforeLock),
        "inputCatcherRecenter": flag(\.inputCatcherRecenter),
        "sfxVolume": number(\.sfxVolume),
        "musicVolume": number(\.musicVolume),
    ]

    /// Ids the schema has and the table lacks, or the other way round, plus
    /// the options a choice setting's enum has that the schema doesn't list.
    /// Empty when everything agrees.
    static func verify() -> [String] {
        var problems: [String] = []
        let schemaIDs = Set(PresetSchema.byID.keys), tableIDs = Set(table.keys)
        problems += schemaIDs.subtracting(tableIDs).sorted().map { "schema has no binding: \($0)" }
        problems += tableIDs.subtracting(schemaIDs).sorted().map { "binding has no schema: \($0)" }
        return problems
    }
}

extension GameSettings {
    /// Every preset-able setting's present value, by id.
    func presetValues() -> [String: PresetValue] {
        var values: [String: PresetValue] = [:]
        for spec in PresetSchema.specs {
            if let access = SettingsBindings.table[spec.id] { values[spec.id] = access.read(self) }
        }
        return values
    }

    /// The present values of `categories` as a preset.
    func presetSnapshot(name: String, summary: String = "", categories: Set<PresetCategory>) -> SettingsPreset {
        let now = presetValues()
        var held: [PresetCategory: [String: PresetValue]] = [:]
        for category in categories {
            var values: [String: PresetValue] = [:]
            for spec in PresetSchema.specs(in: category) { values[spec.id] = now[spec.id] }
            if !values.isEmpty { held[category] = values }
        }
        return SettingsPreset(name: name, summary: summary, created: Date(), categories: held)
    }

    /// Writes the preset's values for `categories` into the live settings.
    /// Returns how many settings changed.
    @discardableResult
    func apply(_ preset: SettingsPreset, categories: Set<PresetCategory>) -> Int {
        var changed = 0
        let now = presetValues()
        for spec in PresetSchema.specs where categories.contains(spec.category) {
            guard let wanted = preset.values(in: spec.category)[spec.id],
                  let accepted = spec.accepting(wanted),
                  let access = SettingsBindings.table[spec.id],
                  !(now[spec.id]?.matches(accepted) ?? false) else { continue }
            access.write(self, accepted)
            changed += 1
        }
        return changed
    }

    /// For each category `preset` holds: whether this device already has it.
    func matches(_ preset: SettingsPreset) -> [PresetCategory: Bool] {
        let now = presetValues()
        return Dictionary(uniqueKeysWithValues: preset.heldCategories.map { ($0, preset.matches($0, current: now)) })
    }
}
