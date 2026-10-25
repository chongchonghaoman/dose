import AppKit
import UniformTypeIdentifiers

enum AlbumDrag {
    static let contentType = UTType(exportedAs: "app.ourlighttable.album-page", conformingTo: .data)
    static func provider(_ id: UUID) -> NSItemProvider {
        let result = NSItemProvider()
        result.registerDataRepresentation(forTypeIdentifier: contentType.identifier, visibility: .ownProcess) { done in
            done(id.uuidString.data(using: .utf8), nil); return nil
        }
        return result
    }
    static func pageID(from provider: NSItemProvider) async -> UUID? {
        let data: Data? = await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: contentType.identifier) { data, _ in continuation.resume(returning: data) }
        }
        return data.flatMap { String(data: $0, encoding: .utf8) }.flatMap { UUID(uuidString: $0) }
    }
}
