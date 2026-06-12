import SwiftUI

/// Minimal "add a host by hand" form for endpoints that discovery won't find
/// (off-subnet boxes, jump targets, anything you reach by DNS name).
struct AddHostSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onAdd: (Host) -> Void

    @State private var hostname = ""
    @State private var port = "22"
    @State private var username = ""
    @State private var displayName = ""

    private var isValid: Bool {
        !hostname.trimmingCharacters(in: .whitespaces).isEmpty && Int(port) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Host")
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
                Button("Add & Connect") {
                    let host = Host(
                        hostname: hostname.trimmingCharacters(in: .whitespaces),
                        port: Int(port) ?? 22,
                        displayName: displayName.isEmpty ? nil : displayName,
                        username: username.isEmpty ? nil : username,
                        source: .manual
                    )
                    onAdd(host)
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
