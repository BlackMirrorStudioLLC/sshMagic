import SwiftUI

/// Collects the username (and optional password) to connect to a host. Shown the
/// first time you connect to a host whose login isn't already known; after that
/// the remembered credentials connect you straight through.
struct ConnectSheet: View {
    let host: Host
    /// Called with the entered credentials. `password` is empty when the user
    /// wants to be prompted in the terminal instead.
    let onConnect: (_ username: String, _ password: String, _ remember: Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var username: String
    @State private var password = ""
    @State private var remember = true

    init(
        host: Host,
        defaultUsername: String,
        onConnect: @escaping (String, String, Bool) -> Void
    ) {
        self.host = host
        self.onConnect = onConnect
        _username = State(initialValue: defaultUsername)
    }

    private var trimmedUser: String { username.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Connect")
                    .font(.title2.bold())
                Text(host.displayName + (host.displayName == host.hostname ? "" : " · \(host.hostname)"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Form {
                TextField("Username", text: $username)
                SecureField("Password", text: $password)
                Toggle("Remember username & password", isOn: $remember)
            }
            .formStyle(.grouped)

            Text(
                password.isEmpty
                    ? "Leave the password blank to be prompted in the terminal."
                    : "The password is stored in your macOS Keychain."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Connect") {
                    onConnect(trimmedUser, password, remember)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedUser.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}
