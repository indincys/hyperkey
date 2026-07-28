import Cocoa

struct InstalledApp: Identifiable, Hashable {
    var id: String { target }
    let name: String
    /// Bundle identifier when it has one, otherwise the path.
    let target: String
    let url: URL

    var icon: NSImage {
        let image = NSWorkspace.shared.icon(forFile: url.path)
        image.size = NSSize(width: 32, height: 32)
        return image
    }
}

/// Enumerates installed applications for the picker.
///
/// Reads the well-known application directories directly rather than querying
/// LaunchServices: it is fast, needs no extra permission, and returns exactly the
/// applications a person thinks of as "installed".
enum AppCatalog {
    private static let searchPaths: [String] = [
        "/Applications",
        "/Applications/Utilities",
        "/System/Applications",
        "/System/Applications/Utilities",
        NSHomeDirectory() + "/Applications",
    ]

    static func scan(completion: @escaping ([InstalledApp]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let apps = scanSync()
            DispatchQueue.main.async { completion(apps) }
        }
    }

    private static func scanSync() -> [InstalledApp] {
        let fileManager = FileManager.default
        var seen = Set<String>()
        var apps: [InstalledApp] = []

        for path in searchPaths {
            let directory = URL(fileURLWithPath: path)
            guard let entries = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isApplicationKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for url in entries where url.pathExtension == "app" {
                let name = url.deletingPathExtension().lastPathComponent
                let target = Bundle(url: url)?.bundleIdentifier ?? url.path
                guard seen.insert(target).inserted else { continue }
                apps.append(InstalledApp(name: name, target: target, url: url))
            }
        }

        return apps.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}
