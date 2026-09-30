import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Imported files are copied under random names; only temporary, user-named links leave the store.
struct AttachmentStore: Sendable {
    let directory: URL

    func url(for fileName: String) -> URL { directory.appending(path: fileName) }

    /// Copies a user-picked file, which may be security scoped or still downloading from a file provider.
    func importFile(at source: URL) async throws -> Attachment {
        try await Task.detached(priority: .userInitiated) { [self] in
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }

            let type = (try? source.resourceValues(forKeys: [.contentTypeKey]).contentType)
                ?? UTType(filenameExtension: source.pathExtension)
            let target = url(for: newFileName(extension: Self.fileExtension(for: source.pathExtension, type: type)))
            do {
                try Self.coordinatedRead(source) { try FileManager.default.copyItem(at: $0, to: target) }
            } catch {
                try? FileManager.default.removeItem(at: target)
                throw error
            }
            return try attachment(for: target, displayName: source.lastPathComponent, type: type)
        }.value
    }

    /// Reads a user-picked image file and stores it as JPEG, like a photo.
    func importImage(at source: URL) async throws -> Attachment {
        let data = try await Task.detached(priority: .userInitiated) {
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            var data = Data()
            try Self.coordinatedRead(source) { data = try Data(contentsOf: $0) }
            return data
        }.value
        let name = source.deletingPathExtension().lastPathComponent + ".jpg"
        return try await importPhoto(data, displayName: name)
    }

    /// Stores photos as JPEG so they open everywhere, including older Android devices without HEIC support.
    func importPhoto(_ data: Data, displayName: String? = nil) async throws -> Attachment {
        try await Task.detached(priority: .userInitiated) { [self] in
            let jpeg = try Self.jpegData(from: data)
            let c = Calendar.gregorian.dateComponents([.year, .month, .day, .hour, .minute, .second], from: .now)
            let name = displayName ?? String(
                format: "Photo %04d-%02d-%02d %02d%02d%02d.jpg", c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!
            )
            let target = url(for: newFileName(extension: "jpg"))
            try jpeg.write(to: target, options: .completeFileProtectionUntilFirstUserAuthentication)
            return try attachment(for: target, displayName: name, type: .jpeg)
        }.value
    }

    private static func coordinatedRead(_ source: URL, _ read: (URL) throws -> Void) throws {
        var coordinatorError: NSError?
        var readError: Error?
        NSFileCoordinator().coordinate(readingItemAt: source, options: .withoutChanges, error: &coordinatorError) { readable in
            do {
                try read(readable)
            } catch {
                readError = error
            }
        }
        if let error = coordinatorError ?? readError { throw error }
    }

    private static func jpegData(from data: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { throw CocoaError(.fileReadCorruptFile) }
        if CGImageSourceGetType(source) as String? == UTType.jpeg.identifier { return data }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImageFromSource(
            destination, source, 0, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return output as Data
    }

    func delete(_ fileNames: [String]) {
        for name in fileNames {
            try? FileManager.default.removeItem(at: url(for: name))
        }
    }

    /// Removes files left behind by abandoned edits or interrupted imports.
    func deleteOrphans(referenced: Set<String>) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        delete(names.filter { !referenced.contains($0) })
    }

    /// A temporary hard link named after the original file, so previews and shares show a meaningful name.
    func shareableURL(for attachment: Attachment) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "shared/\(attachment.fileName)", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let link = folder.appending(path: Self.safeDisplayName(attachment.displayName, fallback: attachment.fileName))
        do {
            try FileManager.default.linkItem(at: url(for: attachment.fileName), to: link)
        } catch {
            try FileManager.default.copyItem(at: url(for: attachment.fileName), to: link)
        }
        return link
    }

    static func safeDisplayName(_ name: String, fallback: String) -> String {
        let cleaned = name
            .components(separatedBy: CharacterSet(charactersIn: "/\\:").union(.controlCharacters))
            .joined(separator: "_")
            .trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: ".")))
        return cleaned.isEmpty ? fallback : String(cleaned.prefix(120))
    }

    private func attachment(for file: URL, displayName: String, type: UTType?) throws -> Attachment {
        let size = try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64 ?? 0
        return Attachment(
            ownerType: .product,
            ownerId: 0,
            displayName: displayName,
            mimeType: type?.preferredMIMEType ?? "application/octet-stream",
            fileName: file.lastPathComponent,
            sizeBytes: size
        )
    }

    private func newFileName(extension ext: String?) -> String {
        UUID().uuidString.lowercased() + (ext.map { ".\($0)" } ?? "")
    }

    private static func fileExtension(for original: String, type: UTType?) -> String? {
        if original.wholeMatch(of: /[A-Za-z0-9]{1,10}/) != nil { return original.lowercased() }
        return type?.preferredFilenameExtension
    }
}
