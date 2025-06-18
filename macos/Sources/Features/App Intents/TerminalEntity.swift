import AppKit
import AppIntents

struct TerminalEntity: AppEntity {
    let id: UUID

    @Property(title: "Title")
    var title: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Terminal")
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)")
    }

    static var defaultQuery = TerminalQuery()

    init(_ view: Ghostty.SurfaceView) {
        self.id = view.uuid
        self.title = view.title
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
    private var all: [Ghostty.SurfaceView] {
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
