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

    /// Settles a failed Google sign-in. A terminal failure clears the saved
    /// flow so the special entry does not reopen; any other failure keeps it
    /// for receipt recovery. Returns whether the flow was cleared.
    @discardableResult
    static func settleFailedSignIn(
        _ error: Error,
        googleFlow flow: GoogleAuthenticationFlow,
        clear: () throws -> Void
    ) -> Bool {
        guard isTerminal(error, googleFlow: flow) else { return false }
        try? clear()
        return true
    }

    /// Apple counterpart of `settleFailedSignIn(_:googleFlow:clear:)`.
    @discardableResult
    static func settleFailedSignIn(
        _ error: Error,
        appleFlow flow: AppleAuthenticationFlow,
        clear: () throws -> Void
    ) -> Bool {
        guard isTerminal(error, appleFlow: flow) else { return false }
        try? clear()
        return true
    }

    static func isTerminal(_ error: Error, googleFlow flow: GoogleAuthenticationFlow) -> Bool {
        // An allowlist refusal is written before anything is committed, so
        // there is no receipt to recover even after the request was sent.
        if (error as? CominaviServiceError)?.isSignInNotAllowlisted == true { return true }
        // Once bytes may have reached the service, an expired replay response
        // is committed-or-unknown until the backend can reconcile the durable
        // request. Never silently mint a second refresh-token family.
        if flow.submissionAttemptedAt != nil { return false }
        if let flowError = error as? GoogleAuthenticationFlowError {
            return flowError != .persistenceFailed
                && flowError != .committedOrUnknown
        }
        if case CominaviServiceError.server(_, _, let status) = error {
            return [400, 401, 403, 404, 409, 410, 422].contains(status)
        }
        return false
    }

    static func isTerminal(_ error: Error, appleFlow flow: AppleAuthenticationFlow) -> Bool {
        if (error as? CominaviServiceError)?.isSignInNotAllowlisted == true { return true }
        if flow.submissionAttemptedAt != nil { return false }
        if let flowError = error as? AppleAuthenticationFlowError {
            // A failed Apple sheet keeps the flow and its entry grant, so a
            // retry right after it (for example after signing in to an
            // Apple Account) needs no new special-entry request.
            return flowError != .persistenceFailed
                && flowError != .committedOrUnknown
                && flowError != .authorizationFailed
        }
        if case CominaviServiceError.server(_, _, let status) = error {
            return [400, 401, 403, 404, 409, 410, 422].contains(status)
        }
        return false
    }
}
