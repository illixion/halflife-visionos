//
//  PresetStore.swift
//  LambdaVision
//
//  The presets: the ones that ship (BuiltInPresets) and the ones the player
//  saved or imported, one `.lambdapreset` file each in Application
//  Support/LambdaVision/Presets. Files are read leniently (a broken or
//  newer one is skipped, never fatal) and only ever written by this store,
//  so a preset made from a file keeps its own copy: deleting the original
//  from Files changes nothing here.
//

import Foundation
import SwiftUI
import Metal
import UniformTypeIdentifiers
import DebugTrace

/// What this headset's GPU can do that a preset should know about.
nonisolated enum DeviceCapability {
    /// Hardware ray tracing worth recommending: the M5 generation (Apple GPU
    /// family 10). Earlier chips can run the ray-traced mirror in software,
    /// slowly, so presets don't pick it for them.
    static let hardwareRayTracing: Bool = MTLCreateSystemDefaultDevice()?.supportsFamily(.apple10) ?? false
}

extension UTType {
    /// Exported in Info.plist: `.lambdapreset`, JSON inside.
    static let lambdaPreset = UTType(exportedAs: "com.illixion.lambdavision.preset", conformingTo: .json)
}

@MainActor
@Observable
final class PresetStore {
    private(set) var userPresets: [SettingsPreset] = []
    /// The newest error from an import, for the page to show.
    var lastError: String?
    /// A preset just added from a file opened in the app (AirDrop, Files):
    /// the launcher offers to show it, then clears this.
    var openedPreset: SettingsPreset?

    /// The presets that ship, with Enhanced fitted to this headset.
    let builtIns = BuiltInPresets.all(rayTracingCapable: DeviceCapability.hardwareRayTracing)

    var all: [SettingsPreset] { builtIns + userPresets }

    /// The first preset whose every category the settings already match:
    /// what the player is effectively playing with, or nil for "Custom".
    func active(for settings: GameSettings) -> SettingsPreset? {
        all.first { preset in settings.matches(preset).values.allSatisfy { $0 } }
    }

    private let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("LambdaVision/Presets", isDirectory: true)
    }()

    init() { reload() }

    func preset(id: String) -> SettingsPreset? { all.first { $0.id == id } }

    // MARK: Reading

    func reload() {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        userPresets = urls
            .filter { $0.pathExtension == SettingsPreset.fileExtension }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? SettingsPreset.decode(data)
            }
            .sorted { ($0.created ?? .distantPast) < ($1.created ?? .distantPast) }
    }

    // MARK: Writing

    private func fileURL(for preset: SettingsPreset) -> URL {
        // The id is ours (a UUID) or came from a file: keep only characters
        // a file name can't be hurt by.
        let safe = String(preset.id.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "-" })
        return directory.appendingPathComponent(safe.isEmpty ? UUID().uuidString : safe)
            .appendingPathExtension(SettingsPreset.fileExtension)
    }

    private func write(_ preset: SettingsPreset) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try preset.encoded().write(to: fileURL(for: preset), options: .atomic)
    }

    /// Saves the present values of `categories` as a new preset.
    @discardableResult
    func saveCurrent(_ settings: GameSettings, name: String, summary: String,
                     categories: Set<PresetCategory>) -> SettingsPreset? {
        let preset = settings.presetSnapshot(name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                             summary: summary, categories: categories)
        return add(preset)
    }

    /// Adds a preset (a new id, so importing the same file twice makes two).
    @discardableResult
    private func add(_ preset: SettingsPreset) -> SettingsPreset? {
        var fresh = preset
        fresh.id = UUID().uuidString
        fresh.isBuiltIn = false
        if fresh.created == nil { fresh.created = Date() }
        do { try write(fresh) } catch {
            lastError = "Couldn't save the preset: \(error.localizedDescription)"
            return nil
        }
        userPresets.append(fresh)
        return fresh
    }

    func rename(_ preset: SettingsPreset, to name: String, summary: String) {
        guard !preset.isBuiltIn, let index = userPresets.firstIndex(where: { $0.id == preset.id }) else { return }
        var edited = userPresets[index]
        edited.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        edited.summary = summary
        do { try write(edited); userPresets[index] = edited }
        catch { lastError = "Couldn't save the preset: \(error.localizedDescription)" }
    }

    func delete(_ preset: SettingsPreset) {
        guard !preset.isBuiltIn else { return }
        try? FileManager.default.removeItem(at: fileURL(for: preset))
        userPresets.removeAll { $0.id == preset.id }
    }

    // MARK: Files

    /// A `.lambdapreset` handed to the app from outside.
    func importFromOpenedURL(_ url: URL) {
        openedPreset = importPreset(from: url)
    }

    /// Reads a preset from a file the player chose (or opened) and keeps a copy.
    @discardableResult
    func importPreset(from url: URL) -> SettingsPreset? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let preset = try SettingsPreset.decode(Data(contentsOf: url))
            lastError = nil
            AppLog.app.log("[Presets] imported \(preset.heldCategories.count, privacy: .public) categories")
            return add(preset)
        } catch {
            lastError = (error as? PresetFileError)?.errorDescription ?? "Couldn't read that file."
            return nil
        }
    }
}

/// A preset as a file the Files app can save: `.fileExporter`'s document.
struct PresetDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.lambdaPreset] }
    let preset: SettingsPreset

    init(_ preset: SettingsPreset) { self.preset = preset }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw PresetFileError.notAPreset }
        preset = try SettingsPreset.decode(data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: try preset.encoded())
    }
}
