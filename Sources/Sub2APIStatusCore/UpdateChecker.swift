import Foundation

public enum AppBuildInfo {
    public static let fallbackVersion = "0.1.9"
    public static let repositoryOwner = "yueqingyou"
    public static let repositoryName = "Sub2APIStatusBar"
    public static let bundleIdentifier = "com.geekywizkid.sub2api-statusbar"
}

public struct AppVersion: Comparable, CustomStringConvertible, Sendable {
    public let rawValue: String
    private let parts: [Int]

    public init(_ rawValue: String) {
        var trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("v") {
            trimmed.removeFirst()
        }
        self.rawValue = trimmed.isEmpty ? "0.0.0" : trimmed
        let numericPrefix = self.rawValue.split(separator: "-", maxSplits: 1).first ?? ""
        parts = numericPrefix
            .split(separator: ".")
            .map { Int($0) ?? 0 }
    }

    public var description: String {
        rawValue
    }

    public static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        lhs.normalizedParts == rhs.normalizedParts
    }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let maxCount = max(lhs.normalizedParts.count, rhs.normalizedParts.count)
        for index in 0..<maxCount {
            let left = index < lhs.normalizedParts.count ? lhs.normalizedParts[index] : 0
            let right = index < rhs.normalizedParts.count ? rhs.normalizedParts[index] : 0
            if left != right {
                return left < right
            }
        }
        return false
    }

    private var normalizedParts: [Int] {
        var values = parts
        while values.last == 0, values.count > 1 {
            values.removeLast()
        }
        return values
    }
}

public struct GitHubReleaseAsset: Decodable, Equatable, Sendable {
    public let name: String
    public let downloadURL: URL
    public let contentType: String?
    public let size: Int?

    public init(name: String, downloadURL: URL, contentType: String?, size: Int?) {
        self.name = name
        self.downloadURL = downloadURL
        self.contentType = contentType
        self.size = size
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case downloadURL = "browser_download_url"
        case contentType = "content_type"
        case size
    }
}

public struct GitHubRelease: Decodable, Equatable, Sendable {
    public let tagName: String
    public let name: String
    public let releaseURL: URL
    public let draft: Bool
    public let prerelease: Bool
    public let assets: [GitHubReleaseAsset]

    public init(
        tagName: String,
        name: String,
        releaseURL: URL,
        draft: Bool,
        prerelease: Bool,
        assets: [GitHubReleaseAsset] = []
    ) {
        self.tagName = tagName
        self.name = name
        self.releaseURL = releaseURL
        self.draft = draft
        self.prerelease = prerelease
        self.assets = assets
    }

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case releaseURL = "html_url"
        case draft
        case prerelease
        case assets
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tagName = try container.decode(String.self, forKey: .tagName)
        name = try container.decode(String.self, forKey: .name)
        releaseURL = try container.decode(URL.self, forKey: .releaseURL)
        draft = try container.decode(Bool.self, forKey: .draft)
        prerelease = try container.decode(Bool.self, forKey: .prerelease)
        assets = try container.decodeIfPresent([GitHubReleaseAsset].self, forKey: .assets) ?? []
    }

    public var version: AppVersion {
        AppVersion(tagName)
    }

    public func installArchiveAsset(repositoryName: String = AppBuildInfo.repositoryName) -> GitHubReleaseAsset? {
        let zipAssets = assets.filter { $0.name.lowercased().hasSuffix(".zip") }
        let repository = repositoryName.lowercased()

        if let appArchive = zipAssets.first(where: { asset in
            let name = asset.name.lowercased()
            return name.contains(repository)
                && name.contains("macos")
                && !name.contains("symbols")
        }) {
            return appArchive
        }

        if let macOSArchive = zipAssets.first(where: { asset in
            let name = asset.name.lowercased()
            return name.contains("macos") && !name.contains("symbols")
        }) {
            return macOSArchive
        }

        return zipAssets.first
    }
}

public struct UpdateInfo: Equatable, Sendable {
    public let currentVersion: AppVersion
    public let latestRelease: GitHubRelease

    public init(currentVersion: AppVersion, release: GitHubRelease) {
        self.currentVersion = currentVersion
        latestRelease = release
    }

    public var isUpdateAvailable: Bool {
        latestRelease.version > currentVersion
    }

    public var statusText: String {
        if isUpdateAvailable {
            return "Version \(latestRelease.version) is available."
        }
        return "You are up to date."
    }
}

public enum UpdateCheckError: Error, LocalizedError, Sendable {
    case invalidReleaseURL
    case badStatus(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidReleaseURL:
            return "Update URL is invalid."
        case let .badStatus(status):
            return "Update check failed with HTTP \(status)."
        }
    }
}

public struct GitHubUpdateChecker: Sendable {
    public let owner: String
    public let repository: String
    public let session: URLSession

    public init(
        owner: String = AppBuildInfo.repositoryOwner,
        repository: String = AppBuildInfo.repositoryName,
        session: URLSession = .shared
    ) {
        self.owner = owner
        self.repository = repository
        self.session = session
    }

    public func check(currentVersion: String) async throws -> UpdateInfo {
        let release = try await latestRelease()
        return UpdateInfo(currentVersion: AppVersion(currentVersion), release: release)
    }

    public func latestRelease() async throws -> GitHubRelease {
        guard let url = URL(string: "https://api.github.com/repos/\(owner)/\(repository)/releases/latest") else {
            throw UpdateCheckError.invalidReleaseURL
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Sub2APIStatusBar", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw UpdateCheckError.badStatus(http.statusCode)
        }
        return try JSONDecoder().decode(GitHubRelease.self, from: data)
    }
}
