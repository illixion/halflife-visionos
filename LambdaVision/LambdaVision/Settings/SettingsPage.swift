//
//  SettingsPage.swift
//  LambdaVision
//
//  The pieces every Settings page shares: the page itself (a grouped Form
//  with a title and the preview column beside it) and the slider row with
//  its value read out on the right.
//

import SwiftUI

/// A Settings page: a grouped form with a title, and beside it the preview
/// column (PreviewPane) showing the setting you are on. `preview` names the
/// setting the column opens on; nil leaves the column out (pages with
/// nothing to show).
struct SettingsPage<Content: View>: View {
    static var paneWidth: CGFloat { 400 }

    let title: String
    let preview: String?
    @ViewBuilder let content: Content

    init(_ title: String, preview: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.preview = preview
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 0) {
            Form { content }
                .formStyle(.grouped)
            if let preview {
                Divider()
                PreviewPane(pageKey: preview)
                    .frame(width: Self.paneWidth)
            }
        }
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

/// A tick box: visionOS has no checkbox toggle style of its own.
struct CheckboxToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: configuration.isOn ? "checkmark.square.fill" : "square")
                    .font(.title3)
                    .foregroundStyle(configuration.isOn ? Color.accentColor : .secondary)
                configuration.label
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(configuration.isOn ? .isSelected : [])
    }
}
