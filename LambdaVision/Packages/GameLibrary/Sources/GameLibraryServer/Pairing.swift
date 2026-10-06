//
//  Pairing.swift
//  GameLibraryServer
//
//  The 6-digit PIN shown in the headset's modal, swapped once for a session
//  token (a cookie for the page, a bearer token for scripts).
//
//  A PIN has 10⁶ values, so guessing must be slow: every wrong attempt
//  starts a short cooldown during which further attempts are refused
//  without being checked, and a handful of wrong attempts replaces the PIN
//  (the modal shows the new one) and locks pairing for longer. A LAN
//  neighbour gets about five guesses per new PIN and half a minute — over a
//  modal left open for an hour, odds of roughly 1 in 2,000 for an attacker
//  who never stops, and they'd be competing with a wearer watching the PIN
//  change in front of them.
//
//  Everything lives in memory: stopping the server forgets every session.
//

import Foundation

public final class Pairing: @unchecked Sendable {
    public struct Policy: Sendable {
        /// Wrong attempts before the PIN is replaced.
        public var failuresPerPIN = 5
        /// Pause after each wrong attempt.
        public var cooldown: TimeInterval = 1
        /// Pause after the PIN is replaced.
        public var lockout: TimeInterval = 30
        /// Sessions kept; the least recently used goes first.
        public var maxSessions = 16
        public init() {}
    }

    public enum Attempt: Equatable, Sendable {
        case paired(token: String)
        /// Wrong; `regenerated` when that used up the PIN.
        case wrong(regenerated: Bool)
        /// Refused unchecked; retry after this many seconds.
        case tooSoon(retryAfter: Int)
    }

    public let policy: Policy
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var currentPIN: String
    private var failures = 0
    private var lockedUntil = Date.distantPast
    private var sessions: [String: Date] = [:]
    /// Told about every new PIN (after failures), off the main thread.
    public var onPINChange: (@Sendable (String) -> Void)?

    public init(policy: Policy = Policy(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.policy = policy
        self.now = now
        currentPIN = Self.makePIN()
    }

    public var pin: String { lock.lock(); defer { lock.unlock() }; return currentPIN }

    public var sessionCount: Int { lock.lock(); defer { lock.unlock() }; return sessions.count }

    public func attempt(_ guess: String) -> Attempt {
        let t = now()
        lock.lock()
        if t < lockedUntil {
            let wait = Int(lockedUntil.timeIntervalSince(t).rounded(.up))
            lock.unlock()
            return .tooSoon(retryAfter: max(1, wait))
        }
        let cleaned = guess.filter(\.isNumber)
        if Self.constantTimeEqual(cleaned, currentPIN) {
            failures = 0
            let token = Self.makeToken()
            if sessions.count >= policy.maxSessions,
               let oldest = sessions.min(by: { $0.value < $1.value })?.key {
                sessions[oldest] = nil
            }
            sessions[token] = t
            lock.unlock()
            return .paired(token: token)
        }
        failures += 1
        var regenerated: String?
        if failures >= policy.failuresPerPIN {
            failures = 0
            currentPIN = Self.makePIN(not: currentPIN)
            regenerated = currentPIN
            lockedUntil = t.addingTimeInterval(policy.lockout)
        } else {
            lockedUntil = t.addingTimeInterval(policy.cooldown)
        }
        let callback = onPINChange
        lock.unlock()
        if let regenerated { callback?(regenerated) }
        return .wrong(regenerated: regenerated != nil)
    }

    /// Whether a token belongs to a live session; marks it used.
    public func validate(_ token: String?) -> Bool {
        guard let token, !token.isEmpty else { return false }
        lock.lock(); defer { lock.unlock() }
        guard sessions[token] != nil else { return false }
        sessions[token] = now()
        return true
    }

    /// Tokens used within `seconds`.
    public func activeTokens(within seconds: TimeInterval) -> Set<String> {
        let cutoff = now().addingTimeInterval(-seconds)
        lock.lock(); defer { lock.unlock() }
        return Set(sessions.filter { $0.value >= cutoff }.keys)
    }

    public func revokeAll() {
        lock.lock(); sessions.removeAll(); lock.unlock()
    }

    static func makePIN(not previous: String? = nil) -> String {
        var rng = SystemRandomNumberGenerator()
        while true {
            let pin = String(format: "%06d", Int.random(in: 0..<1_000_000, using: &rng))
            if pin != previous { return pin }
        }
    }

    static func makeToken() -> String {
        var rng = SystemRandomNumberGenerator()
        return (0..<4).map { _ in String(format: "%016llx", rng.next() as UInt64) }.joined()
    }

    static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<x.count { diff |= x[i] ^ y[i] }
        return diff == 0
    }
}
