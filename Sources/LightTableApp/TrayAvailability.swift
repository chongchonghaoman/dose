import Foundation

extension TableModel {
    /// Preserve library membership and order; only the visible tray excludes
    /// placed films. Removing a slide makes its existing tray entry reappear.
    var trayPhotos: [Photo] {
        let placed = Set(layout.slides.map(\.url))
        return photos.filter { !placed.contains($0.url) }
    }
}
