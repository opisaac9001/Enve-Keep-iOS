import SwiftUI

struct ProductDetailView: View {
    let productId: Int64
    @Environment(KeepStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var editor: Editor?
    @State private var confirmDelete = false
    @State private var errorMessage: String?
    @State private var openedAttachment: OpenedAttachment?

    var body: some View {
        if let product = store.product(productId) {
            content(product)
        } else {
            ContentUnavailableView("Product not found", systemImage: RecordKind.warranty.symbol)
        }
    }

    private func content(_ product: Product) -> some View {
        let today = store.today
        let status = deadlineStatus(product.warrantyExpires, today: today, leadDays: store.settings.warrantyLeadDays)
        return List {
            Section {
                WarrantyHeader(product: product, status: status, today: today)
            }
            if !(product.brand + product.model + product.serialNumber).isEmpty {
                Section("Details") {
                    DetailField("Brand", product.brand)
                    DetailField("Model", product.model)
                    DetailField("Serial number", product.serialNumber, monospaced: true)
                }
            }
            if product.purchaseDate != nil || !product.retailer.isEmpty || product.price != nil {
                Section("Purchase") {
                    DetailField("Purchase date", product.purchaseDate.map(Formats.date) ?? "")
                    DetailField("Retailer", product.retailer)
                    DetailField("Price", product.price.map { Money.format($0, currency: product.currency) } ?? "")
                }
            }
            if !product.notes.isEmpty {
                Section("Notes") {
                    Text(product.notes).textSelection(.enabled)
                }
            }
            Section("Receipts and files") {
                AttachmentGallery(
                    attachments: store.attachments(.product, productId),
                    emptyText: "No receipts or photos. Edit the product to add them.",
                    opened: $openedAttachment,
                    errorMessage: $errorMessage
                )
            }
            Section {
                Button("Delete product", role: .destructive) { confirmDelete = true }
            }
        }
        .keepListStyle()
        .attachmentPresenter($openedAttachment)
        .navigationTitle(product.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ShareLink(item: shareText(product), subject: Text("Product details: \(product.name)")) {
                Label("Share details", systemImage: "square.and.arrow.up")
            }
            Button("Edit") { editor = .product(productId) }
        }
        .editorSheet($editor)
        .confirmationDialog("Delete \(product.name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                do {
                    try store.deleteProduct(productId)
                    dismiss()
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        } message: {
            Text("The product and its receipts and photos will be removed from this device.")
        }
        .errorAlert($errorMessage)
    }

    private func shareText(_ product: Product) -> String {
        [
            product.name,
            product.brand.isEmpty ? nil : String(localized: "Brand: \(product.brand)"),
            product.model.isEmpty ? nil : String(localized: "Model: \(product.model)"),
            product.serialNumber.isEmpty ? nil : String(localized: "Serial number: \(product.serialNumber)"),
            product.purchaseDate.map { String(localized: "Purchase date: \(Formats.date($0))") },
            product.retailer.isEmpty ? nil : String(localized: "Retailer: \(product.retailer)"),
            product.price.map { String(localized: "Price: \(Money.format($0, currency: product.currency))") },
            product.warrantyExpires.map { String(localized: "Warranty ends: \(Formats.date($0))") },
            product.notes.isEmpty ? nil : product.notes,
        ]
        .compactMap { $0 }
        .joined(separator: "\n")
    }
}

private struct WarrantyHeader: View {
    let product: Product
    let status: DeadlineStatus
    let today: Day

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                StatusBadge(text: badgeText, status: status)
                Spacer()
                if let expires = product.warrantyExpires {
                    Text(Formats.date(expires)).foregroundStyle(.secondary)
                }
            }
            if let expires = product.warrantyExpires {
                Text(Formats.deadline(.warranty, days: today.days(until: expires)))
                    .font(.title3.weight(.semibold))
                if let remaining {
                    ProgressView(value: remaining)
                        .tint(status.tint)
                        .accessibilityLabel("Warranty period remaining")
                        .accessibilityValue(remaining.formatted(.percent.precision(.fractionLength(0))))
                    Text("\(Int((remaining * 100).rounded()))% of the warranty period left")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var badgeText: String {
        switch status {
        case .none: String(localized: "No warranty date")
        case .past: String(localized: "Warranty ended")
        default: String(localized: "Under warranty")
        }
    }

    private var remaining: Double? {
        guard let start = product.purchaseDate, let end = product.warrantyExpires, start < end, status != .past else {
            return nil
        }
        let total = Double(start.days(until: end))
        return min(1, max(0, Double(today.days(until: end)) / total))
    }
}

/// A label/value row that hides itself when the value is empty.
struct DetailField: View {
    let label: LocalizedStringKey
    let value: String
    var monospaced = false

    init(_ label: LocalizedStringKey, _ value: String, monospaced: Bool = false) {
        self.label = label
        self.value = value
        self.monospaced = monospaced
    }

    var body: some View {
        if !value.isEmpty {
            LabeledContent(label) {
                Text(value)
                    .monospaced(monospaced)
                    .textSelection(.enabled)
                    .multilineTextAlignment(.trailing)
            }
        }
    }
}
