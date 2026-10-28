//
//  PreviewPane.swift
//  LambdaVision
//
//  The right-hand column of every Settings page: a picture or clip of the
//  setting you are on, what it does, and, for a switch or a choice, a
//  control to peek at each value without changing it. (SettingHelp has the
//  words and the picture names; PreviewFocus says which setting is on show.)
//

import SwiftUI
import AVFoundation

struct PreviewPane: View {
    @Environment(AppModel.self) private var appModel
    @Environment(PreviewFocus.self) private var focus
    /// The page's own first setting, for before anything has been looked at.
    let pageKey: String

    /// A value the player is peeking at, for the key it was chosen on.
    @State private var peek: (key: String, value: String)?

    var body: some View {
        let key = focus.key ?? pageKey
        if let help = SettingHelpCatalog.help(for: key) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    media(for: key, help: help)
                    Text(help.title).font(.title3.weight(.semibold))
                    Text(help.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let note = help.note {
                        Label(note, systemImage: "arrow.clockwise")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
        } else {
            ContentUnavailableView("Look at a setting", systemImage: "eye",
                                   description: Text("Its picture and what it does appear here."))
        }
    }

    // MARK: Media

    /// The setting's value as the states name it: "on"/"off", or the choice.
    private func currentState(of key: String) -> String? {
        guard let access = SettingsBindings.table[key] else { return nil }
        switch access.read(appModel.gameSettings) {
        case .bool(let on): return on ? "on" : "off"
        case .text(let s): return s
        case .number: return nil
        }
    }

    @ViewBuilder
    private func media(for key: String, help: SettingHelp) -> some View {
        switch help.media {
        case .none:
            EmptyView()
        case .still(let name):
            PreviewMedia(asset: name)
        case .fingerGun:
            FingerGunAnimation()
                .aspectRatio(PreviewMedia.aspect, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 16))
        case .states(let states):
            let now = currentState(of: key)
            let shown = (peek?.key == key ? peek?.value : nil) ?? now ?? states[0].value
            let state = states.first { $0.value == shown } ?? states[0]
            VStack(alignment: .leading, spacing: 10) {
                PreviewMedia(asset: state.asset)
                    .id(state.asset)
                    .transition(.opacity)
                Picker("Preview", selection: Binding(
                    get: { shown },
                    set: { peek = (key, $0) })
                ) {
                    ForEach(states) { s in
                        Text(s.value == now ? "\(s.label) ✓" : s.label).tag(s.value)
                    }
                }
                .pickerStyle(.segmented)
                if let now, shown != now {
                    Text("Previewing. Your setting is unchanged.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: state.asset)
        }
    }
}

/// One picture or looping clip from the Previews folder, or a placeholder.
struct PreviewMedia: View {
    static let aspect: CGFloat = 16.0 / 10.0
    let asset: String
    @Environment(AppModel.self) private var appModel

    var body: some View {
        Group {
            if let found = PreviewAssets.find(asset) {
                PreviewMediaFile(found: found)
            } else {
                placeholder
            }
        }
        .aspectRatio(Self.aspect, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(colors: [.gray.opacity(0.35), .gray.opacity(0.15)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(spacing: 6) {
                Image(systemName: "photo").font(.largeTitle)
                Text("Picture coming soon").font(.callout)
                if appModel.gameSettings.developerMode {
                    Text(asset).font(.caption.monospaced())
                }
            }
            .foregroundStyle(.secondary)
        }
    }
}

enum PreviewAssets {
    enum Found { case image(URL), video(URL) }

    private static let imageTypes = ["jpg", "jpeg", "png", "heic"]
    private static let videoTypes = ["mp4", "mov", "m4v"]

    /// A file in the app bundle named `name` (a video before a picture).
    static func find(_ name: String) -> Found? {
        for ext in videoTypes {
            if let url = Bundle.main.url(forResource: name, withExtension: ext) { return .video(url) }
        }
        for ext in imageTypes {
            if let url = Bundle.main.url(forResource: name, withExtension: ext) { return .image(url) }
        }
        return nil
    }
}

/// A muted clip that loops with no controls.
struct LoopingVideo: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> LoopingVideoView { LoopingVideoView(url: url) }
    func updateUIView(_ view: LoopingVideoView, context: Context) {}

    final class LoopingVideoView: UIView {
        private let queue = AVQueuePlayer()
        private var looper: AVPlayerLooper?

        override class var layerClass: AnyClass { AVPlayerLayer.self }
        private var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

        init(url: URL) {
            super.init(frame: .zero)
            queue.isMuted = true
            looper = AVPlayerLooper(player: queue, templateItem: AVPlayerItem(url: url))
            playerLayer.player = queue
            playerLayer.videoGravity = .resizeAspectFill
            queue.play()
        }
        required init?(coder: NSCoder) { fatalError() }
    }
}
