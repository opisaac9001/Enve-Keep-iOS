import Foundation

extension Receipt {
    static let symbol = "receipt"

    /// Undated receipts sort by the day they were added.
    var sortDate: Day { purchaseDate ?? addedOn }

    func matches(_ query: String) -> Bool {
        Search.matches(
            query, merchant, category, tags.joined(separator: " "), notes,
            items.map(\.description).joined(separator: " "),
            recognizedText.values.joined(separator: " ")
        )
    }
}

enum ReceiptSort: CaseIterable, Sendable {
    case newest, oldest, highestTotal, merchant
}

enum ReceiptGrouping: CaseIterable, Sendable {
    case month, category, merchant, none
}

struct ReceiptGroup: Identifiable, Sendable {
    let id: String
    /// Empty for the ungrouped list and for receipts without a category; the UI supplies a label.
    let title: String
    let receipts: [Receipt]

    var totals: [(currency: String, amount: Decimal)] { ReceiptOrganizer.totals(receipts) }
}

enum ReceiptOrganizer {
    static func groups(_ receipts: [Receipt], sort: ReceiptSort, grouping: ReceiptGrouping) -> [ReceiptGroup] {
        let sorted = receipts.sorted { isOrdered($0, before: $1, by: sort) }
        switch grouping {
        case .none:
            return sorted.isEmpty ? [] : [ReceiptGroup(id: "all", title: "", receipts: sorted)]
        case .month:
            let months = Dictionary(grouping: sorted) { $0.sortDate.year * 12 + $0.sortDate.month - 1 }
            let newestFirst = sort != .oldest
            return months.keys.sorted { newestFirst ? $0 > $1 : $0 < $1 }.map { key in
                let first = Day(year: key / 12, month: key % 12 + 1, day: 1)!
                let title = first.date().formatted(.dateTime.month(.wide).year())
                return ReceiptGroup(id: "month-\(key)", title: title, receipts: months[key]!)
            }
        case .category, .merchant:
            let key: (Receipt) -> String = grouping == .category ? \.category : \.merchant
            let buckets = Dictionary(grouping: sorted) { key($0).trimmingCharacters(in: .whitespaces) }
            return buckets.keys.sorted { lhs, rhs in
                if lhs.isEmpty != rhs.isEmpty { return rhs.isEmpty }
                return lhs.localizedStandardCompare(rhs) == .orderedAscending
            }.map { ReceiptGroup(id: "\(grouping)-\($0)", title: $0, receipts: buckets[$0]!) }
        }
    }

    static func totals(_ receipts: [Receipt]) -> [(currency: String, amount: Decimal)] {
        var totals: [String: Decimal] = [:]
        for receipt in receipts {
            guard let total = receipt.total else { continue }
            totals[receipt.currency, default: 0] += total
        }
        return totals.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    static func categories(_ receipts: [Receipt]) -> [String] {
        Set(receipts.map(\.category).filter { !$0.isEmpty }).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    static func tags(_ receipts: [Receipt]) -> [String] {
        Set(receipts.flatMap(\.tags)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Splits comma-separated tag input, dropping blanks and case-insensitive duplicates.
    static func tags(from text: String) -> [String] {
        var seen = Set<String>()
        return text.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    private static func isOrdered(_ lhs: Receipt, before rhs: Receipt, by sort: ReceiptSort) -> Bool {
        switch sort {
        case .newest:
            (lhs.sortDate, lhs.id) > (rhs.sortDate, rhs.id)
        case .oldest:
            (lhs.sortDate, lhs.id) < (rhs.sortDate, rhs.id)
        case .highestTotal:
            // Blank totals last; mixed currencies compare by face value.
            switch (lhs.total, rhs.total) {
            case let (l?, r?) where l != r: l > r
            case (nil, _?): false
            case (_?, nil): true
            default: (lhs.sortDate, lhs.id) > (rhs.sortDate, rhs.id)
            }
        case .merchant:
            switch lhs.merchant.localizedStandardCompare(rhs.merchant) {
            case .orderedAscending: true
            case .orderedDescending: false
            case .orderedSame: (lhs.sortDate, lhs.id) > (rhs.sortDate, rhs.id)
            }
        }
    }
}
