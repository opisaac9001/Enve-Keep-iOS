import QuickLook
import SwiftUI

struct ReceiptDetailView: View {
    let receiptId: Int64
    @Environment(KeepStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var editor: ReceiptEditorRequest?
    @State private var confirmDelete = false
    @State private var errorMessage: String?
    @State private var preview: URL?
    @State private var previewPages: [URL] = []
    @State private var sharedPages: SharedPages?

    var body: some View {
        if let receipt = store.receipt(receiptId) {
            content(receipt)
        } else {
            ContentUnavailableView("Receipt not found", systemImage: Receipt.symbol)
        }
    }

    private func content(_ receipt: Receipt) -> some View {
        let pages = store.attachments(.receipt, receiptId)
        return List {
            Section {
                ReceiptHeader(receipt: receipt)
            }
            if !pages.isEmpty {
                Section("Scans") {
                    ScrollView(.horizontal) {
                        HStack(spacing: 12) {
                            ForEach(Array(pages.enumerated()), id: \.element.id) { index, page in
                                Button {
                                    open(pages, at: index)
                                } label: {
                                    ReceiptPageThumbnail(page: page, width: 110, height: 150)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(String(localized: "Page \(index + 1) of \(pages.count)"))
                                .accessibilityHint("Opens a preview")
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .scrollIndicators(.hidden)
                }
            }
            Section("Items") {
                if receipt.items.isEmpty {
                    Text("No items").foregroundStyle(.secondary)
                }
                ForEach(Array(receipt.items.enumerated()), id: \.offset) { _, item in
                    ItemRow(item: item, currency: receipt.currency)
                }
            }
            if receipt.subtotal != nil || receipt.tax != nil || receipt.tip != nil || receipt.total != nil {
                Section("Totals") {
                    amountRow("Subtotal", receipt.subtotal, receipt.currency)
                    amountRow("Tax", receipt.tax, receipt.currency)
                    amountRow("Tip", receipt.tip, receipt.currency)
                    amountRow("Total", receipt.total, receipt.currency)
                }
            }
            if !receipt.notes.isEmpty {
                Section("Notes") {
                    Text(receipt.notes).textSelection(.enabled)
                }
            }
            let texts = pages.enumerated().compactMap { index, page in
                receipt.recognizedText[page.fileName].map { (page: index + 1, text: $0) }
            }
            if !texts.isEmpty {
                Section {
                    DisclosureGroup("Recognized text") {
                        ForEach(texts, id: \.page) { entry in
                            VStack(alignment: .leading, spacing: 4) {
                                if texts.count > 1 {
                                    Text("Page \(entry.page)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                }
                                Text(entry.text.isEmpty ? String(localized: "No text found") : entry.text)
                                    .font(.footnote.monospaced())
                                    .textSelection(.enabled)
                            }
                        }
                    }
                } footer: {
                    Text("Read on this iPhone when the page was added. It may contain mistakes.")
                }
            }
            Section {
                Button("Delete receipt", role: .destructive) { confirmDelete = true }
            }
        }
        .keepListStyle()
        .quickLookPreview($preview, in: previewPages)
        .sheet(item: $sharedPages) { shared in
            ActivityView(items: shared.urls)
                .presentationDetents([.medium, .large])
        }
        .navigationTitle(receipt.merchant)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Menu {
                ShareLink(item: shareText(receipt), subject: Text("Receipt: \(receipt.merchant)")) {
                    Label("Share details", systemImage: "text.alignleft")
                }
                if !pages.isEmpty {
                    Button("Share scans", systemImage: "doc.on.doc") { share(pages) }
                }
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            Button("Edit") { editor = ReceiptEditorRequest(receiptId: receiptId) }
        }
        .sheet(item: $editor) { request in
            ReceiptEditView(request: request) { _ in }
        }
        .confirmationDialog("Delete \(receipt.merchant)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                do {
                    try store.deleteReceipt(receiptId)
                    dismiss()
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        } message: {
            Text("The receipt and its scans will be removed from this device.")
        }
        .errorAlert($errorMessage)
    }

    @ViewBuilder
    private func amountRow(_ label: LocalizedStringKey, _ amount: Decimal?, _ currency: String) -> some View {
        if let amount {
            LabeledContent(label) {
                Text(Money.format(amount, currency: currency))
                    .monospacedDigit()
                    .textSelection(.enabled)
            }
        }
    }

    private func open(_ pages: [Attachment], at index: Int) {
        do {
            previewPages = try pages.map(store.attachmentStore.shareableURL)
            preview = previewPages[index]
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func share(_ pages: [Attachment]) {
        do {
            sharedPages = SharedPages(urls: try pages.map(store.attachmentStore.shareableURL))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func shareText(_ receipt: Receipt) -> String {
        let money = { Money.format($0, currency: receipt.currency) }
        let items = receipt.items.map { item in
            let quantity = item.quantity.map { "\(Money.formatForInput($0)) × " } ?? ""
            let amount = item.amount.map { "  \(money($0))" } ?? ""
            return "\(quantity)\(item.description)\(amount)"
        }
        return ([
            receipt.merchant,
            receipt.purchaseDate.map { String(localized: "Date: \(Formats.date($0))") },
            receipt.category.isEmpty ? nil : String(localized: "Category: \(receipt.category)"),
        ] + items.map(Optional.some) + [
            receipt.subtotal.map { String(localized: "Subtotal: \(money($0))") },
            receipt.tax.map { String(localized: "Tax: \(money($0))") },
            receipt.tip.map { String(localized: "Tip: \(money($0))") },
            receipt.total.map { String(localized: "Total: \(money($0))") },
            receipt.tags.isEmpty ? nil : String(localized: "Tags: \(receipt.tags.joined(separator: ", "))"),
            receipt.notes.isEmpty ? nil : receipt.notes,
        ])
        .compactMap { $0 }
        .joined(separator: "\n")
    }
}

private struct SharedPages: Identifiable {
    let id = UUID()
    let urls: [URL]
}

private struct ReceiptHeader: View {
    let receipt: Receipt

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if !receipt.category.isEmpty {
                    StatusBadge(text: receipt.category, status: .ok)
                }
                Spacer()
                Text(receipt.purchaseDate.map(Formats.date) ?? String(localized: "No purchase date"))
                    .foregroundStyle(.secondary)
            }
            Text(receipt.total.map { Money.format($0, currency: receipt.currency) } ?? String(localized: "No total"))
                .font(.largeTitle.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(receipt.total == nil ? .secondary : .primary)
            if !receipt.tags.isEmpty {
                Text(receipt.tags.map { "#\($0)" }.joined(separator: " "))
                    .font(.subheadline)
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

private struct ItemRow: View {
    let item: ReceiptItem
    let currency: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.description.isEmpty ? String(localized: "Unnamed item") : item.description)
                    .foregroundStyle(item.description.isEmpty ? .secondary : .primary)
                if let quantity = item.quantity {
                    Text("Quantity \(Money.formatForInput(quantity))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let amount = item.amount {
                Text(Money.format(amount, currency: currency))
                    .monospacedDigit()
                    .foregroundStyle(amount < 0 ? Color.accentColor : .primary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
