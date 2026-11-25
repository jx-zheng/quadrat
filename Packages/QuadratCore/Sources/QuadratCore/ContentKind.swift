import Foundation

/// Colour is the kind of content, not the depth, so a nested `node_modules` stays `node_modules`.
public enum ContentKind: UInt8, CaseIterable, Equatable, Sendable {
    case developer = 0
    case builds = 1
    case nodeModules = 2
    case vms = 3
    case photos = 4
    case media = 5
    case apps = 6
    case documents = 7
    case caches = 8
    case backups = 9
    case system = 10
    case other = 11
    case unscanned = 12

    public var legendTitle: String {
        switch self {
        case .developer: return "Developer"
        case .builds: return "Builds & repos"
        case .nodeModules: return "node_modules"
        case .vms: return "VMs & models"
        case .photos: return "Photos"
        case .media: return "Media"
        case .apps: return "Apps"
        case .documents: return "Documents"
        case .caches: return "Caches"
        case .backups: return "Backups"
        case .system: return "System"
        case .other: return "Other"
        case .unscanned: return "Not scanned"
        }
    }
}

public enum KindClassifier {
    public static func classify(name: String, parent: ContentKind, isDirectory: Bool) -> ContentKind {
        let lower = name.lowercased()
        if lower == "node_modules" || lower == ".npm" || lower == "bower_components" {
            return .nodeModules
        }
        if lower == "applications" || lower.hasSuffix(".app") { return .apps }
        if isBuildName(lower) { return .builds }
        if isCacheName(lower) { return .caches }
        if lower.contains("backup") || lower == ".trash" || lower == "trash" { return .backups }
        if isPhotoName(lower) { return .photos }
        if isMediaName(lower) { return .media }
        if isVMName(lower) { return .vms }
        if isDocumentName(lower) { return .documents }
        if isSystemName(lower) { return .system }
        if lower == "developer" || lower == ".git" { return .developer }
        if let ext = extensionKind(lower, isDirectory: isDirectory) {
            return ext
        }
        if parent != .other && parent != .unscanned {
            return parent
        }
        return .other
    }

    private static func isBuildName(_ lower: String) -> Bool {
        switch lower {
        case "deriveddata", "build", ".build", "pods", "carthage", "archives",
             "modulecache.noindex", "index.noindex", "sdkstatcaches.noindex":
            return true
        default:
            return lower.hasSuffix(".xcarchive")
        }
    }

    private static func isCacheName(_ lower: String) -> Bool {
        lower == "caches" || lower == "cache" || lower == ".cache" || lower.hasSuffix("cache")
    }

    private static func isPhotoName(_ lower: String) -> Bool {
        lower == "pictures" || lower == "photos" || lower == "originals"
            || lower.hasSuffix(".photoslibrary") || lower.hasSuffix(".photolibrary")
    }

    private static func isMediaName(_ lower: String) -> Bool {
        lower == "movies" || lower == "music" || lower == "tv" || lower == "podcasts"
            || lower == "screen recordings" || lower == "exports"
            || lower.hasSuffix(".fcpbundle") || lower.hasSuffix(".tvlibrary")
    }

    private static func isVMName(_ lower: String) -> Bool {
        lower == "docker.raw" || lower == ".ollama" || lower == "models" || lower == "vm"
            || lower.hasSuffix(".vmdk") || lower.hasSuffix(".qcow2") || lower.hasSuffix(".vdi")
            || lower.hasSuffix(".raw")
    }

    private static func isDocumentName(_ lower: String) -> Bool {
        switch lower {
        case "documents", "desktop", "downloads", "datasets", "other downloads":
            return true
        default:
            return false
        }
    }

    private static func isSystemName(_ lower: String) -> Bool {
        switch lower {
        case "system", "system & other", "bin", "sbin", "private", "var":
            return true
        default:
            return false
        }
    }

    private static func extensionKind(_ lower: String, isDirectory: Bool) -> ContentKind? {
        guard !isDirectory, let dot = lower.lastIndex(of: ".") else { return nil }
        let ext = String(lower[lower.index(after: dot)...])
        switch ext {
        case "jpg", "jpeg", "png", "heic", "gif", "tiff", "tif", "dng", "webp":
            return .photos
        case "mp4", "mov", "m4v", "mkv", "mp3", "aac", "wav", "aiff", "flac":
            return .media
        case "pdf", "txt", "md", "rtf", "doc", "docx", "pages", "key", "numbers", "ppt", "pptx":
            return .documents
        case "dmg", "iso":
            return .vms
        case "app":
            return .apps
        default:
            return nil
        }
    }
}
