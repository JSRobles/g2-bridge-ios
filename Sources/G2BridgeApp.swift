import SwiftUI
import Translation

@main
struct G2BridgeApp: App {
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .task { model.start() }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var translationConfig: TranslationSession.Configuration?

    var body: some View {
        NavigationStack {
            List {
                Section("Bridge") {
                    Text(model.status)
                    Toggle("Keep alive with silent audio", isOn: $model.audioKeepAlive)
                    Toggle("Keep alive with location", isOn: $model.locationKeepAlive)
                }
                Section("Apple on-device models") {
                    Button("Download Japanese → English translation") {
                        translationConfig = TranslationSession.Configuration(
                            source: Locale.Language(identifier: "ja"),
                            target: Locale.Language(identifier: "en"))
                    }
                    Text("Leave this app running while you use the glasses; it translates what the glasses app streams to 127.0.0.1:\(BridgeServer.port).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("Log") {
                    ForEach(Array(model.lines.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(.footnote, design: .monospaced))
                    }
                }
            }
            .navigationTitle("G2 Bridge")
        }
        // Shows Apple's download prompt for the translation languages the first time.
        .translationTask(translationConfig) { session in
            do {
                try await session.prepareTranslation()
                appLog("translation languages ready")
            } catch {
                appLog("translation download failed: \(error)")
            }
        }
    }
}
