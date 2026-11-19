import LLMCore
import SwiftUI

/// Chat is home; Models and Settings are sheets over it.
struct RootView: View {
    @Bindable var environment: AppEnvironment

    var body: some View {
        NavigationStack {
            ChatScreen(environment: environment)
        }
        .tint(Theme.accent)
        .sheet(item: $environment.sheet) { sheet in
            Group {
                switch sheet {
                case .models: ModelsScreen(environment: environment)
                case .settings: SettingsScreen(environment: environment)
                }
            }
            // Neutral tint in sheets (Done, pickers, sliders); accents are set explicitly.
            .tint(Theme.textPrimary)
            .safeLinkHandling()
            .presentationBackground(Theme.groupedBackground)
        }
        .alert(
            Text("Something went wrong"),
            isPresented: Binding(
                get: { environment.alertMessage != nil },
                set: { if !$0 { environment.alertMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(environment.alertMessage ?? "")
        }
        .safeLinkHandling()
        .onChange(of: environment.isDownloadRunning, initial: true) {
            environment.updateIdleTimerForDownloads()
        }
    }
}
