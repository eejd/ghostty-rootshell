import SwiftUI

struct CommandOption: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let description: String?
    let shortcut: String?
    let action: () -> Void

    static func == (lhs: CommandOption, rhs: CommandOption) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

struct CommandPaletteView: View {
    @Binding var isPresented: Bool
    var backgroundColor: Color = Color(nsColor: .windowBackgroundColor)
    var options: [CommandOption]
    @State private var query = ""
    @State private var selectedIndex: UInt?
    @State private var hoveredOptionID: UUID?

    // The options that we should show, taking into account any filtering from
    // the query.
    var filteredOptions: [CommandOption] {
        if query.isEmpty {
            return options
        } else {
            return options.filter { $0.title.localizedCaseInsensitiveContains(query) }
        }
    }

    var selectedOption: CommandOption? {
        guard let selectedIndex else { return nil }
        return if selectedIndex < filteredOptions.count {
            filteredOptions[Int(selectedIndex)]
        } else {
            filteredOptions.last
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CommandPaletteQuery(query: $query) { event in
                switch (event) {
                case .exit:
                    isPresented = false

                case .submit:
                    isPresented = false
                    selectedOption?.action()

                case .move(.up):
                    if filteredOptions.isEmpty { break }
                    let current = selectedIndex ?? UInt(filteredOptions.count)
                    selectedIndex = (current == 0)
                        ? UInt(filteredOptions.count - 1)
                        : current - 1

                case .move(.down):
                    if filteredOptions.isEmpty { break }
                    let current = selectedIndex ?? UInt.max
                    selectedIndex = (current >= UInt(filteredOptions.count - 1))
                        ? 0
                        : current + 1

                case .move(_):
                    // Unknown, ignore
                    break
                }
            }
            .onChange(of: query) { newValue in
                // If the user types a query then we want to make sure the first
                // value is selected. If the user clears the query and we were selecting
                // the first, we unset any selection.
                if !newValue.isEmpty {
                    if selectedIndex == nil {
                        selectedIndex = 0
                    }
                } else {
                    if let selectedIndex, selectedIndex == 0 {
                        self.selectedIndex = nil
                    }
                }
            }

            Divider()
                .padding(.bottom, 4)

            CommandTable(
                options: filteredOptions,
                selectedIndex: $selectedIndex,
                hoveredOptionID: $hoveredOptionID) { option in
                    isPresented = false
                    option.action()
            }
        }
        .frame(maxWidth: 500)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(backgroundColor)
                .shadow(color: .black.opacity(0.4), radius: 10, x: 0, y: 10)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.black.opacity(0.1), lineWidth: 1)
                )
        )
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
    var options: [CommandOption]
    @Binding var selectedIndex: UInt?
    @Binding var hoveredOptionID: UUID?
    var action: (CommandOption) -> Void

    var body: some View {
        if options.isEmpty {
            Text("No matches")
                .foregroundStyle(.secondary)
                .padding()
        } else {
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(options.enumerated()), id: \.1.id) { index, option in
                            CommandRow(
                                option: option,
                                isSelected: {
                                    if let selected = selectedIndex {
                                        return selected == index ||
                                            (selected >= options.count &&
                                                index == options.count - 1)
                                    } else {
                                        return false
                                    }
                                }(),
                                hoveredID: $hoveredOptionID
                            ) {
                                action(option)
                            }
                        }
                    }
                }
                .frame(maxHeight: 200)
                .onChange(of: selectedIndex) { _ in
                    guard let selectedIndex,
                          selectedIndex < options.count else { return }
                    proxy.scrollTo(
                        options[Int(selectedIndex)].id)
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
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text(option.title)
                Spacer()
                if let shortcut = option.shortcut {
                    Text(shortcut)
                        .font(.system(.body, design: .monospaced))
                        .kerning(1.5)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.gray.opacity(0.2))
                        )
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
        .help(option.description ?? "")
        .buttonStyle(PlainButtonStyle())
        .onHover { hovering in
            hoveredID = hovering ? option.id : nil
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
    }
}
