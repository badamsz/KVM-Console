import KVMKit
import SwiftUI

/// The key combination entries of a Send Keys menu: the user's own, then a
/// submenu of built-in ones for each operating system. Used by the console
/// toolbar and by Console > Send Keys in the menu bar.
struct KeyComboMenuItems: View {
    let send: (KeyComboItem) -> Void
    private var custom: CustomKeyCombos { .shared }

    var body: some View {
        if !custom.items.isEmpty {
            Section("My Key Combos") {
                ForEach(custom.items) { item in
                    Button(item.menuTitle) { send(item) }
                }
            }
        }
        ForEach(TargetOS.allCases) { os in
            Menu(os.displayName) {
                KeyComboLibraryMenu(os: os, action: send)
            }
        }
    }
}

/// The built-in combinations for one operating system, in titled sections.
struct KeyComboLibraryMenu: View {
    let os: TargetOS
    let action: (KeyComboItem) -> Void

    var body: some View {
        ForEach(KeyComboLibrary.groups(for: os)) { group in
            Section(group.title) {
                ForEach(group.items) { item in
                    Button(item.menuTitle) { action(item) }
                }
            }
        }
    }
}

/// Lists, adds, edits, reorders and deletes the user's own key combinations.
/// Shown in Settings and as a sheet over a console.
struct KeyCombosEditorView: View {
    /// Shows a Done button, for use in a sheet.
    var onDone: (() -> Void)?

    private var store: CustomKeyCombos { .shared }
    @State private var selection = Set<UUID>()
    @State private var editing: KeyComboItem?

    init(onDone: (() -> Void)? = nil) {
        self.onDone = onDone
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Your key combinations appear at the top of the **Send Keys** menu in the console toolbar, and under **Console > Send Keys**. Built-in ones for Windows, macOS and Linux are in the same menus.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            List(selection: $selection) {
                ForEach(store.items) { item in
                    HStack {
                        Text(item.name.isEmpty ? "Untitled" : item.name)
                            .foregroundStyle(item.name.isEmpty ? .secondary : .primary)
                        Spacer()
                        Text(item.keysLabel ?? item.keys)
                            .foregroundStyle(item.keysLabel == nil ? .red : .secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .tag(item.id)
                }
                .onMove { store.move(from: $0, to: $1) }
            }
            .contextMenu(forSelectionType: UUID.self) { ids in
                if ids.count == 1, let item = store.items.first(where: { ids.contains($0.id) }) {
                    Button("Edit…") { editing = item }
                    Button("Duplicate") { store.upsert(item.copy()) }
                }
                if !ids.isEmpty {
                    Button("Delete", role: .destructive) { store.remove(ids) }
                }
            } primaryAction: { ids in
                if ids.count == 1, let item = store.items.first(where: { ids.contains($0.id) }) { editing = item }
            }
            .onDeleteCommand { store.remove(selection) }
            .overlay {
                if store.items.isEmpty {
                    ContentUnavailableView {
                        Label("No Key Combos", systemImage: "keyboard")
                    } description: {
                        Text("Press + to make one, or add one from the library and change it.")
                    }
                }
            }
            .frame(minHeight: 220)

            HStack(spacing: 8) {
                Button {
                    editing = KeyComboItem(name: "", keys: "")
                } label: {
                    Image(systemName: "plus")
                }
                .help("New key combination")
                Button {
                    store.remove(selection)
                    selection = []
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(selection.isEmpty)
                .help("Delete the selected key combinations")
                Button("Edit…") {
                    if let item = store.items.first(where: { selection.contains($0.id) }) { editing = item }
                }
                .disabled(selection.count != 1)
                Menu("Add from Library") {
                    ForEach(TargetOS.allCases) { os in
                        Menu(os.displayName) {
                            KeyComboLibraryMenu(os: os) { store.upsert($0.copy()) }
                        }
                    }
                }
                .fixedSize()
                Spacer()
                if let onDone {
                    Button("Done", action: onDone)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding()
        .sheet(item: $editing) { item in
            KeyComboEditSheet(item: item) { store.upsert($0) }
        }
    }
}

/// Edits one key combination, checking the keys as they're typed.
struct KeyComboEditSheet: View {
    let onSave: (KeyComboItem) -> Void
    @State private var item: KeyComboItem
    @Environment(\.dismiss) private var dismiss

    init(item: KeyComboItem, onSave: @escaping (KeyComboItem) -> Void) {
        self.onSave = onSave
        _item = State(initialValue: item)
    }

    private var parsed: Result<[[String]], Error> {
        Result { try item.steps() }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Form {
                TextField("Name", text: $item.name, prompt: Text("Enter BIOS Setup"))
                TextField("Keys", text: $item.keys, prompt: Text("ctrl+alt+delete"))
                    .font(.body.monospaced())
                    .autocorrectionDisabled()
                Picker("Labels for", selection: $item.os) {
                    Text("Any System").tag(TargetOS?.none)
                    ForEach(TargetOS.allCases) { Text($0.displayName).tag(Optional($0)) }
                }
                LabeledContent("Sends") {
                    switch parsed {
                    case .success(let steps):
                        Text(KeyComboLabel.label(steps, os: item.os))
                            .textSelection(.enabled)
                    case .failure(let error):
                        Text(item.keys.trimmingCharacters(in: .whitespaces).isEmpty
                             ? "Type the keys to press." : error.localizedDescription)
                            .foregroundStyle(item.keys.trimmingCharacters(in: .whitespaces).isEmpty ? Color.secondary : Color.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if case .success(let steps) = parsed, steps.count > 1 {
                    LabeledContent("Pause between steps") {
                        HStack {
                            Slider(value: $item.stepDelay, in: KeyComboItem.stepDelayRange, step: 0.05)
                                .frame(width: 160)
                            Text(String(format: "%.2f s", item.stepDelay))
                                .monospacedDigit()
                                .frame(width: 56, alignment: .trailing)
                        }
                    }
                }
            }
            .formStyle(.grouped)

            VStack(alignment: .leading, spacing: 4) {
                Text("Join keys with +, modifiers first: **ctrl+alt+delete**, **win+l**, **cmd+opt+esc**, **ctrl+alt+f2**.")
                Text("Separate steps with commas to press them one after another: **alt+sysrq+s, alt+sysrq+b**.")
                Text("Key names: ctrl, alt (option), shift, win (cmd, super), enter, esc, tab, space, backspace, delete, up, down, left, right, home, end, pageup, pagedown, f1–f12, sysrq (print screen), a–z, 0–9, and punctuation such as / or comma.")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    var saved = item
                    saved.name = saved.name.trimmingCharacters(in: .whitespaces)
                    saved.keys = saved.keys.trimmingCharacters(in: .whitespaces)
                    onSave(saved)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled((try? item.steps()) == nil)
            }
            .padding([.horizontal, .bottom])
        }
        .frame(width: 520)
    }
}
