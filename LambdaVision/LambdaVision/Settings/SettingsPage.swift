//
//  SettingsPage.swift
//  LambdaVision
//
//  The pieces every Settings page shares: the page itself (a grouped Form
//  with a title, the shape Hypnos's Settings pages use) and the slider row
//  with its value read out on the right.
//

import SwiftUI

/// A Settings page: a grouped form with a title, pushed from SettingsView.
struct SettingsPage<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        Form { content }
            .formStyle(.grouped)
            .navigationTitle(title)
    }
}

/// A slider with its title on the left and the formatted value on the right.
struct SettingsSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String

    init(_ title: String,
         _ value: Binding<Double>,
         _ range: ClosedRange<Double>,
         _ step: Double,
         format: @escaping (Double) -> String) {
        self.title = title
        self._value = value
        self.range = range
        self.step = step
        self.format = format
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text(format(value))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range, step: step)
        }
    }

    nonisolated static func percent(_ v: Double) -> String { String(format: "%.0f%%", v * 100) }
}
