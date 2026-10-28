//
//  PreviewFocus.swift
//  LambdaVision
//
//  Which setting the preview column (PreviewPane) is showing. A control
//  claims it with `.previews("waterReflections")`: looking at it, tapping it
//  or changing it makes the column show that setting's picture, a short
//  explanation, and how it looks switched off and on. The column keeps the
//  last one, so moving your eyes to the picture doesn't lose it.
//

import SwiftUI

@MainActor
@Observable
final class PreviewFocus {
    /// The setting (a PresetSchema id, or a topic key from SettingHelp) on show.
    var key: String?
}

private struct PreviewsModifier<Value: Equatable>: ViewModifier {
    @Environment(PreviewFocus.self) private var focus
    let key: String
    let value: Value

    func body(content: Content) -> some View {
        content
            .onHover { if $0 { focus.key = key } }
            .simultaneousGesture(TapGesture().onEnded { focus.key = key })
            .onChange(of: value) { focus.key = key }
    }
}

extension View {
    /// Shows `key`'s preview while this control is looked at, tapped or changed.
    /// Pass the bound value so a change from elsewhere (a preset) also counts.
    func previews<V: Equatable>(_ key: String, value: V) -> some View {
        modifier(PreviewsModifier(key: key, value: value))
    }

    func previews(_ key: String) -> some View {
        modifier(PreviewsModifier(key: key, value: 0))
    }
}
