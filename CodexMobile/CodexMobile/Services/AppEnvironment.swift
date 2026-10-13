// FILE: AppEnvironment.swift
// Purpose: Centralizes local runtime endpoint and public app config lookups.
// Layer: Service
// Exports: AppEnvironment
// Depends on: Foundation

import Foundation

enum AppEnvironment {
    private static let defaultRelayURLInfoPlistKey = "CODEX_REMOTE_DEFAULT_RELAY_URL"

    // Open-source builds should provide an explicit relay instead of silently
    // pointing at a hosted service the user does not control.
    static let defaultRelayURLString = ""

    static var relayBaseURL: String {
        if let infoURL = resolvedString(forInfoPlistKey: defaultRelayURLInfoPlistKey) {
            return infoURL
        }
        return defaultRelayURLString
    }

    // Legal links shown in Settings.
    // Keep these pointed at a public source-of-truth until the website serves dedicated legal routes.
    static let privacyPolicyURL = URL(
        string: "https://github.com/sky-story/CodexLink/blob/main/docs/privacy.md"
    )!
    static let termsOfUseURL = URL(
        string: "https://github.com/sky-story/CodexLink/blob/main/docs/terms.md"
    )!

    // Retain the property name for existing callers; feedback belongs to this fork.
    static var feedbackMailtoURL: URL {
        URL(string: "https://github.com/sky-story/CodexLink/issues")!
    }
}

private extension AppEnvironment {
    static func resolvedString(forInfoPlistKey key: String) -> String? {
        guard let rawValue = Bundle.main.object(forInfoDictionaryKey: key) as? String else {
            return nil
        }

        let trimmedValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty else {
            return nil
        }

        if trimmedValue.hasPrefix("$("), trimmedValue.hasSuffix(")") {
            return nil
        }

        return trimmedValue
    }
}
