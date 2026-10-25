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

/// The conversation: finished sentences, oldest first, scrolled to the newest.
struct TranscriptView: View {
    @EnvironmentObject var model: AppModel
    let mode: TranscriptMode

    /// Each language tab is only what was translated into it: the Japanese tab your English translated
    /// to Japanese, the English tab the other person's Japanese translated to English.
    private var visible: [Sentence] {
        switch mode {
        case .both: return model.sentences
        case .japanese: return model.sentences.filter { $0.speaker == .me }
        case .english: return model.sentences.filter { $0.speaker == .them }
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if visible.isEmpty {
                    VStack(spacing: 8) {
                        Text("Waiting for speech…").foregroundStyle(.secondary)
                        Text(model.status).font(.footnote).foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 80)
                } else {
                    LazyVStack(spacing: 14) {
                        ForEach(visible) { sentence in
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

/// One sentence as a bubble: the other person's on the left, yours on the right.
struct SentenceView: View {
    let sentence: Sentence
    let mode: TranscriptMode

    private var mine: Bool { sentence.speaker == .me }

    var body: some View {
        VStack(alignment: mine ? .trailing : .leading, spacing: 4) {
            Text(mine ? "You" : "Them").font(.caption2).foregroundStyle(.secondary)
            switch mode {
            case .japanese:
                line(sentence.japanese, .title)
            case .english:
                line(sentence.english, .title2)
            case .both:
                // What was spoken first, its translation under it.
                line(mine ? sentence.english : sentence.japanese, .title3)
                line(mine ? sentence.japanese : sentence.english, .body, secondary: true)
            }
        }
        .padding(12)
        .background((mine ? Color.blue : Color.gray).opacity(0.15), in: RoundedRectangle(cornerRadius: 14))
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
        .textSelection(.enabled)
    }

    private func line(_ text: String?, _ font: Font, secondary: Bool = false) -> some View {
        Text(text ?? "…")
            .font(font)
            .foregroundStyle(secondary ? Color.secondary : Color.primary)
            .multilineTextAlignment(mine ? .trailing : .leading)
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let downloadTranslation: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section("Conversation") {
                    Text("The glasses app shows what the other person says, in English. Here, what you say in English is translated to Japanese for them to read (the Japanese tab, in large text, only what you said). The English tab is only what they said, translated to English. The Both tab has everything.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Toggle("Keep the screen on", isOn: $model.keepScreenOn)
                }
                Section("Bridge") {
                    Text(model.status)
                    Toggle("Keep alive with silent audio", isOn: $model.audioKeepAlive)
                    Toggle("Keep alive with location", isOn: $model.locationKeepAlive)
                    Text("iOS freezes an app shortly after it leaves the screen unless it has a reason to run. Leave this app running while you use the glasses; it translates what the glasses app streams to 127.0.0.1:\(BridgeServer.port).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("Apple on-device models") {
                    Button("Download Japanese and English translation", action: downloadTranslation)
                    Toggle("Translate with Apple's language model (experimental)", isOn: $model.useLanguageModel)
                    Text("Language model: \(ContextTranslator.statusText). It translates each sentence knowing the earlier lines (who is speaking about whom). It is slower than the plain translation, which shows first and is replaced when it arrives.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
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
