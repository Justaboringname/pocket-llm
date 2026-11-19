import Foundation
import LLMCore
import Observation
import SwiftUI
import UIKit

/// Composition root: picks the real (device) or mock (simulator) backend and owns the
/// long-lived objects the UI uses, plus the little UI state that must outlive any one screen
/// (which sheet is open, downloads started from a card, keeping the screen awake).
///
/// - Device: ``LiveModelStore`` + `HubModelDownloader` (files in `Application Support/Models`)
///   and `MLXEngine`.
/// - Simulator: ``MockModelStore`` + ``MockEngine`` — MLX needs a real Metal GPU family, so the
///   simulator only explores the UI.
/// - DEBUG + `LLM_UI_DEMO=<scene>`: a seeded mock setup for screenshots (see `DemoScene`).
@Observable
@MainActor
final class AppEnvironment {
    enum Sheet: String, Identifiable {
        case models
        case settings
        var id: String { rawValue }
    }

    let store: any ModelStore
    let chat: ChatViewModel
    let safety: SafetyMonitor
    /// `true` in the simulator (mock store and engine).
    let usesMockBackend: Bool

    /// The sheet shown over the chat, if any.
    var sheet: Sheet?

    /// The chat is the root screen; `true` means no sheet covers it. Setting `true` dismisses
    /// any sheet (used by the self-test harness before it takes screenshots).
    var showsChat: Bool {
        get { sheet == nil }
        set { if newValue { sheet = nil } }
    }

    /// An error from an action that has no better place to show it (e.g. deleting files).
    var alertMessage: String?

    #if DEBUG
        /// The demo scene this environment was seeded for, if any.
        var demoScene: DemoScene?
    #endif

    /// Load the last used model automatically when the app becomes active. Off for the
    /// self-test (it loads its own model) and the demo scenes (they seed their own state).
    @ObservationIgnored private let loadsPreferredModelAutomatically: Bool
    @ObservationIgnored private var didAttemptAutomaticLoad = false
    /// The UI disabled the idle timer for a running download (and must re-enable it).
    @ObservationIgnored private var holdsIdleTimer = false

    init(
        store: any ModelStore, chat: ChatViewModel, safety: SafetyMonitor, usesMock: Bool,
        loadsPreferredModelAutomatically: Bool
    ) {
        self.store = store
        self.chat = chat
        self.safety = safety
        self.usesMockBackend = usesMock
        self.loadsPreferredModelAutomatically = loadsPreferredModelAutomatically
    }

    static func make() -> AppEnvironment {
        #if DEBUG
            if let scene = DemoScene.requested {
                return DemoScene.makeEnvironment(for: scene)
            }
        #endif

        let safety = SafetyMonitor()
        let persistence = conversationPersistence()

        #if targetEnvironment(simulator)
            let store: any ModelStore = MockModelStore()
            let engine: any InferenceEngine = MockEngine()
            let usesMock = true
        #else
            let store: any ModelStore
            do {
                let root = try AppDirectories.modelsRoot()
                let downloader = HubModelDownloader(
                    cacheDirectory: root.appending(path: "hub", directoryHint: .isDirectory))
                store = try LiveModelStore(rootDirectory: root, downloader: downloader)
            } catch {
                fatalError("Cannot prepare Application Support/Models: \(error)")
            }
            let engine: any InferenceEngine = MLXEngine()
            let usesMock = false
        #endif

        let chat = ChatViewModel(
            engine: engine, store: store, safety: safety, persistence: persistence)
        chat.restore()
        return AppEnvironment(
            store: store, chat: chat, safety: safety, usesMock: usesMock,
            loadsPreferredModelAutomatically: !isSelfTestRun)
    }

    private static var isSelfTestRun: Bool {
        #if SELFTEST
            return ProcessInfo.processInfo.environment["LLM_SELFTEST"]?.isEmpty == false
        #else
            return false
        #endif
    }

    /// The self-test keeps its conversation in a separate file so it never overwrites the
    /// user's chat.
    private static func conversationPersistence() -> (any ConversationPersisting)? {
        guard let file = try? AppDirectories.currentConversationFile() else { return nil }
        #if SELFTEST
            if ProcessInfo.processInfo.environment["LLM_SELFTEST"]?.isEmpty == false {
                return FileConversationStore(
                    fileURL: file.deletingLastPathComponent().appending(path: "selftest.json"))
            }
        #endif
        return FileConversationStore(fileURL: file)
    }

    // MARK: - Model actions
    //
    // Long-running work starts in unstructured tasks owned here, never in a view's `.task`, so
    // closing the Models sheet does not cancel a download or a load.

    /// Downloads `spec`. When no model is selected yet (first run), the new model is loaded
    /// right after the download completes.
    func download(_ spec: ModelSpec) {
        Task {
            do {
                try await store.download(spec)
            } catch {
                return  // The store reports failures in its state; cancellation is silent.
            }
            if chat.modelState == .noModel {
                use(spec)
            }
        }
    }

    func cancelDownload(_ spec: ModelSpec) {
        store.cancelDownload(spec)
    }

    /// Loads `spec` and makes it the current model.
    func use(_ spec: ModelSpec) {
        Task {
            try? await chat.loadModel(spec)  // Errors surface as `chat.lastError` / modelState.
        }
    }

    /// Deletes the files of `spec`, unloading it first if it is the current model.
    func delete(_ spec: ModelSpec) {
        Task {
            if chat.currentModel?.id == spec.id {
                await chat.clearModel()
            }
            do {
                try await store.delete(spec)
            } catch {
                alertMessage = error.localizedDescription
            }
        }
    }

    /// Free-space check before a download, with the same margin as ``LiveModelStore``.
    /// Returns `nil` when there is enough space (or the free space is unknown).
    func storageShortfall(for spec: ModelSpec) -> (required: Int64, available: Int64)? {
        guard let available = store.availableDiskBytes() else { return nil }
        let required =
            spec.downloadBytes + max(LiveModelStore.minimumFreeSpaceMargin, spec.downloadBytes / 20)
        return available < required ? (required, available) : nil
    }

    /// Memory fit as the UI should show it: for the model that is loaded (or loading), the fit
    /// measured when it was loaded — measuring again would count its own memory against it.
    func displayedFit(for spec: ModelSpec) -> MemoryFit {
        switch chat.modelState {
        case .ready(let current) where current.id == spec.id:
            return chat.currentModelFit ?? chat.memoryFit(for: spec)
        case .loading(let current, _) where current.id == spec.id:
            return chat.currentModelFit ?? .ok
        default:
            return chat.memoryFit(for: spec)
        }
    }

    var isDownloadRunning: Bool {
        store.catalog.contains { store.state(for: $0).isDownloading }
    }

    /// Models that are downloaded, in catalog order.
    var downloadedModels: [ModelSpec] {
        store.catalog.filter { store.state(for: $0).isDownloaded }
    }

    // MARK: - System events

    /// Maps the scene phase onto the chat. Leaving `.active` stops generation inside a
    /// background-task assertion so the GPU is idle before the app is suspended.
    func handleScenePhase(_ phase: ScenePhase) {
        let mapped: AppLifecyclePhase
        switch phase {
        case .active: mapped = .active
        case .inactive: mapped = .inactive
        case .background: mapped = .background
        @unknown default: mapped = .inactive
        }
        guard mapped != .active else {
            Task {
                await chat.handleLifecycle(.active)
                loadPreferredModelIfNeeded()
            }
            return
        }
        let assertion = BackgroundAssertion(name: "Finish GPU work")
        Task {
            await chat.handleLifecycle(mapped)
            assertion.end()
        }
    }

    func handleMemoryWarning() {
        Task { await chat.handleMemoryWarning() }
    }

    /// Keeps the screen awake while a download runs (downloads pause when the app leaves the
    /// foreground). Only undoes what it did itself, so it never fights the self-test harness.
    func updateIdleTimerForDownloads() {
        if isDownloadRunning, !holdsIdleTimer, !UIApplication.shared.isIdleTimerDisabled {
            holdsIdleTimer = true
            UIApplication.shared.isIdleTimerDisabled = true
        } else if !isDownloadRunning, holdsIdleTimer {
            holdsIdleTimer = false
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    /// Once per launch: reload the model of the restored conversation if it is still
    /// downloaded and fits.
    private func loadPreferredModelIfNeeded() {
        guard loadsPreferredModelAutomatically, !didAttemptAutomaticLoad else { return }
        didAttemptAutomaticLoad = true
        guard chat.modelState == .noModel, let id = chat.preferredModelID,
            let spec = store.catalog.first(where: { $0.id == id }),
            store.state(for: spec).isDownloaded,
            chat.memoryFit(for: spec).allowsLoading
        else { return }
        use(spec)
    }
}

/// Wraps `beginBackgroundTask` / `endBackgroundTask`.
@MainActor
final class BackgroundAssertion {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    init(name: String) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
