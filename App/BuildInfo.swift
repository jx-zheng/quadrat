import Foundation

enum BuildInfo {
    /// Short git SHA baked in at build time, or "dev" when git is unavailable.
    static var shortSHA: String {
        if let sha = Bundle.main.object(forInfoDictionaryKey: "GitCommit") as? String {
            let trimmed = sha.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, !trimmed.hasPrefix("$("), trimmed != "GIT_COMMIT" {
                return trimmed
            }
        }
        return "dev"
    }

    static var footer: String { "Quadrat · \(shortSHA)" }
}
