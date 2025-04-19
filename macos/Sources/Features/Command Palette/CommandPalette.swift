import SwiftUI

struct CommandOption: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let shortcut: String?
    let action: () -> Void

    static func == (lhs: CommandOption, rhs: CommandOption) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    // Sample data remains the same
    static let sampleData: [CommandOption] = [
        .init(title: "assistant: copy code", shortcut: nil, action: {}),
        .init(title: "assistant: inline assist", shortcut: "⌃⏎", action: {}),
        .init(title: "assistant: insert into editor", shortcut: "⌘<", action: {}),
        .init(title: "assistant: new chat", shortcut: nil, action: {}),
        .init(title: "assistant: open prompt library", shortcut: nil, action: {}),
        .init(title: "assistant: quote selection", shortcut: "⌘>", action: {}),
        .init(title: "assistant: show configuration", shortcut: nil, action: {}),
        .init(title: "assistant: toggle focus", shortcut: "⌘?", action: {}),
    ]
}

struct CommandPaletteView: View {
    @Binding var isPresented: Bool
    var backgroundColor: Color = Color(nsColor: .windowBackgroundColor)
    var options: [CommandOption] = CommandOption.sampleData
    @State private var query = ""
    @State private var selectedIndex: UInt = 0
    @State private var hoveredOptionID: UUID? = nil

    // The options that we should show, taking into account any filtering from
    // the query.
    var filteredOptions: [CommandOption] {
        if query.isEmpty {
            return options
        } else {
            return options.filter { $0.title.localizedCaseInsensitiveContains(query) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Prompt Field
            CommandPaletteQuery(query: $query) { event in
                switch (event) {
                case .exit:
                    isPresented = false

                case .submit:
                    isPresented = false

                case .move(.up):
                    if selectedIndex > 0 {
                        selectedIndex -= 1
                    }

                case .move(.down):
                    if selectedIndex < filteredOptions.count - 1 {
                        selectedIndex += 1
                    }

                case .move(_):
                    // Unknown, ignore
                    break
                }
            }

            Divider()
                .padding(.bottom, 4)

            CommandTable(
                options: options,
                query: $query,
                selectedIndex: $selectedIndex,
                hoveredOptionID: $hoveredOptionID)
        }
        .frame(width: 500)
        .background(backgroundColor)
        .cornerRadius(12)
        .shadow(radius: 20)
        .padding()
    }
}

/// The text field for building the query for the command palette.
fileprivate struct CommandPaletteQuery: View {
    @Binding var query: String
    var onEvent: ((KeyboardEvent) -> Void)? = nil
    @FocusState private var isTextFieldFocused: Bool

    enum KeyboardEvent {
        case exit
        case submit
        case move(MoveCommandDirection)
    }

    var body: some View {
        ZStack {
            Group {
                Button { onEvent?(.move(.up)) } label: { Color.clear }
                    .buttonStyle(PlainButtonStyle())
                    .keyboardShortcut(.upArrow, modifiers: [])
                Button { onEvent?(.move(.down)) } label: { Color.clear }
                    .buttonStyle(PlainButtonStyle())
                    .keyboardShortcut(.downArrow, modifiers: [])

                Button { onEvent?(.move(.up)) } label: { Color.clear }
                    .buttonStyle(PlainButtonStyle())
                    .keyboardShortcut(.init("p"), modifiers: [.control])
                Button { onEvent?(.move(.down)) } label: { Color.clear }
                    .buttonStyle(PlainButtonStyle())
                    .keyboardShortcut(.init("n"), modifiers: [.control])
            }
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)

            TextField("Execute a command…", text: $query)
                .padding()
                .font(.system(size: 14))
                .textFieldStyle(PlainTextFieldStyle())
                .focused($isTextFieldFocused)
                .onAppear {
                    isTextFieldFocused = true
                }
                .onChange(of: isTextFieldFocused) { focused in
                    if !focused {
                        onEvent?(.exit)
                    }
                }
                .onExitCommand { onEvent?(.exit) }
                .onMoveCommand { onEvent?(.move($0)) }
                .onSubmit { onEvent?(.submit) }
        }
    }
}

fileprivate struct CommandTable: View {
    var options: [CommandOption] = CommandOption.sampleData
    @Binding var query: String
    @Binding var selectedIndex: UInt
    @Binding var hoveredOptionID: UUID?

    // The options that we should show, taking into account any filtering from
    // the query.
    var filteredOptions: [CommandOption] {
        if query.isEmpty {
            return options
        } else {
            return options.filter { $0.title.localizedCaseInsensitiveContains(query) }
        }
    }

    var body: some View {
        if filteredOptions.isEmpty {
            Text("No matches")
                .foregroundStyle(.secondary)
                .padding()
        } else {
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(filteredOptions.enumerated()), id: \.1.id) { index, option in
                            CommandRow(
                                option: option,
                                isSelected: selectedIndex == index,
                                hoveredID: $hoveredOptionID
                            )
                        }
                    }
                }
                .frame(height: 200)
                .onChange(of: selectedIndex) { _ in
                    guard selectedIndex < filteredOptions.count else { return }
                    withAnimation {
                        proxy.scrollTo(
                            filteredOptions[Int(selectedIndex)].id,
                            anchor: .center)
                    }
                }
            }
        }
    }
}

/// A single row in the command palette.
fileprivate struct CommandRow: View {
    let option: CommandOption
    var isSelected: Bool
    @Binding var hoveredID: UUID?

    var body: some View {
        Button(action: option.action) {
            HStack {
                Text(option.title.lowercased())
                Spacer()
                if let shortcut = option.shortcut {
                    Text(shortcut)
                        .foregroundStyle(.secondary)
                        .font(.system(size: 12))
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 8)
            .background(
                isSelected
                    ? Color.accentColor.opacity(0.2)
                    : (hoveredID == option.id
                       ? Color.secondary.opacity(0.2)
                       : Color.clear)
            )
            .cornerRadius(6)
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { hovering in
            hoveredID = hovering ? option.id : nil
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
    }
}
