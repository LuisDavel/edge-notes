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
                .disabled(isTesting || baseURLText.isEmpty || token.isEmpty)

                Spacer()

                Button("Save") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(baseURLText.isEmpty || token.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 460, height: 220)
    }

    private func testConnection() {
        guard let url = URL(string: baseURLText) else {
            testResult = .failure("Invalid URL")
            return
        }
        let credentials = DayCredentials(baseURL: url, token: token)
        isTesting = true
        testResult = nil
        Task {
            let client = DayClient(credentials: credentials)
            do {
                let board = try await client.board(sprintID: nil)
                testResult = .success(columns: board.columns.count)
            } catch {
                testResult = .failure(Self.message(for: error))
            }
            isTesting = false
        }
    }

    private func save() {
        guard let url = URL(string: baseURLText) else {
            testResult = .failure("Invalid URL")
            return
        }
        DaySettings.baseURL = url
        DayKeychain.writeToken(token)
        NotificationCenter.default.post(name: .dayCredentialsChanged, object: nil)
    }

    private static func message(for error: Error) -> String {
        guard let dayError = error as? DayError else {
            return "Connection failed"
        }
        switch dayError {
        case .unauthorized: return "Unauthorized — check the token"
        case .forbidden: return "Forbidden — token lacks access"
        case .notFound: return "Not found — check the URL"
        case .server(let status, let message):
            return message.isEmpty ? "Server error (\(status))" : "Server error (\(status)): \(message)"
        case .offline: return "Offline — could not reach the server"
        case .decoding: return "Unexpected response from server"
        }
    }
}
