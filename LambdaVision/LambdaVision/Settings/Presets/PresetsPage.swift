//
//  PresetsPage.swift
//  LambdaVision
//
//  Settings › Presets: the presets that ship, the ones you saved, and what
//  applying the one you pick would change. The left column lists them and
//  holds the actions (save the present settings, import a file); the right
//  column is the Apply panel, with a checkbox per category so a preset can
//  bring in only the look, or only the controls.
//

import SwiftUI
import UniformTypeIdentifiers

struct PresetsPage: View {
    @Environment(AppModel.self) private var appModel
    @State private var selectedID: String? = BuiltInPresets.enhancedID
    @State private var showSave = false
    @State private var showImport = false
    @State private var exporting: SettingsPreset?
    @State private var renaming: SettingsPreset?

    var body: some View {
        let store = appModel.presets
        let settings = appModel.gameSettings
        let active = store.active(for: settings)
        HStack(spacing: 0) {
            List(selection: $selectedID) {
                Section {
                    LabeledContent("In use") {
                        Text(active?.name ?? "Custom").foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("A preset is a saved set of settings. Applying one lets you pick which parts to bring in, so a look preset leaves your controls alone.")
                }

                Section("Included") {
                    ForEach(store.builtIns) { preset in row(preset, active: active) }
                }

                Section {
                    if store.userPresets.isEmpty {
                        Text("Nothing saved yet.").foregroundStyle(.secondary)
                    }
                    ForEach(store.userPresets) { preset in
                        row(preset, active: active)
                            .contextMenu {
                                Button("Rename…", systemImage: "pencil") { renaming = preset }
                                Button("Export…", systemImage: "square.and.arrow.up") { exporting = preset }
                                Button("Delete", systemImage: "trash", role: .destructive) {
                                    if selectedID == preset.id { selectedID = BuiltInPresets.enhancedID }
                                    store.delete(preset)
                                }
                            }
                    }
                } header: {
                    Text("Yours")
                } footer: {
                    if let error = store.lastError { Text(error).foregroundStyle(.red) }
                }

                Section {
                    Button("Save current settings…", systemImage: "square.and.arrow.down") { showSave = true }
                    Button("Import from a file…", systemImage: "folder") { showImport = true }
                }
            }
            .frame(minWidth: 320)

            Divider()

            Group {
                if let preset = selectedID.flatMap(store.preset(id:)) {
                    PresetApplyPanel(preset: preset) { exporting = preset }
                        .id(preset.id)
                } else {
                    ContentUnavailableView("Pick a preset", systemImage: "slider.horizontal.3")
                }
            }
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Presets")
        .sheet(isPresented: $showSave) {
            SavePresetSheet { selectedID = $0.id }
        }
        .sheet(item: $renaming) { RenamePresetSheet(preset: $0) }
        .fileImporter(isPresented: $showImport, allowedContentTypes: [.lambdaPreset, .json]) { result in
            if case .success(let url) = result, let added = store.importPreset(from: url) {
                selectedID = added.id
            } else if case .failure(let error) = result {
                store.lastError = error.localizedDescription
            }
        }
        .fileExporter(isPresented: Binding(get: { exporting != nil }, set: { if !$0 { exporting = nil } }),
                      document: exporting.map(PresetDocument.init),
                      contentType: .lambdaPreset,
                      defaultFilename: exporting?.name ?? "Preset") { _ in exporting = nil }
    }

    private func row(_ preset: SettingsPreset, active: SettingsPreset?) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(preset.name).font(.body.weight(.semibold))
                Text(preset.heldCategories.map(\.title).joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            if active?.id == preset.id {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    .accessibilityLabel("In use")
            }
        }
        .tag(preset.id)
    }
}

/// What applying a preset would change, with a checkbox per category.
struct PresetApplyPanel: View {
    @Environment(AppModel.self) private var appModel
    let preset: SettingsPreset
    var onExport: (() -> Void)?
    var onApplied: (() -> Void)?

    @State private var chosen: Set<PresetCategory> = []
    @State private var applied: Int?

    var body: some View {
        let settings = appModel.gameSettings
        let now = settings.presetValues()
        let held = preset.heldCategories
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(preset.name).font(.title2.weight(.semibold))
                    if !preset.summary.isEmpty {
                        Text(preset.summary).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if !DeviceCapability.hardwareRayTracing,
                   preset.values(in: .reflections)["waterMirrorMethod"] == .text("rayTraced") {
                    Label("This preset uses ray-traced reflections, which are made for the M5 headset. On this one they may cost frame rate.",
                          systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.orange)
                }

                ForEach(held) { category in
                    let changes = Self.changes(preset, category, now: now)
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(isOn: Binding(
                            get: { chosen.contains(category) },
                            set: { if $0 { chosen.insert(category) } else { chosen.remove(category) } }
                        )) {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(category.title).font(.headline)
                                    Text(changes.isEmpty ? "Already the same" : "\(changes.count) \(changes.count == 1 ? "change" : "changes")")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            } icon: { Image(systemName: category.systemImage) }
                        }
                        .toggleStyle(CheckboxToggleStyle())
                        ForEach(changes, id: \.title) { change in
                            HStack {
                                Text(change.title).font(.callout)
                                Spacer()
                                Text("\(change.from) → \(change.to)")
                                    .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            .padding(.leading, 34)
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
                }

                HStack {
                    Button {
                        applied = settings.apply(preset, categories: chosen)
                        onApplied?()
                    } label: {
                        Label("Apply", systemImage: "checkmark")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(chosen.isEmpty)
                    if let onExport {
                        Button("Export…", systemImage: "square.and.arrow.up", action: onExport)
                    }
                    if let applied {
                        Text(applied == 0 ? "Nothing needed changing." : "\(applied) \(applied == 1 ? "setting" : "settings") changed.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            // Tick what would change something; a category already the same
            // starts unticked (it can still be ticked).
            chosen = Set(held.filter { !Self.changes(preset, $0, now: now).isEmpty })
        }
    }

    struct Change { let title: String; let from: String; let to: String }

    /// The settings of `category` this preset would change, in schema order.
    static func changes(_ preset: SettingsPreset, _ category: PresetCategory,
                        now: [String: PresetValue]) -> [Change] {
        let wanted = preset.values(in: category)
        return PresetSchema.specs(in: category).compactMap { spec in
            guard let value = wanted[spec.id].flatMap(spec.accepting), let have = now[spec.id],
                  !have.matches(value) else { return nil }
            return Change(title: spec.title, from: describe(have), to: describe(value))
        }
    }

    static func describe(_ value: PresetValue) -> String {
        switch value {
        case .bool(let b): return b ? "On" : "Off"
        case .number(let n): return String(format: "%.3g", n)
        case .text(let s):
            var out = ""
            for ch in s { if ch.isUppercase { out += " " + ch.lowercased() } else { out.append(ch) } }
            return out.prefix(1).uppercased() + out.dropFirst()
        }
    }
}

/// Name a preset and choose which categories of the present settings it saves.
struct SavePresetSheet: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    var onSaved: (SettingsPreset) -> Void

    @State private var name = ""
    @State private var summary = ""
    @State private var chosen = Set(PresetCategory.allCases)

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                    TextField("Description (optional)", text: $summary)
                }
                Section {
                    ForEach(PresetCategory.allCases) { category in
                        Toggle(isOn: Binding(
                            get: { chosen.contains(category) },
                            set: { if $0 { chosen.insert(category) } else { chosen.remove(category) } }
                        )) {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(category.title)
                                    Text(category.blurb).font(.caption).foregroundStyle(.secondary)
                                }
                            } icon: { Image(systemName: category.systemImage) }
                        }
                        .toggleStyle(CheckboxToggleStyle())
                    }
                } header: {
                    Text("Save these settings")
                } footer: {
                    Text("A preset saves the values the settings have now, for the groups you tick.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Save preset")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if let saved = appModel.presets.saveCurrent(appModel.gameSettings, name: name,
                                                                    summary: summary, categories: chosen) {
                            onSaved(saved)
                        }
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || chosen.isEmpty)
                }
            }
        }
        .frame(minWidth: 520, minHeight: 560)
    }
}

struct RenamePresetSheet: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    let preset: SettingsPreset
    @State private var name = ""
    @State private var summary = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                TextField("Description", text: $summary)
            }
            .formStyle(.grouped)
            .navigationTitle("Rename preset")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        appModel.presets.rename(preset, to: name, summary: summary)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .frame(minWidth: 480, minHeight: 280)
        .onAppear { name = preset.name; summary = preset.summary }
    }
}
