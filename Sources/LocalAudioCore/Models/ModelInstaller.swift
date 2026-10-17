import Foundation

struct ModelInstallProgress: Sendable {
    let text: String
    let fraction: Double?
}

actor ModelInstaller {
    typealias Validator = @Sendable (URL) async throws -> Void
    typealias Reporter = @Sendable (ModelInstallProgress) -> Void
    typealias Capacity = @Sendable (URL) throws -> Int64

    let storage: URL
    let manifest: ModelManifest
    let downloader: any ModelDownloading
    let validator: Validator
    let capacity: Capacity
    private let fileManager = FileManager.default
    private let reserveBytes: Int64 = 128 * 1_024 * 1_024
    private var selectionURL: URL { storage.appendingPathComponent("model-selection.json") }

    init(storage: URL, manifest: ModelManifest, downloader: any ModelDownloading,
         validator: @escaping Validator, capacity: @escaping Capacity = ModelInstaller.availableCapacity) {
        self.storage = storage.standardizedFileURL.resolvingSymlinksInPath()
        self.manifest = manifest
        self.downloader = downloader
        self.validator = validator
        self.capacity = capacity
    }

    static func availableCapacity(_ url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let bytes = values.volumeAvailableCapacityForImportantUsage else {
            throw ModelSetupError.message("Could not check free disk space. Choose a writable local model storage folder.")
        }
        return bytes
    }

    func install(report: @escaping Reporter) async throws -> URL {
        try manifest.validate()
        try ensureDirectory(storage)
        let staging = storage.appendingPathComponent("staging-" + manifest.revision, isDirectory: true)
        try ensureDirectory(staging)
        let owner = staging.appendingPathComponent(".localaudio-staging")
        try rejectSymlink(owner)
        let existing = try fileManager.contentsOfDirectory(atPath: staging.path)
        if !existing.isEmpty {
            guard (try? String(contentsOf: owner, encoding: .utf8)) == manifest.revision else {
                throw ModelSetupError.message("The model staging folder is not owned by this installer. Choose another storage folder.")
            }
        } else {
            try manifest.revision.write(to: owner, atomically: true, encoding: .utf8)
        }

        var verifiedBytes: Int64 = 0
        var needed: [ModelManifestFile] = []
        report(.init(text: "Checking saved download files…", fraction: 0))
        for file in manifest.files {
            try Task.checkCancellation()
            let destination = try safeAsset(file.path, beneath: staging)
            if fileManager.fileExists(atPath: destination.path), (try? ModelFileIntegrity.verify(destination, expected: file)) != nil {
                verifiedBytes += file.size
            } else {
                needed.append(file)
            }
        }
        let remaining = needed.reduce(Int64(0)) { $0 + $1.size }
        let largest = needed.map(\.size).max() ?? 0
        guard try capacity(storage) >= remaining + largest + reserveBytes,
              try capacity(fileManager.temporaryDirectory) >= largest + reserveBytes else {
            throw ModelSetupError.message("Not enough disk space for model setup. Free at least \(ByteCountFormatter.string(fromByteCount: remaining + largest + reserveBytes, countStyle: .file)) and retry. Verified files will be reused.")
        }

        for file in needed {
            try Task.checkCancellation()
            let destination = try safeAsset(file.path, beneath: staging)
            try ensureDirectory(destination.deletingLastPathComponent())
            let partial = destination.deletingLastPathComponent().appendingPathComponent(".download-" + UUID().uuidString)
            defer { try? fileManager.removeItem(at: partial) }
            let alreadyVerified = verifiedBytes
            var lastError: Error?
            for attempt in 1...3 {
                try Task.checkCancellation()
                do {
                    try await downloader.download(file, to: partial) { bytes in
                        report(.init(text: "Downloading \(file.path) (\(attempt)/3)…",
                            fraction: Double(alreadyVerified + min(file.size, max(0, bytes))) / Double(self.manifest.totalBytes)))
                    }
                    lastError = nil
                    break
                } catch {
                    if Task.isCancelled { throw CancellationError() }
                    lastError = error
                    try? fileManager.removeItem(at: partial)
                    if attempt < 3 {
                        report(.init(text: "Download interrupted. Retrying \(file.path)…", fraction: Double(verifiedBytes) / Double(manifest.totalBytes)))
                        try await Task.sleep(for: .seconds(attempt))
                    }
                }
            }
            if let lastError { throw lastError }
            try Task.checkCancellation()
            report(.init(text: "Verifying \(file.path)…", fraction: Double(verifiedBytes) / Double(manifest.totalBytes)))
            try ModelFileIntegrity.verify(partial, expected: file)
            if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
            try fileManager.moveItem(at: partial, to: destination)
            verifiedBytes += file.size
        }
        // Verify the whole staged pack again before running the offline loader.
        report(.init(text: "Checking the complete model and loading it locally…", fraction: 1))
        try verifyPack(staging)
        try validateStructure(staging)
        try await validator(staging)
        try Task.checkCancellation()
        let installs = storage.appendingPathComponent("installed", isDirectory: true)
        try ensureDirectory(installs)
        let activated = installs.appendingPathComponent(manifest.id + "-" + manifest.revision + "-" + UUID().uuidString, isDirectory: true)
        try fileManager.moveItem(at: staging, to: activated)
        do {
            try persist(Selection(path: activated.path, managedRevision: manifest.revision, modelPackID: manifest.id))
        } catch {
            // Previous selection is still authoritative. Retain the completed
            // pack for diagnosis rather than deleting any existing install.
            throw error
        }
        return activated
    }

    func useLocalFolder(_ directory: URL) async throws -> URL {
        let resolved = directory.standardizedFileURL.resolvingSymlinksInPath()
        try validateStructure(resolved)
        try await validator(resolved)
        try Task.checkCancellation()
        try ensureDirectory(storage)
        try persist(Selection(path: resolved.path, managedRevision: nil, modelPackID: manifest.id))
        return resolved
    }

    func restore(report: @escaping Reporter) async throws -> URL {
        guard fileManager.fileExists(atPath: selectionURL.path) else { throw ModelSetupError.notSelected(manifest.pack) }
        try rejectSymlink(selectionURL)
        let selection = try JSONDecoder().decode(Selection.self, from: Data(contentsOf: selectionURL))
        guard selection.modelPackID == nil || selection.modelPackID == manifest.id else {
            throw ModelSetupError.message("This saved model selection belongs to another model pack. Select the correct optional model folder in Settings.")
        }
        let directory = URL(fileURLWithPath: selection.path, isDirectory: true).standardizedFileURL
        report(.init(text: "Checking the selected local model…", fraction: nil))
        if let revision = selection.managedRevision {
            guard revision == manifest.revision else {
                throw ModelSetupError.message("The saved model uses an unsupported version. Choose a compatible local folder or install this app's model.")
            }
            try verifyPack(directory)
        }
        try validateStructure(directory)
        try await validator(directory)
        try Task.checkCancellation()
        return directory
    }

    private struct Selection: Codable { let path: String; let managedRevision: String?; let modelPackID: String? }

    private func persist(_ selection: Selection) throws {
        try rejectSymlink(selectionURL)
        try JSONEncoder().encode(selection).write(to: selectionURL, options: .atomic)
    }

    private func verifyPack(_ directory: URL) throws {
        for file in manifest.files {
            try Task.checkCancellation()
            try ModelFileIntegrity.verify(safeAsset(file.path, beneath: directory), expected: file)
        }
    }

    private func validateStructure(_ directory: URL) throws {
        try Task.checkCancellation()
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue,
              fileManager.isReadableFile(atPath: directory.path) else {
            throw ModelSetupError.message("The selected model folder is missing or unreadable. Select the folder containing the four supported .mlmodelc bundles and \(manifest.pack.parameterFile).")
        }
        for bundle in manifest.requiredBundles {
            try Task.checkCancellation()
            let root = directory.appendingPathComponent(bundle, isDirectory: true)
            isDirectory = false
            guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw ModelSetupError.message("The selected folder is missing \(bundle). Choose the folder containing all four \(manifest.displayName) bundles.")
            }
            try requireFile(root.appendingPathComponent("coremldata.bin"))
            guard let items = fileManager.enumerator(at: root, includingPropertiesForKeys: nil) else {
                throw ModelSetupError.message("Cannot inspect \(bundle). Check folder permissions.")
            }
            for case let item as URL in items {
                try Task.checkCancellation()
                if item.pathExtension == "partial" {
                    throw ModelSetupError.message("The selected model contains an unfinished download: \(item.lastPathComponent).")
                }
            }
        }
        try requireFile(directory.appendingPathComponent(manifest.pack.parameterFile))
    }

    private func requireFile(_ url: URL) throws {
        let info = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard info.isRegularFile == true, (info.fileSize ?? 0) > 0, fileManager.isReadableFile(atPath: url.path) else {
            throw ModelSetupError.message("Missing or unreadable local model asset: \(url.lastPathComponent).")
        }
    }

    private func ensureDirectory(_ url: URL) throws {
        // Never repair blocking files or follow an injected model-store symlink.
        var current = storage
        try rejectSymlink(current)
        if url != storage {
            let rootParts = storage.pathComponents
            guard Array(url.pathComponents.prefix(rootParts.count)) == rootParts else {
                throw ModelSetupError.message("Refusing a model path outside app storage.")
            }
            for component in url.pathComponents.dropFirst(rootParts.count) {
                current.appendPathComponent(component, isDirectory: true)
                try rejectSymlink(current)
            }
        }
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private func safeAsset(_ path: String, beneath directory: URL) throws -> URL {
        let probe = ModelManifestFile(path: path, url: directory, size: 1, algorithm: .sha256, digest: "")
        try probe.validatePath()
        var current = directory
        try rejectSymlink(current)
        for component in path.split(separator: "/") {
            current.appendPathComponent(String(component))
            try rejectSymlink(current)
        }
        return current
    }

    private func rejectSymlink(_ url: URL) throws {
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw ModelSetupError.message("A model-store path is a symbolic link. Choose another storage folder: \(url.lastPathComponent)")
        }
    }
}
