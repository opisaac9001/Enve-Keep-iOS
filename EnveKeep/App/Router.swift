import SwiftUI

enum AppTab: Hashable {
    case home, warranties, subscriptions, documents
}

enum Route: Hashable {
    case product(Int64)
    case subscription(Int64)
    case document(Int64)
    case settings

    init(_ kind: RecordKind, id: Int64) {
        self = switch kind {
        case .warranty: .product(id)
        case .subscription: .subscription(id)
        case .document: .document(id)
        }
    }
}

@MainActor
@Observable
final class Router {
    var tab = AppTab.home
    var homePath: [Route] = []
    var warrantiesPath: [Route] = []
    var subscriptionsPath: [Route] = []
    var documentsPath: [Route] = []

    /// Opens a record from outside the app, such as a tapped reminder.
    func open(_ kind: RecordKind, id: Int64) {
        let route = Route(kind, id: id)
        switch kind {
        case .warranty:
            tab = .warranties
            warrantiesPath = [route]
        case .subscription:
            tab = .subscriptions
            subscriptionsPath = [route]
        case .document:
            tab = .documents
            documentsPath = [route]
        }
    }
}
