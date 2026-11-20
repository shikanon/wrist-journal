import SwiftUI

@MainActor
final class PhoneJournal: ObservableObject {
    @Published private(set) var recordings: [Recording] = []
    @Published private(set) var report: HealthReport?
    @Published var message: String?

    let store = JournalStore()

    private lazy var transfer = CompanionTransfer(store: store) { [weak self] event in
        Task { @MainActor [weak self] in
            switch event {
            case .updated: self?.reload()
            case .message(let message): self?.message = message
            }
        }
    }

    init() {
        reload()
        transfer.activate()
    }

    private func reload() {
        do {
            recordings = try store.list()
            report = try store.report()
        } catch {
            message = error.localizedDescription
        }
    }

    func delete(_ entry: Recording) -> Bool {
        do {
            try store.delete(entry.id)
            reload()
            return true
        } catch {
            message = error.localizedDescription
            return false
        }
    }

    func deleteReport() {
        do {
            try store.deleteReport()
            report = nil
        } catch {
            message = error.localizedDescription
        }
    }
}
