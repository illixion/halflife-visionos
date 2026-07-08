//
//  AppModel.swift
//  LambdaVision
//
//  Created by Ixion on 10/05/2026.
//

import SwiftUI

/// Maintains app-wide state
@MainActor
@Observable
class AppModel {
    let immersiveSpaceID = "ImmersiveSpace"
    enum ImmersiveSpaceState {
        case closed
        case inTransition
        case open
    }
    var immersiveSpaceState = ImmersiveSpaceState.closed

    /// Player-facing settings (Graphics/Audio/Input), shared by SettingsView
    /// and the render startup. Created here so its init pushes the stored
    /// Renderer-static knobs before the immersive space opens.
    let gameSettings = GameSettings()
}
