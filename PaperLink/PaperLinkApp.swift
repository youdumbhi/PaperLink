import SwiftUI
import SwiftData
import Combine
import FirebaseCore
import FirebaseAuth
import GoogleSignIn

@main
struct PaperlinkApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var theme = PLThemeStore()
    @StateObject private var auth = PLAuthStore()
    @StateObject private var network = NetworkMonitor()
    private let syncHeartbeat = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    // ✅ single, shared container instance
    private let container: ModelContainer = PaperlinkApp.makeModelContainer()
 
    init() {
        // ✅ Firebase boot
        FirebaseApp.configure()

        // ✅ Cloudflare Tunnel HTTPS hostname (replace with YOUR real domain)
        // Example final form: "https://api.paperlink.benchen.com"
        PaperLinkSyncManager.shared.configure(serverBaseURL: "https://paperlink.benchen.io")
    }

    private static func makeModelContainer() -> ModelContainer {
        do {
            return try ModelContainer(for: PLFolder.self, PLNote.self, PLPendingUpload.self)
        } catch {
            print("SwiftData load failed on first attempt: \(error)")

            // Last-resort fallback: keep app usable instead of crashing.
            do {
                let inMemoryConfig = ModelConfiguration(isStoredInMemoryOnly: true)
                return try ModelContainer(
                    for: PLFolder.self, PLNote.self, PLPendingUpload.self,
                    configurations: inMemoryConfig
                )
            } catch {
                fatalError("Failed to create SwiftData container (persistent + in-memory): \(error)")
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(theme)
                .environmentObject(auth)
                .environmentObject(network)
                .modelContainer(container)   // ✅ attach at view root
                .onOpenURL { url in
                    // ✅ Required to complete Google Sign-In flow
                    GIDSignIn.sharedInstance.handle(url)
                }
                .onAppear {
                    guard auth.isSignedIn else { return }
                    Task { @MainActor in
                        let ctx = container.mainContext
                        await PaperLinkSyncManager.shared.runSyncCycle(
                            ctx: ctx,
                            allowUpload: network.isOnline,
                            forceFullSync: true
                        )
                    }
                }
                .onChange(of: network.isOnline) { _, online in
                    guard online else { return }
                    guard auth.isSignedIn else { return }
                    Task { @MainActor in
                        let ctx = container.mainContext
                        await PaperLinkSyncManager.shared.runSyncCycle(
                            ctx: ctx,
                            allowUpload: true,
                            forceFullSync: true
                        )
                    }
                }
                .onChange(of: auth.isSignedIn) { _, signedIn in
                    guard signedIn else { return }
                    Task { @MainActor in
                        let ctx = container.mainContext
                        await PaperLinkSyncManager.shared.runSyncCycle(
                            ctx: ctx,
                            allowUpload: network.isOnline,
                            forceFullSync: true
                        )
                    }
                }
                .onChange(of: scenePhase) { _, newPhase in
                    guard newPhase == .active else { return }
                    guard auth.isSignedIn else { return }
                    Task { @MainActor in
                        let ctx = container.mainContext
                        await PaperLinkSyncManager.shared.runSyncCycle(
                            ctx: ctx,
                            allowUpload: network.isOnline,
                            forceFullSync: true
                        )
                    }
                }
                .onReceive(syncHeartbeat) { _ in
                    guard scenePhase == .active else { return }
                    guard auth.isSignedIn else { return }
                    Task { @MainActor in
                        let ctx = container.mainContext
                        await PaperLinkSyncManager.shared.runSyncCycle(
                            ctx: ctx,
                            allowUpload: network.isOnline
                        )
                    }
                }
        }
    }
}
