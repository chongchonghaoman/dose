import AppKit
import UniformTypeIdentifiers

/// In-app drags carry identity only. Exporting an NSURL lets SwiftUI copy the
/// image into a Drag cache, which must never become a second library photo.
enum PhotoDrag {
    static let contentType = UTType(exportedAs: "app.ourlighttable.photo-reference", conformingTo: .data)
    static let acceptedTypes: [UTType] = [contentType, .fileURL]

    private struct Reference: Codable { let version: Int; let url: URL }

    static func provider(for photo: Photo) -> NSItemProvider {
        let provider = NSItemProvider()
        let data = try? JSONEncoder().encode(Reference(version: 1, url: photo.url.standardizedFileURL))
        provider.suggestedName = photo.name
        provider.registerDataRepresentation(forTypeIdentifier: contentType.identifier, visibility: .ownProcess) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }

    static func sourceURL(from provider: NSItemProvider) async -> URL? {
        let data: Data? = await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: contentType.identifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
        guard let data, let reference = try? JSONDecoder().decode(Reference.self, from: data),
              reference.version == 1, reference.url.isFileURL else { return nil }
        return reference.url.standardizedFileURL
    }

    static func fileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url: URL?
                if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                else if let value = item as? URL { url = value }
                else if let text = item as? String { url = URL(string: text) }
                else { url = nil }
                continuation.resume(returning: url?.isFileURL == true ? url?.standardizedFileURL : nil)
            }
        }
    }
}
