import Foundation
import Observation

struct KeepData: Codable, Hashable, Sendable {
    var products: [Product] = []
    var subscriptions: [Subscription] = []
    var documents: [Document] = []
    var attachments: [Attachment] = []
    var settings = Settings()
}

/// All records live in one JSON file written atomically; attachment files sit beside it.
@MainActor
@Observable
final class KeepStore {
    private(set) var data: KeepData
    private(set) var today = Day.today()

    let root: URL
    let attachmentStore: AttachmentStore
    @ObservationIgnored private let fileURL: URL

    static func appDefault() -> KeepStore {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return KeepStore(root: support.appending(path: "EnveKeep", directoryHint: .isDirectory))
    }

    init(root: URL) {
        self.root = root
        fileURL = root.appending(path: "keep.json")
        attachmentStore = AttachmentStore(directory: root.appending(path: "attachments", directoryHint: .isDirectory))
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var excluded = root
        try? excluded.setResourceValues(values)

        data = KeepData()
        if let bytes = try? Data(contentsOf: fileURL) {
            do {
                data = try JSONDecoder().decode(KeepData.self, from: bytes)
            } catch {
                // Keep the unreadable file for recovery instead of overwriting it on the next save.
                let aside = root.appending(path: "keep-unreadable-\(Int(Date().timeIntervalSince1970)).json")
                try? fileManager.moveItem(at: fileURL, to: aside)
            }
        }
        BackupService.recoverInterruptedImport(root: root, referenced: Set(data.attachments.map(\.fileName)))
        try? fileManager.createDirectory(at: attachmentStore.directory, withIntermediateDirectories: true)
    }

    func refreshToday() {
        let now = Day.today()
        if now != today { today = now }
    }

    var settings: Settings { data.settings }

    func product(_ id: Int64) -> Product? { data.products.first { $0.id == id } }
    func subscription(_ id: Int64) -> Subscription? { data.subscriptions.first { $0.id == id } }
    func document(_ id: Int64) -> Document? { data.documents.first { $0.id == id } }

    func attachments(_ ownerType: OwnerType, _ ownerId: Int64) -> [Attachment] {
        data.attachments.filter { $0.ownerType == ownerType && $0.ownerId == ownerId }
    }

    @discardableResult
    func saveProduct(_ product: Product, added: [Attachment], removed: [Attachment]) throws -> Int64 {
        try saveOwned(.product, added: added, removed: removed) { data in
            upsert(product, into: &data.products)
        }
    }

    @discardableResult
    func saveDocument(_ document: Document, added: [Attachment], removed: [Attachment]) throws -> Int64 {
        try saveOwned(.document, added: added, removed: removed) { data in
            upsert(document, into: &data.documents)
        }
    }

    @discardableResult
    func saveSubscription(_ subscription: Subscription) throws -> Int64 {
        try mutate { upsert(subscription, into: &$0.subscriptions) }
    }

    func updateSubscription(_ id: Int64, _ transform: (Subscription) -> Subscription) throws {
        try mutate { data in
            guard let index = data.subscriptions.firstIndex(where: { $0.id == id }) else { return }
            data.subscriptions[index] = transform(data.subscriptions[index])
        }
    }

    func deleteProduct(_ id: Int64) throws {
        try deleteOwned(.product, id) { $0.products.removeAll { $0.id == id } }
    }

    func deleteDocument(_ id: Int64) throws {
        try deleteOwned(.document, id) { $0.documents.removeAll { $0.id == id } }
    }

    func deleteSubscription(_ id: Int64) throws {
        try mutate { $0.subscriptions.removeAll { $0.id == id } }
    }

    func updateSettings(_ transform: (inout Settings) -> Void) throws {
        try mutate { transform(&$0.settings) }
    }

    /// Swaps in imported records; the caller has already put the matching attachment files in place.
    func replaceAll(with imported: KeepData) throws {
        try mutate { $0 = imported }
    }

    func deleteOrphanedAttachments() {
        attachmentStore.deleteOrphans(referenced: Set(data.attachments.map(\.fileName)))
    }

    // MARK: - Private

    private func mutate<T>(_ body: (inout KeepData) throws -> T) throws -> T {
        var next = data
        let result = try body(&next)
        guard next != data else { return result }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        try encoder.encode(next).write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        data = next
        return result
    }

    private func saveOwned(
        _ ownerType: OwnerType,
        added: [Attachment],
        removed: [Attachment],
        upsert: (inout KeepData) -> Int64
    ) throws -> Int64 {
        let removedIds = Set(removed.map(\.id))
        let id = try mutate { data in
            let id = upsert(&data)
            var attachmentId = nextId(data.attachments)
            for attachment in added {
                var owned = attachment
                owned.id = attachmentId
                owned.ownerType = ownerType
                owned.ownerId = id
                data.attachments.append(owned)
                attachmentId += 1
            }
            data.attachments.removeAll { removedIds.contains($0.id) }
            return id
        }
        attachmentStore.delete(removed.map(\.fileName))
        return id
    }

    private func deleteOwned(_ ownerType: OwnerType, _ id: Int64, delete: (inout KeepData) -> Void) throws {
        let files = attachments(ownerType, id).map(\.fileName)
        try mutate { data in
            data.attachments.removeAll { $0.ownerType == ownerType && $0.ownerId == id }
            delete(&data)
        }
        attachmentStore.delete(files)
    }
}

private protocol Record: Identifiable where ID == Int64 {
    var id: Int64 { get set }
}

extension Product: Record {}
extension Subscription: Record {}
extension Document: Record {}

private func nextId<T: Identifiable>(_ items: [T]) -> Int64 where T.ID == Int64 {
    (items.map(\.id).max() ?? 0) + 1
}

private func upsert<T: Record>(_ record: T, into items: inout [T]) -> Int64 {
    if record.id != 0, let index = items.firstIndex(where: { $0.id == record.id }) {
        items[index] = record
        return record.id
    }
    var inserted = record
    inserted.id = nextId(items)
    items.append(inserted)
    return inserted.id
}
