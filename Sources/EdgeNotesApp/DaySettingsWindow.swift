import AppKit
import SwiftUI
import EdgeNotesCore

/// Lets the user enter the Day base URL and API token, test the
/// connection, and save. The token is written only to `DayKeychain`; the
/// URL is written to `DaySettings` (UserDefaults). Saving posts
/// `.dayCredentialsChanged` — this task does not react to it beyond that.
@MainActor
final class DaySettingsWindowController {
    private var window: NSWindow?

    init() {}

    func show() {
        if window == nil {
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 220),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered, defer: false)
            win.title = "Day Settings"
            win.center()
            win.isReleasedWhenClosed = false
            win.contentView = NSHostingView(rootView: DaySettingsView())
            window = win
        } else {
            // Reflect whatever is currently persisted each time the window
            // is reopened, rather than whatever was last typed.
            window?.contentView = NSHostingView(rootView: DaySettingsView())
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

private enum ConnectionTestResult {
    case success(columns: Int)
    case failure(String)

    var text: String {
        switch self {
        case .success(let columns): return "Connected — \(columns) column\(columns == 1 ? "" : "s")"
        case .failure(let message): return message
        }
    }

    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}

private struct DaySettingsView: View {
    @State private var baseURLText: String
    @State private var token: String
    @State private var testResult: ConnectionTestResult?
    @State private var isTesting = false

    init() {
        _baseURLText = State(initialValue: DaySettings.baseURL?.absoluteString ?? "")
        _token = State(initialValue: DayKeychain.readToken() ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Day Settings")
                .font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Text("Base URL")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("https://day.example.com", text: $baseURLText)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("API Token")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                SecureField("Token", text: $token)
                    .textFieldStyle(.roundedBorder)
            }

            if let testResult {
                Text(testResult.text)
                    .font(.caption)
                    .foregroundStyle(testResult.isSuccess ? .green : .red)
                    .lineLimit(2)
            }

            Spacer()

            HStack {
                Button("Test Connection") {
                    testConnection()
                }
                .disabled(isTesting || isBlank(baseURLText) || isBlank(token))

                Spacer()

                Button("Save") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isBlank(baseURLText) || isBlank(token))
            }
        }
        .padding(16)
        .frame(width: 460, height: 220)
    }

    private var trimmedToken: String {
        token.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Parses `baseURLText` (trimmed) into a URL, requiring an http/https
    /// scheme and a host so a bare hostname like "day.example.com" — which
    /// `URL(string:)` accepts but which fails only much later, as an opaque
    /// network error — is rejected here with a message that names the
    /// actual problem.
    private func parseBaseURL() -> (url: URL?, errorMessage: String?) {
        let trimmed = baseURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else {
            return (nil, "Invalid URL")
        }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return (nil, "URL must start with http:// or https://")
        }
        guard let host = url.host, !host.isEmpty else {
            return (nil, "URL is missing a host")
        }
        return (url, nil)
    }

    private func testConnection() {
        let parsed = parseBaseURL()
        guard let url = parsed.url else {
            testResult = .failure(parsed.errorMessage ?? "Invalid URL")
            return
        }
        let credentials = DayCredentials(baseURL: url, token: trimmedToken)
        isTesting = true
        testResult = nil
        Task {
            let client = DayClient(credentials: credentials)
            do {
                let board = try await client.board(sprintID: nil)
                testResult = .success(columns: board.columns.count)
            } catch {
                testResult = .failure((error as? DayError)?.userFacingMessage ?? "Connection failed")
            }
            isTesting = false
        }
    }

    private func save() {
        let parsed = parseBaseURL()
        guard let url = parsed.url else {
            testResult = .failure(parsed.errorMessage ?? "Invalid URL")
            return
        }
        let tokenToSave = trimmedToken
        guard DayKeychain.writeToken(tokenToSave) else {
            testResult = .failure("Could not save the token to the Keychain — try again")
            return
        }
        DaySettings.baseURL = url
        testResult = nil
        NotificationCenter.default.post(name: .dayCredentialsChanged, object: nil)
    }
}
