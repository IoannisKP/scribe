import AudioCapture
import Foundation
import UniformTypeIdentifiers

public struct ImportedSessionResult: Equatable, Sendable {
    public let directory: URL
    public let manifest: CaptureSessionManifest
    public let originalURL: URL
    public let canonicalAudioURL: URL
    public let canonicalSampleCount: UInt64
}

public enum SessionMediaImportProgress: Equatable, Sendable {
    case copying(filename: String)
    case converting(filename: String)
}

public enum SessionMediaImportError:
    Error,
    Equatable,
    LocalizedError,
    Sendable
{
    case notAFile(filename: String)
    case copyFailed(filename: String, detail: String)

    public var errorDescription: String? {
        switch self {
        case let .notAFile(filename):
            "“\(filename)” isn't an audio or video file. Choose a single file to import."
        case let .copyFailed(filename, _):
            "Scribe couldn't copy “\(filename)”. The original file is untouched."
        }
    }
}

public actor SessionMediaImporter {
    private let fileManager: FileManager
    private let folderManager: SessionFolderManager
    private let converter: ImportedMediaConverter

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.folderManager = SessionFolderManager(fileManager: fileManager)
        self.converter = ImportedMediaConverter()
    }

    public func importFile(
        at sourceURL: URL,
        into library: URL,
        date: Date = Date(),
        progress: @escaping @Sendable (SessionMediaImportProgress) -> Void = {
            _ in
        }
    ) async throws -> ImportedSessionResult {
        let values = try? sourceURL.resourceValues(forKeys: [
            .isRegularFileKey,
            .contentTypeKey
        ])
        guard values?.isRegularFile == true else {
            throw SessionMediaImportError.notAFile(
                filename: sourceURL.lastPathComponent
            )
        }

        let filename = sourceURL.lastPathComponent
        let title = sourceURL.deletingPathExtension().lastPathComponent
        let pathExtension = sourceURL.pathExtension.lowercased()
        let originalFormat = pathExtension.isEmpty
            ? values?.contentType?.identifier ?? "unknown"
            : pathExtension
        // `audio.wav` is reserved for the canonical derivative. Keeping a
        // same-named original byte-for-byte requires a containing directory.
        let originalRelativePath = filename.caseInsensitiveCompare("audio.wav")
            == .orderedSame
            ? "Original/\(filename)"
            : filename
        let created = try folderManager.createImportedSession(
            in: library,
            title: title,
            originalFilename: filename,
            originalFormat: originalFormat,
            originalRelativePath: originalRelativePath,
            date: date
        )

        do {
            let originalURL = created.directory.appendingPathComponent(
                originalRelativePath,
                isDirectory: false
            )
            try fileManager.createDirectory(
                at: originalURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            do {
                progress(.copying(filename: filename))
                try fileManager.copyItem(at: sourceURL, to: originalURL)
            } catch {
                throw SessionMediaImportError.copyFailed(
                    filename: filename,
                    detail: error.localizedDescription
                )
            }

            let canonicalURL = created.directory.appendingPathComponent(
                "audio.wav",
                isDirectory: false
            )
            progress(.converting(filename: filename))
            let conversion = try await converter.convert(
                sourceURL: originalURL,
                outputURL: canonicalURL
            )
            return ImportedSessionResult(
                directory: created.directory,
                manifest: created.manifest,
                originalURL: originalURL,
                canonicalAudioURL: canonicalURL,
                canonicalSampleCount: conversion.sampleCount
            )
        } catch {
            try? fileManager.removeItem(at: created.directory)
            throw error
        }
    }
}
