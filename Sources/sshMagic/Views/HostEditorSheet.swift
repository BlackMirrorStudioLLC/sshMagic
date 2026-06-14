import SwiftUI

/// Form for adding a host by hand, or editing a saved one. Covers endpoints
/// discovery won't find (off-subnet boxes, jump targets, DNS names) and lets you
/// change a saved connection's details.
struct HostEditorSheet: View {
    /// The host being edited, or nil when adding a new one.
    let editing: Host?
    let onSave: (Host) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var hostname: String
    @State private var port: String
    @State private var username: String
    @State private var displayName: String

    init(editing: Host? = nil, onSave: @escaping (Host) -> Void) {
        self.editing = editing
        self.onSave = onSave
        _hostname = State(initialValue: editing?.hostname ?? "")
        _port = State(initialValue: editing.map { String($0.port) } ?? "22")
        _username = State(initialValue: editing?.username ?? "")
        // Only pre-fill the display name if it's a custom label (not just the host).
        let label = editing.flatMap { $0.displayName == $0.hostname ? nil : $0.displayName }
        _displayName = State(initialValue: label ?? "")
    }

    private var isEditing: Bool { editing != nil }

    private var isValid: Bool {
        !hostname.trimmingCharacters(in: .whitespaces).isEmpty && Int(port) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isEditing ? "Edit Host" : "Add Host")
                .font(.title2.bold())

            Form {
                TextField("Hostname or IP", text: $hostname)
                TextField("Port", text: $port)
                TextField("Username (optional)", text: $username)
                TextField("Display name (optional)", text: $displayName)
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isEditing ? "Save" : "Add & Connect") {
                    let host = Host(
                        hostname: hostname.trimmingCharacters(in: .whitespaces),
                        port: Int(port) ?? 22,
                        displayName: displayName.isEmpty ? nil : displayName,
                        username: username.isEmpty ? nil : username,
                        source: .manual
                    )
                    onSave(host)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
