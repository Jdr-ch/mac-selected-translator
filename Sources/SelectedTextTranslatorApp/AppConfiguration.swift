import Foundation

struct AppConfiguration {
    let backendBaseURL: URL
    let projectRoot: URL?

    var translateURL: URL {
        backendBaseURL.appendingPathComponent("translate")
    }

    var healthURL: URL {
        backendBaseURL.appendingPathComponent("health")
    }

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main
    ) {
        let rawBackendURL = environment["TRANSLATOR_BACKEND_URL"]
            ?? bundle.object(forInfoDictionaryKey: "TranslatorBackendURL") as? String
            ?? "http://127.0.0.1:8765"

        self.backendBaseURL = Self.normalizedBackendURL(from: rawBackendURL)

        let rawProjectRoot = environment["TRANSLATOR_PROJECT_ROOT"]
            ?? bundle.object(forInfoDictionaryKey: "TranslatorProjectRoot") as? String
        if let rawProjectRoot, !rawProjectRoot.isEmpty {
            self.projectRoot = URL(fileURLWithPath: rawProjectRoot, isDirectory: true)
        } else {
            self.projectRoot = nil
        }
    }

    private static func normalizedBackendURL(from rawValue: String) -> URL {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutTrailingSlash = trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
        return URL(string: withoutTrailingSlash) ?? URL(string: "http://127.0.0.1:8765")!
    }
}
