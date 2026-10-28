//
//  SettingHelp.swift
//  LambdaVision
//
//  What the preview column says about each setting: a one-line title, a few
//  sentences on what it does, and the pictures that show it. Pictures are
//  ordinary files in the app's Previews folder (a photo of the headset's
//  view, a screenshot, or a looping .mp4), found by name; one that isn't
//  there yet shows a placeholder, so the column works before they exist.
//  Previews/README in docs/settings-previews.md lists the names wanted.
//
//  A setting with `states` shows the picture for its present value and
//  lets you peek at the others, so the effect of a switch is visible
//  before you flip it. States are named by the value: "on" and "off" for
//  a switch, the raw choice for a picker.
//

import SwiftUI

struct HelpState: Identifiable, Hashable {
    let value: String
    let label: String
    let asset: String
    var id: String { value }
}

enum HelpMedia {
    case none
    /// One picture or clip whatever the setting is.
    case still(String)
    /// A picture per value of the setting.
    case states([HelpState])
    /// A drawn animation (FingerGunAnimation).
    case fingerGun
}

struct SettingHelp {
    let title: String
    let detail: String
    var media: HelpMedia = .none
    /// Shown under the picture: when it applies, what it costs.
    var note: String?
}

enum SettingHelpCatalog {
    private static func onOff(_ name: String, off: String = "Off", on: String = "On") -> HelpMedia {
        .states([HelpState(value: "off", label: off, asset: "\(name)-off"),
                 HelpState(value: "on", label: on, asset: "\(name)-on")])
    }

    private static let restart = "Applies when the game restarts. You'll be offered a reload when you close Settings."

    static func help(for key: String) -> SettingHelp? { table[key] }

    /// The first thing each page shows, before anything is looked at.
    static let pageDefaults: [String: String] = [
        "graphics": "foveatedEngine", "reflections": "glassReflections", "immersion": "progressiveImmersion",
        "hands": "gestureInputEnabled", "controls": "inputMode", "audio": "sfxVolume",
        "troubleshooting": "progressiveImmersion",
    ]

    private static let table: [String: SettingHelp] = [
        // Graphics
        "foveatedEngine": SettingHelp(
            title: "Foveated rendering",
            detail: "Draws the game sharpest where you are looking and coarser toward the edges, using the headset's eye tracking. A third of the pixels for the same sharpness where it counts, which is what keeps the frame rate up.",
            media: .still("foveatedEngine"), note: restart),
        "renderScale": SettingHelp(
            title: "Render scale",
            detail: "How many pixels the game draws, as a share of the display's. Lower is faster and softer. Used only with foveated rendering off.",
            media: .still("renderScale"), note: restart),
        "edgeSmoothing": SettingHelp(
            title: "Edge smoothing",
            detail: "4× MSAA smooths the edges of the geometry itself, thin wires, rails and grates included, at a small GPU cost. FXAA runs inside the pass that already draws the game to the display and softens the stair-steps that remain; turn it off if distant HUD or console text looks soft.",
            media: .still("edgeSmoothing"), note: "MSAA applies when the game restarts; FXAA applies at once."),
        "fxaaEnabled": SettingHelp(
            title: "FXAA edge smoothing",
            detail: "Softens the stair-steps along edges inside the pass that already draws the game to the display, so it costs almost nothing. Turn it off if distant HUD or console text looks soft.",
            media: onOff("fxaaEnabled")),
        "engineMSAA": SettingHelp(
            title: "4× MSAA",
            detail: "Smooths the edges of the geometry itself, thin wires, rails and grates included, at a small GPU cost.",
            media: onOff("engineMSAA"), note: restart),
        "linearColor": SettingHelp(
            title: "Linear colour",
            detail: "Shows the game's shading as it was drawn for a CRT, with true darks. Off is the older, lifted look. Gamma may want retuning after switching it.",
            media: onOff("linearColor")),
        "gamma": SettingHelp(
            title: "Gamma",
            detail: "The engine's gamma. Higher is brighter in the mid-tones.",
            media: .still("gamma")),
        "brightness": SettingHelp(
            title: "Brightness",
            detail: "The engine's brightness, on top of gamma.",
            media: .still("gamma")),
        "reprojectionDepth": SettingHelp(
            title: "Per-pixel reprojection depth",
            detail: "Tells the headset how far away each pixel is, so near walls and the gun hold still when you move your head between frames. Off treats the whole image as distant.",
            media: onOff("reprojectionDepth")),

        // Reflections & water
        "glassReflections": SettingHelp(
            title: "Glass reflections",
            detail: "Adds a reflection to windows and glass, strongest at glancing angles, like real glass.",
            media: onOff("glassReflections")),
        "waterReflections": SettingHelp(
            title: "Water reflections",
            detail: "The same for water, with gentle ripples. Still water mirrors the room.",
            media: onOff("waterReflections")),
        "sharpWaterReflections": SettingHelp(
            title: "Sharp water reflections",
            detail: "Mirrors what you actually see in flat water, instead of only the room's general shape.",
            media: onOff("sharpWaterReflections", off: "Soft", on: "Sharp")),
        "sharpGlassReflections": SettingHelp(
            title: "Sharp glass reflections",
            detail: "Does the same for windows when the method is Rendered or Ray traced. Otherwise glass reflects a snapshot of the room around you, which bends what is close to the pane.",
            media: onOff("sharpGlassReflections", off: "Soft", on: "Sharp")),
        "waterMirrorMethod": SettingHelp(
            title: "Sharp reflection method",
            detail: "Screen space mirrors the picture on screen: cheap, but blind to what no pixel shows, like the underside of a table (water only). Rendered draws the view again from your mirror image for the window or water filling most of your view. Ray traced follows every reflected ray: made for the M5 headset's ray-tracing hardware, and slower on older chips.",
            media: .states([HelpState(value: "screenSpace", label: "Screen space", asset: "waterMirrorMethod-screenSpace"),
                            HelpState(value: "rendered", label: "Rendered", asset: "waterMirrorMethod-rendered"),
                            HelpState(value: "rayTraced", label: "Ray traced", asset: "waterMirrorMethod-rayTraced")])),
        "waterRipples": SettingHelp(
            title: "Water ripples",
            detail: "How strongly the water's surface breaks up its reflection. 0 is a still mirror.",
            media: .still("waterRipples")),
        "reflectionStrength": SettingHelp(
            title: "Reflection strength",
            detail: "Scales how bright glass and water reflections are. 1× is close to physical and faint in this art.",
            media: .still("reflectionStrength")),

        // Immersion
        "progressiveImmersion": SettingHelp(
            title: "Progressive immersion",
            detail: "Opens the game as a portal you widen or narrow with the Digital Crown, with your room showing around it, instead of filling your whole view. While Mac Virtual Display is connected the portal can stay one size, show black or go missing.",
            media: onOff("progressiveImmersion", off: "Full view", on: "Portal"), note: restart),
        "weaponExternal": SettingHelp(
            title: "Hand-tracked weapon model",
            detail: "Draws the weapon in your hand, following it directly and lit by the world. Off falls back to the classic engine-drawn weapon.",
            media: onOff("weaponExternal", off: "Classic", on: "In your hand")),
        "weaponModel": SettingHelp(
            title: "Weapon model",
            detail: "Picks which of the game's two models of each weapon you hold. The viewmodel is animated but was only ever modelled on the side the old flat camera saw, so turning it over shows it open. The world model, the one other players see, is whole from every side but has no animation: a reload shows only as the ring above the weapon filling. The Gluon Gun has no world model you can hold and keeps its viewmodel.",
            media: .states([HelpState(value: "viewmodel", label: "Viewmodel", asset: "weaponModel-viewmodel"),
                            HelpState(value: "world", label: "World model", asset: "weaponModel-world")])),
        "hideParkedParts": SettingHelp(
            title: "Hide parked weapon parts",
            detail: "Hides what the old flat view kept just out of frame until an animation needed it, the pistol's spare magazine and the shotgun's shell, so it doesn't float beside the gun in your hand.",
            media: onOff("hideParkedParts")),
        "flashlightOnGun": SettingHelp(
            title: "Gun-mounted flashlight",
            detail: "The flashlight rides your weapon hand and lights where the gun points. Off is the stock headlamp.",
            media: onOff("flashlightOnGun", off: "Headlamp", on: "On the gun")),
        "fastWeaponSwitch": SettingHelp(
            title: "Fast weapon switch",
            detail: "Picking a weapon switches to it at once, without the extra press to confirm.",
            media: .none),
        "avatarBody": SettingHelp(
            title: "First-person body",
            detail: "Draws Gordon under your head, following your hands and holding the weapon.",
            media: onOff("avatarBody")),
        "avatarLegs": SettingHelp(
            title: "Legs",
            detail: "Stands Gordon on the game's floor, stepping as you walk, turn or move with the stick.",
            media: onOff("avatarLegs")),
        "hevHUD": SettingHelp(
            title: "HEV suit holograms",
            detail: "Replaces the flat HUD: ammo floats beside the weapon, and health and suit charge appear over your other forearm when you turn it toward you.",
            media: onOff("hevHUD", off: "Flat HUD", on: "Holograms")),
        "aimReticle": SettingHelp(
            title: "Aim reticle",
            detail: "Marks where the gun's shot would land. Dot and beam adds a faint line from the muzzle.",
            media: .states([HelpState(value: "off", label: "Off", asset: "aimReticle-off"),
                            HelpState(value: "dot", label: "Dot", asset: "aimReticle-dot"),
                            HelpState(value: "beam", label: "Dot and beam", asset: "aimReticle-beam")])),

        // Hands
        "dominantHand": SettingHelp(
            title: "Dominant hand",
            detail: "The hand that holds the weapon. The other one moves you and works the wheel.",
            media: .fingerGun),
        "fireAimMode": SettingHelp(
            title: "Fire aims at",
            detail: "An accessibility option. Where I look makes shots follow your gaze instead of the weapon barrel, and the game's own crosshair marks where they go.",
            media: .none),
        "gestureInputEnabled": SettingHelp(
            title: "Immersive gesture input",
            detail: "Fire with a finger gun: curl your dominant index finger to pull the trigger. Reload by curling your thumb down, index extended, and holding until the ring above the weapon fills. Press buttons by reaching out and poking with your off-hand index finger, and rest an open palm on a health or HEV charger to keep it running. On a train, poke the console to take the controls, then pinch and push or pull to work the throttle.",
            media: .fingerGun),
        "altFireGesture": SettingHelp(
            title: "Alt-fire: thumb to middle finger",
            detail: "Press the tip of your thumb against the side of your curled middle finger, index still pointing, for alt-fire. It is held as long as the thumb stays there, so taps zoom or launch a grenade and a hold charges the gauss gun. Curl the index while holding to fire both. After either thumb gesture, lift the thumb before doing the other.",
            media: .still("altFireGesture")),
        "altFireSensitivity": SettingHelp(
            title: "Alt-fire sensitivity",
            detail: "How close the thumb must come. Higher reacts from farther away; lower it if alt-fire goes off when you reload.",
            media: .still("altFireGesture")),
        "armSwingEnabled": SettingHelp(
            title: "Arm-swing walking",
            detail: "Close both hands into fists and pump your arms like jogging: the harder you swing, the faster you go, up to full run speed. Flick both fists up together to jump. Once you're running, point your gun hand to aim and fire while the other arm keeps you running; that arm's flick alone then jumps.",
            media: .still("armSwing")),
        "armSwingDirection": SettingHelp(
            title: "Swing direction",
            detail: "Whether swinging takes you where you look or where your fists point.",
            media: .still("armSwing")),
        "armSwingSensitivity": SettingHelp(
            title: "Swing sensitivity",
            detail: "How hard you need to swing to move.",
            media: .still("armSwing")),
        "handLongJump": SettingHelp(
            title: "Long jump at a run",
            detail: "With the long jump module, a jump made at a full run becomes a long jump.",
            media: .none),
        "wheelUtilities": SettingHelp(
            title: "Weapon wheel extras",
            detail: "Switch weapons with the weapon wheel: pinch all fingertips together, move your hand toward a sector, release to pick. It has one sector per weapon slot you hold anything in. This adds flashlight, quick save and quick load sectors; hold quick save or quick load armed until its outer arc fills.",
            media: .still("weaponWheel")),
        "wheelExpand": SettingHelp(
            title: "Wheel: reach past the rim",
            detail: "Keep moving past the rim over a slot holding several weapons and it opens into an outer arc of them; slide along it and release. Come back inside the rim to fold it.",
            media: .still("weaponWheel")),

        // Keyboard, mouse & gamepad
        "inputMode": SettingHelp(
            title: "Input mode",
            detail: "Auto follows the last thing you used: a key, the mouse or the gamepad switches to it at once, and a look-and-pinch brings the hands back. With a keyboard, mouse or gamepad the game plays like the desktop original in stereo: the weapon is the classic viewmodel in front of you, the body's arms stop following your hands and the hand gestures rest.",
            media: .none),
        "freeAim": SettingHelp(
            title: "Free aim",
            detail: "The mouse and the right stick swing the gun inside a zone ahead of your body, and only pushing past the zone's edge turns you. The aim reticle marks where shots land, and looking around with your head doesn't drag the gun. Off, the mouse and stick turn you directly and shots go where you look. Needs the hand-tracked weapon model.",
            media: .still("freeAim")),
        "flatHUDPlacement": SettingHelp(
            title: "HEV holograms placement",
            detail: "Follow view moves health and suit to the lower left of your view and ammo to the lower right, like Half-Life 2; they trail your head slightly instead of sticking to your eyes. Attached to hands keeps them on your hands as in hands mode.",
            media: .none),
        "mouseSmoothing": SettingHelp(
            title: "Mouse smoothing",
            detail: "Spreads the mouse's movement evenly across frames (visionOS delivers it less often than the game draws), at the cost of the set delay.",
            media: .none),
        "lookPitch": SettingHelp(
            title: "Look up/down with mouse and stick",
            detail: "Adds mouse and stick pitch to your head's. It tilts the game's horizon away from the room's, which some find uncomfortable, and hides the first-person body while a tilt is set.",
            media: .none),
        "inputCatcher": SettingHelp(
            title: "Mouse capture window",
            detail: "Keeps an invisible window in front of you while you play with a mouse: visionOS only lets the game read the mouse while the pointer is over one of its windows. It steps aside for the menu and the console, and a look-and-pinch works through it.",
            media: .none),
        "snapTurnDegrees": SettingHelp(
            title: "Snap-turn angle",
            detail: "How far Z, X and the stick on snap turning turn you in one step.",
            media: .none),

        // Audio
        "sfxVolume": SettingHelp(
            title: "Sound effects",
            detail: "The game's effects volume.", media: .none),
        "musicVolume": SettingHelp(
            title: "Music",
            detail: "The volume of the game's MP3 music.", media: .none),
    ]
}
