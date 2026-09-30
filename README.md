# Enve Keep for iOS

A free, open source iPhone app for keeping track of product warranties, subscriptions, document expiry dates and receipts. Everything stays on your phone. It is the iOS companion to [Enve Keep for Android](https://github.com/opisaac9001/Enve-Keep-Android). Backups without receipts work across both apps; receipts use a newer iOS backup format.

## Features

- **Dashboard**: past-due items (expired documents, missed renewals, warranties that ended in the last month), everything coming up within your reminder windows, a per-category overview and estimated monthly spend. Search covers every record.
- **Warranties**: products with brand, model, serial number, purchase date, retailer, price and currency, warranty end date (with 1/2/3/5-year shortcuts), notes and any number of receipts, photos or PDFs. Share a product's details as text when making a claim.
- **Subscriptions**: price, currency, a billing cycle of every N days/weeks/months/years, and the next renewal. Renewals follow the original billing date, so a plan billed on the 31st renews on the last day of shorter months and returns to the 31st afterwards. You can mark a renewal as paid, mark a subscription as canceled, or reactivate it.
- **Documents**: passports, licences, insurance and similar, with issuer, document number, issue and expiry dates, notes and attachments.
- **Receipts**: scan paper receipts with the document camera (edges are found, cropped and straightened, and long receipts can span several pages), or pick images from Photos or Files, or enter a receipt by hand. Apple's Vision framework reads the text on the iPhone, and Enve Keep drafts the merchant, purchase date, currency, line items with quantities, discounts, subtotal, tax, tip and total for you to check. Recognition can make mistakes, especially with handwriting, so every field stays editable and anything the text doesn't clearly state is left blank rather than guessed. Each receipt keeps its page images and the original recognized text. The list can be searched (including the scanned text), sorted by date, total or merchant, grouped by month, category or merchant with per-currency totals, and filtered by category or tag. Share a receipt's details as text or its original scans. The document camera needs a real iPhone; in Simulator, receipts can be added from Photos, Files or by hand.
- **Attachments**: add files from the Files app, pick from your photo library, or take a photo. Everything is copied into the app's private storage, and photos are saved as JPEG so they open on any device. Tap an attachment to preview it with Quick Look, or share it with its original name.
- **Reminders**: local notifications at 9 AM when a date enters its reminder window and again when it arrives. Lead times are configurable per category, and the app asks for notification permission in context.
- **Backup**: export every record, receipt, attachment and setting to a single ZIP file, then import it on this or another device. Backups without receipts also import into Enve Keep for Android (see below). Imports are fully validated in a staging area first. Unexpected entries, path traversal, symlinks, bad checksums, oversized archives and dangling attachment references are all rejected, and your existing data is replaced only after you confirm.
- System, light and dark themes, plus VoiceOver labels throughout.

## Privacy

Enve Keep has no accounts, servers, analytics, ads or in-app purchases, and it makes no network requests. Records and files live only in the app's private storage and are excluded from iCloud device backups. Receipt text is recognized on the device with Apple's Vision framework; no image or text is sent anywhere. The only way data leaves the app is when you export a backup or share a file yourself.

## Backup format

The ZIP holds `backup.json` and a flat `attachments/` folder. The manifest uses the same keys and types as Android: ISO `yyyy-MM-dd` dates, decimal amounts as strings, upper-case enum names and explicit `null`s. For the exact schema, see `EnveKeep/Model/Models.swift` and `EnveKeep/Data/BackupArchive.swift`.

There are two versions:

- **Version 1** is the format Enve Keep for Android reads and writes. Enve Keep for iOS imports it unchanged, and it exports version 1 whenever there are no receipts.
- **Version 2** is written once you have at least one receipt. It adds a `receipts` list and a `receiptAttachments` list for their page images (owner type `RECEIPT`), whose files sit in the same `attachments/` folder. The version 1 keys keep their exact shape, so Enve Keep for Android can still read the manifest and then refuses the file with "Backup was made by a newer version of Enve Keep" instead of silently dropping receipts. Keep a separate version 1 backup if you need to restore data on Android.

## Building

Requirements: Xcode 26 or newer and [XcodeGen](https://github.com/yonaskolb/XcodeGen). The only dependency is [ZIPFoundation](https://github.com/weichsel/ZIPFoundation), which Swift Package Manager resolves.

```sh
xcodegen generate
xcodebuild -project EnveKeep.xcodeproj -scheme EnveKeep \
  -destination "platform=iOS Simulator,name=iPhone Air" build test
```

Minimum iOS version: 17.0.

## Project layout

- `Model/`: records, settings and the `Day` calendar-date type.
- `Domain/`: renewal math, deadline status, money parsing, search, receipt text parsing and organizing.
- `Data/`: the atomic JSON store, attachment storage, backup archive and import/export, and on-device text recognition.
- `Reminders/`: local notification scheduling.
- `UI/`: SwiftUI screens, one folder per section, plus shared components.

## License

MIT. See [LICENSE](LICENSE).
