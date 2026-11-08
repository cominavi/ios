import Foundation

/// Lifecycle rules for the hidden Google/Apple special entry.
///
/// Opening `cominavi://auth/google` or `cominavi://auth/apple` saves a
/// provider flow before the person picks a provider, and the sign-in screen
/// offers both. Whichever provider wins, the other flow must not outlive the
/// sign-in: a leftover flow would reopen the special entry on the next launch
/// and hide the verified account behind the sign-in screen.
enum SpecialEntryAuthenticationState {
    /// Whether launch should reopen the special entry from saved flows. A
    /// verified account always wins over a saved flow.
    static func shouldRestore(
        hasVerifiedProfile: Bool,
        googleFlow: GoogleAuthenticationFlow?,
        appleFlow: AppleAuthenticationFlow?
    ) -> Bool {
        guard !hasVerifiedProfile else { return false }
        return googleFlow?.entryContext == .special
            || appleFlow?.entryContext == .special
    }

    /// Clears every Google and Apple flow that never reached the backend,
    /// after a sign-in with any provider. Such a flow holds no server state,
    /// so dropping it cannot lose a session. A flow whose submission was
    /// attempted is committed-or-unknown and stays for receipt recovery.
    /// Logout keeps its own stricter rule: it clears every flow.
    static func retireUnsubmittedFlows(
        google: GoogleAuthenticationFlowCoordinator,
        apple: AppleAuthenticationFlowCoordinator,
        now: Date = Date()
    ) throws {
        if let flow = try google.load(now: now), flow.submissionAttemptedAt == nil {
            try google.clear()
        }
        if let flow = try apple.load(now: now), flow.submissionAttemptedAt == nil {
            try apple.clear()
        }
    }
}
