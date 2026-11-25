import Foundation

/// Sidebar "Jump To" destinations, resolved by exact path under the user's home.
public enum JumpTargets {
    public enum Key: Equatable, Sendable {
        case home
        case homeDeveloper
        case libraryDeveloper
        case downloads
    }

    public static func homeComponents(from homePrefix: String) -> [String] {
        homePrefix.split(separator: "/").map(String.init).filter { !$0.isEmpty && $0 != "." }
    }

    public static func components(for key: Key, homePrefix: String) -> [String] {
        let home = homeComponents(from: homePrefix)
        switch key {
        case .home: return home
        case .homeDeveloper: return home + ["Developer"]
        case .libraryDeveloper: return home + ["Library", "Developer"]
        case .downloads: return home + ["Downloads"]
        }
    }

    /// Walks exact path components from the store root. If the root is already
    /// the first component (a scan that started at $HOME), that component is skipped.
    public static func resolve(store: NodeStore, homePrefix: String, key: Key) -> UInt32? {
        let parts = components(for: key, homePrefix: homePrefix)
        guard !parts.isEmpty, store.rootID != 0 else { return nil }
        return walk(store: store, components: parts)
    }

    public static func walk(store: NodeStore, components: [String]) -> UInt32? {
        guard !components.isEmpty, store.rootID != 0 else { return nil }
        var id = store.rootID
        var rest = components
        if store.name(of: id) == rest[0] {
            rest = Array(rest.dropFirst())
        }
        for part in rest {
            var found: UInt32?
            store.forEachChild(id) { child in
                if found == nil, store.name(of: child) == part { found = child }
            }
            guard let next = found else { return nil }
            id = next
        }
        return id
    }
}
