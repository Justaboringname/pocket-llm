import LLMCore
import SwiftUI
import UIKit

@main
struct LLMOnIPhoneApp: App {
    @State private var environment = AppEnvironment.make()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView(environment: environment)
                .onReceive(
                    NotificationCenter.default.publisher(
                        for: UIApplication.didReceiveMemoryWarningNotification)
                ) { _ in
                    environment.handleMemoryWarning()
                }
                #if SELFTEST
                    .task {
                        await SelfTestRunner.runIfRequested(environment: environment)
                    }
                #endif
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            environment.handleScenePhase(phase)
        }
    }
}
