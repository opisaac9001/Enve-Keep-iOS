import SwiftUI

extension ReceiptSort {
    var label: LocalizedStringKey {
        switch self {
        case .newest: "Newest first"
        case .oldest: "Oldest first"
        case .highestTotal: "Highest total"
        case .merchant: "Merchant"
        }
    }
}

extension ReceiptGrouping {
    var label: LocalizedStringKey {
        switch self {
        case .month: "Month"
        case .category: "Category"
        case .merchant: "Merchant"
        case .none: "None"
        }
    }
}

struct ReceiptListView: View {
    @Environment(KeepStore.self) private var store
    @Environment(Router.self) private var router
    @State private var query = ""
    @State private var sort = ReceiptSort.newest
    @State private var grouping = ReceiptGrouping.month
    @State private var category: String?
    @State private var tag: String?
    @State private var captureSource: CaptureSource?
    @State private var editor: ReceiptEditorRequest?
    @State private var pendingDelete: Receipt?
    @State private var errorMessage: String?

    var body: some View {
        let receipts = store.data.receipts
        let filtered = receipts.filter { receipt in
            receipt.matches(query)
                && category.map { receipt.category == $0 } ?? true
                && tag.map { receipt.tags.contains($0) } ?? true
        }
        let groups = ReceiptOrganizer.groups(filtered, sort: sort, grouping: grouping)

        List {
            if category != nil || tag != nil {
                activeFilters
            }
            ForEach(groups) { group in
                Section {
                    ForEach(group.receipts) { receipt in
                        NavigationLink(value: Route.receipt(receipt.id)) {
                            ReceiptRow(receipt: receipt)
                        }
                        .swipeActions {
                            Button("Delete", systemImage: "trash") { pendingDelete = receipt }
                                .tint(Color.keepPast)
                        }
                    }
                } header: {
                    if grouping != .none {
                        GroupHeader(title: groupTitle(group), totals: group.totals)
                    }
                }
            }
        }
        .keepListStyle()
        .overlay {
            if receipts.isEmpty {
                ContentUnavailableView {
                    Label("No receipts yet", systemImage: Receipt.symbol)
                } description: {
                    Text("Scan paper receipts or import photos. Merchant, date, items and totals are read on this iPhone for you to check and edit.")
                } actions: {
                    AddPagesMenu(source: $captureSource) {
                        Text("Add receipt")
                    }
                    .buttonStyle(.borderedProminent)
                    .foregroundStyle(Color.keepOnAccent)
                    Button("Enter manually") { editor = ReceiptEditorRequest() }
                }
            } else if filtered.isEmpty {
                ContentUnavailableView("No matches", systemImage: "magnifyingglass", description: Text("Try a different search or filter."))
            }
        }
        .navigationTitle("Receipts")
        .searchable(text: $query, prompt: "Search receipts and scanned text")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if !receipts.isEmpty { organizeMenu(receipts) }
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    if DocumentScanner.isSupported {
                        Button("Scan receipt", systemImage: "doc.viewfinder") { captureSource = .scanner }
                    }
                    Button("Photo Library", systemImage: "photo.on.rectangle") { captureSource = .photos }
                    Button("Choose Files", systemImage: "folder") { captureSource = .files }
                    Button("Enter manually", systemImage: "square.and.pencil") { editor = ReceiptEditorRequest() }
                } label: {
                    Label("Add receipt", systemImage: "plus")
                }
            }
        }
        .receiptCapture($captureSource, errorMessage: $errorMessage) { capture in
            editor = ReceiptEditorRequest(capture: capture)
        }
        .sheet(item: $editor) { request in
            ReceiptEditView(request: request) { router.receiptsPath.append(.receipt($0)) }
        }
        .confirmationDialog(
            "Delete \(pendingDelete?.merchant ?? "")?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { receipt in
            Button("Delete", role: .destructive) { delete(receipt) }
        } message: { _ in
            Text("The receipt and its scans will be removed from this device.")
        }
        .errorAlert($errorMessage)
    }

    private var activeFilters: some View {
        HStack {
            Image(systemName: "line.3.horizontal.decrease.circle.fill")
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            Text([category, tag.map { "#\($0)" }].compactMap { $0 }.joined(separator: " · "))
                .lineLimit(1)
            Spacer()
            Button("Clear") {
                category = nil
                tag = nil
            }
            .buttonStyle(.borderless)
        }
        .font(.subheadline)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(localized: "Filtered by \([category, tag].compactMap { $0 }.joined(separator: ", "))"))
    }

    private func organizeMenu(_ receipts: [Receipt]) -> some View {
        let categories = ReceiptOrganizer.categories(receipts)
        let tags = ReceiptOrganizer.tags(receipts)
        return Menu {
            Picker(selection: $sort) {
                ForEach(ReceiptSort.allCases, id: \.self) { Text($0.label).tag($0) }
            } label: {
                Label("Sort by", systemImage: "arrow.up.arrow.down")
            }
            .pickerStyle(.menu)
            Picker(selection: $grouping) {
                ForEach(ReceiptGrouping.allCases, id: \.self) { Text($0.label).tag($0) }
            } label: {
                Label("Group by", systemImage: "square.stack")
            }
            .pickerStyle(.menu)
            if !categories.isEmpty {
                Picker(selection: $category) {
                    Text("All categories").tag(String?.none)
                    ForEach(categories, id: \.self) { Text($0).tag(Optional($0)) }
                } label: {
                    Label("Category", systemImage: "folder")
                }
                .pickerStyle(.menu)
            }
            if !tags.isEmpty {
                Picker(selection: $tag) {
                    Text("All tags").tag(String?.none)
                    ForEach(tags, id: \.self) { Text($0).tag(Optional($0)) }
                } label: {
                    Label("Tag", systemImage: "tag")
                }
                .pickerStyle(.menu)
            }
        } label: {
            Label(
                "Sort and filter",
                systemImage: category == nil && tag == nil
                    ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill"
            )
        }
    }

    private func groupTitle(_ group: ReceiptGroup) -> String {
        if !group.title.isEmpty { return group.title }
        return grouping == .category ? String(localized: "No category") : String(localized: "Other")
    }

    private func delete(_ receipt: Receipt) {
        do {
            try store.deleteReceipt(receipt.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct GroupHeader: View {
    let title: String
    let totals: [(currency: String, amount: Decimal)]

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
            Spacer()
            Text(totals.map { Money.format($0.amount, currency: $0.currency) }.joined(separator: " + "))
                .monospacedDigit()
        }
    }
}

struct ReceiptRow: View {
    let receipt: Receipt
    @Environment(KeepStore.self) private var store

    var body: some View {
        HStack(spacing: 12) {
            if let page = store.attachments(.receipt, receipt.id).first {
                AttachmentThumbnail(attachment: page, size: 44)
            } else {
                Image(systemName: Receipt.symbol)
                    .foregroundStyle(Color.keepOnPrimaryContainer)
                    .frame(width: 44, height: 44)
                    .background(Color.keepPrimaryContainer, in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(receipt.merchant).font(.body.weight(.medium))
                let subtitle = [
                    receipt.purchaseDate.map(Formats.date) ?? String(localized: "No date"),
                    receipt.category.isEmpty ? nil : receipt.category,
                ].compactMap { $0 }.joined(separator: " · ")
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                if !receipt.tags.isEmpty {
                    Text(receipt.tags.map { "#\($0)" }.joined(separator: " "))
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let total = receipt.total {
                Text(Money.format(total, currency: receipt.currency))
                    .font(.body.weight(.semibold))
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
