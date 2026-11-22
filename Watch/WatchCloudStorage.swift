import Foundation

@MainActor
final class WatchCloudStorage {
    private let cloud = CloudBackup()
    private var task: Task<Void, Never>?
    private var generation = UUID()
    var uploading: Bool { task != nil }

    func pause() {
        task?.cancel()
        // Retain the task until CloudKit acknowledges cancellation; no overlapping upload.
    }
    func waitForCompletion() async { await task?.value }

    func run(store: JournalStore, finished: @escaping @MainActor (String?, Date?) -> Void) {
        guard task == nil else { return }
        let token = UUID()
        generation = token
        task = Task {
            defer { if generation == token { task = nil } }
            var state = StorageWorkState.load(store)
            guard state.cloudRetry.allows(configuration: "cloud") else {
                finished("云端上传等待重试", state.cloudRetry.nextAttempt)
                return
            }
            do {
                try store.recoverEvictions()
                for entry in try store.pendingRecordings() where entry.storage == .cloud && entry.isPlayable {
                    try Task.checkCancellation()
                    try await cloud.save(recording: entry, audio: store.audio(entry.id), wifiOnly: true)
                    try Task.checkCancellation()
                    try store.evictLocal(entry.id, cloudConfirmedAt: .now)
                    // Reload because device-transfer callbacks may have updated the shared state.
                    state = StorageWorkState.load(store)
                    state.cloudRetry = RetryState()
                    try state.save(store)
                }
                finished(nil, nil)
            } catch is CancellationError {
                finished(nil, nil)
            } catch {
                if !Task.isCancelled {
                    state = StorageWorkState.load(store)
                    state.cloudRetry.fail(configuration: "cloud", authentication: false)
                    try? state.save(store)
                    finished("原音已保留：\(error.localizedDescription)", state.cloudRetry.nextAttempt)
                }
            }
        }
    }
}
