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

/// Which parts of each finished sentence a tab shows.
enum TranscriptMode {
    case both, japanese, english
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("selectedTab") private var selectedTab = 0 // remembered between launches
    @State private var showSettings = false
    @State private var translationConfig: TranslationSession.Configuration?

    var body: some View {
        NavigationStack {
            TabView(selection: $selectedTab) {
                TranscriptView(mode: .both)
                    .tabItem { Label("Both", systemImage: "rectangle.split.2x1") }
                    .tag(0)
                TranscriptView(mode: .japanese)
                    .tabItem { Label("Japanese", systemImage: "j.square") }
                    .tag(1)
                TranscriptView(mode: .english)
                    .tabItem { Label("English", systemImage: "e.square") }
                    .tag(2)
            }
            .navigationTitle("G2 Bridge")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(downloadTranslation: {
                translationConfig = TranslationSession.Configuration(
                    source: Locale.Language(identifier: "ja"),
                    target: Locale.Language(identifier: "en"))
            })
            .environmentObject(model)
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

/// The finished sentences, oldest first, scrolled to the newest.
struct TranscriptView: View {
    @EnvironmentObject var model: AppModel
    let mode: TranscriptMode

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if model.sentences.isEmpty {
                    VStack(spacing: 8) {
                        Text("Waiting for speech from the glasses app…").foregroundStyle(.secondary)
                        Text(model.status).font(.footnote).foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 80)
                } else {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(model.sentences) { sentence in
                            SentenceView(sentence: sentence, mode: mode)
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding()
                }
            }
            .onChange(of: model.sentences) { _, _ in
                withAnimation { proxy.scrollTo("end", anchor: .bottom) }
            }
        }
    }
}

struct SentenceView: View {
    let sentence: Sentence
    let mode: TranscriptMode

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if mode != .english {
                Text(sentence.japanese).font(mode == .both ? .title3 : .title2)
            }
            if mode != .japanese {
                Text(sentence.english ?? "…")
                    .font(mode == .both ? .body : .title2)
                    .foregroundStyle(mode == .both ? Color.secondary : Color.primary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let downloadTranslation: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section("Bridge") {
                    Text(model.status)
                    Toggle("Keep alive with silent audio", isOn: $model.audioKeepAlive)
                    Toggle("Keep alive with location", isOn: $model.locationKeepAlive)
                    Text("iOS freezes an app shortly after it leaves the screen unless it has a reason to run. Leave this app running while you use the glasses; it translates what the glasses app streams to 127.0.0.1:\(BridgeServer.port).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("Apple on-device models") {
                    Button("Download Japanese → English translation", action: downloadTranslation)
                }
                Section("Text") {
                    Button("Clear all sentences", role: .destructive) { model.clearSentences() }
                }
                Section("Log") {
                    ForEach(Array(model.lines.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(.footnote, design: .monospaced))
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
    }
}
