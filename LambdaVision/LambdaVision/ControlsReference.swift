//
//  ControlsReference.swift
//  LambdaVision
//
//  The default keyboard, mouse and gamepad bindings, shown in Settings
//  (Keyboard, mouse & gamepad > Controls). Keyboard and mouse rows are the
//  first-run binds (Lambda_Bridge.c) plus the engine's own defaults; players
//  can rebind them in the game's menu (Configuration > Controls), which this
//  list doesn't track. Gamepad rows are fixed (GamepadInput.swift). Keep in
//  step with README's Controls section.
//

import SwiftUI

struct ControlsReferenceView: View {
    private typealias Row = (input: String, action: String)

    private let keyboard: [Row] = [
        ("W A S D / arrows ↑ ↓", "Move"),
        ("← →", "Turn (smooth)"),
        ("Z / X", "Snap turn left / right"),
        ("Space", "Jump"),
        ("Ctrl", "Crouch (hold, then Space: long jump)"),
        ("Shift", "Walk"),
        ("E", "Use"),
        ("R", "Reload"),
        ("F", "Flashlight"),
        ("1–0", "Weapon slots"),
        ("[ / ]", "Previous / next weapon"),
        ("Q", "Last weapon"),
        ("J / Enter", "Fire"),
        ("K", "Alt-fire"),
        ("F5 / F6", "Quick save"),
        ("F9 / F7", "Quick load"),
        ("T", "Spray"),
        ("Esc", "Menu"),
        ("~", "Console"),
    ]
    private let mouse: [Row] = [
        ("Move", "Turn (and look up/down with that setting)"),
        ("Left button", "Fire"),
        ("Right button", "Alt-fire"),
        ("Wheel", "Previous / next weapon"),
        ("In the menu", "Move the cursor, click to select"),
    ]
    private let gamepad: [Row] = [
        ("Left stick", "Move"),
        ("Right stick", "Turn (smooth or snap)"),
        ("Right trigger", "Fire"),
        ("Left trigger", "Alt-fire"),
        ("A", "Jump"),
        ("B", "Crouch (hold, then A: long jump)"),
        ("X", "Reload"),
        ("Y", "Use"),
        ("Left shoulder", "Walk"),
        ("Right shoulder", "Last weapon"),
        ("D-pad ← →", "Previous / next weapon"),
        ("D-pad ↑", "Flashlight"),
        ("View / Options", "Tap: quick save · hold 1 s: quick load"),
        ("Menu", "Menu"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            group("Keyboard", keyboard)
            group("Mouse", mouse)
            group("Gamepad", gamepad)
        }
        .font(.callout)
    }

    private func group(_ title: String, _ rows: [Row]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            ForEach(rows, id: \.input) { row in
                HStack(alignment: .firstTextBaseline) {
                    Text(row.input)
                        .frame(width: 170, alignment: .leading)
                        .foregroundStyle(.secondary)
                    Text(row.action)
                }
            }
        }
    }
}
