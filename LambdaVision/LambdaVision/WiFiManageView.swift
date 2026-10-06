//
//  WiFiManageView.swift
//  LambdaVision
//
//  "Manage over Wi-Fi": the modal that runs GameLibraryServer for as long
//  as it is open. It shows the address to open in a browser, the PIN to
//  type there, who is connected, and what is being uploaded and imported.
//  Closing it stops the server, ends every session and cuts off any
//  upload (whole files already sent stay staged for next time).
//

import SwiftUI
import DebugTrace
import GameLibrary
import GameLibraryServer

@MainActor
@Observable
final class WiFiManager {
    enum State: Equatable {
        case starting
        case running(port: UInt16)
        case failed(String)
    }

    private(set) var state = State.starting
    private(set) var pin = ""
    private(set) var sessions = 0
    private(set) var upload = LibraryServer.UploadProgress()
    private(set) var importing = false
    private(set) var importProgress: Double?
    private(set) var log: [LogLine] = []
    private(set) var hostName: String?
    private(set) var addresses: [String] = []

    private let library: GameLibraryStore
    private var server: LibraryServer?

    init(library: GameLibraryStore) { self.library = library }

    func start() async {
        guard server == nil, let root = GameData.documentsRoot else {
            if GameData.documentsRoot == nil { state = .failed("The app's Documents folder isn't available.") }
            return
        }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LambdaVision")
        var config = LibraryServer.Configuration(
            library: GameData.library(root: root.path),
            uploadRoot: support.appendingPathComponent("WiFiUpload"),
            importStagingRoot: FileManager.default.temporaryDirectory.appendingPathComponent("GameImport"),
            hashCacheURL: support.appendingPathComponent("wifi-hashes.json"))
        config.serviceName = "LambdaVision"
        let store = library
        let host = LibraryServer.Host(
            runningGame: { GameData.runningGame },
            activeGamedir: { await MainActor.run { store.selectedGame?.gamedir } },
            setActive: { gamedir in
                await MainActor.run {
                    guard let game = store.games.first(where: { $0.gamedir.lowercased() == gamedir.lowercased() }) else { return nil }
                    store.select(game)
                    return store.pendingSwitchTitle.map { "Reopen LambdaVision on the headset to switch to \($0)." }
                }
            },
            mayImport: { await MainActor.run { !store.isImporting } },
            onEvent: { [weak self] event in
                // In order, on the main thread. The store hears about imports
                // even after this modal is gone: one started here finishes
                // after the server stops.
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        switch event {
                        case .importing(let on): store.externalImportRunning = on
                        case .libraryChanged: store.refreshSoon()
                        default: break
                        }
                        self?.handle(event)
                    }
                }
            })
        let server = LibraryServer(config, host: host)
        self.server = server
        pin = server.pin
        log = server.recentLog
        do {
            let port = try await server.start()
            // Closed before the listener came up.
            guard self.server === server else { server.stop(); return }
            hostName = NetworkInfo.localHostName()
            addresses = NetworkInfo.ipv4Addresses()
            state = .running(port: port)
            AppLog.app.log("[WiFi] serving on port \(port) (\(self.addresses.count) addresses)")
        } catch {
            self.server = nil
            state = .failed("Couldn't start the server: \(error.localizedDescription)")
            AppLog.app.error("[WiFi] failed to start: \(error.localizedDescription, privacy: .public)")
        }
    }

    func stop() {
        guard let server else { return }
        self.server = nil
        server.stop()
        AppLog.app.log("[WiFi] stopped")
    }

    private func handle(_ event: LibraryServer.Event) {
        switch event {
        case .pinChanged(let new):
            pin = new
            AppLog.app.log("[WiFi] PIN replaced after repeated wrong attempts")
        case .sessions(let n):
            sessions = n
            AppLog.app.log("[WiFi] \(n) connected")
        case .upload(let u):
            upload = u
        case .importing(let on):
            importing = on
            AppLog.app.log("[WiFi] import \(on ? "started" : "finished", privacy: .public)")
        case .importProgress(let f):
            importProgress = f
        case .log(let line):
            log.append(line)
            if log.count > 200 { log.removeFirst(log.count - 200) }
            // Paths and game names are the user's.
            AppLog.app.log("[WiFi] \(line.level.rawValue, privacy: .public): \(line.text, privacy: .private)")
        case .libraryChanged:
            break   // the store refreshes (see onEvent)
        case .failed(let why):
            server = nil
            state = .failed("The server stopped: \(why)")
            AppLog.app.error("[WiFi] listener failed: \(why, privacy: .public)")
        }
    }

    var primaryURL: String? {
        guard case .running(let port) = state else { return nil }
        if let hostName { return "http://\(hostName):\(port)" }
        return addresses.first.map { "http://\($0):\(port)" }
    }

    var fallbackURLs: [String] {
        guard case .running(let port) = state else { return [] }
        let all = addresses.map { "http://\($0):\(port)" }
        return hostName == nil ? Array(all.dropFirst()) : all
    }
}

struct WiFiManageView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var manager: WiFiManager

    init(library: GameLibraryStore) {
        _manager = State(initialValue: WiFiManager(library: library))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch manager.state {
                    case .starting:
                        ProgressView("Starting…").frame(maxWidth: .infinity)
                    case .failed(let message):
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                            .fixedSize(horizontal: false, vertical: true)
                    case .running:
                        addressSection
                        pinSection
                        activitySection
                    }
                    Label("Closing this window stops the server and any upload in progress. Files that finished uploading are kept, and the page picks up where it stopped next time.",
                          systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("Manage over Wi-Fi")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(minWidth: 520, minHeight: 560)
        .task { await manager.start() }
        .onDisappear { manager.stop() }
    }

    private var addressSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("On a phone or computer on the same Wi-Fi, open")
                .foregroundStyle(.secondary)
            if let url = manager.primaryURL {
                Text(url)
                    .font(.title2.monospaced().weight(.semibold))
                    .textSelection(.enabled)
            }
            if !manager.fallbackURLs.isEmpty {
                Text("If that doesn't load: \(manager.fallbackURLs.joined(separator: "  or  "))")
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var pinSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("and enter this PIN").foregroundStyle(.secondary)
            Text(spaced(manager.pin))
                .font(.system(size: 64, weight: .bold, design: .monospaced))
                .contentTransition(.numericText())
                .accessibilityLabel("PIN \(manager.pin.map(String.init).joined(separator: " "))")
            Label(manager.sessions == 0 ? "No one connected yet"
                  : manager.sessions == 1 ? "1 browser connected" : "\(manager.sessions) browsers connected",
                  systemImage: manager.sessions == 0 ? "wifi" : "checkmark.circle.fill")
                .font(.subheadline)
                .foregroundStyle(manager.sessions == 0 ? Color.secondary : Color.green)
        }
    }

    @ViewBuilder
    private var activitySection: some View {
        let u = manager.upload
        if u.activeUploads > 0 || (u.plannedFiles > 0 && u.completedFiles < u.plannedFiles && !manager.importing) {
            VStack(alignment: .leading, spacing: 6) {
                if u.plannedBytes > 0 {
                    ProgressView(value: min(1, Double(u.receivedBytes) / Double(u.plannedBytes))) {
                        Text("Receiving \(u.completedFiles) of \(u.plannedFiles) files")
                    } currentValueLabel: {
                        Text("\(bytes(u.receivedBytes)) of \(bytes(u.plannedBytes))")
                    }
                } else {
                    ProgressView { Text("Receiving files…") }
                }
            }
        }
        if manager.importing {
            if let f = manager.importProgress {
                ProgressView(value: f) { Text("Importing…") }
            } else {
                ProgressView { Text("Importing…") }
            }
        }
        if !manager.log.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(manager.log.suffix(10)) { line in
                    Label(line.text, systemImage: icon(line.level))
                        .font(.caption)
                        .foregroundStyle(line.level == .warning || line.level == .error ? Color.yellow : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func spaced(_ pin: String) -> String {
        pin.count == 6 ? pin.prefix(3) + " " + pin.suffix(3) : pin
    }

    private func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

    private func icon(_ level: LogLine.Level) -> String {
        switch level {
        case .info: "circle.fill"
        case .success: "checkmark"
        case .warning, .error: "exclamationmark.triangle"
        }
    }
}
