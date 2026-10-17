import Foundation
import Combine

@MainActor
public final class ModelManager: ObservableObject {
    @Published public private(set) var statusText = "Download the English model or choose an existing local model folder."
    @Published public private(set) var progress: Double?
    @Published public private(set) var isBusy = false
    @Published public private(set) var modelDirectory: URL?
    @Published public private(set) var isReady = false

    private let installer: ModelInstaller?
    private var operationTask: Task<URL, Error>?
    private var operationID: UUID?
    private var completionWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]

    public init(storageDirectory: URL, validator: @escaping @Sendable (URL) async throws -> Void) {
        do {
            installer = ModelInstaller(storage: storageDirectory, manifest: try ModelManifest.bundled(),
                downloader: StreamingModelDownloader(), validator: validator)
        } catch {
            installer = nil
            statusText = error.localizedDescription
        }
    }

    init(installer: ModelInstaller) { self.installer = installer }

    /// Explicit user action. The only operation that can request network data.
    public func install() async {
        do { try await perform(.install) } catch { /* Published status describes failure. */ }
    }

    public func cancel() {
        guard isBusy else { return }
        statusText = "Cancelling model setup…"
        operationTask?.cancel()
    }

    /// Cancels setup and waits through the operation's cleanup, including the
    /// supplied validator. Waiting only for the child task could race perform's
    /// defer and return while isBusy still belongs to the cancelled operation.
    public func cancelAndWait() async {
        guard let id = operationID else { return }
        cancel()
        await withCheckedContinuation { continuation in
            guard operationID == id else { continuation.resume(); return }
            completionWaiters[id, default: []].append(continuation)
        }
    }

    /// Reads the selected folder and validates it offline; never repairs it.
    public func useLocalFolder(_ folder: URL) async throws { try await perform(.local(folder)) }

    /// Call once at launch, or to explicitly recheck the persisted selection.
    /// This performs local checks and the supplied offline validator only.
    public func refresh() async {
        do { try await perform(.refresh) } catch { /* Published status describes failure. */ }
    }

    private enum Operation { case install, local(URL), refresh }

    private func perform(_ operation: Operation) async throws {
        guard !isBusy else { throw ModelSetupError.message("Model setup is already running.") }
        guard let installer else { throw ModelSetupError.message(statusText) }
        let id = UUID()
        operationID = id
        isBusy = true
        progress = nil
        statusText = "Preparing model setup…"
        let report: ModelInstaller.Reporter = { [weak self] update in
            Task { @MainActor in
                guard let self, self.operationID == id, self.operationTask?.isCancelled != true else { return }
                self.statusText = update.text
                self.progress = update.fraction
            }
        }
        let task: Task<URL, Error>
        switch operation {
        case .install: task = Task { try await installer.install(report: report) }
        case .local(let folder): task = Task { try await installer.useLocalFolder(folder) }
        case .refresh: task = Task { try await installer.restore(report: report) }
        }
        operationTask = task
        defer {
            operationTask = nil
            operationID = nil
            isBusy = false
            progress = nil
            let waiters = completionWaiters.removeValue(forKey: id) ?? []
            for waiter in waiters { waiter.resume() }
        }
        do {
            let directory = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            modelDirectory = directory
            isReady = true
            switch operation {
            case .local: statusText = "Local model loaded and ready."
            default: statusText = "English model loaded and ready."
            }
        } catch {
            if case .refresh = operation { modelDirectory = nil; isReady = false }
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                statusText = "Model setup cancelled. Verified download files are kept for Retry."
            } else {
                statusText = error.localizedDescription
            }
            throw error
        }
    }
}
