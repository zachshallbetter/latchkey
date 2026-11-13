#if !LATCHKEY_APP_STORE
import Combine
import Sparkle
import SwiftUI

/// Automatic updates for the direct download, through Sparkle. The App Store build updates through the App Store and
/// compiles none of this. Without a public key in the build (SPARKLE_PUBLIC_KEY in App/project.yml) it never starts.
@MainActor
final class AppUpdater: ObservableObject {
    static let shared = AppUpdater()

    let controller: SPUStandardUpdaterController?
    @Published private(set) var canCheck = false
    private var observation: AnyCancellable?

    private init() {
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        guard let key, !key.trimmingCharacters(in: .whitespaces).isEmpty else {
            #if DEBUG
            print("Updater not started: SUPublicEDKey is empty (set SPARKLE_PUBLIC_KEY in App/project.yml).")
            #endif
            controller = nil
            return
        }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        observation = controller.updater.publisher(for: \.canCheckForUpdates).sink { [weak self] in self?.canCheck = $0 }
    }

    func checkForUpdates() { controller?.checkForUpdates(nil) }
}

/// "Check for Updates…" in the app menu; disabled while a check runs or when the updater isn't running.
struct CheckForUpdatesButton: View {
    @ObservedObject var updater: AppUpdater

    var body: some View {
        Button("Check for Updates…") { updater.checkForUpdates() }.disabled(!updater.canCheck)
    }
}
#endif
