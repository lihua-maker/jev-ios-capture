import Foundation

/// The app and the keyboard extension are separate processes with separate sandboxes; the ONLY
/// channel between them is an App Group container. It requires a provisioning profile that grants
/// the group, so everything here degrades gracefully: when the group is unavailable the keyboard
/// falls back to the clipboard (see `ClipboardHandoff`).
public enum SharedContainer {
    public static let appGroupID = "group.ai.jevcopilot"

    public static var directory: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    public static var defaults: UserDefaults? {
        UserDefaults(suiteName: appGroupID)
    }

    /// True when the app was built with the App Group entitlement and the profile allows it.
    public static var isAvailable: Bool { directory != nil }

    public static func url(for name: String) -> URL? {
        directory?.appendingPathComponent(name)
    }
}

/// Last-resort handoff when no App Group is available (e.g. a free personal team): the app puts the
/// recommended reply on the clipboard and the keyboard inserts it. Requires keyboard Full Access.
public enum ClipboardHandoff {
    public static let marker = "jev-copilot:reply:"

    /// What the app writes: a marker, then the text, so the keyboard cannot mistake unrelated
    /// clipboard content for a suggestion.
    public static func encode(_ text: String) -> String { marker + text }

    public static func decode(_ clipboard: String?) -> String? {
        guard let clipboard, clipboard.hasPrefix(marker) else { return nil }
        let body = String(clipboard.dropFirst(marker.count))
        return body.isEmpty ? nil : body
    }
}