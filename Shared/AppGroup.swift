import Foundation

/// Shared App Group between the main app and the Broadcast Upload Extension.
/// Must match the "com.apple.security.application-groups" entitlement on BOTH targets,
/// and must be registered on developer.apple.com under this Apple ID's team once real
/// signing is set up (Xcode's "Automatic" signing can also create it on first build).
enum AppGroup {
    static let identifier = "group.com.screenmirror.shared"

    /// Local Unix-domain socket the main app listens on and the extension connects to,
    /// to forward captured video/audio frames. Living inside the App Group container
    /// is what lets both processes (app + extension, which are sandboxed separately)
    /// agree on a path they're both allowed to use.
    static var socketPath: String {
        guard let containerURL = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: identifier)
        else {
            fatalError("App Group container not available — check the entitlement and that the group is registered for this Apple Developer team.")
        }
        return containerURL.appendingPathComponent("frames.sock").path
    }
}
