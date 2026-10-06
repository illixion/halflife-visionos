//
//  DebugApprovalWindow.swift
//  LambdaVision
//
//  DebugTrace asks on the device before a client may debug the app. Its
//  default prompt (`.ask`) is a UIKit alert over the frontmost window, which
//  the immersive space doesn't have: the request just waits out its 60 s and
//  is refused. So the server uses `.custom` with this: the request opens its
//  own small window, which visionOS shows in front of the player over full
//  immersion, like the Console and Performance windows.
//

import SwiftUI
import DebugTrace
#if canImport(DebugTraceServer) && !LAMBDA_NO_DEBUG_SERVER
import DebugTraceServer
#endif

@MainActor @Observable
final class DebugApprovalCenter {
    static let shared = DebugApprovalCenter()
    static let windowID = "debug-approval"

    /// The client waiting for an answer, shown by the window.
    private(set) var client: String?
    private(set) var appName = ""

    /// Captured from whichever window appeared last; opening a window needs
    /// a SwiftUI action and the request arrives from the server, not a view.
    @ObservationIgnored var openWindow: OpenWindowAction?
    @ObservationIgnored var dismissWindow: DismissWindowAction?

    #if canImport(DebugTraceServer) && !LAMBDA_NO_DEBUG_SERVER
    @ObservationIgnored private var continuation: CheckedContinuation<DebugApprovalDecision, Never>?

    /// The `.custom` approval handler. DebugTrace runs one at a time per
    /// client, so a second client waits for the first to be answered.
    func ask(_ request: DebugApprovalRequest) async -> DebugApprovalDecision {
        guard let openWindow else {
            AppLog.app.log("[DebugServer] approval refused: no window has appeared yet to open the prompt from")
            return .deny
        }
        while continuation != nil { try? await Task.sleep(for: .milliseconds(200)) }
        client = request.client
        appName = request.appName
        openWindow(id: Self.windowID)
        return await withCheckedContinuation { continuation = $0 }
    }

    func answer(_ decision: DebugApprovalDecision) {
        continuation?.resume(returning: decision)
        continuation = nil
        client = nil
        dismissWindow?(id: Self.windowID)
    }
    #endif
}

extension View {
    /// Lets the approval center open its window from this view's scene.
    func capturesDebugApprovalActions() -> some View {
        modifier(CaptureWindowActions())
    }
}

private struct CaptureWindowActions: ViewModifier {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    func body(content: Content) -> some View {
        content.onAppear {
            DebugApprovalCenter.shared.openWindow = openWindow
            DebugApprovalCenter.shared.dismissWindow = dismissWindow
        }
    }
}

struct DebugApprovalView: View {
    private var center = DebugApprovalCenter.shared

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "ladybug")
                .font(.system(size: 40))
            Text("Allow debug access?")
                .font(.title2.bold())
            if let client = center.client {
                Text("\(client) wants to read \(center.appName)'s logs, take screenshots and run its debug commands.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                #if canImport(DebugTraceServer) && !LAMBDA_NO_DEBUG_SERVER
                VStack(spacing: 10) {
                    Button("Allow") { center.answer(.allowOnce) }
                        .buttonStyle(.borderedProminent)
                    Button("Always for This Build") { center.answer(.allowForBuild) }
                    Button("Don't Allow", role: .cancel) { center.answer(.deny) }
                }
                #endif
            } else {
                Text("No request is waiting.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(32)
        .frame(width: 460)
        .capturesDebugApprovalActions()
        #if canImport(DebugTraceServer) && !LAMBDA_NO_DEBUG_SERVER
        // Closing the window without answering counts as Don't Allow, so the
        // request isn't left hanging until its timeout.
        .onDisappear { if center.client != nil { center.answer(.deny) } }
        #endif
    }
}
