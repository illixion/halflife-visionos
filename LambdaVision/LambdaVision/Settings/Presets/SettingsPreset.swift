//
//  SettingsPreset.swift
//  LambdaVision
//
//  A settings preset: named values for some of the setting categories, as
//  one JSON file (`.lambdapreset`) that can be saved, shared and loaded.
//  This file is Foundation only and shared with Tools/PresetProbe, which
//  checks the file format and the matching rules on the Mac.
//
//  What a preset may hold is the schema below (`PresetSchema`): every
//  setting's id, its category and what values it takes. A file written by a
//  newer build can name settings this one doesn't have, and a hand-edited
//  one can hold values out of range, so loading keeps only what the schema
//  accepts (`sanitized`) rather than trusting the file.
//

import Foundation

/// The groups of settings a preset saves and applies together. The Apply
/// sheet offers one checkbox per category the preset holds.
nonisolated enum PresetCategory: String, CaseIterable, Codable, Identifiable, Sendable {
    case graphics, reflections, immersion, hands, controls, audio

    var id: String { rawValue }

    var title: String {
        switch self {
        case .graphics: "Graphics"
        case .reflections: "Reflections & Water"
        case .immersion: "Immersion"
        case .hands: "Hands"
        case .controls: "Keyboard, Mouse & Gamepad"
        case .audio: "Audio"
        }
    }

    var systemImage: String {
        switch self {
        case .graphics: "sparkles.tv"
        case .reflections: "drop"
        case .immersion: "figure.stand"
        case .hands: "hand.raised"
        case .controls: "gamecontroller"
        case .audio: "speaker.wave.2"
        }
    }

    /// One line under the checkbox: what applying it changes.
    var blurb: String {
        switch self {
        case .graphics: "Resolution, edge smoothing, colour and depth"
        case .reflections: "Glass and water reflections"
        case .immersion: "Portal or full view, your body, the weapon in your hand and the HUD"
        case .hands: "Finger gun, movement gestures and the weapon wheel"
        case .controls: "Input mode, mouse, turning and free aim"
        case .audio: "Sound effect and music volume"
        }
    }
}

/// One setting's value in a preset file.
nonisolated enum PresetValue: Codable, Hashable, Sendable {
    case bool(Bool)
    case number(Double)
    case text(String)

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else { self = .text(try c.decode(String.self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .text(let s): try c.encode(s)
        }
    }

    /// Equal for matching purposes: numbers within a rounding error.
    func matches(_ other: PresetValue) -> Bool {
        if case .number(let a) = self, case .number(let b) = other { return abs(a - b) < 1e-6 }
        return self == other
    }
}

/// What one setting takes.
nonisolated enum SettingKind: Sendable {
    case bool
    case number(ClosedRange<Double>)
    case choice([String])
}

nonisolated struct SettingSpec: Sendable {
    let id: String
    let title: String
    let category: PresetCategory
    let kind: SettingKind

    /// The value if this setting accepts it, clamped into range; nil if not.
    func accepting(_ value: PresetValue) -> PresetValue? {
        switch (kind, value) {
        case (.bool, .bool): return value
        case (.number(let r), .number(let n)):
            guard n.isFinite else { return nil }
            return .number(min(max(n, r.lowerBound), r.upperBound))
        case (.choice(let options), .text(let s)): return options.contains(s) ? value : nil
        default: return nil
        }
    }
}

/// Every setting a preset can hold. Settings that belong to this device or
/// to a session (developer mode, the debug server, the chosen game) are not
/// here on purpose: a preset someone sends you must not turn those on.
nonisolated enum PresetSchema {
    /// What the settings are called, for the Apply sheet's list of changes.
    private static let titles: [String: String] = [
        "renderScale": "Render scale",
        "foveatedEngine": "Foveated rendering",
        "fxaaEnabled": "FXAA edge smoothing",
        "engineMSAA": "4× MSAA",
        "linearColor": "Linear colour",
        "gamma": "Gamma",
        "brightness": "Brightness",
        "reprojectionDepth": "Per-pixel reprojection depth",
        "glassReflections": "Glass reflections",
        "waterReflections": "Water reflections",
        "sharpGlassReflections": "Sharp glass reflections",
        "sharpWaterReflections": "Sharp water reflections",
        "waterMirrorMethod": "Sharp reflection method",
        "waterRipples": "Water ripples",
        "reflectionStrength": "Reflection strength",
        "progressiveImmersion": "Progressive immersion",
        "avatarBody": "First-person body",
        "avatarLegs": "Legs",
        "weaponExternal": "Hand-tracked weapon model",
        "weaponModel": "Weapon model",
        "hideParkedParts": "Hide parked weapon parts",
        "flashlightOnGun": "Gun-mounted flashlight",
        "hevHUD": "HEV suit holograms",
        "aimReticle": "Aim reticle",
        "dominantHand": "Dominant hand",
        "fireAimMode": "Fire aims at",
        "gestureInputEnabled": "Immersive gesture input",
        "altFireGesture": "Alt-fire gesture",
        "altFireSensitivity": "Alt-fire sensitivity",
        "armSwingEnabled": "Arm-swing walking",
        "armSwingDirection": "Swing direction",
        "armSwingSensitivity": "Swing sensitivity",
        "handLongJump": "Long jump at a run",
        "wheelUtilities": "Wheel: flashlight, quick save/load",
        "wheelExpand": "Wheel: reach past the rim",
        "fastWeaponSwitch": "Fast weapon switch",
        "inputMode": "Input mode",
        "flatHUDPlacement": "HEV holograms placement",
        "mouseSensitivity": "Mouse sensitivity",
        "mouseSmoothing": "Mouse smoothing",
        "mouseSmoothingMs": "Mouse smoothing time",
        "snapTurnDegrees": "Snap-turn angle",
        "stickSmoothTurn": "Smooth stick turning",
        "stickTurnSpeed": "Stick turn speed",
        "lookPitch": "Look up/down with mouse and stick",
        "freeAim": "Free aim",
        "freeAimYaw": "Free-aim zone width",
        "freeAimPitch": "Free-aim zone height",
        "freeAimShape": "Zone shape",
        "freeAimAnchor": "Zone centred on",
        "freeAimFollow": "Head follow lag",
        "freeAimRealign": "Turn the zone toward a turned head",
        "freeAimRealignAngle": "Realign once the head is past",
        "freeAimRealignTime": "Realign catch-up time",
        "freeAimPivot": "Weapon turns about",
        "freeAimRecenter": "Re-centre the aim when idle",
        "freeAimRecenterTime": "Re-centre speed",
        "freeAimUse": "Use (E) picks what the gun points at",
        "inputCatcher": "Mouse capture window",
        "inputCatcherAskBeforeLock": "Ask before locking the mouse",
        "inputCatcherRecenter": "Re-centre capture window",
        "sfxVolume": "Sound effects",
        "musicVolume": "Music",
    ]

    private static func b(_ id: String, _ c: PresetCategory) -> SettingSpec {
        SettingSpec(id: id, title: titles[id] ?? id, category: c, kind: .bool)
    }
    private static func n(_ id: String, _ c: PresetCategory, _ r: ClosedRange<Double>) -> SettingSpec {
        SettingSpec(id: id, title: titles[id] ?? id, category: c, kind: .number(r))
    }
    private static func e(_ id: String, _ c: PresetCategory, _ options: [String]) -> SettingSpec {
        SettingSpec(id: id, title: titles[id] ?? id, category: c, kind: .choice(options))
    }

    static let specs: [SettingSpec] = [
        // Graphics
        n("renderScale", .graphics, 0.5...1.0),
        b("foveatedEngine", .graphics),
        b("fxaaEnabled", .graphics),
        b("engineMSAA", .graphics),
        b("linearColor", .graphics),
        n("gamma", .graphics, 1.8...3.6),
        n("brightness", .graphics, 0...1),
        b("reprojectionDepth", .graphics),
        // Reflections & water
        b("glassReflections", .reflections),
        b("waterReflections", .reflections),
        b("sharpGlassReflections", .reflections),
        b("sharpWaterReflections", .reflections),
        e("waterMirrorMethod", .reflections, ["screenSpace", "rendered", "rayTraced"]),
        n("waterRipples", .reflections, 0...3),
        n("reflectionStrength", .reflections, 0.5...4),
        // Immersion: the portal, your body, the weapon in your hand, the HUD
        b("progressiveImmersion", .immersion),
        b("avatarBody", .immersion),
        b("avatarLegs", .immersion),
        b("weaponExternal", .immersion),
        e("weaponModel", .immersion, ["viewmodel", "world"]),
        b("hideParkedParts", .immersion),
        b("flashlightOnGun", .immersion),
        b("hevHUD", .immersion),
        e("aimReticle", .immersion, ["off", "dot", "beam"]),
        // Hands
        e("dominantHand", .hands, ["right", "left"]),
        e("fireAimMode", .hands, ["barrel", "gaze"]),
        b("gestureInputEnabled", .hands),
        b("altFireGesture", .hands),
        n("altFireSensitivity", .hands, 0.5...2),
        b("armSwingEnabled", .hands),
        e("armSwingDirection", .hands, ["head", "hands"]),
        n("armSwingSensitivity", .hands, 0.5...2),
        b("handLongJump", .hands),
        b("wheelUtilities", .hands),
        b("wheelExpand", .hands),
        b("fastWeaponSwitch", .hands),
        // Keyboard, mouse & gamepad
        e("inputMode", .controls, ["auto", "hands", "keyboardMouse", "gamepad"]),
        e("flatHUDPlacement", .controls, ["followView", "hands"]),
        n("mouseSensitivity", .controls, 0.5...10),
        b("mouseSmoothing", .controls),
        n("mouseSmoothingMs", .controls, 5...100),
        n("snapTurnDegrees", .controls, 15...45),
        b("stickSmoothTurn", .controls),
        n("stickTurnSpeed", .controls, 45...240),
        b("lookPitch", .controls),
        b("freeAim", .controls),
        n("freeAimYaw", .controls, 0...45),
        n("freeAimPitch", .controls, 0...60),
        e("freeAimShape", .controls, ["ellipse", "rectangle"]),
        e("freeAimAnchor", .controls, ["body", "head"]),
        n("freeAimFollow", .controls, 0.1...1.5),
        b("freeAimRealign", .controls),
        n("freeAimRealignAngle", .controls, 15...90),
        n("freeAimRealignTime", .controls, 0.3...5),
        e("freeAimPivot", .controls, ["shoulder", "hand", "eye"]),
        b("freeAimRecenter", .controls),
        n("freeAimRecenterTime", .controls, 0.2...3),
        b("freeAimUse", .controls),
        b("inputCatcher", .controls),
        b("inputCatcherAskBeforeLock", .controls),
        b("inputCatcherRecenter", .controls),
        // Audio
        n("sfxVolume", .audio, 0...1),
        n("musicVolume", .audio, 0...1),
    ]

    static let byID: [String: SettingSpec] = Dictionary(uniqueKeysWithValues: specs.map { ($0.id, $0) })

    static func specs(in category: PresetCategory) -> [SettingSpec] {
        specs.filter { $0.category == category }
    }
}

nonisolated struct SettingsPreset: Codable, Identifiable, Hashable, Sendable {
    static let formatName = "lambdavision.preset"
    static let currentVersion = 1
    /// The file extension, and the type Info.plist exports for it.
    static let fileExtension = "lambdapreset"

    var id: String
    var name: String
    var summary: String
    var created: Date?
    /// category raw value → setting id → value. Keyed by strings so a
    /// category a newer build adds doesn't make the file unreadable.
    var categories: [String: [String: PresetValue]]
    /// Ours (shipped with the app): can't be edited or deleted. Not saved.
    var isBuiltIn: Bool = false

    private enum CodingKeys: String, CodingKey {
        case format, version, id, name, summary, created, categories
    }

    init(id: String = UUID().uuidString, name: String, summary: String = "", created: Date? = nil,
         categories: [PresetCategory: [String: PresetValue]], isBuiltIn: Bool = false) {
        self.id = id
        self.name = name
        self.summary = summary
        self.created = created
        self.categories = Dictionary(uniqueKeysWithValues: categories.map { ($0.key.rawValue, $0.value) })
        self.isBuiltIn = isBuiltIn
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard try c.decodeIfPresent(String.self, forKey: .format) == Self.formatName else {
            throw PresetFileError.notAPreset
        }
        let version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        guard version <= Self.currentVersion else { throw PresetFileError.newerVersion(version) }
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try c.decode(String.self, forKey: .name)
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        created = try c.decodeIfPresent(Date.self, forKey: .created)
        categories = try c.decode([String: [String: PresetValue]].self, forKey: .categories)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.formatName, forKey: .format)
        try c.encode(Self.currentVersion, forKey: .version)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(summary, forKey: .summary)
        try c.encodeIfPresent(created, forKey: .created)
        try c.encode(categories, forKey: .categories)
    }

    // MARK: Reading

    /// The categories this preset holds settings for, in the schema's order.
    var heldCategories: [PresetCategory] {
        PresetCategory.allCases.filter { !(categories[$0.rawValue]?.isEmpty ?? true) }
    }

    func values(in category: PresetCategory) -> [String: PresetValue] {
        categories[category.rawValue] ?? [:]
    }

    /// The preset with only what the schema accepts: unknown settings are
    /// dropped, values clamped into range, a setting filed under the wrong
    /// category moved nowhere (it is dropped too), and emptied categories
    /// removed.
    var sanitized: SettingsPreset {
        var copy = self
        copy.categories = [:]
        for category in PresetCategory.allCases {
            var kept: [String: PresetValue] = [:]
            for (id, value) in values(in: category) {
                guard let spec = PresetSchema.byID[id], spec.category == category,
                      let accepted = spec.accepting(value) else { continue }
                kept[id] = accepted
            }
            if !kept.isEmpty { copy.categories[category.rawValue] = kept }
        }
        return copy
    }

    /// Whether `current` (the present value of each setting) already has
    /// every value this preset holds for `category`. False for a category
    /// the preset doesn't hold.
    func matches(_ category: PresetCategory, current: [String: PresetValue]) -> Bool {
        let wanted = values(in: category)
        guard !wanted.isEmpty else { return false }
        return wanted.allSatisfy { id, value in current[id]?.matches(value) ?? false }
    }

    /// A copy holding only `categories`.
    func limited(to wanted: Set<PresetCategory>) -> SettingsPreset {
        var copy = self
        copy.categories = categories.filter { key, _ in
            PresetCategory(rawValue: key).map(wanted.contains) ?? false
        }
        return copy
    }

    // MARK: Files

    static func decode(_ data: Data) throws -> SettingsPreset {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let preset: SettingsPreset
        do { preset = try decoder.decode(SettingsPreset.self, from: data) }
        catch let error as PresetFileError { throw error }
        catch { throw PresetFileError.notAPreset }
        let clean = preset.sanitized
        guard !clean.categories.isEmpty else { throw PresetFileError.empty }
        return clean
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
}

nonisolated enum PresetFileError: Error, Equatable, LocalizedError {
    case notAPreset
    case newerVersion(Int)
    case empty

    var errorDescription: String? {
        switch self {
        case .notAPreset: "This isn't a LambdaVision settings preset."
        case .newerVersion: "This preset was made by a newer version of LambdaVision."
        case .empty: "This preset has no settings this version understands."
        }
    }
}
