import Foundation

/// Draft values read from receipt text. Anything the text doesn't clearly state stays nil.
struct ParsedReceipt: Equatable, Sendable {
    var merchant: String?
    var purchaseDate: Day?
    var currency: String?
    var items: [ReceiptItem] = []
    var subtotal: Decimal?
    var tax: Decimal?
    var tip: Decimal?
    var total: Decimal?
}

/// Reads two-decimal amounts without treating summaries or payment lines as items.
enum ReceiptParser {
    static func parse(_ text: String, today: Day, locale: Locale = .current, defaultCurrency: String) -> ParsedReceipt {
        let lines = text.components(separatedBy: .newlines).map(normalize).filter { !$0.isEmpty }.map(Line.init)
        var result = ParsedReceipt()
        result.merchant = merchant(in: lines)
        result.purchaseDate = purchaseDate(in: lines.map(\.text), today: today, locale: locale)
        result.currency = currency(in: text, defaultCurrency: defaultCurrency)

        var subtotal: Decimal?
        var taxes: [(keyword: String, value: Decimal)] = []
        var taxTotal: Decimal?
        var tips: [Decimal] = []
        var totals: [(value: Decimal, afterTip: Bool)] = []
        var items: [ReceiptItem] = []
        var pendingDescription: String?
        var pendingQuantity: Quantity?

        var index = 0
        while index < lines.count {
            let line = lines[index]
            let kind = classify(line)
            var amount = line.lineAmounts.last?.value
            if amount == nil, kind.isSummary, index + 1 < lines.count, lines[index + 1].isAmountOnly {
                index += 1
                amount = lines[index].lineAmounts.last?.value
            }
            defer { index += 1 }

            switch kind {
            case .ignore:
                pendingDescription = nil
                continue
            case .subtotal:
                if let amount, subtotal == nil { subtotal = amount }
            case .tip:
                if let amount { tips.append(amount) }
            case .tax(let keyword, let isTotal):
                if let amount {
                    if isTotal { taxTotal = amount } else { taxes.append((keyword, amount)) }
                }
            case .total:
                if let amount { totals.append((amount, !tips.isEmpty)) }
            case .item:
                break
            }
            if kind.isSummary {
                pendingDescription = nil
                continue
            }

            let summaryStarted = subtotal != nil || taxTotal != nil || !taxes.isEmpty || !tips.isEmpty
            guard totals.isEmpty, !summaryStarted || line.isDiscount else { continue }

            if let quantity = line.quantity, line.letterCount < 2 {
                if let lineTotal = amount {
                    if let description = pendingDescription {
                        items.append(ReceiptItem(description: description, quantity: quantity.count, amount: lineTotal))
                        pendingDescription = nil
                    } else if let last = items.indices.last, items[last].quantity == nil, items[last].amount == lineTotal {
                        items[last].quantity = quantity.count
                    } else {
                        pendingQuantity = quantity
                    }
                } else if let last = items.indices.last, items[last].quantity == nil, items[last].amount == quantity.lineTotal {
                    items[last].quantity = quantity.count
                } else if let description = pendingDescription {
                    items.append(ReceiptItem(description: description, quantity: quantity.count, amount: quantity.lineTotal))
                    pendingDescription = nil
                } else {
                    pendingQuantity = quantity
                }
                continue
            }

            guard let amount else {
                if line.letterCount >= 2 {
                    if let quantity = line.quantity {
                        items.append(ReceiptItem(description: line.itemDescription, quantity: quantity.count, amount: quantity.lineTotal))
                        pendingDescription = nil
                    } else {
                        pendingDescription = line.itemDescription
                    }
                }
                continue
            }

            if line.letterCount < 2 {
                if let description = pendingDescription {
                    let count = pendingQuantity.flatMap { $0.lineTotal == amount ? $0.count : nil }
                    items.append(ReceiptItem(description: description, quantity: count, amount: amount))
                    pendingDescription = nil
                    pendingQuantity = nil
                }
                continue
            }

            var count = line.quantity?.count ?? line.leadingCount
            if count == nil, let pending = pendingQuantity, pending.lineTotal == amount { count = pending.count }
            let signed = line.isDiscount && amount > 0 ? -amount : amount
            items.append(ReceiptItem(description: line.itemDescription, quantity: count, amount: signed))
            pendingDescription = nil
            pendingQuantity = nil
        }

        result.items = items
        result.subtotal = subtotal
        result.tip = tips.last
        if let taxTotal {
            result.tax = taxTotal
        } else if !taxes.isEmpty {
            var seen = Set<String>()
            result.tax = taxes.filter { seen.insert("\($0.keyword) \($0.value)").inserted }.reduce(0) { $0 + $1.value }
        }
        result.total = chooseTotal(totals, subtotal: subtotal, tax: result.tax, tip: result.tip, items: items)
        return result
    }

    /// Differing totals stay blank unless a tip or arithmetic resolves them.
    private static func chooseTotal(
        _ totals: [(value: Decimal, afterTip: Bool)],
        subtotal: Decimal?,
        tax: Decimal?,
        tip: Decimal?,
        items: [ReceiptItem]
    ) -> Decimal? {
        let values = Set(totals.map(\.value))
        if values.count <= 1 { return values.first }
        if let withTip = totals.last(where: \.afterTip) { return withTip.value }
        let amounts = items.compactMap(\.amount)
        guard let base = subtotal ?? (amounts.isEmpty ? nil : amounts.reduce(0, +)) else { return nil }
        let expected = [base + (tax ?? 0), base + (tax ?? 0) + (tip ?? 0)]
        let matching = totals.map(\.value).filter(expected.contains)
        return Set(matching).count == 1 ? matching.first : nil
    }

    // MARK: - Header fields

    private static func merchant(in lines: [Line]) -> String? {
        let bodyStart = lines.firstIndex { !$0.amounts.isEmpty } ?? lines.count
        for line in lines.prefix(min(8, bodyStart)) {
            var candidate = line.text
            if let welcome = candidate.range(of: #"^welcome to\s+"#, options: [.regularExpression, .caseInsensitive]) {
                candidate.removeSubrange(welcome)
            }
            let folded = fold(candidate)
            let letters = candidate.filter(\.isLetter).count
            let digits = candidate.filter(\.isNumber).count
            guard letters >= 3, digits < 5, candidate.first?.isNumber == false, !candidate.contains(":"),
                  !Patterns.merchantJunk.matches(folded), dateMatch(in: candidate) == nil
            else { continue }
            return candidate.trimmingCharacters(in: CharacterSet(charactersIn: " *#-=_~.,"))
        }
        return nil
    }

    private static func purchaseDate(in lines: [String], today: Day, locale: Locale) -> Day? {
        let monthFirst = localeIsMonthFirst(locale)
        let latest = today.adding(days: 1)
        for line in lines where !Patterns.notPurchaseDate.matches(fold(line)) {
            guard let match = dateMatch(in: line) else { continue }
            let resolved: Day? = switch match {
            case .ymd(let y, let m, let d): Day(year: y, month: m, day: d)
            case .monthName(let y, let m, let d): Day(year: y, month: m, day: d)
            case .numeric(let a, let b, let y, let dotted):
                if dotted || a > 12 { Day(year: y, month: b, day: a) }
                else if b > 12 { Day(year: y, month: a, day: b) }
                else { monthFirst ? Day(year: y, month: a, day: b) : Day(year: y, month: b, day: a) }
            }
            if let resolved, resolved.year >= 2000, resolved <= latest { return resolved }
        }
        return nil
    }

    private enum DateMatch {
        case ymd(Int, Int, Int)
        case monthName(Int, Int, Int)
        case numeric(Int, Int, year: Int, dotted: Bool)
    }

    private static func dateMatch(in line: String) -> DateMatch? {
        if let g = Patterns.isoDate.groups(in: line), let y = Int(g[1]), let m = Int(g[2]), let d = Int(g[3]) {
            return .ymd(y, m, d)
        }
        if let g = Patterns.numericDate.groups(in: line), let a = Int(g[1]), let b = Int(g[3]), let y = Int(g[4]) {
            return .numeric(a, b, year: fullYear(y), dotted: g[2] == ".")
        }
        let folded = fold(line)
        if let g = Patterns.monthFirstDate.groups(in: folded), let m = month(g[1]), let d = Int(g[2]), let y = Int(g[3]) {
            return .monthName(fullYear(y), m, d)
        }
        if let g = Patterns.dayFirstDate.groups(in: folded), let d = Int(g[1]), let m = month(g[2]), let y = Int(g[3]) {
            return .monthName(fullYear(y), m, d)
        }
        return nil
    }

    private static func fullYear(_ year: Int) -> Int { year < 100 ? 2000 + year : year }

    private static func month(_ name: String) -> Int? {
        let months = ["jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "mai": 5, "jun": 6, "jul": 7, "aug": 8,
                      "sep": 9, "oct": 10, "okt": 10, "nov": 11, "dec": 12, "dez": 12]
        return months[String(name.prefix(3))]
    }

    private static func localeIsMonthFirst(_ locale: Locale) -> Bool {
        let format = DateFormatter.dateFormat(fromTemplate: "Md", options: 0, locale: locale) ?? "M/d"
        guard let m = format.firstIndex(of: "M"), let d = format.firstIndex(of: "d") else { return true }
        return m < d
    }

    private static func currency(in text: String, defaultCurrency: String) -> String? {
        let codes = Set(Patterns.currencyCode.allGroups(in: text).map { $0[1] })
        if codes.count == 1 { return codes.first }
        if codes.count > 1 { return nil }
        let unique: [(String, String)] = [("€", "EUR"), ("£", "GBP"), ("₹", "INR"), ("₩", "KRW"), ("₺", "TRY"), ("₪", "ILS"), ("zł", "PLN")]
        let found = Set(unique.filter { text.contains($0.0) }.map(\.1))
        if found.count == 1 { return found.first }
        if found.count > 1 { return nil }
        // Symbols shared by several currencies only confirm the default; they never pick a different one.
        let shared: [(String, Set<String>)] = [
            ("$", ["USD", "CAD", "AUD", "NZD", "MXN", "SGD", "HKD"]),
            ("¥", ["JPY", "CNY"]),
            ("kr", ["SEK", "NOK", "DKK", "ISK"]),
        ]
        for (symbol, currencies) in shared where text.contains(symbol) && currencies.contains(defaultCurrency) {
            return defaultCurrency
        }
        return nil
    }

    // MARK: - Lines

    private static func normalize(_ raw: String) -> String {
        var line = raw.replacingOccurrences(of: "\t", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .map { fixMisreadDigits(String($0)) }
            .joined(separator: " ")
        // Handwriting often leaves a gap around the decimal point of the final amount.
        line = line.replacingOccurrences(of: #"(\d)\s+([.,]\d{2})\s*$"#, with: "$1$2", options: .regularExpression)
        line = line.replacingOccurrences(of: #"(\d[.,])\s+(\d{2})\s*$"#, with: "$1$2", options: .regularExpression)
        return line.trimmingCharacters(in: .whitespaces)
    }

    /// "4.OO" or "l2.50" in an otherwise numeric token are OCR confusions of 0 and 1.
    private static func fixMisreadDigits(_ token: String) -> String {
        guard token.wholeMatch(of: /[-−(]?[$€£]?[0-9OoIl]*[0-9][0-9OoIl]*[.,][0-9OoIl]{2}[)\-]?/) != nil else { return token }
        return String(token.map { "Oo".contains($0) ? "0" : "Il".contains($0) ? "1" : $0 })
    }

    fileprivate static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// Keyword text with digit-for-letter OCR slips undone, so "T0TAL" and "SUBT0TAL" still match.
    fileprivate static func keywordText(_ label: String) -> String {
        fold(label).split(separator: " ").map { word in
            guard word.contains(where: \.isLetter), word.contains(where: \.isNumber) else { return String(word) }
            return String(word.map { $0 == "0" ? "o" : $0 == "1" ? "l" : $0 == "5" ? "s" : $0 })
        }.joined(separator: " ")
    }

    private enum Kind {
        case item, ignore, subtotal, tip, total
        case tax(keyword: String, isTotal: Bool)

        var isSummary: Bool {
            switch self {
            case .item, .ignore: false
            default: true
            }
        }
    }

    private static func classify(_ line: Line) -> Kind {
        let label = line.keywords
        if Patterns.payment.matches(label) { return .ignore }
        if Patterns.subtotal.matches(label) { return .subtotal }
        if Patterns.tip.matches(label) { return .tip }
        let isTotal = Patterns.total.matches(label)
        if let keyword = Patterns.tax.groups(in: label)?[1] {
            if !isTotal { return .tax(keyword: keyword, isTotal: false) }
            return Patterns.included.matches(label) ? .total : .tax(keyword: keyword, isTotal: true)
        }
        return isTotal ? .total : .item
    }
}

private struct Amount {
    let value: Decimal
    let range: NSRange
}

private struct Quantity {
    let count: Decimal
    let unitPrice: Decimal
    let range: NSRange

    var lineTotal: Decimal { count * unitPrice }
}

private struct Line {
    let text: String
    let amounts: [Amount]
    let quantity: Quantity?
    /// Amounts outside the quantity expression, i.e. candidates for the line's own total.
    let lineAmounts: [Amount]
    let keywords: String
    let letterCount: Int

    init(_ text: String) {
        self.text = text
        amounts = Patterns.amount.matches(in: text).map { match in
            let ns = text as NSString
            let number = ns.substring(with: match.range(withName: "num"))
            let negative = match.range(withName: "sign").location != NSNotFound
                || match.range(withName: "sign2").location != NSNotFound
                || match.range(withName: "trail").location != NSNotFound
                || (match.range(withName: "open").location != NSNotFound && match.range(withName: "close").location != NSNotFound)
            let value = Line.decimal(number)
            return Amount(value: negative ? -value : value, range: match.range)
        }
        quantity = Patterns.quantity.firstMatch(in: text).flatMap { match in
            let ns = text as NSString
            guard let count = Decimal(string: ns.substring(with: match.range(at: 1)).replacingOccurrences(of: ",", with: "."),
                                      locale: Locale(identifier: "en_US_POSIX")),
                  count > 0
            else { return nil }
            return Quantity(count: count, unitPrice: Line.decimal(ns.substring(with: match.range(at: 2))), range: match.range)
        }
        let quantityRange = quantity?.range
        lineAmounts = amounts.filter { amount in
            quantityRange.map { NSIntersectionRange($0, amount.range).length == 0 } ?? true
        }
        let label = Line.removing(amounts.map(\.range) + [quantityRange].compactMap { $0 }, from: text)
        keywords = ReceiptParser.keywordText(label)
        letterCount = ReceiptParser.fold(label)
            .replacingOccurrences(of: Patterns.unitWords, with: " ", options: .regularExpression)
            .filter(\.isLetter).count
    }

    var isAmountOnly: Bool { !lineAmounts.isEmpty && letterCount < 2 }
    var isDiscount: Bool { Patterns.discount.matches(keywords) }

    /// A leading "2 x" or "2x" before the description.
    var leadingCount: Decimal? {
        Patterns.leadingCount.groups(in: text).flatMap { Decimal(string: $0[1]) }
    }

    var itemDescription: String {
        let ns = text as NSString
        let end = lineAmounts.first?.range.location ?? ns.length
        var removed = [NSRange(location: end, length: ns.length - end)]
        if let quantity { removed.append(quantity.range) }
        var description = Line.removing(removed, from: text)
        for pattern in [#"^\d{1,3}\s*[x×]\s+"#, #"^\d{5,}\s+"#, #"[$€£¥₹₩]"#, Patterns.currencyCodePattern] {
            description = description.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        return description
            .split(separator: " ").joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " .:*#-=_~@"))
    }

    /// The last separator before two final digits is the decimal point; any others group thousands.
    static func decimal(_ number: String) -> Decimal {
        let digits = number.filter(\.isNumber)
        return Decimal(string: "\(digits.dropLast(2)).\(digits.suffix(2))", locale: Locale(identifier: "en_US_POSIX")) ?? 0
    }

    static func removing(_ ranges: [NSRange], from text: String) -> String {
        let result = NSMutableString(string: text)
        for range in ranges.sorted(by: { $0.location > $1.location }) where NSMaxRange(range) <= result.length {
            result.replaceCharacters(in: range, with: " ")
        }
        return result as String
    }
}

private enum Patterns {
    static let amount = TextPattern(
        #"(?<![\d.,])(?<sign>[-−–]\s?)?(?<open>\()?(?:[$€£¥₹₩]\s?)?(?<sign2>[-−–])?"#
            + #"(?<num>\d{1,3}(?:[.,']\d{3})+[.,]\d{2}|\d+[.,]\d{2})(?<close>\))?(?<trail>-(?!\d))?(?!\d|[.,]\d|\s?%)"#
    )
    static let quantity = TextPattern(
        #"(?<![\d.,])(\d{1,4}(?:[.,]\d{1,3})?)\s*(?:(?:lb|lbs|kg|g|oz|ea|pc|pcs|stk|st)\.?\s*)?[x×*@]\s*(?:[$€£]\s*)?(\d+[.,]\d{2})(?:\s*/\s*(?:lb|kg|ea|st|stk|pc))?"#
    )
    static let leadingCount = TextPattern(#"^(\d{1,3})\s*[x×]\s+(?=\p{L})"#)
    static let unitWords = #"\b(lb|lbs|kg|g|oz|ea|each|pc|pcs|stk|st|x)\b"#

    static let payment = TextPattern(
        #"\b(cash|change|tender(ed)?|visa|mastercard|amex|debit|auth(orization)?|approval|approved|you saved|total savings|loyalty|points|ruckgeld|gegeben|especes|rendu|efectivo|contanti|paid|payment|balance(?!\s*due)|rounding)\b"#
    )
    static let subtotal = TextPattern(
        #"(sub\s*-?\s*total|zwischensumme|sous[\s-]*total|subtotale|\bht\b|hors taxes?|\bexcl|\bexkl|before tax|pre-?tax|\bnetto\b)"#
    )
    static let tip = TextPattern(#"\b(tip|tips|gratuity|trinkgeld|pourboire|propina|mancia)\b"#)
    static let total = TextPattern(
        #"\b(total|amount due|balance due|to pay|summe|gesamt|gesamtbetrag|zu zahlen|totale|importe|totaal|te betalen|brutto|montant|a payer|ttc)\b"#
    )
    static let tax = TextPattern(#"\b(tax|taxes|sales tax|vat|gst|hst|pst|qst|mwst|ust|tva|iva|btw|moms|igic)\b"#)
    static let included = TextPattern(#"\b(incl|inkl|including|included|inc|ttc)\b"#)
    static let discount = TextPattern(
        #"\b(discount|coupon|savings|saving|promo|promotion|rabatt|remise|descuento|sconto|korting|reduction|markdown)\b"#
    )

    static let merchantJunk = TextPattern(
        #"(receipt|invoice|welcome|thank|\btel\b|phone|\bfax\b|store\s*#|\border\b|\btable\b|server|cashier|register|\bdate\b|\btime\b|guest|customer|copy|terminal|www|http|@|\.com\b)"#
    )
    static let notPurchaseDate = TextPattern(#"\b(exp|expires?|expiry|valid|return|returns|until|best before|use by|bis|gultig)\b"#)
    static let isoDate = TextPattern(#"\b(20\d{2})[-/.](\d{1,2})[-/.](\d{1,2})\b"#)
    static let numericDate = TextPattern(#"\b(\d{1,2})([./-])(\d{1,2})\2(\d{4}|\d{2})\b"#)
    static let monthFirstDate = TextPattern(
        #"\b(jan|feb|mar|apr|may|mai|jun|jul|aug|sep|oct|okt|nov|dec|dez)[a-z]*\.?\s+(\d{1,2})(?:st|nd|rd|th)?,?\s+(\d{4}|\d{2})\b"#
    )
    static let dayFirstDate = TextPattern(
        #"\b(\d{1,2})\.?\s+(jan|feb|mar|apr|may|mai|jun|jul|aug|sep|oct|okt|nov|dec|dez)[a-z]*\.?,?\s+(\d{4}|\d{2})\b"#
    )

    static let currencyCodePattern = #"\b(USD|EUR|GBP|CAD|AUD|NZD|CHF|JPY|CNY|SEK|NOK|DKK|PLN|CZK|HUF|INR|MXN|BRL|ZAR|SGD|HKD|KRW|TRY|ILS)\b"#
    static let currencyCode = TextPattern(currencyCodePattern, caseInsensitive: false)
}

/// A thin wrapper over `NSRegularExpression`, which supports the lookbehind these patterns rely on.
private struct TextPattern: @unchecked Sendable {
    let expression: NSRegularExpression

    init(_ pattern: String, caseInsensitive: Bool = true) {
        expression = try! NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : [])
    }

    func matches(in text: String) -> [NSTextCheckingResult] {
        expression.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
    }

    func firstMatch(in text: String) -> NSTextCheckingResult? {
        expression.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length))
    }

    func matches(_ text: String) -> Bool { firstMatch(in: text) != nil }

    /// Capture groups of the first match, with index 0 as the whole match.
    func groups(in text: String) -> [String]? {
        firstMatch(in: text).map { groups(of: $0, in: text) }
    }

    func allGroups(in text: String) -> [[String]] {
        matches(in: text).map { groups(of: $0, in: text) }
    }

    private func groups(of match: NSTextCheckingResult, in text: String) -> [String] {
        (0..<match.numberOfRanges).map { index in
            let range = match.range(at: index)
            return range.location == NSNotFound ? "" : (text as NSString).substring(with: range)
        }
    }
}
