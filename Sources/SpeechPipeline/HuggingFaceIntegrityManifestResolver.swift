import CryptoKit
import Foundation
import ModelManager

struct HuggingFaceModelSource: Equatable, Sendable {
    let repository: String
    let revision: String
    let requiredRoots: [String]
    let strippingRemotePrefix: String?

    init(
        repository: String,
        revision: String = "main",
        requiredRoots: [String],
        strippingRemotePrefix: String? = nil
    ) throws {
        guard Self.isRepository(repository),
            Self.isSafePathComponent(revision),
            !requiredRoots.isEmpty,
            requiredRoots.allSatisfy(Self.isSafeRelativePath),
            strippingRemotePrefix.map(Self.isSafeRelativePath) ?? true
        else {
            throw HuggingFaceManifestError.invalidSource(repository)
        }
        self.repository = repository
        self.revision = revision
        self.requiredRoots = Array(Set(requiredRoots)).sorted()
        self.strippingRemotePrefix = strippingRemotePrefix
    }

    func localPath(for remotePath: String) throws -> String {
        guard let strippingRemotePrefix else {
            return remotePath
        }
        let prefix = strippingRemotePrefix + "/"
        guard remotePath.hasPrefix(prefix) else {
            throw HuggingFaceManifestError.invalidArtifact(remotePath)
        }
        let localPath = String(remotePath.dropFirst(prefix.count))
        guard Self.isSafeRelativePath(localPath) else {
            throw HuggingFaceManifestError.invalidArtifact(remotePath)
        }
        return localPath
    }

    private static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/") else {
            return false
        }
        return path.split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy { component in
                !component.isEmpty && component != "." && component != ".."
            }
    }

    private static func isRepository(_ repository: String) -> Bool {
        let components = repository.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        return components.count == 2
            && components.allSatisfy { isSafePathComponent(String($0)) }
    }

    private static func isSafePathComponent(_ component: String) -> Bool {
        !component.isEmpty && component != "." && component != ".."
            && !component.contains("/") && !component.contains("\\")
    }
}

struct HuggingFaceResolvedArtifact: Equatable, Sendable {
    let integrity: ModelArtifactIntegrity
    let downloadURL: URL
}

enum HuggingFaceManifestError:
    Error,
    Equatable,
    LocalizedError,
    Sendable
{
    case invalidSource(String)
    case invalidResponse(URL)
    case missingRoot(String)
    case emptyDirectory(String)
    case invalidArtifact(String)
    case oversizedNonLFSArtifact(String, Int64)

    var errorDescription: String? {
        switch self {
        case let .invalidSource(source):
            "Invalid Hugging Face model source: \(source)."
        case let .invalidResponse(url):
            "Hugging Face returned invalid manifest data from \(url.absoluteString)."
        case let .missingRoot(path):
            "The upstream model manifest is missing required artifact \(path)."
        case let .emptyDirectory(path):
            "The upstream model directory \(path) contains no files."
        case let .invalidArtifact(path):
            "The upstream model manifest contains invalid metadata for \(path)."
        case let .oversizedNonLFSArtifact(path, size):
            "The upstream artifact \(path) has no SHA-256 and is too large to verify safely (\(size) bytes)."
        }
    }
}

struct HuggingFaceIntegrityManifestResolver: Sendable {
    typealias Fetch = @Sendable (URL) async throws -> Data

    // Hugging Face's upload tooling automatically routes files over 10 MB to
    // large-file storage. Regular Git artifacts below that boundary are still
    // downloaded and SHA-256 hashed here before entering the managed plan.
    private static let maximumNonLFSHashBytes: Int64 = 10 * 1_024 * 1_024
    private let fetch: Fetch

    init(fetch: @escaping Fetch = Self.fetchFromNetwork) {
        self.fetch = fetch
    }

    func resolve(
        _ source: HuggingFaceModelSource
    ) async throws -> ModelIntegrityManifest {
        try ModelIntegrityManifest(
            artifacts: await resolveArtifacts(source).map(\.integrity)
        )
    }

    func resolveArtifacts(
        _ source: HuggingFaceModelSource
    ) async throws -> [HuggingFaceResolvedArtifact] {
        let rootURL = try treeURL(for: source, path: nil)
        let rootItems = try decodeItems(
            try await fetch(rootURL),
            from: rootURL
        )
        var artifacts: [HuggingFaceResolvedArtifact] = []

        for root in source.requiredRoots {
            guard let item = rootItems.first(where: { $0.path == root }) else {
                throw HuggingFaceManifestError.missingRoot(root)
            }
            switch item.type {
            case "file":
                artifacts.append(
                    try await artifact(for: item, source: source)
                )
            case "directory":
                let directoryURL = try treeURL(for: source, path: root)
                let directoryItems = try decodeItems(
                    try await fetch(directoryURL),
                    from: directoryURL
                ).filter { $0.type == "file" }
                guard !directoryItems.isEmpty else {
                    throw HuggingFaceManifestError.emptyDirectory(root)
                }
                for file in directoryItems {
                    artifacts.append(
                        try await artifact(for: file, source: source)
                    )
                }
            default:
                throw HuggingFaceManifestError.invalidArtifact(root)
            }
        }
        return artifacts
    }

    private func artifact(
        for item: TreeItem,
        source: HuggingFaceModelSource
    ) async throws -> HuggingFaceResolvedArtifact {
        guard item.size >= 0 else {
            throw HuggingFaceManifestError.invalidArtifact(item.path)
        }
        let digest: String
        if let lfs = item.lfs,
            lfs.size == item.size,
            Self.isSHA256(lfs.oid)
        {
            digest = lfs.oid.lowercased()
        } else {
            guard item.size <= Self.maximumNonLFSHashBytes else {
                throw HuggingFaceManifestError.oversizedNonLFSArtifact(
                    item.path,
                    item.size
                )
            }
            let contentURL = try rawURL(for: source, path: item.path)
            let data = try await fetch(contentURL)
            guard data.count == item.size else {
                throw HuggingFaceManifestError.invalidArtifact(item.path)
            }
            digest = SHA256.hash(data: data).map {
                String(format: "%02x", $0)
            }.joined()
        }
        return try HuggingFaceResolvedArtifact(
            integrity: ModelArtifactIntegrity(
                relativePath: source.localPath(for: item.path),
                expectedByteCount: item.size,
                sha256: digest
            ),
            downloadURL: rawURL(for: source, path: item.path)
        )
    }

    private func decodeItems(
        _ data: Data,
        from url: URL
    ) throws -> [TreeItem] {
        do {
            return try JSONDecoder().decode([TreeItem].self, from: data)
        } catch {
            throw HuggingFaceManifestError.invalidResponse(url)
        }
    }

    private func treeURL(
        for source: HuggingFaceModelSource,
        path: String?
    ) throws -> URL {
        var url = URL(string: "https://huggingface.co/api/models")!
        for component in source.repository.split(separator: "/") {
            url.appendPathComponent(String(component))
        }
        url.appendPathComponent("tree")
        url.appendPathComponent(source.revision)
        if let path {
            for component in path.split(separator: "/") {
                url.appendPathComponent(String(component))
            }
        }
        guard var components = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        ) else {
            throw HuggingFaceManifestError.invalidSource(source.repository)
        }
        components.queryItems = [
            URLQueryItem(
                name: "recursive",
                value: path == nil ? "false" : "true"
            ),
            URLQueryItem(name: "expand", value: "true"),
            URLQueryItem(name: "limit", value: "100"),
        ]
        guard let result = components.url else {
            throw HuggingFaceManifestError.invalidSource(source.repository)
        }
        return result
    }

    private func rawURL(
        for source: HuggingFaceModelSource,
        path: String
    ) throws -> URL {
        var url = URL(string: "https://huggingface.co")!
        for component in source.repository.split(separator: "/") {
            url.appendPathComponent(String(component))
        }
        url.appendPathComponent("resolve")
        url.appendPathComponent(source.revision)
        for component in path.split(separator: "/") {
            url.appendPathComponent(String(component))
        }
        guard var components = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        ) else {
            throw HuggingFaceManifestError.invalidSource(source.repository)
        }
        components.queryItems = [URLQueryItem(name: "download", value: "true")]
        guard let result = components.url else {
            throw HuggingFaceManifestError.invalidSource(source.repository)
        }
        return result
    }

    private static func fetchFromNetwork(_ url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let response = response as? HTTPURLResponse,
            (200..<300).contains(response.statusCode)
        else {
            throw HuggingFaceManifestError.invalidResponse(url)
        }
        return data
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit }
    }
}

private struct TreeItem: Decodable, Sendable {
    struct LFS: Decodable, Sendable {
        let oid: String
        let size: Int64
    }

    let type: String
    let path: String
    let size: Int64
    let lfs: LFS?
}
