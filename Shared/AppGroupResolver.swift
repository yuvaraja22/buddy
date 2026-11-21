import Foundation

/// Resolves the active App Group container dynamically so Main App and WidgetKit
/// continue sharing data seamlessly after SideStore / AltStore re-signs the IPA
/// with a free Apple ID (which appends a Team ID suffix to App Group identifiers).
public enum AppGroupResolver {
    public static let defaultGroupIdentifier = "group.com.yuvaraja.buddy"
    public static let snapshotFileName = "widget_snapshot.json"

    private static let lock = NSLock()
    private static var cachedGroupID: String?

    /// Returns the active, accessible App Group identifier if one is provisioned.
    /// Non-nil results are cached; `nil` is never permanently cached so transient startup
    /// timing issues do not lock the app out of the shared container.
    public static func activeGroupIdentifier(
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) -> String? {
        if bundle == .main {
            lock.lock()
            let cached = cachedGroupID
            lock.unlock()
            if let cached {
                return cached
            }
        }

        let candidates = candidateGroupIdentifiers(for: bundle)
        let resolved = candidates.first { candidate in
            fileManager.containerURL(forSecurityApplicationGroupIdentifier: candidate) != nil
        }

        if bundle == .main, let resolved {
            lock.lock()
            cachedGroupID = resolved
            lock.unlock()
        }
        return resolved
    }

    /// Ordered candidate App Group IDs extracted from provisioning metadata and bundle info.
    public static func candidateGroupIdentifiers(for bundle: Bundle = .main) -> [String] {
        var candidates: [String] = []

        if let provisionURL = bundle.url(forResource: "embedded", withExtension: "mobileprovision"),
           let data = try? Data(contentsOf: provisionURL) {
            candidates.append(contentsOf: extractAppGroups(fromMobileProvisionData: data))
        }

        if let altGroups = bundle.infoDictionary?["ALTAppGroups"] as? [String] {
            candidates.append(contentsOf: altGroups)
        }

        if let bundleID = bundle.bundleIdentifier, !bundleID.isEmpty {
            candidates.append(contentsOf: derivedGroupIdentifiers(fromBundleIdentifier: bundleID))
        }

        candidates.append(defaultGroupIdentifier)

        var seen = Set<String>()
        return candidates.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Derives candidate App Group IDs from a bundle identifier, handling both standard
    /// Xcode builds (`com.yuvaraja.buddy.widgets`) and SideStore/AltStore re-signed
    /// extensions (`com.yuvaraja.buddy.widgets.<TEAMID>` or `com.yuvaraja.buddy.<TEAMID>.widgets`).
    public static func derivedGroupIdentifiers(fromBundleIdentifier bundleID: String) -> [String] {
        guard !bundleID.isEmpty else { return [] }
        var derived: [String] = []

        if let widgetsRange = bundleID.range(of: ".widgets") {
            let stripped = String(bundleID[..<widgetsRange.lowerBound] + bundleID[widgetsRange.upperBound...])
            if !stripped.isEmpty {
                derived.append("group.\(stripped)")
            }
        }
        derived.append("group.\(bundleID)")
        return derived
    }

    /// Extracts `com.apple.security.application-groups` from raw CMS-signed `embedded.mobileprovision` bytes.
    public static func extractAppGroups(fromMobileProvisionData data: Data) -> [String] {
        let startMarker = Data("<?xml".utf8)
        let endMarker = Data("</plist>".utf8)

        guard let startRange = data.range(of: startMarker),
              let endRange = data.range(of: endMarker, in: startRange.lowerBound..<data.endIndex) else {
            return []
        }

        let plistData = data[startRange.lowerBound..<endRange.upperBound]
        guard let plist = try? PropertyListSerialization.propertyList(
            from: plistData,
            options: [],
            format: nil
        ) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any],
              let groups = entitlements["com.apple.security.application-groups"] as? [String] else {
            return []
        }
        return groups
    }

    /// Shared container directory used by both Buddy and BuddyWidgets.
    /// Falls back safely to Application Support in unsigned simulator environments.
    public static var sharedContainerURL: URL {
        let fm = FileManager.default
        if let groupID = activeGroupIdentifier(fileManager: fm),
           let container = fm.containerURL(forSecurityApplicationGroupIdentifier: groupID) {
            return container
        }
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? fm.createDirectory(at: appSupport, withIntermediateDirectories: true)
        return appSupport
    }

    public static var widgetSnapshotURL: URL {
        sharedContainerURL.appendingPathComponent(snapshotFileName)
    }

    public static var sharedDefaults: UserDefaults {
        if let groupID = activeGroupIdentifier(),
           let defaults = UserDefaults(suiteName: groupID) {
            return defaults
        }
        return .standard
    }

    /// Human-readable diagnostic status for Settings -> SideStore Diagnostics.
    public static var diagnosticSummary: String {
        if let active = activeGroupIdentifier() {
            return "Active (\(active))"
        }
        return "Local fallback (App Group not provisioned)"
    }
}
