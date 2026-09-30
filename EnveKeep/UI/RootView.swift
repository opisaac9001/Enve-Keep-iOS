import SwiftUI

struct RootView: View {
    @Environment(KeepStore.self) private var store
    @Environment(Router.self) private var router
    @Environment(\.reminders) private var reminders
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var router = router
        TabView(selection: $router.tab) {
            NavigationStack(path: $router.homePath) {
                DashboardView().routeDestinations()
            }
            .tabItem { Label("Home", systemImage: "house") }
            .tag(AppTab.home)

            NavigationStack(path: $router.warrantiesPath) {
                ProductListView().routeDestinations()
            }
            .tabItem { Label("Warranties", systemImage: RecordKind.warranty.symbol) }
            .tag(AppTab.warranties)

            NavigationStack(path: $router.subscriptionsPath) {
                SubscriptionListView().routeDestinations()
            }
            .tabItem { Label("Subscriptions", systemImage: RecordKind.subscription.symbol) }
            .tag(AppTab.subscriptions)

            NavigationStack(path: $router.documentsPath) {
                DocumentListView().routeDestinations()
            }
            .tabItem { Label("Documents", systemImage: RecordKind.document.symbol) }
            .tag(AppTab.documents)

            NavigationStack(path: $router.receiptsPath) {
                ReceiptListView().routeDestinations()
            }
            .tabItem { Label("Receipts", systemImage: Receipt.symbol) }
            .tag(AppTab.receipts)
        }
        .preferredColorScheme(store.settings.themeMode.colorScheme)
        .task(id: store.data) {
            await reminders?.reschedule(store.data)
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            store.refreshToday()
            Task { await reminders?.reschedule(store.data) }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
            store.refreshToday()
        }
    }
}

private extension View {
    func routeDestinations() -> some View {
        navigationDestination(for: Route.self) { route in
            switch route {
            case .product(let id): ProductDetailView(productId: id)
            case .subscription(let id): SubscriptionDetailView(subscriptionId: id)
            case .document(let id): DocumentDetailView(documentId: id)
            case .receipt(let id): ReceiptDetailView(receiptId: id)
            case .settings: SettingsView()
            }
        }
    }
}
