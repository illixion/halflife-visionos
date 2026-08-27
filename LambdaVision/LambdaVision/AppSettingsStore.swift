//
//  AppSettingsStore.swift
//  LambdaVision
//
//  UserDefaults-backed persistence for the player-facing settings surfaced in
//  SettingsView. Each property is a getter/setter pair around a namespaced
//  `lambdavision.settings.*` key. GameSettings reads these as its stored-
//  property defaults and writes back from `didSet`, so adding a persistent
//  setting is: a key + accessor here, a property + one-line `didSet` there.
//
//  Enums persist as `rawValue` strings (robust to case reordering; unknown
//  values fall back to the in-code default rather than crashing). Doubles use
//  an explicit missing-key check because UserDefaults returns 0 for absent
//  keys, which would be a wrong default for e.g. render scale or volume.
//
//  Pattern mirrors an equivalent store in a sibling app.
//

import Foundation

@MainActor
enum AppSettingsStore {
    private static let defaults = UserDefaults.standard

    private static func double(_ key: String, _ fallback: Double) -> Double {
        (defaults.object(forKey: key) as? Double) ?? fallback
    }
    private static func bool(_ key: String, _ fallback: Bool) -> Bool {
        (defaults.object(forKey: key) as? Bool) ?? fallback
    }

    // MARK: Graphics
    private static let renderScaleKey     = "lambdavision.settings.renderScale"
    private static let metalFXEnabledKey  = "lambdavision.settings.metalFXEnabled"
    private static let fxaaEnabledKey     = "lambdavision.settings.fxaaEnabled"
    private static let gammaKey           = "lambdavision.settings.gamma"
    private static let brightnessKey      = "lambdavision.settings.brightness"
    private static let snapTurnDegreesKey = "lambdavision.settings.snapTurnDegrees"

    static var renderScale: Double {
        get { double(renderScaleKey, 0.75) }
        set { defaults.set(newValue, forKey: renderScaleKey) }
    }
    /// Currently IGNORED as a startup value: the MetalFX toggle is hidden and
    /// GameSettings forces the chain off regardless of what's stored here (see
    /// GameSettings.metalFXEnabled for the frame-time numbers). Kept so the
    /// setting can come back without a migration.
    static var metalFXEnabled: Bool {
        get { bool(metalFXEnabledKey, false) }
        set { defaults.set(newValue, forKey: metalFXEnabledKey) }
    }
    /// FXAA inside the composite pass. On by default — it replaced the
    /// FXAA-pass + MetalFX chain and costs no extra render pass.
    static var fxaaEnabled: Bool {
        get { bool(fxaaEnabledKey, true) }
        set { defaults.set(newValue, forKey: fxaaEnabledKey) }
    }
    static var gamma: Double {
        get { double(gammaKey, 2.5) }
        set { defaults.set(newValue, forKey: gammaKey) }
    }
    static var brightness: Double {
        get { double(brightnessKey, 0.0) }
        set { defaults.set(newValue, forKey: brightnessKey) }
    }
    static var snapTurnDegrees: Double {
        get { double(snapTurnDegreesKey, 30) }
        set { defaults.set(newValue, forKey: snapTurnDegreesKey) }
    }

    // MARK: Audio
    private static let sfxVolumeKey   = "lambdavision.settings.sfxVolume"
    private static let musicVolumeKey = "lambdavision.settings.musicVolume"

    static var sfxVolume: Double {
        get { double(sfxVolumeKey, 0.7) }   // engine `volume` default
        set { defaults.set(newValue, forKey: sfxVolumeKey) }
    }
    static var musicVolume: Double {
        get { double(musicVolumeKey, 1.0) } // engine `MP3Volume` default
        set { defaults.set(newValue, forKey: musicVolumeKey) }
    }

    // MARK: Input
    private static let dominantHandKey        = "lambdavision.settings.dominantHand"
    private static let fireAimModeKey         = "lambdavision.settings.fireAimMode"
    private static let gestureInputEnabledKey = "lambdavision.settings.gestureInputEnabled"
    private static let fastWeaponSwitchKey    = "lambdavision.settings.fastWeaponSwitch"
    private static let weaponExternalKey      = "lambdavision.settings.weaponExternal"

    static var dominantHand: DominantHand {
        get {
            guard let raw = defaults.string(forKey: dominantHandKey),
                  let v = DominantHand(rawValue: raw) else { return .right }
            return v
        }
        set { defaults.set(newValue.rawValue, forKey: dominantHandKey) }
    }
    static var fireAimMode: FireAimMode {
        get {
            guard let raw = defaults.string(forKey: fireAimModeKey),
                  let v = FireAimMode(rawValue: raw) else { return .barrel }
            return v
        }
        set { defaults.set(newValue.rawValue, forKey: fireAimModeKey) }
    }
    static var gestureInputEnabled: Bool {
        get { bool(gestureInputEnabledKey, false) }
        set { defaults.set(newValue, forKey: gestureInputEnabledKey) }
    }
    static var fastWeaponSwitch: Bool {
        get { bool(fastWeaponSwitchKey, true) }  // engine startup sets hud_fastswitch 1
        set { defaults.set(newValue, forKey: fastWeaponSwitchKey) }
    }
    static var weaponExternal: Bool {
        get { bool(weaponExternalKey, true) }    // default: draw the weapon in the Metal pass
        set { defaults.set(newValue, forKey: weaponExternalKey) }
    }
}
