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
    @StateObject private var tutorial = PLTutorialCoordinator()
    private let syncHeartbeat = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private let persistentContainer: ModelContainer
    private let guestContainer: ModelContainer
 
    init() {
        // ✅ Firebase boot
        FirebaseApp.configure()

        // ✅ Cloudflare Tunnel HTTPS hostname (replace with YOUR real domain)
        // Example final form: "https://api.paperlink.benchen.com"
        PaperLinkSyncManager.shared.configure(serverBaseURL: "https://paperlink.benchen.io")

        persistentContainer = PaperlinkApp.makePersistentModelContainer()
        guestContainer = PaperlinkApp.makeGuestModelContainer()
    }

    private static func makePersistentModelContainer() -> ModelContainer {
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

    private static func makeGuestModelContainer() -> ModelContainer {
        do {
            let inMemoryConfig = ModelConfiguration(isStoredInMemoryOnly: true)
            return try ModelContainer(
                for: PLFolder.self, PLNote.self, PLPendingUpload.self,
                configurations: inMemoryConfig
            )
        } catch {
            fatalError("Failed to create in-memory guest SwiftData container: \(error)")
        }
    }

    private var activeContainer: ModelContainer {
        auth.isGuestSession ? guestContainer : persistentContainer
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(theme)
                .environmentObject(auth)
                .environmentObject(network)
                .environmentObject(tutorial)
                .modelContainer(activeContainer)   // ✅ attach at view root
                .onOpenURL { url in
                    // ✅ Required to complete Google Sign-In flow
                    GIDSignIn.sharedInstance.handle(url)
                }
                .onAppear {
                    PaperLinkSyncManager.shared.setCloudSyncEnabled(auth.canUseCloudSync)
                    guard auth.canUseCloudSync else { return }
                    Task { @MainActor in
                        let ctx = activeContainer.mainContext
                        await PaperLinkSyncManager.shared.runSyncCycle(
                            ctx: ctx,
                            allowUpload: network.isOnline,
                            forceFullSync: true
                        )
                    }
                }
                .onChange(of: network.isOnline) { _, online in
                    PaperLinkSyncManager.shared.setCloudSyncEnabled(auth.canUseCloudSync)
                    guard online else { return }
                    guard auth.canUseCloudSync else { return }
                    Task { @MainActor in
                        let ctx = activeContainer.mainContext
                        await PaperLinkSyncManager.shared.runSyncCycle(
                            ctx: ctx,
                            allowUpload: true,
                            forceFullSync: true
                        )
                    }
                }
                .onChange(of: auth.canUseCloudSync) { _, canUseCloudSync in
                    PaperLinkSyncManager.shared.setCloudSyncEnabled(canUseCloudSync)
                    guard canUseCloudSync else { return }
                    Task { @MainActor in
                        let ctx = activeContainer.mainContext
                        await PaperLinkSyncManager.shared.runSyncCycle(
                            ctx: ctx,
                            allowUpload: network.isOnline,
                            forceFullSync: true
                        )
                    }
                }
                .onChange(of: scenePhase) { _, newPhase in
                    guard newPhase == .active else { return }
                    PaperLinkSyncManager.shared.setCloudSyncEnabled(auth.canUseCloudSync)
                    guard auth.canUseCloudSync else { return }
                    Task { @MainActor in
                        let ctx = activeContainer.mainContext
                        await PaperLinkSyncManager.shared.runSyncCycle(
                            ctx: ctx,
                            allowUpload: network.isOnline,
                            forceFullSync: true
                        )
                    }
                }
                .onReceive(syncHeartbeat) { _ in
                    guard scenePhase == .active else { return }
                    PaperLinkSyncManager.shared.setCloudSyncEnabled(auth.canUseCloudSync)
                    guard auth.canUseCloudSync else { return }
                    Task { @MainActor in
                        let ctx = activeContainer.mainContext
                        await PaperLinkSyncManager.shared.runSyncCycle(
                            ctx: ctx,
                            allowUpload: network.isOnline
                        )
                    }
                }
        }
    }
}
