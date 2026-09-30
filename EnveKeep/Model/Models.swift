import Foundation

// Field names, defaults and JSON shapes mirror Enve Keep Android so backups interoperate.
// Encoding writes every key, with explicit nulls, the way kotlinx.serialization does with encodeDefaults.

struct Product: Identifiable, Hashable, Sendable {
    var id: Int64 = 0
    var name: String
    var brand = ""
    var model = ""
    var serialNumber = ""
    var purchaseDate: Day?
    var retailer = ""
    var price: Decimal?
    var currency: String
    var warrantyExpires: Day?
    var notes = ""
}

enum CycleUnit: String, Codable, CaseIterable, Sendable {
    case days = "DAYS"
    case weeks = "WEEKS"
    case months = "MONTHS"
    case years = "YEARS"
}

struct Subscription: Identifiable, Hashable, Sendable {
    var id: Int64 = 0
    var name: String
    var price: Decimal?
    var currency: String
    var cycleCount = 1
    var cycleUnit = CycleUnit.months
    var nextRenewal: Day
    /// Original billing date the schedule is derived from, so month-end renewals don't drift.
    var anchorDate: Day
    var canceledOn: Day?
    var notes = ""

    var isActive: Bool { canceledOn == nil }
}

struct Document: Identifiable, Hashable, Sendable {
    var id: Int64 = 0
    var title: String
    var issuer = ""
    var reference = ""
    var issuedOn: Day?
    var expiresOn: Day?
    var notes = ""
}

struct ReceiptItem: Hashable, Sendable {
    var description: String
    var quantity: Decimal?
    /// Line total; discounts and returns are negative.
    var amount: Decimal?
}

/// Receipts are iOS-only and travel in version 2 backups, which Enve Keep for Android rejects as newer.
struct Receipt: Identifiable, Hashable, Sendable {
    var id: Int64 = 0
    var merchant: String
    var purchaseDate: Day?
    var currency: String
    var items: [ReceiptItem] = []
    var subtotal: Decimal?
    var tax: Decimal?
    var tip: Decimal?
    var total: Decimal?
    var category = ""
    var tags: [String] = []
    var notes = ""
    /// On-device OCR output per scanned page, keyed by the page attachment's file name.
    var recognizedText: [String: String] = [:]
    var addedOn: Day
}

enum OwnerType: String, Codable, Sendable {
    case product = "PRODUCT"
    case document = "DOCUMENT"
    case receipt = "RECEIPT"
}

struct Attachment: Identifiable, Hashable, Sendable {
    var id: Int64 = 0
    var ownerType: OwnerType
    var ownerId: Int64
    var displayName: String
    var mimeType: String
    var fileName: String
    var sizeBytes: Int64

    var isImage: Bool { mimeType.hasPrefix("image/") }
}

enum ThemeMode: String, Codable, CaseIterable, Sendable {
    case system = "SYSTEM"
    case light = "LIGHT"
    case dark = "DARK"
}

struct Settings: Hashable, Sendable {
    var themeMode = ThemeMode.system
    var remindersEnabled = true
    var warrantyLeadDays = 30
    var subscriptionLeadDays = 7
    var documentLeadDays = 60
    var defaultCurrency = Settings.localCurrency
    var reminderPromptDismissed = false

    static var localCurrency: String { Locale.current.currency?.identifier ?? "USD" }
}

// MARK: - Codable

/// Decimal amounts travel as plain strings (`BigDecimal.toPlainString`) to avoid float rounding.
enum AmountCoding {
    private static let posix = Locale(identifier: "en_US_POSIX")

    static func parse(_ text: String) -> Decimal? {
        guard text.wholeMatch(of: /-?[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?/) != nil else { return nil }
        return Decimal(string: text, locale: posix)
    }

    static func string(_ value: Decimal) -> String {
        var value = value
        return NSDecimalString(&value, posix)
    }
}

private struct JSONKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

private extension KeyedDecodingContainer where K == JSONKey {
    func value<T: Decodable>(_ key: String, default fallback: T) throws -> T {
        try decodeIfPresent(T.self, forKey: JSONKey(key)) ?? fallback
    }

    func required<T: Decodable>(_ key: String) throws -> T {
        try decode(T.self, forKey: JSONKey(key))
    }

    func amount(_ key: String) throws -> Decimal? {
        guard let raw = try decodeIfPresent(String.self, forKey: JSONKey(key)) else { return nil }
        guard let value = AmountCoding.parse(raw) else {
            throw DecodingError.dataCorruptedError(forKey: JSONKey(key), in: self, debugDescription: "Invalid amount \(raw)")
        }
        return value
    }
}

private extension KeyedEncodingContainer where K == JSONKey {
    mutating func put<T: Encodable>(_ value: T, _ key: String) throws {
        try encode(value, forKey: JSONKey(key))
    }

    mutating func putAmount(_ value: Decimal?, _ key: String) throws {
        try put(value.map(AmountCoding.string), key)
    }
}

extension Product: Codable {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: JSONKey.self)
        id = try c.value("id", default: 0)
        name = try c.required("name")
        brand = try c.value("brand", default: "")
        model = try c.value("model", default: "")
        serialNumber = try c.value("serialNumber", default: "")
        purchaseDate = try c.value("purchaseDate", default: nil)
        retailer = try c.value("retailer", default: "")
        price = try c.amount("price")
        currency = try c.required("currency")
        warrantyExpires = try c.value("warrantyExpires", default: nil)
        notes = try c.value("notes", default: "")
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: JSONKey.self)
        try c.put(id, "id")
        try c.put(name, "name")
        try c.put(brand, "brand")
        try c.put(model, "model")
        try c.put(serialNumber, "serialNumber")
        try c.put(purchaseDate, "purchaseDate")
        try c.put(retailer, "retailer")
        try c.putAmount(price, "price")
        try c.put(currency, "currency")
        try c.put(warrantyExpires, "warrantyExpires")
        try c.put(notes, "notes")
    }
}

extension Subscription: Codable {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: JSONKey.self)
        id = try c.value("id", default: 0)
        name = try c.required("name")
        price = try c.amount("price")
        currency = try c.required("currency")
        cycleCount = try c.value("cycleCount", default: 1)
        cycleUnit = try c.value("cycleUnit", default: .months)
        nextRenewal = try c.required("nextRenewal")
        anchorDate = try c.value("anchorDate", default: nextRenewal)
        canceledOn = try c.value("canceledOn", default: nil)
        notes = try c.value("notes", default: "")
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: JSONKey.self)
        try c.put(id, "id")
        try c.put(name, "name")
        try c.putAmount(price, "price")
        try c.put(currency, "currency")
        try c.put(cycleCount, "cycleCount")
        try c.put(cycleUnit, "cycleUnit")
        try c.put(nextRenewal, "nextRenewal")
        try c.put(anchorDate, "anchorDate")
        try c.put(canceledOn, "canceledOn")
        try c.put(notes, "notes")
    }
}

extension Document: Codable {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: JSONKey.self)
        id = try c.value("id", default: 0)
        title = try c.required("title")
        issuer = try c.value("issuer", default: "")
        reference = try c.value("reference", default: "")
        issuedOn = try c.value("issuedOn", default: nil)
        expiresOn = try c.value("expiresOn", default: nil)
        notes = try c.value("notes", default: "")
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: JSONKey.self)
        try c.put(id, "id")
        try c.put(title, "title")
        try c.put(issuer, "issuer")
        try c.put(reference, "reference")
        try c.put(issuedOn, "issuedOn")
        try c.put(expiresOn, "expiresOn")
        try c.put(notes, "notes")
    }
}

extension ReceiptItem: Codable {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: JSONKey.self)
        description = try c.value("description", default: "")
        quantity = try c.amount("quantity")
        amount = try c.amount("amount")
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: JSONKey.self)
        try c.put(description, "description")
        try c.putAmount(quantity, "quantity")
        try c.putAmount(amount, "amount")
    }
}

extension Receipt: Codable {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: JSONKey.self)
        id = try c.value("id", default: 0)
        merchant = try c.required("merchant")
        purchaseDate = try c.value("purchaseDate", default: nil)
        currency = try c.required("currency")
        items = try c.value("items", default: [])
        subtotal = try c.amount("subtotal")
        tax = try c.amount("tax")
        tip = try c.amount("tip")
        total = try c.amount("total")
        category = try c.value("category", default: "")
        tags = try c.value("tags", default: [])
        notes = try c.value("notes", default: "")
        recognizedText = try c.value("recognizedText", default: [:])
        addedOn = try c.required("addedOn")
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: JSONKey.self)
        try c.put(id, "id")
        try c.put(merchant, "merchant")
        try c.put(purchaseDate, "purchaseDate")
        try c.put(currency, "currency")
        try c.put(items, "items")
        try c.putAmount(subtotal, "subtotal")
        try c.putAmount(tax, "tax")
        try c.putAmount(tip, "tip")
        try c.putAmount(total, "total")
        try c.put(category, "category")
        try c.put(tags, "tags")
        try c.put(notes, "notes")
        try c.put(recognizedText, "recognizedText")
        try c.put(addedOn, "addedOn")
    }
}

extension Attachment: Codable {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: JSONKey.self)
        id = try c.value("id", default: 0)
        ownerType = try c.required("ownerType")
        ownerId = try c.required("ownerId")
        displayName = try c.required("displayName")
        mimeType = try c.required("mimeType")
        fileName = try c.required("fileName")
        sizeBytes = try c.required("sizeBytes")
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: JSONKey.self)
        try c.put(id, "id")
        try c.put(ownerType, "ownerType")
        try c.put(ownerId, "ownerId")
        try c.put(displayName, "displayName")
        try c.put(mimeType, "mimeType")
        try c.put(fileName, "fileName")
        try c.put(sizeBytes, "sizeBytes")
    }
}

extension Settings: Codable {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: JSONKey.self)
        let defaults = Settings()
        themeMode = try c.value("themeMode", default: defaults.themeMode)
        remindersEnabled = try c.value("remindersEnabled", default: defaults.remindersEnabled)
        warrantyLeadDays = try c.value("warrantyLeadDays", default: defaults.warrantyLeadDays)
        subscriptionLeadDays = try c.value("subscriptionLeadDays", default: defaults.subscriptionLeadDays)
        documentLeadDays = try c.value("documentLeadDays", default: defaults.documentLeadDays)
        defaultCurrency = try c.value("defaultCurrency", default: defaults.defaultCurrency)
        reminderPromptDismissed = try c.value("reminderPromptDismissed", default: defaults.reminderPromptDismissed)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: JSONKey.self)
        try c.put(themeMode, "themeMode")
        try c.put(remindersEnabled, "remindersEnabled")
        try c.put(warrantyLeadDays, "warrantyLeadDays")
        try c.put(subscriptionLeadDays, "subscriptionLeadDays")
        try c.put(documentLeadDays, "documentLeadDays")
        try c.put(defaultCurrency, "defaultCurrency")
        try c.put(reminderPromptDismissed, "reminderPromptDismissed")
    }
}
