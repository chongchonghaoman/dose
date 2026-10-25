import Foundation
import CoreGraphics

public enum FilmFormat: String, Codable, CaseIterable, Sendable {
    case film135 = "135", film120 = "120"
    public var columns: Int { self == .film135 ? 3 : 5 }
    public var rows: Int { self == .film135 ? 3 : 4 }
}

public struct AlbumPocket: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var format: FilmFormat
    public var column: Int
    public var row: Int
    public var url: URL?
    public init(id: UUID = UUID(), format: FilmFormat, column: Int, row: Int, url: URL? = nil) {
        self.id = id; self.format = format; self.column = column; self.row = row
        self.url = url?.standardizedFileURL
    }
    public var rect: CGRect { CGRect(x: column, y: row, width: format.columns, height: format.rows) }
}

/// A fixed sheet on a common 15 by 12 lattice. Camera zoom never changes slots.
public struct AlbumPage: Identifiable, Codable, Equatable, Sendable {
    public static let columns = 15, rows = 12
    public static let size = CGSize(width: 620, height: 690)
    public static let content = CGRect(x: 48, y: 38, width: 540, height: 600)
    public let id: UUID
    public var name: String
    public private(set) var pockets: [AlbumPocket]
    public var position: CGPoint?

    public init(id: UUID = UUID(), name: String, pockets: [AlbumPocket] = [], position: CGPoint? = nil) {
        self.id = id; self.name = name; self.pockets = pockets; self.position = position
    }
    public var photoCount: Int { pockets.filter { $0.url != nil }.count }
    public func accepts(_ pocket: AlbumPocket, excluding ids: Set<UUID> = []) -> Bool {
        guard pocket.column >= 0, pocket.row >= 0,
              pocket.column <= Self.columns - pocket.format.columns,
              pocket.row <= Self.rows - pocket.format.rows else { return false }
        return !pockets.contains { !ids.contains($0.id) && $0.id != pocket.id && $0.rect.intersects(pocket.rect) }
    }
    @discardableResult public mutating func add(_ format: FilmFormat, column: Int? = nil, row: Int? = nil) -> UUID? {
        for y in row.map({ [$0] }) ?? Array(0...(Self.rows - format.rows)) {
            for x in column.map({ [$0] }) ?? Array(0...(Self.columns - format.columns)) {
                let pocket = AlbumPocket(format: format, column: x, row: y)
                if accepts(pocket) { pockets.append(pocket); return pocket.id }
            }
        }
        return nil
    }
    public mutating func setPhoto(_ url: URL?, in id: UUID) {
        guard let index = pockets.firstIndex(where: { $0.id == id }), url == nil || url!.isFileURL else { return }
        pockets[index].url = url?.standardizedFileURL
    }
    public mutating func remove(_ id: UUID) { pockets.removeAll { $0.id == id } }
    @discardableResult public mutating func move(_ id: UUID, column: Int, row: Int) -> Bool {
        guard let index = pockets.firstIndex(where: { $0.id == id }) else { return false }
        var moved = pockets[index]; moved.column = column; moved.row = row
        if accepts(moved) { pockets[index] = moved; return true }
        if let other = pockets.firstIndex(where: { $0.id != id && $0.column == column && $0.row == row && $0.format == moved.format }) {
            var swapped = pockets[other]; swapped.column = pockets[index].column; swapped.row = pockets[index].row
            let excluded: Set<UUID> = [id, swapped.id]
            if accepts(moved, excluding: excluded) && accepts(swapped, excluding: excluded) {
                pockets[index] = moved; pockets[other] = swapped; return true
            }
        }
        return false
    }
    public mutating func fillEmptyPage(with format: FilmFormat) {
        guard pockets.isEmpty else { return }
        for row in stride(from: 0, to: Self.rows, by: format.rows) {
            for col in stride(from: 0, to: Self.columns, by: format.columns) { _ = add(format, column: col, row: row) }
        }
    }
    public func sanitized() -> AlbumPage {
        var result = AlbumPage(id: id, name: name.isEmpty ? "相册页" : name, position: position)
        if let p = result.position, !p.x.isFinite || !p.y.isFinite { result.position = nil }
        var seen = Set<UUID>()
        for var pocket in pockets where seen.insert(pocket.id).inserted {
            if pocket.url?.isFileURL == false { pocket.url = nil }
            pocket.url = pocket.url?.standardizedFileURL
            if result.accepts(pocket) { result.pockets.append(pocket) }
        }
        return result
    }
    public static func pocketRect(_ pocket: AlbumPocket) -> CGRect {
        CGRect(x: content.minX + CGFloat(pocket.column) * content.width / CGFloat(columns),
               y: content.minY + CGFloat(pocket.row) * content.height / CGFloat(rows),
               width: CGFloat(pocket.format.columns) * content.width / CGFloat(columns),
               height: CGFloat(pocket.format.rows) * content.height / CGFloat(rows))
    }
    public static func imageRect(_ pocket: AlbumPocket, aspect: Double) -> CGRect {
        let cell = pocketRect(pocket).insetBy(dx: 9, dy: 14)
        let ratio = aspect.isFinite && aspect > 0 ? aspect : 1.5
        let side = min(cell.width, cell.height)
        let width = min(side, side * ratio), height = width / ratio
        return CGRect(x: cell.midX - width / 2, y: cell.midY - height / 2, width: width, height: height)
    }
}
