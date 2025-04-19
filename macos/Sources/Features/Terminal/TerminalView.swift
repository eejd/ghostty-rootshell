import SwiftUI
import GhosttyKit

/// This delegate is notified of actions and property changes regarding the terminal view. This
/// delegate is optional and can be used by a TerminalView caller to react to changes such as
/// titles being set, cell sizes being changed, etc.
protocol TerminalViewDelegate: AnyObject {
    /// Called when the currently focused surface changed. This can be nil.
    func focusedSurfaceDidChange(to: Ghostty.SurfaceView?)

    /// The title of the terminal should change.
    func titleDidChange(to: String)

    /// The URL of the pwd should change.
    func pwdDidChange(to: URL?)

    /// The cell size changed.
    func cellSizeDidChange(to: NSSize)

    /// The surface tree did change in some way, i.e. a split was added, removed, etc. This is
    /// not called initially.
    func surfaceTreeDidChange()

    /// This is called when a split is zoomed.
    func zoomStateDidChange(to: Bool)
}

/// The view model is a required implementation for TerminalView callers. This contains
/// the main state between the TerminalView caller and SwiftUI. This abstraction is what
/// allows AppKit to own most of the data in SwiftUI.
protocol TerminalViewModel: ObservableObject {
    /// The tree of terminal surfaces (splits) within the view. This is mutated by TerminalView
    /// and children. This should be @Published.
    var surfaceTree: Ghostty.SplitNode? { get set }
}

/// The main terminal view. This terminal view supports splits.
struct TerminalView<ViewModel: TerminalViewModel>: View {
    @ObservedObject var ghostty: Ghostty.App

    // The required view model
    @ObservedObject var viewModel: ViewModel

    // An optional delegate to receive information about terminal changes.
    weak var delegate: (any TerminalViewDelegate)? = nil

    // The most recently focused surface, equal to focusedSurface when
    // it is non-nil.
    @State private var lastFocusedSurface: Weak<Ghostty.SurfaceView> = .init()

    // This seems like a crutch after switching from SwiftUI to AppKit lifecycle.
    @FocusState private var focused: Bool

    // Various state values sent back up from the currently focused terminals.
    @FocusedValue(\.ghosttySurfaceView) private var focusedSurface
    @FocusedValue(\.ghosttySurfaceTitle) private var surfaceTitle
    @FocusedValue(\.ghosttySurfacePwd) private var surfacePwd
    @FocusedValue(\.ghosttySurfaceZoomed) private var zoomedSplit
    @FocusedValue(\.ghosttySurfaceCellSize) private var cellSize

    // The title for our window
    private var title: String {
        if let surfaceTitle, !surfaceTitle.isEmpty {
            return surfaceTitle
        }
        return "👻"
    }

    // The pwd of the focused surface as a URL
    private var pwdURL: URL? {
        guard let surfacePwd, surfacePwd != "" else { return nil }
        return URL(fileURLWithPath: surfacePwd)
    }

    // The commands available to the command palette.
    private var commandOptions: [CommandOption] {
        guard let surface = lastFocusedSurface.value?.surface else { return [] }

        var ptr: UnsafeMutablePointer<ghostty_command_s>? = nil
        var count: Int = 0
        ghostty_surface_commands(surface, &ptr, &count)
        guard let ptr else { return [] }

        let buffer = UnsafeBufferPointer(start: ptr, count: count)
        return Array(buffer).map { c in
            let action = String(cString: c.action)
            return CommandOption(
                title: String(cString: c.title),
                shortcut: ghostty.config.keyEquivalent(for: action)?.description
            ) {}
        }
    }

    @State var showingCommandPalette = false

    var body: some View {
        switch ghostty.readiness {
        case .loading:
            Text("Loading")
        case .error:
            ErrorView()
        case .ready:
            ZStack {
                VStack(spacing: 0) {
                    // If we're running in debug mode we show a warning so that users
                    // know that performance will be degraded.
                    if (Ghostty.info.mode == GHOSTTY_BUILD_MODE_DEBUG || Ghostty.info.mode == GHOSTTY_BUILD_MODE_RELEASE_SAFE) {
                        DebugBuildWarningView()
                    }

                    HStack {
                        Spacer()
                        Button("Command Palette") {
                            showingCommandPalette.toggle()
                        }
                        Spacer()
                    }
                    .background(Color(.windowBackgroundColor))
                    .frame(maxWidth: .infinity)

                    Ghostty.TerminalSplit(node: $viewModel.surfaceTree)
                        .environmentObject(ghostty)
                        .focused($focused)
                        .onAppear { self.focused = true }
                        .onChange(of: focusedSurface) { newValue in
                            // We want to keep track of our last focused surface so even if
                            // we lose focus we keep this set to the last non-nil value.
                            if newValue != nil {
                                lastFocusedSurface = .init(newValue)
                            }

                            self.delegate?.focusedSurfaceDidChange(to: newValue)
                        }
                        .onChange(of: title) { newValue in
                            self.delegate?.titleDidChange(to: newValue)
                        }
                        .onChange(of: pwdURL) { newValue in
                            self.delegate?.pwdDidChange(to: newValue)
                        }
                        .onChange(of: cellSize) { newValue in
                            guard let size = newValue else { return }
                            self.delegate?.cellSizeDidChange(to: size)
                        }
                        .onChange(of: viewModel.surfaceTree?.hashValue) { _ in
                            // This is funky, but its the best way I could think of to detect
                            // ANY CHANGE within the deeply nested surface tree -- detecting a change
                            // in the hash value.
                            self.delegate?.surfaceTreeDidChange()
                        }
                        .onChange(of: zoomedSplit) { newValue in
                            self.delegate?.zoomStateDidChange(to: newValue ?? false)
                        }
                }
                // Ignore safe area to extend up in to the titlebar region if we have the "hidden" titlebar style
                .ignoresSafeArea(.container, edges: ghostty.config.macosTitlebarStyle == "hidden" ? .top : [])

                if showingCommandPalette {
                    // The Palette View Itself
                    GeometryReader { geometry in
                        VStack {
                            Spacer().frame(height: geometry.size.height * 0.1)

                            CommandPaletteView(
                                isPresented: $showingCommandPalette,
                                backgroundColor: ghostty.config.backgroundColor,
                                options: commandOptions
                            )
                            .transition(
                                .move(edge: .top)
                                .combined(with: .opacity)
                                .animation(.spring(response: 0.4, dampingFraction: 0.8))
                            ) // Spring animation
                            .zIndex(1) // Ensure it's on top

                            Spacer()
                        }
                        .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
                    }
                }
            }
        }
    }
}

struct DebugBuildWarningView: View {
    @State private var isPopover = false

    var body: some View {
        HStack {
            Spacer()

            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.yellow)

            Text("You're running a debug build of Ghostty! Performance will be degraded.")
                .padding(.all, 8)
                .popover(isPresented: $isPopover, arrowEdge: .bottom) {
                    Text("""
                    Debug builds of Ghostty are very slow and you may experience
                    performance problems. Debug builds are only recommended during
                    development.
                    """)
                    .padding(.all)
                }

            Spacer()
        }
        .background(Color(.windowBackgroundColor))
        .frame(maxWidth: .infinity)
        .onTapGesture {
            isPopover = true
        }
    }
}
