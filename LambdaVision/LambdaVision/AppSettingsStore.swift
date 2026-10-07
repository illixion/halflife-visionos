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
    private static let linearColorKey     = "lambdavision.settings.linearColor"
    private static let snapTurnDegreesKey = "lambdavision.settings.snapTurnDegrees"
    private static let reprojectionDepthKey = "lambdavision.settings.reprojectionDepth"
    private static let glassReflectionsKey = "lambdavision.settings.glassReflections"
    private static let waterReflectionsKey = "lambdavision.settings.waterReflections"
    private static let reflectionStrengthKey = "lambdavision.settings.reflectionStrength"
    private static let sharpWaterKey = "lambdavision.settings.sharpWaterReflections"
    private static let waterRipplesKey = "lambdavision.settings.waterRipples"

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
    /// Decode the engine's gamma-encoded image to linear light for the
    /// drawable (Renderer.displayDecodeGamma).
    static var linearColor: Bool {
        get { bool(linearColorKey, true) }
        set { defaults.set(newValue, forKey: linearColorKey) }
    }
    /// Per-pixel depth for the compositor's reprojection
    /// (Renderer.reprojectionDepth). Off by default until judged on device.
    static var reprojectionDepth: Bool {
        get { bool(reprojectionDepthKey, false) }
        set { defaults.set(newValue, forKey: reprojectionDepthKey) }
    }
    /// Fresnel reflections on glass (Renderer.glassReflections, r_vrglass).
    /// Off by default: a prototype until judged on device.
    static var glassReflections: Bool {
        get { bool(glassReflectionsKey, false) }
        set { defaults.set(newValue, forKey: glassReflectionsKey) }
    }
    /// The same probe reflection on water (Renderer.waterReflections,
    /// r_vrwater). Off by default until judged on device.
    static var waterReflections: Bool {
        get { bool(waterReflectionsKey, false) }
        set { defaults.set(newValue, forKey: waterReflectionsKey) }
    }
    /// Scales glass and water reflectance (Renderer.reflectionStrength).
    /// 3× by default: the headset showed physical 4% glass barely at all.
    static var reflectionStrength: Double {
        get { double(reflectionStrengthKey, 3.0) }
        set { defaults.set(newValue, forKey: reflectionStrengthKey) }
    }
    /// The screen-space mirror on horizontal water (Renderer.sharpWaterReflections),
    /// under Water reflections. On by default; off is the probe-only look.
    static var sharpWaterReflections: Bool {
        get { bool(sharpWaterKey, false) }   // off until it measures well on device
        set { defaults.set(newValue, forKey: sharpWaterKey) }
    }
    /// Ripple slope multiplier (Renderer.waterRipples), 0–3×.
    static var waterRipples: Double {
        get { double(waterRipplesKey, 1.0) }
        set { defaults.set(newValue, forKey: waterRipplesKey) }
    }
    static var gamma: Double {
        get { double(gammaKey, 3.0) }   // with Linear colour on; tuned on the headset 2026-10-06
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

    // MARK: Game
    private static let selectedGameKey = "lambdavision.settings.selectedGame"

    /// The gamedir the engine starts with (`-game`); nil = Half-Life.
    static var selectedGame: String? {
        get { defaults.string(forKey: selectedGameKey) }
        set { defaults.set(newValue, forKey: selectedGameKey) }
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
    private static let flashlightOnGunKey     = "lambdavision.settings.flashlightOnGun"
    private static let fastWeaponSwitchKey    = "lambdavision.settings.fastWeaponSwitch"
    private static let armSwingEnabledKey     = "lambdavision.settings.armSwingEnabled"
    private static let armSwingDirectionKey   = "lambdavision.settings.armSwingDirection"
    private static let armSwingSensitivityKey = "lambdavision.settings.armSwingSensitivity"
    private static let longJumpKey            = "lambdavision.settings.handLongJump"
    private static let wheelUtilitiesKey      = "lambdavision.settings.wheelUtilities"
    private static let wheelExpandKey         = "lambdavision.settings.wheelExpand"
    private static let altFireGestureKey      = "lambdavision.settings.altFireGesture"
    private static let altFireSensitivityKey  = "lambdavision.settings.altFireSensitivity"
    private static let weaponExternalKey      = "lambdavision.settings.weaponExternal"
    private static let avatarBodyKey          = "lambdavision.settings.avatarBody"
    private static let avatarLegsKey          = "lambdavision.settings.avatarLegs"
    private static let hevHUDKey              = "lambdavision.settings.hevHUD"
    private static let aimReticleKey          = "lambdavision.settings.aimReticle"
    private static let weaponModelKey         = "lambdavision.settings.weaponModel"
    private static let developerModeKey       = "lambdavision.settings.developerMode"
    private static let hideParkedPartsKey     = "lambdavision.settings.hideParkedParts"

    static var dominantHand: DominantHand {
        get {
            guard let raw = defaults.string(forKey: dominantHandKey),
                  let v = DominantHand(rawValue: raw) else { return .right }
            return v
        }
        set { defaults.set(newValue.rawValue, forKey: dominantHandKey) }
    }
    static var aimReticle: AimReticle {
        get {
            guard let raw = defaults.string(forKey: aimReticleKey),
                  let v = AimReticle(rawValue: raw) else { return .dot }
            return v
        }
        set { defaults.set(newValue.rawValue, forKey: aimReticleKey) }
    }
    static var weaponModel: WeaponModelStyle {
        get {
            guard let raw = defaults.string(forKey: weaponModelKey),
                  let v = WeaponModelStyle(rawValue: raw) else { return .viewmodel }
            return v
        }
        set { defaults.set(newValue.rawValue, forKey: weaponModelKey) }
    }
    static var fireAimMode: FireAimMode {
        get {
            guard let raw = defaults.string(forKey: fireAimModeKey),
                  let v = FireAimMode(rawValue: raw) else { return .barrel }
            return v
        }
        set { defaults.set(newValue.rawValue, forKey: fireAimModeKey) }
    }
    static var hideParkedParts: Bool {
        get { bool(hideParkedPartsKey, true) }
        set { defaults.set(newValue, forKey: hideParkedPartsKey) }
    }
    static var flashlightOnGun: Bool {
        get { bool(flashlightOnGunKey, true) }
        set { defaults.set(newValue, forKey: flashlightOnGunKey) }
    }
    static var gestureInputEnabled: Bool {
        get { bool(gestureInputEnabledKey, false) }
        set { defaults.set(newValue, forKey: gestureInputEnabledKey) }
    }
    static var armSwingEnabled: Bool {
        get { bool(armSwingEnabledKey, true) }
        set { defaults.set(newValue, forKey: armSwingEnabledKey) }
    }
    static var armSwingDirection: ArmSwingDirection {
        get {
            guard let raw = defaults.string(forKey: armSwingDirectionKey),
                  let v = ArmSwingDirection(rawValue: raw) else { return .head }
            return v
        }
        set { defaults.set(newValue.rawValue, forKey: armSwingDirectionKey) }
    }
    static var armSwingSensitivity: Double {
        get { double(armSwingSensitivityKey, 1.0) }
        set { defaults.set(newValue, forKey: armSwingSensitivityKey) }
    }
    static var handLongJump: Bool {
        get { bool(longJumpKey, true) }
        set { defaults.set(newValue, forKey: longJumpKey) }
    }
    static var wheelUtilities: Bool {
        get { bool(wheelUtilitiesKey, true) }
        set { defaults.set(newValue, forKey: wheelUtilitiesKey) }
    }
    static var wheelExpand: Bool {
        get { bool(wheelExpandKey, true) }
        set { defaults.set(newValue, forKey: wheelExpandKey) }
    }
    static var altFireGesture: Bool {
        get { bool(altFireGestureKey, true) }
        set { defaults.set(newValue, forKey: altFireGestureKey) }
    }
    static var altFireSensitivity: Double {
        get { double(altFireSensitivityKey, 1.0) }
        set { defaults.set(newValue, forKey: altFireSensitivityKey) }
    }
    static var fastWeaponSwitch: Bool {
        get { bool(fastWeaponSwitchKey, true) }  // engine startup sets hud_fastswitch 1
        set { defaults.set(newValue, forKey: fastWeaponSwitchKey) }
    }
    static var weaponExternal: Bool {
        get { bool(weaponExternalKey, true) }    // default: draw the weapon in the Metal pass
        set { defaults.set(newValue, forKey: weaponExternalKey) }
    }
    static var avatarBody: Bool {
        get { bool(avatarBodyKey, true) }        // default: draw the first-person body
        set { defaults.set(newValue, forKey: avatarBodyKey) }
    }
    static var avatarLegs: Bool {
        get { bool(avatarLegsKey, true) }        // default: the body stands on its legs
        set { defaults.set(newValue, forKey: avatarLegsKey) }
    }
    static var hevHUD: Bool {
        get { bool(hevHUDKey, true) }            // default: the holographic HEV HUD
        set { defaults.set(newValue, forKey: hevHUDKey) }
    }
    /// Default on in Debug builds, off in Release (Oneiros's rule); an
    /// explicit choice is remembered either way.
    static var developerMode: Bool {
        get {
            #if DEBUG
            bool(developerModeKey, true)
            #else
            bool(developerModeKey, false)
            #endif
        }
        set { defaults.set(newValue, forKey: developerModeKey) }
    }

    // MARK: Keyboard, mouse and gamepad
    private static let inputModeKey        = "lambdavision.settings.inputMode"
    private static let mouseSensitivityKey = "lambdavision.settings.mouseSensitivity"
    private static let stickSmoothTurnKey  = "lambdavision.settings.stickSmoothTurn"
    private static let stickTurnSpeedKey   = "lambdavision.settings.stickTurnSpeed"
    private static let lookPitchKey        = "lambdavision.settings.lookPitch"

    static var inputMode: InputModeSetting {
        get {
            guard let raw = defaults.string(forKey: inputModeKey),
                  let v = InputModeSetting(rawValue: raw) else { return .auto }
            return v
        }
        set { defaults.set(newValue.rawValue, forKey: inputModeKey) }
    }
    static var mouseSensitivity: Double {
        get { double(mouseSensitivityKey, 3) }    // Half-Life's `sensitivity` default
        set { defaults.set(newValue, forKey: mouseSensitivityKey) }
    }
    static var stickSmoothTurn: Bool {
        get { bool(stickSmoothTurnKey, true) }
        set { defaults.set(newValue, forKey: stickSmoothTurnKey) }
    }
    static var stickTurnSpeed: Double {
        get { double(stickTurnSpeedKey, 100) }    // the engine's `joy_yaw` default
        set { defaults.set(newValue, forKey: stickTurnSpeedKey) }
    }
    static var lookPitch: Bool {
        get { bool(lookPitchKey, false) }
        set { defaults.set(newValue, forKey: lookPitchKey) }
    }
    private static let inputCatcherKey         = "lambdavision.settings.inputCatcher"
    private static let inputCatcherRecenterKey = "lambdavision.settings.inputCatcherRecenter"
    /// The invisible mouse-capture window (InputCatcher).
    static var inputCatcher: Bool {
        get { bool(inputCatcherKey, true) }
        set { defaults.set(newValue, forKey: inputCatcherKey) }
    }
    private static let inputCatcherAlphaKey = "lambdavision.settings.inputCatcherAlpha"
    /// The catcher's fill opacity: the visionOS pointer ignores a window
    /// where nothing is drawn (Color.clear didn't catch on the headset).
    static var inputCatcherAlpha: Double {
        get { double(inputCatcherAlphaKey, InputCatcher.defaultAlpha) }
        set { defaults.set(newValue, forKey: inputCatcherAlphaKey) }
    }
    private static let inputCatcherTechniqueKey = "lambdavision.settings.inputCatcherTechnique"
    static var inputCatcherTechnique: InputCatcherTechnique {
        get {
            guard let raw = defaults.string(forKey: inputCatcherTechniqueKey),
                  let v = InputCatcherTechnique(rawValue: raw) else { return .metalClear }
            return v
        }
        set { defaults.set(newValue.rawValue, forKey: inputCatcherTechniqueKey) }
    }
    static var inputCatcherRecenter: Bool {
        get { bool(inputCatcherRecenterKey, true) }
        set { defaults.set(newValue, forKey: inputCatcherRecenterKey) }
    }

    // MARK: HEV holograms outside hands mode
    private static let flatHUDPlacementKey = "lambdavision.settings.flatHUDPlacement"

    static var flatHUDPlacement: FlatHUDPlacement {
        get {
            guard let raw = defaults.string(forKey: flatHUDPlacementKey),
                  let v = FlatHUDPlacement(rawValue: raw) else { return .followView }
            return v
        }
        set { defaults.set(newValue.rawValue, forKey: flatHUDPlacementKey) }
    }

    // MARK: Debug server
    private static let debugServerKey = "lambdavision.settings.debugServer"

    /// Settings › Advanced › Debug server (DebugEndpoints): automatic (the
    /// DebugTrace default), always on, or off. Development builds only.
    static var debugServer: DebugServerMode {
        get {
            guard let raw = defaults.string(forKey: debugServerKey),
                  let v = DebugServerMode(rawValue: raw) else { return .automatic }
            return v
        }
        set { defaults.set(newValue.rawValue, forKey: debugServerKey) }
    }
}
