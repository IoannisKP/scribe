import CryptoKit
import Foundation

public struct ModelArtifactIntegrity: Equatable, Codable, Sendable {
    public let relativePath: String
    public let expectedByteCount: Int64
    public let sha256: String

    public init(
        relativePath: String,
        expectedByteCount: Int64,
        sha256: String
    ) throws {
        guard Self.isSafeRelativePath(relativePath) else {
            throw ModelIntegrityError.invalidRelativePath(relativePath)
        }
        guard expectedByteCount >= 0 else {
            throw ModelIntegrityError.invalidExpectedByteCount(
                relativePath,
                expectedByteCount
            )
        }
        let normalizedDigest = sha256.lowercased()
        guard normalizedDigest.count == 64,
            normalizedDigest.allSatisfy(\.isHexDigit)
        else {
            throw ModelIntegrityError.invalidSHA256(relativePath, sha256)
        }
        self.relativePath = relativePath
        self.expectedByteCount = expectedByteCount
        self.sha256 = normalizedDigest
    }

    private static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/") else {
            return false
        }
        let components = path.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        return components.allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\")
        }
    }
}

public struct ModelIntegrityManifest: Equatable, Codable, Sendable {
    public let artifacts: [ModelArtifactIntegrity]

    public init(artifacts: [ModelArtifactIntegrity]) throws {
        guard !artifacts.isEmpty else {
            throw ModelIntegrityError.emptyManifest
        }
        var paths: Set<String> = []
        for artifact in artifacts {
            guard paths.insert(artifact.relativePath).inserted else {
                throw ModelIntegrityError.duplicateArtifact(
                    artifact.relativePath
                )
            }
        }
        self.artifacts = artifacts
    }
}

public enum ModelIntegrityError:
    Error,
    Equatable,
    LocalizedError,
    Sendable
{
    case emptyManifest
    case invalidRelativePath(String)
    case invalidExpectedByteCount(String, Int64)
    case invalidSHA256(String, String)
    case duplicateArtifact(String)
    case missingArtifact(String)
    case artifactEscapesInstallation(String)
    case byteCountMismatch(
        path: String,
        expected: Int64,
        actual: Int64
    )
    case checksumMismatch(path: String, expected: String, actual: String)

    public var errorDescription: String? {
        switch self {
        case .emptyManifest:
            "A checksum manifest must contain at least one artifact."
        case let .invalidRelativePath(path):
            "Model artifact path ‘\(path)’ is not a safe relative path."
        case let .invalidExpectedByteCount(path, byteCount):
            "Model artifact \(path) has invalid expected size \(byteCount)."
        case let .invalidSHA256(path, digest):
            "Model artifact \(path) has invalid SHA-256 digest ‘\(digest)’."
        case let .duplicateArtifact(path):
            "Model artifact \(path) appears more than once in its manifest."
        case let .missingArtifact(path):
            "Downloaded model artifact \(path) is missing."
        case let .artifactEscapesInstallation(path):
            "Downloaded model artifact \(path) resolves outside its installation."
        case let .byteCountMismatch(path, expected, actual):
            "Downloaded model artifact \(path) has \(actual) bytes; expected \(expected)."
        case let .checksumMismatch(path, expected, actual):
            "Downloaded model artifact \(path) has SHA-256 \(actual); expected \(expected)."
        }
    }
}

public actor ModelIntegrityVerifier {
    private let readChunkSize: Int

    public init(readChunkSize: Int = 1_048_576) {
        self.readChunkSize = max(1, readChunkSize)
    }

    public func verify(
        directory: URL,
        manifest: ModelIntegrityManifest
    ) throws {
        let resolvedDirectory = directory.resolvingSymlinksInPath()
            .standardizedFileURL
        for artifact in manifest.artifacts {
            let artifactURL = directory.appendingPathComponent(
                artifact.relativePath,
                isDirectory: false
            )
            let resolvedArtifact = artifactURL.resolvingSymlinksInPath()
                .standardizedFileURL
            let installationPrefix = resolvedDirectory.path.hasSuffix("/")
                ? resolvedDirectory.path
                : resolvedDirectory.path + "/"
            guard resolvedArtifact.path.hasPrefix(installationPrefix)
            else {
                throw ModelIntegrityError.artifactEscapesInstallation(
                    artifact.relativePath
                )
            }
            guard FileManager.default.fileExists(atPath: artifactURL.path) else {
                throw ModelIntegrityError.missingArtifact(
                    artifact.relativePath
                )
            }
            let values = try artifactURL.resourceValues(forKeys: [
                .fileSizeKey,
                .isRegularFileKey,
            ])
            guard values.isRegularFile == true else {
                throw ModelIntegrityError.missingArtifact(
                    artifact.relativePath
                )
            }
            let actualByteCount = Int64(values.fileSize ?? -1)
            guard actualByteCount == artifact.expectedByteCount else {
                throw ModelIntegrityError.byteCountMismatch(
                    path: artifact.relativePath,
                    expected: artifact.expectedByteCount,
                    actual: actualByteCount
                )
            }
            let actualDigest = try sha256(of: artifactURL)
            guard actualDigest == artifact.sha256 else {
                throw ModelIntegrityError.checksumMismatch(
                    path: artifact.relativePath,
                    expected: artifact.sha256,
                    actual: actualDigest
                )
            }
        }
    }

    private func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer {
            try? handle.close()
        }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: readChunkSize) ?? Data()
            guard !data.isEmpty else {
                break
            }
            hasher.update(data: data)
        }
        return hasher.finalize().map {
            String(format: "%02x", $0)
        }.joined()
    }
}
