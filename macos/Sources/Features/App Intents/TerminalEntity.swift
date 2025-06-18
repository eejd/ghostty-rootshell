import AppKit
import AppIntents
import SwiftUI

struct TerminalEntity: AppEntity {
    let id: UUID

    @Property(title: "Title")
    var title: String

    @Property(title: "Working Directory")
    var workingDirectory: String?

    @MainActor
    @DeferredProperty(title: "Full Contents")
    @available(macOS 26.0, *)
    var screenContents: String? {
        get async {
            guard let surfaceView else { return nil }
            return surfaceView.cachedScreenContents.get()
        }
    }

    @MainActor
    @DeferredProperty(title: "Visible Contents")
    @available(macOS 26.0, *)
    var visibleContents: String? {
        get async {
            guard let surfaceView else { return nil }
            return surfaceView.cachedVisibleContents.get()
        }
    }

    var screenshot: Image?

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Terminal")
    }

    @MainActor
    var displayRepresentation: DisplayRepresentation {
        var rep = DisplayRepresentation(title: "\(title)")
        if let screenshot,
           let nsImage = ImageRenderer(content: screenshot).nsImage,
           let data = nsImage.tiffRepresentation {
            rep.image = .init(data: data)
        }

        return rep
    }

    /// Returns the view associated with this entity. This may no longer exist.
    @MainActor
    var surfaceView: Ghostty.SurfaceView? {
        Self.defaultQuery.all.first { $0.uuid == self.id }
    }

    static var defaultQuery = TerminalQuery()

    init(_ view: Ghostty.SurfaceView) {
        self.id = view.uuid
        self.title = view.title
        self.workingDirectory = view.pwd
        self.screenshot = view.screenshot()
    }
}

struct TerminalQuery: EntityStringQuery, EnumerableEntityQuery {
    @MainActor
    func entities(for identifiers: [TerminalEntity.ID]) async throws -> [TerminalEntity] {
        return all.filter {
            identifiers.contains($0.uuid)
        }.map {
            TerminalEntity($0)
        }
    }

    @MainActor
    func entities(matching string: String) async throws -> [TerminalEntity] {
        return all.filter {
            $0.title.localizedCaseInsensitiveContains(string)
        }.map {
            TerminalEntity($0)
        }
    }

    @MainActor
    func allEntities() async throws -> [TerminalEntity] {
        return all.map { TerminalEntity($0) }
    }

    @MainActor
    func suggestedEntities() async throws -> [TerminalEntity] {
        return try await allEntities()
    }

    @MainActor
    var all: [Ghostty.SurfaceView] {
        // Find all of our terminal windows (includes quick terminal)
        let controllers = NSApp.windows.compactMap {
            $0.windowController as? BaseTerminalController
        }

        // Get all our surfaces
        return controllers.reduce([]) { result, c in
            result + (c.surfaceTree.root?.leaves() ?? [])
        }
    }
}
