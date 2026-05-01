//
//  RootView.swift
//  PaperLink
//
//  ✅ Root-level fixes applied:
//  - iPhone: left rail is an OVERLAY drawer (does not push content)
//  - iPad: rail can be docked when open
//  - Single stable menu button (hamburger <-> X)
//  - ✅ FIX: rail top reserved space increased so X never overlaps first rail button
//  - ✅ FIX: selecting any rail item auto-closes the sidebar on iPhone
//
//  ✅ NEW:
//  - Shows a Sign in with Google screen BEFORE the library UI
//  - Auth state persists; auto-enters app if already signed in
//  - Adds NetworkMonitor (we'll use it later for offline restrictions)
//

import SwiftUI
import SwiftData
import Combine
import FirebaseAuth
import FirebaseCore
import GoogleSignIn
import Network
import LocalAuthentication

enum PLRailTab: String, CaseIterable {
    case library
    case folders
    case info
    case trash
    case settings
}

// MARK: - Theme

enum PLTheme: String, CaseIterable, Identifiable {
    case freeform = "Freeform"
    case classic = "Classic"
    case dusk = "Dusk"
    case mint = "Mint"
    case graphite = "Graphite"

    var id: String { rawValue }
}

struct PLThemePalette {
    let background: Color
    let canvas: Color
    let accent: Color
    let railButton: Color
    let card: Color
    let textPrimary: Color
    let textSecondary: Color
    let danger: Color
    let outline: Color
}

private struct PLDockedSidebarInsetKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    var plDockedSidebarInset: CGFloat {
        get { self[PLDockedSidebarInsetKey.self] }
        set { self[PLDockedSidebarInsetKey.self] = newValue }
    }
}

final class PLThemeStore: ObservableObject {
    @AppStorage("pl_theme") private var storedThemeRaw: String = PLTheme.freeform.rawValue

    @Published var theme: PLTheme = .freeform {
        didSet { storedThemeRaw = theme.rawValue }
    }

    init() {
        if storedThemeRaw == PLTheme.classic.rawValue {
            storedThemeRaw = PLTheme.freeform.rawValue
        }
        self.theme = PLTheme(rawValue: storedThemeRaw) ?? .freeform
    }

    var palette: PLThemePalette {
        switch theme {
        case .freeform:
            // Inferred from Apple Freeform's official screenshots: paper-white canvas,
            // subtly cooler UI surfaces, soft gray outlines, restrained blue accent.
            return PLThemePalette(
                background: Color(red: 0.95, green: 0.96, blue: 0.97),
                canvas: Color(red: 0.99, green: 0.99, blue: 1.00),
                accent: Color(red: 0.20, green: 0.49, blue: 0.92),
                railButton: Color(red: 0.98, green: 0.98, blue: 0.99),
                card: Color(red: 0.97, green: 0.98, blue: 0.99),
                textPrimary: Color(red: 0.15, green: 0.16, blue: 0.18),
                textSecondary: Color(red: 0.41, green: 0.44, blue: 0.49),
                danger: Color(red: 0.84, green: 0.27, blue: 0.24),
                outline: Color.black.opacity(0.07)
            )

        case .classic:
            return PLThemePalette(
                background: Color(red: 0.90, green: 0.79, blue: 0.66),
                canvas: Color(red: 0.97, green: 0.94, blue: 0.89),
                accent: Color(red: 0.17, green: 0.48, blue: 0.49),
                railButton: Color(red: 0.99, green: 0.97, blue: 0.94),
                card: Color(red: 0.98, green: 0.96, blue: 0.92),
                textPrimary: Color(red: 0.11, green: 0.10, blue: 0.09),
                textSecondary: Color(red: 0.33, green: 0.28, blue: 0.24),
                danger: Color(red: 0.75, green: 0.20, blue: 0.16),
                outline: Color(red: 0.15, green: 0.12, blue: 0.10).opacity(0.12)
            )

        case .dusk:
            return PLThemePalette(
                background: Color(red: 0.13, green: 0.12, blue: 0.11),
                canvas: Color(red: 0.19, green: 0.17, blue: 0.16),
                accent: Color(red: 0.82, green: 0.64, blue: 0.33),
                railButton: Color.white.opacity(0.08),
                card: Color.white.opacity(0.05),
                textPrimary: Color.white.opacity(0.92),
                textSecondary: Color.white.opacity(0.68),
                danger: Color.red.opacity(0.90),
                outline: Color.white.opacity(0.10)
            )

        case .mint:
            return PLThemePalette(
                background: Color(red: 0.80, green: 0.92, blue: 0.88),
                canvas: Color(red: 0.92, green: 0.97, blue: 0.94),
                accent: Color(red: 0.11, green: 0.50, blue: 0.41),
                railButton: Color(red: 0.98, green: 1.00, blue: 0.99),
                card: Color(red: 0.94, green: 0.98, blue: 0.96),
                textPrimary: Color(red: 0.10, green: 0.16, blue: 0.14),
                textSecondary: Color(red: 0.28, green: 0.36, blue: 0.33),
                danger: Color(red: 0.76, green: 0.20, blue: 0.18),
                outline: Color(red: 0.09, green: 0.15, blue: 0.13).opacity(0.10)
            )

        case .graphite:
            return PLThemePalette(
                background: Color(red: 0.14, green: 0.15, blue: 0.16),
                canvas: Color(red: 0.20, green: 0.21, blue: 0.23),
                accent: Color(red: 0.31, green: 0.68, blue: 0.72),
                railButton: Color.white.opacity(0.08),
                card: Color.white.opacity(0.05),
                textPrimary: Color.white.opacity(0.92),
                textSecondary: Color.white.opacity(0.68),
                danger: Color.red.opacity(0.90),
                outline: Color.white.opacity(0.10)
            )
        }
    }
}

// MARK: - Network Monitor (for offline mode later)

final class NetworkMonitor: ObservableObject {
    @Published private(set) var isOnline: Bool = true

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "pl.network.monitor")

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.isOnline = (path.status == .satisfied)
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }
}

// MARK: - Auth Store

@MainActor
final class PLAuthStore: ObservableObject {
    @Published private(set) var user: FirebaseAuth.User? = nil
    @Published private(set) var isBooting: Bool = true
    @Published var isSigningIn: Bool = false
    @Published var lastErrorMessage: String? = nil

    private var authHandle: AuthStateDidChangeListenerHandle?

    init() {
        authHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            guard let self else { return }
            self.user = user
            self.isBooting = false
        }
    }

    var isSignedIn: Bool { user != nil }

    func signOut() {
        do {
            try Auth.auth().signOut()
            GIDSignIn.sharedInstance.signOut()
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func signInWithGoogle() async {
        lastErrorMessage = nil
        isSigningIn = true
        defer { isSigningIn = false }

        guard let clientID = FirebaseApp.app()?.options.clientID else {
            lastErrorMessage = "Missing Firebase clientID. Check GoogleService-Info.plist."
            return
        }

        guard let rootVC = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
            .first(where: { $0.isKeyWindow })?.rootViewController else {
            lastErrorMessage = "Unable to find a root view controller."
            return
        }

        // ✅ Newer GoogleSignIn: set configuration here (NOT in the signIn call)
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)

        do {
            // ✅ No `configuration:` argument
            let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: rootVC)

            guard let idToken = result.user.idToken?.tokenString else {
                lastErrorMessage = "Google Sign-In missing ID token."
                return
            }

            let accessToken = result.user.accessToken.tokenString
            let credential = GoogleAuthProvider.credential(withIDToken: idToken, accessToken: accessToken)
            _ = try await Auth.auth().signIn(with: credential)

        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }
}

// MARK: - Root

struct RootView: View {
    @EnvironmentObject private var theme: PLThemeStore
    @EnvironmentObject private var auth: PLAuthStore
    @EnvironmentObject private var network: NetworkMonitor
    @Environment(\.horizontalSizeClass) private var hSizeClass

    @State private var tab: PLRailTab = .library

    /// Controls the left rail open/close
    @State private var showSidebar: Bool = false

    /// Kept for now so LibraryView compiles.
    @State private var deleteMode: Bool = false
    @State private var showOfflineBanner: Bool = false
    @State private var offlineBannerDismissWorkItem: DispatchWorkItem? = nil

    // Layout constants
    private let railWidth: CGFloat = 86
    private let menuButtonSize: CGFloat = 56
    private let menuTopPadding: CGFloat = 18
    private let menuLeadingPadding: CGFloat = 16

    // ✅ extra reserve so the first rail button never sits under the X/hamburger
    private let railTopReserveExtra: CGFloat = 14

    private var isPhoneCompact: Bool { hSizeClass == .compact }
    private var dockedSidebarInset: CGFloat { isPhoneCompact ? 0 : (showSidebar ? railWidth + 14 : 0) }

    var body: some View {
        GeometryReader { proxy in
            let p = theme.palette
            let topSafeInset = proxy.safeAreaInsets.top

            ZStack(alignment: .topLeading) {
                p.background.ignoresSafeArea()

                if auth.isBooting {
                    bootSplash
                } else if !auth.isSignedIn {
                    SignInScreen()
                } else {
                    mainAppShell(topSafeInset: topSafeInset)
                        .environment(\.plDockedSidebarInset, dockedSidebarInset)
                }
            }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.92), value: auth.isSignedIn)
    }

    // MARK: - Boot splash

    private var bootSplash: some View {
        let p = theme.palette
        return VStack(spacing: 14) {
            Image(systemName: "square.grid.2x2.fill")
                .font(.system(size: 44, weight: .bold))
                .foregroundStyle(p.textPrimary)

            Text("PaperLink")
                .font(.system(size: 28, weight: .heavy))
                .foregroundStyle(p.textPrimary)

            ProgressView()
                .tint(p.textPrimary)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(p.canvas.ignoresSafeArea())
    }

    // MARK: - Main app shell (rail + content)

    private func mainAppShell(topSafeInset: CGFloat) -> some View {
        let p = theme.palette

        return ZStack(alignment: .topLeading) {
            p.background.ignoresSafeArea()

            // MAIN CONTENT (never shifts)
            mainContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // SIDEBAR OVERLAY on iPhone (slides OVER content so nothing reflows)
            if isPhoneCompact {
                sidebarOverlay(topSafeInset: topSafeInset)
            } else {
                // iPad / regular width: keep rail docked if open
                if showSidebar {
                    dockedSidebar(topSafeInset: topSafeInset)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
            }

            // SINGLE menu button (position stable)
            MenuToggleButton(isOpen: $showSidebar)
                .padding(.top, menuTopPadding)
                .padding(.leading, menuLeadingPadding)

        }
        .safeAreaInset(edge: isPhoneCompact ? .bottom : .top) {
            if showOfflineBanner && !network.isOnline {
                OfflineBanner {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showOfflineBanner = false
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, isPhoneCompact ? 0 : 10)
                .padding(.bottom, isPhoneCompact ? 10 : 0)
                .transition(
                    .move(edge: isPhoneCompact ? .bottom : .top)
                        .combined(with: .opacity)
                )
            }
        }
        .onAppear {
            // Start closed on every device.
            showSidebar = false
            updateOfflineBannerVisibility(isOnline: network.isOnline, animated: false)
        }
        .onChange(of: hSizeClass) { _, newSizeClass in
            // Never carry an open rail into compact (iPhone) layout.
            if newSizeClass == .compact { showSidebar = false }
        }
        .onChange(of: network.isOnline) { _, isOnline in
            updateOfflineBannerVisibility(isOnline: isOnline, animated: true)
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.92), value: showSidebar)
        .animation(.spring(response: 0.28, dampingFraction: 0.92), value: showOfflineBanner)
    }

    // MARK: - Main content

    private var mainContent: some View {
        Group {
            switch tab {
            case .library:
                LibraryView(
                    showPinnedSheet: .constant(false),
                    showSidebar: $showSidebar,
                    deleteMode: $deleteMode
                )

            case .folders:
                FolderBrowserView()

            case .info:
                InfoView()

            case .trash:
                RecentlyDeletedView()

            case .settings:
                SettingsView()
            }
        }
    }

    // MARK: - iPad docked sidebar

    private func dockedSidebar(topSafeInset: CGFloat) -> some View {
        LeftRail(
            tab: $tab,
            topReservedHeight: topSafeInset + menuTopPadding + menuButtonSize + railTopReserveExtra,
            onSelect: {
                // iPad: optional; keep open by default
            }
        )
        .frame(width: railWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(theme.palette.canvas)
    }

    // MARK: - iPhone overlay sidebar

    private func sidebarOverlay(topSafeInset: CGFloat) -> some View {
        let p = theme.palette

        return ZStack(alignment: .leading) {
            if showSidebar {
                // Scrim
                Color.black.opacity(0.10)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.92)) {
                            showSidebar = false
                        }
                    }

                // Drawer
                LeftRail(
                    tab: $tab,
                    topReservedHeight: topSafeInset + menuTopPadding + menuButtonSize + railTopReserveExtra,
                    onSelect: {
                        // ✅ Auto-close on selection for iPhone
                        showSidebar = false
                    }
                )
                .frame(width: railWidth)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(p.canvas)
                .overlay(
                    Rectangle()
                        .fill(p.outline)
                        .frame(width: 1),
                    alignment: .trailing
                )
                .shadow(color: .black.opacity(0.12), radius: 10, x: 4, y: 0)
                .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .ignoresSafeArea()
    }

    private func updateOfflineBannerVisibility(isOnline: Bool, animated: Bool) {
        offlineBannerDismissWorkItem?.cancel()

        let applyVisibility = {
            showOfflineBanner = !isOnline
        }

        if animated {
            withAnimation(.spring(response: 0.24, dampingFraction: 0.92)) {
                applyVisibility()
            }
        } else {
            applyVisibility()
        }

        guard !isOnline else { return }

        let workItem = DispatchWorkItem {
            withAnimation(.easeInOut(duration: 0.2)) {
                showOfflineBanner = false
            }
        }
        offlineBannerDismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.5, execute: workItem)
    }
}

// MARK: - Sign In Screen

private struct SignInScreen: View {
    @EnvironmentObject private var theme: PLThemeStore
    @EnvironmentObject private var auth: PLAuthStore

    var body: some View {
        let p = theme.palette

        VStack(spacing: 18) {
            Spacer()

            VStack(spacing: 10) {
                Image(systemName: "square.grid.2x2.fill")
                    .font(.system(size: 48, weight: .bold))
                    .foregroundStyle(p.textPrimary)

                Text("PaperLink")
                    .font(.system(size: 34, weight: .heavy))
                    .foregroundStyle(p.textPrimary)

                Text("Sign in to sync your notes across devices.")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(p.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
            }
            .padding(.horizontal, 28)

            VStack(spacing: 12) {
                Button {
                    Task { await auth.signInWithGoogle() }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "g.circle.fill")
                            .font(.system(size: 18, weight: .bold))

                        Text(auth.isSigningIn ? "Signing in..." : "Sign in with Google")
                            .font(.system(size: 16, weight: .bold))
                    }
                    .foregroundStyle(p.textPrimary)
                    .frame(maxWidth: 340)
                    .frame(height: 52)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(p.card.opacity(0.95))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(p.outline, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .disabled(auth.isSigningIn)
                .opacity(auth.isSigningIn ? 0.7 : 1.0)

                if let msg = auth.lastErrorMessage, !msg.isEmpty {
                    Text(msg)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(p.danger)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 22)
                        .padding(.top, 4)
                }
            }

            Spacer()

            Text("Tip: Make sure you added GoogleService-Info.plist and the REVERSED_CLIENT_ID URL scheme.")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(p.textSecondary.opacity(0.85))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(p.canvas.ignoresSafeArea())
    }
}

// MARK: - Offline banner (visual only for now)

private struct OfflineBanner: View {
    @EnvironmentObject private var theme: PLThemeStore
    var onDismiss: () -> Void

    var body: some View {
        let p = theme.palette
        return HStack(spacing: 10) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 14, weight: .bold))

            Text("Offline mode. You can create notes, but editing existing items is paused.")
                .font(.system(size: 12, weight: .bold))
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .black))
                    .frame(width: 24, height: 24)
                    .background(p.textPrimary.opacity(0.08))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(p.textPrimary)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(p.card.opacity(0.98))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(p.outline, lineWidth: 1)
        )
        .padding(.top, 6)
        .padding(.horizontal, 16)
    }
}

// MARK: - Single Menu Button (Hamburger -> X)

private struct MenuToggleButton: View {
    @EnvironmentObject private var theme: PLThemeStore
    @Binding var isOpen: Bool

    var body: some View {
        let p = theme.palette

        Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.92)) {
                isOpen.toggle()
            }
        } label: {
            Image(systemName: isOpen ? "xmark" : "line.3.horizontal")
                .font(.system(size: 22, weight: .bold))
                .frame(width: 56, height: 56)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(p.railButton)
                        .shadow(
                            color: .black.opacity(isOpen ? 0.0 : 0.18),
                            radius: isOpen ? 0 : 10,
                            x: 0,
                            y: isOpen ? 0 : 6
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(p.outline, lineWidth: 1)
                )
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, value: isOpen)
        }
        .buttonStyle(.plain)
        .foregroundStyle(p.textPrimary)
        .accessibilityLabel(isOpen ? "Close Menu" : "Open Menu")
    }
}

// MARK: - Left Rail

struct LeftRail: View {
    @EnvironmentObject private var theme: PLThemeStore
    @Binding var tab: PLRailTab

    /// Space reserved so the rail doesn't sit under the overlay menu button.
    let topReservedHeight: CGFloat

    /// Called when any item is selected (used to auto-close on iPhone).
    var onSelect: () -> Void = {}

    var body: some View {
        let p = theme.palette

        VStack(spacing: 18) {

            // Reserve space where the overlay button sits
            Spacer()
                .frame(height: topReservedHeight)

            VStack(spacing: 14) {
                RailButton(icon: "books.vertical", selected: tab == .library) {
                    tab = .library
                    onSelect()
                }
                RailButton(icon: "folder", selected: tab == .folders) {
                    tab = .folders
                    onSelect()
                }
                RailButton(icon: "info.circle", selected: tab == .info) {
                    tab = .info
                    onSelect()
                }
            }

            Spacer()

            Button {
                tab = .trash
                onSelect()
            } label: {
                VStack(spacing: 6) {
                    Image(systemName: tab == .trash ? "trash.fill" : "trash")
                        .font(.system(size: 20, weight: .bold))
                        .frame(width: 56, height: 56)
                        .background(tab == .trash ? p.accent.opacity(0.35) : p.railButton)
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                        .overlay(
                            RoundedRectangle(cornerRadius: 18)
                                .stroke(p.outline, lineWidth: 1)
                        )
                    Text("Trash")
                        .font(.system(size: 11, weight: .bold))
                        .opacity(0.75)
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(p.textPrimary)
            .padding(.bottom, 10)

            Button {
                tab = .settings
                onSelect()
            } label: {
                VStack(spacing: 6) {
                    Image(systemName: tab == .settings ? "gearshape.fill" : "gearshape")
                        .font(.system(size: 20, weight: .bold))
                        .frame(width: 56, height: 56)
                        .background(tab == .settings ? p.accent.opacity(0.35) : p.railButton)
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                        .overlay(
                            RoundedRectangle(cornerRadius: 18)
                                .stroke(p.outline, lineWidth: 1)
                        )
                    Text("Settings")
                        .font(.system(size: 11, weight: .bold))
                        .opacity(0.75)
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(p.textPrimary)
            .padding(.bottom, 18)
        }
        .frame(maxHeight: .infinity)
        .background(p.canvas)
    }
}

struct RailButton: View {
    @EnvironmentObject private var theme: PLThemeStore

    let icon: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        let p = theme.palette

        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .bold))
                .frame(width: 56, height: 56)
                .background(selected ? p.accent.opacity(0.55) : p.railButton)
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(p.outline, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .foregroundStyle(p.textPrimary)
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject private var theme: PLThemeStore
    @EnvironmentObject private var auth: PLAuthStore
    @Environment(\.plDockedSidebarInset) private var dockedSidebarInset
    @AppStorage("pl_apple_pencil_only_draw") private var applePencilOnlyDraw: Bool = false
    @AppStorage(PLDrawingPaletteDefaults.Key.autoMinimize) private var drawingPaletteAutoMinimize: Bool = PLDrawingPaletteDefaults.autoMinimize
    @AppStorage(PLDrawingDefaults.Key.paperStyleRaw) private var defaultDrawingPaperStyleRaw: String = PLDrawingDefaults.paperStyleRaw
    @AppStorage(PLDrawingDefaults.Key.penWidth) private var defaultPenWidth: Double = PLDrawingDefaults.penWidth
    @AppStorage(PLDrawingDefaults.Key.markerWidth) private var defaultMarkerWidth: Double = PLDrawingDefaults.markerWidth
    @AppStorage(PLDrawingDefaults.Key.lineSpacing) private var defaultLineSpacing: Double = PLDrawingDefaults.lineSpacing
    @AppStorage(PLDrawingDefaults.Key.dotSpacing) private var defaultDotSpacing: Double = PLDrawingDefaults.dotSpacing
    @AppStorage(PLDrawingDefaults.Key.dotSize) private var defaultDotSize: Double = PLDrawingDefaults.dotSize

    private var headerMenuClearance: CGFloat {
#if canImport(UIKit)
        UIDevice.current.userInterfaceIdiom == .phone ? 58 : max(68, dockedSidebarInset)
#else
        68
#endif
    }

    var body: some View {
        let p = theme.palette

        ScrollView {
            HStack(alignment: .top, spacing: 14) {
                Color.clear
                    .frame(width: headerMenuClearance, height: 1)

                VStack(alignment: .leading, spacing: 16) {
                    Text("Settings")
                        .font(.system(size: 28, weight: .heavy))
                        .foregroundStyle(p.textPrimary)

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Theme")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(p.textSecondary)

                        HStack(spacing: 10) {
                            ForEach(PLTheme.allCases) { t in
                                let selected = (theme.theme == t)

                                Button {
                                    withAnimation(.spring(response: 0.26, dampingFraction: 0.90)) {
                                        theme.theme = t
                                    }
                                } label: {
                                    Text(t.rawValue)
                                        .font(.system(size: 14, weight: .bold))
                                        .foregroundStyle(selected ? p.background : p.textPrimary)
                                        .frame(maxWidth: .infinity)
                                        .frame(height: 40)
                                        .background(
                                            RoundedRectangle(cornerRadius: 14)
                                                .fill(selected ? p.textPrimary.opacity(0.92) : p.railButton)
                                        )
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 14)
                                                .stroke(p.outline, lineWidth: 1)
                                        )
                                        .scaleEffect(selected ? 1.02 : 1.0)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(16)
                    .background(p.card)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18)
                            .stroke(p.outline, lineWidth: 1)
                    )

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Drawing")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(p.textSecondary)

                        Toggle("Only draw with Apple Pencil", isOn: $applePencilOnlyDraw)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(p.textPrimary)
                            .tint(p.accent)

                        Toggle("Auto-minimize drawing palette", isOn: $drawingPaletteAutoMinimize)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(p.textPrimary)
                            .tint(p.accent)

                        Text("When enabled, finger touches still pan and scroll, but only Apple Pencil creates strokes.")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(p.textSecondary)
                    }
                    .padding(16)
                    .background(p.card)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18)
                            .stroke(p.outline, lineWidth: 1)
                    )

                    PLDrawingPreferencesSection(
                        paperStyle: Binding(
                            get: { PLDrawingPaperStyle(rawValue: defaultDrawingPaperStyleRaw) ?? .lined },
                            set: { defaultDrawingPaperStyleRaw = $0.rawValue }
                        ),
                        penWidth: $defaultPenWidth,
                        markerWidth: $defaultMarkerWidth,
                        lineSpacing: $defaultLineSpacing,
                        dotSpacing: $defaultDotSpacing,
                        dotSize: $defaultDotSize
                    )

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Account")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(p.textSecondary)

                        if let email = auth.user?.email, !email.isEmpty {
                            Text(email)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(p.textPrimary)
                        }

                        Button(role: .destructive) {
                            auth.signOut()
                        } label: {
                            Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                                .font(.system(size: 15, weight: .bold))
                                .frame(maxWidth: .infinity)
                                .frame(height: 46)
                                .background(p.danger.opacity(0.16))
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 16)
                                        .stroke(p.danger.opacity(0.34), lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(p.danger)
                    }
                    .padding(16)
                    .background(p.card)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18)
                            .stroke(p.outline, lineWidth: 1)
                    )

                    Spacer(minLength: 0)
                }

                Spacer(minLength: 0)
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(p.canvas.ignoresSafeArea())
    }
}

struct PLDrawingPreferencesSection: View {
    @EnvironmentObject private var theme: PLThemeStore

    @Binding var paperStyle: PLDrawingPaperStyle
    @Binding var penWidth: Double
    @Binding var markerWidth: Double
    @Binding var lineSpacing: Double
    @Binding var dotSpacing: Double
    @Binding var dotSize: Double

    var body: some View {
        let p = theme.palette

        VStack(alignment: .leading, spacing: 12) {
            Text("Preferences")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(p.textSecondary)

            Text("Preview")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(p.textPrimary.opacity(0.85))

            HStack(spacing: 10) {
                ForEach(PLDrawingPaperStyle.allCases, id: \.self) { style in
                    DrawingPaperPreviewTile(
                        style: style,
                        isSelected: paperStyle == style,
                        lineSpacing: lineSpacing,
                        dotSpacing: dotSpacing,
                        dotSize: dotSize
                    ) {
                        paperStyle = style
                    }
                }
            }

            DrawingStrokePreviewRow(
                penWidth: penWidth,
                markerWidth: markerWidth
            )

            prefStepper("Default pen width", value: $penWidth, range: 1...24, suffix: "px")
            prefStepper("Default marker width", value: $markerWidth, range: 4...36, suffix: "px")
            prefStepper("Default line spacing", value: $lineSpacing, range: 12...80, suffix: "px")
            prefStepper("Default dot spacing", value: $dotSpacing, range: 12...80, suffix: "px")
            prefStepper("Default dot size", value: $dotSize, range: 1...8, suffix: "px")
        }
        .padding(16)
        .background(p.card)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(p.outline, lineWidth: 1)
        )
    }

    private func prefStepper(_ label: String, value: Binding<Double>, range: ClosedRange<Double>, suffix: String) -> some View {
        let p = theme.palette

        return HStack {
            Text(label)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(p.textPrimary.opacity(0.85))
            Spacer()
            Stepper("", value: value, in: range, step: 1)
                .labelsHidden()
            Text("\(Int(value.wrappedValue))\(suffix)")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(p.textSecondary)
                .frame(width: 72, alignment: .trailing)
        }
        .padding(12)
        .background(p.railButton)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(p.outline, lineWidth: 1)
        )
    }
}

private struct DrawingPaperPreviewTile: View {
    @EnvironmentObject private var theme: PLThemeStore

    let style: PLDrawingPaperStyle
    let isSelected: Bool
    let lineSpacing: Double
    let dotSpacing: Double
    let dotSize: Double
    let action: () -> Void

    var body: some View {
        let p = theme.palette

        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                GeometryReader { geo in
                    ZStack {
                        RoundedRectangle(cornerRadius: 14)
                            .fill(p.railButton.opacity(0.9))

                        switch style {
                        case .lined:
                            linedPreview(in: geo.size)
                        case .dotGrid:
                            dotPreview(in: geo.size)
                        case .blank:
                            EmptyView()
                        }
                    }
                }
                .frame(height: 74)

                Text(style.label)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(isSelected ? p.background : p.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(isSelected ? p.textPrimary.opacity(0.92) : p.railButton)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(p.outline, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func linedPreview(in size: CGSize) -> some View {
        let spacing = CGFloat(max(10, min(lineSpacing, 34)))
        let lineCount = Int(size.height / spacing) + 2

        Canvas { context, canvasSize in
            for idx in 0..<lineCount {
                let y = CGFloat(idx) * spacing
                var path = Path()
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: canvasSize.width, y: y))
                context.stroke(path, with: .color(.black.opacity(0.12)), lineWidth: 1)
            }
        }
    }

    @ViewBuilder
    private func dotPreview(in size: CGSize) -> some View {
        let spacing = CGFloat(max(10, min(dotSpacing, 30)))
        let radius = CGFloat(max(1, min(dotSize, 4)))

        Canvas { context, canvasSize in
            var x: CGFloat = spacing * 0.5
            while x < canvasSize.width {
                var y: CGFloat = spacing * 0.5
                while y < canvasSize.height {
                    let rect = CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)
                    context.fill(Path(ellipseIn: rect), with: .color(.black.opacity(0.16)))
                    y += spacing
                }
                x += spacing
            }
        }
    }
}

private struct DrawingStrokePreviewRow: View {
    @EnvironmentObject private var theme: PLThemeStore

    let penWidth: Double
    let markerWidth: Double

    var body: some View {
        let p = theme.palette

        VStack(alignment: .leading, spacing: 10) {
            Text("Stroke preview")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(p.textPrimary.opacity(0.85))

            VStack(spacing: 10) {
                strokePreview(label: "Pen", width: penWidth, opacity: 0.95)
                strokePreview(label: "Marker", width: markerWidth, opacity: 0.30)
            }
        }
        .padding(12)
        .background(p.railButton)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(p.outline, lineWidth: 1)
        )
    }

    private func strokePreview(label: String, width: Double, opacity: Double) -> some View {
        let p = theme.palette

        return HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(p.textSecondary)
                .frame(width: 44, alignment: .leading)

            Capsule()
                .fill(p.textPrimary.opacity(opacity))
                .frame(height: max(2, min(width, 18)))

            Text("\(Int(width))px")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(p.textSecondary)
                .frame(width: 44, alignment: .trailing)
        }
    }
}

// MARK: - Recently Deleted

struct RecentlyDeletedView: View {
    @Environment(\.modelContext) private var ctx
    @Environment(\.plDockedSidebarInset) private var dockedSidebarInset
    @EnvironmentObject private var theme: PLThemeStore
    @EnvironmentObject private var network: NetworkMonitor

    @Query(sort: \PLNote.updatedAt, order: .reverse) private var allNotes: [PLNote]
    @Query(sort: \PLFolder.updatedAt, order: .reverse) private var allFolders: [PLFolder]

    @State private var showEmptyTrashVerification = false
    @State private var isEmptyingTrash = false
    @State private var emptyTrashErrorMessage: String? = nil

    private enum TrashEntry: Identifiable {
        case folder(PLFolder)
        case note(PLNote)

        var id: String {
            switch self {
            case .folder(let folder): return "folder-\(folder.id.uuidString)"
            case .note(let note): return "note-\(note.id.uuidString)"
            }
        }

        var deletedAt: Date {
            switch self {
            case .folder(let folder): return folder.deletedAt ?? folder.updatedAt
            case .note(let note): return note.deletedAt ?? note.updatedAt
            }
        }
    }

    private var headerMenuClearance: CGFloat {
#if canImport(UIKit)
        UIDevice.current.userInterfaceIdiom == .phone ? 58 : max(68, dockedSidebarInset)
#else
        68
#endif
    }

    private var deletedFoldersByID: [UUID: PLFolder] {
        Dictionary(uniqueKeysWithValues: deletedFolders.map { ($0.id, $0) })
    }

    private var deletedFolders: [PLFolder] {
        allFolders.filter { $0.deletedAt != nil }
    }

    private var deletedNotes: [PLNote] {
        allNotes.filter { $0.deletedAt != nil }
    }

    private var visibleDeletedFolders: [PLFolder] {
        deletedFolders
            .filter { folder in
                guard let parentID = folder.parentFolderID else { return true }
                return deletedFoldersByID[parentID] == nil
            }
            .sorted { lhs, rhs in
                (lhs.deletedAt ?? lhs.updatedAt) > (rhs.deletedAt ?? rhs.updatedAt)
            }
    }

    private var visibleDeletedNotes: [PLNote] {
        deletedNotes
            .filter { note in
                guard let folderID = note.folderID else { return true }
                return deletedFoldersByID[folderID] == nil
            }
            .sorted { lhs, rhs in
                (lhs.deletedAt ?? lhs.updatedAt) > (rhs.deletedAt ?? rhs.updatedAt)
            }
    }

    private var visibleTrashEntries: [TrashEntry] {
        let entries =
            visibleDeletedFolders.map(TrashEntry.folder)
            + visibleDeletedNotes.map(TrashEntry.note)

        return entries.sorted { $0.deletedAt > $1.deletedAt }
    }

    private var gridColumns: [GridItem] {
#if canImport(UIKit)
        if UIDevice.current.userInterfaceIdiom == .phone {
            return [GridItem(.flexible(), spacing: 14)]
        }
#endif
        return [GridItem(.adaptive(minimum: 280, maximum: 380), spacing: 16)]
    }

    private var canEmptyTrash: Bool {
        network.isOnline && !visibleTrashEntries.isEmpty && !isEmptyingTrash
    }

    var body: some View {
        let p = theme.palette

        ScrollView {
            HStack(alignment: .top, spacing: 14) {
                Color.clear
                    .frame(width: headerMenuClearance, height: 1)

                VStack(alignment: .leading, spacing: 18) {
                    trashHeaderCard

                    if visibleTrashEntries.isEmpty {
                        emptyStateCard
                    } else {
                        LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 16) {
                            ForEach(visibleTrashEntries) { entry in
                                switch entry {
                                case .folder(let folder):
                                    deletedFolderCard(folder)
                                case .note(let note):
                                    deletedNoteCard(note)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: 980, alignment: .leading)

                Spacer(minLength: 0)
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(p.canvas.ignoresSafeArea())
        .sheet(isPresented: $showEmptyTrashVerification) {
            EmptyTrashVerificationSheet(
                isWorking: isEmptyingTrash,
                onCancel: {
                    showEmptyTrashVerification = false
                },
                onConfirm: {
                    showEmptyTrashVerification = false
                    Task { await emptyTrash() }
                }
            )
            .presentationDetents([.height(560)])
            .presentationCornerRadius(28)
        }
    }

    private var trashHeaderCard: some View {
        let p = theme.palette

        return VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    headerTextBlock

                    Spacer(minLength: 12)

                    emptyTrashButton
                }

                VStack(alignment: .leading, spacing: 14) {
                    headerTextBlock

                    emptyTrashButton
                }
            }

            Text("Restoring a folder brings back its notes and subfolders. Trash in PaperLink is sync-backed soft delete, so restore is immediate and safe.")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(p.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if !network.isOnline {
                Text("Connect to the internet to empty trash across devices.")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(p.textSecondary)
            }

            if let emptyTrashErrorMessage {
                Text(emptyTrashErrorMessage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(p.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(p.card)
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .overlay(
            RoundedRectangle(cornerRadius: 22)
                .stroke(p.outline, lineWidth: 1)
        )
    }

    private var headerTextBlock: some View {
        let p = theme.palette

        return VStack(alignment: .leading, spacing: 12) {
            Text("Recently Deleted")
                .font(.system(size: 28, weight: .heavy))
                .foregroundStyle(p.textPrimary)

            Text("\(visibleTrashEntries.count) item\(visibleTrashEntries.count == 1 ? "" : "s") waiting in trash")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(p.textSecondary)
        }
    }

    private var emptyTrashButton: some View {
        let p = theme.palette

        return Button {
            showEmptyTrashVerification = true
        } label: {
            Label(isEmptyingTrash ? "Emptying..." : "Empty Trash", systemImage: "trash.fill")
                .font(.system(size: 15, weight: .bold))
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .background(canEmptyTrash ? p.danger : p.railButton)
                .foregroundStyle(canEmptyTrash ? p.canvas : p.textSecondary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!canEmptyTrash)
    }

    private var emptyStateCard: some View {
        let p = theme.palette

        return VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "trash.slash")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(p.accent)

            Text("Trash is empty")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(p.textPrimary)

            Text("Deleted notes and folders will show up here until you restore them.")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(p.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(p.card)
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .overlay(
            RoundedRectangle(cornerRadius: 22)
                .stroke(p.outline, lineWidth: 1)
        )
    }

    private func deletedFolderCard(_ folder: PLFolder) -> some View {
        let p = theme.palette
        let stats = deletedFolderStats(for: folder)

        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(p.accent.opacity(0.14))
                        .frame(width: 44, height: 44)

                    Image(systemName: "folder.fill")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(p.accent)
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text(folder.name.isEmpty ? "Untitled Folder" : folder.name)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(p.textPrimary)
                        .lineLimit(2)

                    Text(deletedTimestamp(for: folder.deletedAt))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(p.textSecondary)
                }

                Spacer(minLength: 0)
            }

            Text(folderSummary(stats: stats))
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(p.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                restoreFolder(folder)
            } label: {
                Label("Restore Folder", systemImage: "arrow.uturn.backward.circle.fill")
                    .font(.system(size: 15, weight: .bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(p.accent)
                    .foregroundStyle(p.canvas)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(p.card)
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .overlay(
            RoundedRectangle(cornerRadius: 22)
                .stroke(p.outline, lineWidth: 1)
        )
    }

    private func deletedNoteCard(_ note: PLNote) -> some View {
        let p = theme.palette

        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(kindAccent(for: note).opacity(0.14))
                        .frame(width: 44, height: 44)

                    Image(systemName: iconName(for: note))
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(kindAccent(for: note))
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text(note.title.isEmpty ? noteFallbackTitle(for: note) : note.title)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(p.textPrimary)
                        .lineLimit(2)

                    Text(deletedTimestamp(for: note.deletedAt))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(p.textSecondary)
                }

                Spacer(minLength: 0)
            }

            Text(notePreview(for: note))
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(p.textSecondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                restoreNote(note)
            } label: {
                Label("Restore Note", systemImage: "arrow.uturn.backward.circle.fill")
                    .font(.system(size: 15, weight: .bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(p.accent)
                    .foregroundStyle(p.canvas)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(p.card)
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .overlay(
            RoundedRectangle(cornerRadius: 22)
                .stroke(p.outline, lineWidth: 1)
        )
    }

    @MainActor
    private func restoreNote(_ note: PLNote) {
        note.deletedAt = nil
        note.updatedAt = .now
        try? ctx.save()
        PaperLinkSyncManager.shared.enqueueNote(note, ctx: ctx)
    }

    @MainActor
    private func restoreFolder(_ folder: PLFolder) {
        let subtreeFolderIDs = collectFolderSubtreeIDs(root: folder.id)
        let foldersToRestore = allFolders.filter { subtreeFolderIDs.contains($0.id) && $0.deletedAt != nil }
        let notesToRestore = allNotes.filter { note in
            guard let folderID = note.folderID else { return false }
            return subtreeFolderIDs.contains(folderID) && note.deletedAt != nil
        }

        for restoreFolder in foldersToRestore {
            restoreFolder.deletedAt = nil
            restoreFolder.updatedAt = .now
        }
        for note in notesToRestore {
            note.deletedAt = nil
            note.updatedAt = .now
        }

        try? ctx.save()

        for restoreFolder in foldersToRestore {
            PaperLinkSyncManager.shared.enqueueFolder(restoreFolder, ctx: ctx)
        }
        for note in notesToRestore {
            PaperLinkSyncManager.shared.enqueueNote(note, ctx: ctx)
        }
    }

    private func collectFolderSubtreeIDs(root: UUID) -> Set<UUID> {
        var result: Set<UUID> = [root]
        var queue: [UUID] = [root]

        while let next = queue.first {
            queue.removeFirst()
            let children = allFolders
                .filter { $0.parentFolderID == next }
                .map(\.id)

            for child in children where !result.contains(child) {
                result.insert(child)
                queue.append(child)
            }
        }

        return result
    }

    private func deletedFolderStats(for folder: PLFolder) -> (folders: Int, notes: Int) {
        let subtreeFolderIDs = collectFolderSubtreeIDs(root: folder.id)
        let folderCount = max(subtreeFolderIDs.count - 1, 0)
        let noteCount = allNotes.filter { note in
            guard let folderID = note.folderID else { return false }
            return subtreeFolderIDs.contains(folderID) && note.deletedAt != nil
        }.count
        return (folders: folderCount, notes: noteCount)
    }

    private func folderSummary(stats: (folders: Int, notes: Int)) -> String {
        if stats.folders == 0 {
            return "\(stats.notes) note\(stats.notes == 1 ? "" : "s") inside"
        }
        return "\(stats.folders) subfolder\(stats.folders == 1 ? "" : "s"), \(stats.notes) note\(stats.notes == 1 ? "" : "s")"
    }

    private func notePreview(for note: PLNote) -> String {
        switch note.kind {
        case .text:
            let trimmed = (note.textBody ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Text note" : trimmed
        case .photo:
            return "Photo note"
        case .drawing:
            return "Drawing note"
        }
    }

    private func noteFallbackTitle(for note: PLNote) -> String {
        switch note.kind {
        case .text: return "Untitled Note"
        case .photo: return "Photo Note"
        case .drawing: return "Drawing Note"
        }
    }

    private func iconName(for note: PLNote) -> String {
        switch note.kind {
        case .text: return "text.alignleft"
        case .photo: return "photo"
        case .drawing: return "pencil.and.outline"
        }
    }

    private func kindAccent(for note: PLNote) -> Color {
        let p = theme.palette
        switch note.kind {
        case .text:
            return p.accent
        case .photo:
            return Color(red: 0.72, green: 0.39, blue: 0.18)
        case .drawing:
            return Color(red: 0.18, green: 0.36, blue: 0.76)
        }
    }

    private func deletedTimestamp(for date: Date?) -> String {
        guard let date else { return "Deleted recently" }
        return "Deleted \(date.formatted(date: .abbreviated, time: .shortened))"
    }

    @MainActor
    private func emptyTrash() async {
        guard canEmptyTrash else { return }

        isEmptyingTrash = true
        emptyTrashErrorMessage = nil
        defer { isEmptyingTrash = false }

        do {
            try await PaperLinkSyncManager.shared.emptyTrash(ctx: ctx)
        } catch {
            emptyTrashErrorMessage = "Empty Trash failed: \(error.localizedDescription)"
        }
    }
}

private struct EmptyTrashVerificationSheet: View {
    @EnvironmentObject private var theme: PLThemeStore

    let isWorking: Bool
    let onCancel: () -> Void
    let onConfirm: () -> Void

    @State private var isAuthenticated = false
    @State private var isAuthenticating = false
    @State private var authError: String?

    var body: some View {
        let p = theme.palette

        VStack(spacing: 16) {
            Capsule()
                .fill(p.textPrimary.opacity(0.18))
                .frame(width: 44, height: 5)
                .padding(.top, 10)

            Text("Empty Trash")
                .font(.system(size: 24, weight: .heavy))
                .foregroundStyle(p.textPrimary)

            Text("Authenticate, then trace the full circle to permanently remove everything in Recently Deleted.")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(p.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 22)

            if !isAuthenticated {
                Button {
                    authenticate()
                } label: {
                    Label(isAuthenticating ? "Checking..." : "Authenticate with Device Passcode", systemImage: "lock.fill")
                        .font(.system(size: 15, weight: .bold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(p.accent.opacity(0.82))
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                        .overlay(
                            RoundedRectangle(cornerRadius: 18)
                                .stroke(p.outline, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .foregroundStyle(p.textPrimary)
                .padding(.horizontal, 18)
                .disabled(isAuthenticating)
            }

            CircularTraceConfirmPad(
                isEnabled: isAuthenticated && !isWorking,
                onComplete: onConfirm
            )
            .frame(height: 240)
            .padding(.horizontal, 18)
            .opacity(isAuthenticated ? 1 : 0.45)

            if let authError {
                Text(authError)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(p.danger)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 22)
            } else if !isAuthenticated {
                Text("Authentication is required before the circle unlocks.")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(p.textSecondary)
            }

            Button("Cancel", role: .cancel, action: onCancel)
                .font(.system(size: 16, weight: .bold))
                .frame(height: 52)
                .frame(maxWidth: .infinity)
                .background(p.railButton)
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(p.outline, lineWidth: 1)
                )
                .foregroundStyle(p.textPrimary)
                .padding(.horizontal, 18)
                .padding(.bottom, 18)
        }
        .background(p.background)
    }

    private func authenticate() {
        guard !isAuthenticating else { return }
        isAuthenticating = true
        authError = nil

        let context = LAContext()
        context.localizedFallbackTitle = "Use Passcode"

        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            authError = error?.localizedDescription ?? "Authentication is unavailable on this device."
            isAuthenticating = false
            return
        }

        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Authenticate to permanently empty Recently Deleted.") { success, evalError in
            DispatchQueue.main.async {
                isAuthenticating = false
                if success {
                    isAuthenticated = true
                    authError = nil
                } else {
                    authError = evalError?.localizedDescription ?? "Authentication failed."
                }
            }
        }
    }
}

private struct CircularTraceConfirmPad: View {
    @EnvironmentObject private var theme: PLThemeStore

    let isEnabled: Bool
    let onComplete: () -> Void

    @State private var visitedSegments: Set<Int> = []
    @State private var isTracking = false

    private let segmentCount = 32

    var body: some View {
        let p = theme.palette

        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let radius = size * 0.36
            let lineWidth = max(22, size * 0.10)

            ZStack {
                Circle()
                    .stroke(p.textPrimary.opacity(0.10), lineWidth: lineWidth)

                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(
                        p.danger,
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
                    )
                    .rotationEffect(.degrees(-90))

                VStack(spacing: 8) {
                    Text(isEnabled ? "Draw the circle" : "Locked")
                        .font(.system(size: 18, weight: .heavy))
                        .foregroundStyle(p.textPrimary)

                    Text(isEnabled ? "\(Int(progress * 100))% complete" : "Authenticate first")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(p.textSecondary)
                }

                Circle()
                    .fill(Color.clear)
                    .contentShape(Circle())
            }
            .frame(width: size, height: size)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard isEnabled else { return }
                        track(value.location, in: geo.size, radius: radius, tolerance: lineWidth * 0.85)
                    }
                    .onEnded { _ in
                        guard isEnabled else { return }
                        if progress >= 0.84 {
                            onComplete()
                        }
                        withAnimation(.spring(response: 0.24, dampingFraction: 0.88)) {
                            visitedSegments.removeAll()
                            isTracking = false
                        }
                    }
            )
        }
    }

    private var progress: CGFloat {
        CGFloat(visitedSegments.count) / CGFloat(segmentCount)
    }

    private func track(_ point: CGPoint, in size: CGSize, radius: CGFloat, tolerance: CGFloat) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let dx = point.x - center.x
        let dy = point.y - center.y
        let distance = hypot(dx, dy)

        guard abs(distance - radius) <= tolerance else {
            if !isTracking {
                visitedSegments.removeAll()
            }
            return
        }

        isTracking = true

        var angle = atan2(dy, dx)
        if angle < 0 { angle += (.pi * 2) }

        let segment = min(segmentCount - 1, max(0, Int((angle / (.pi * 2)) * CGFloat(segmentCount))))
        visitedSegments.insert(segment)
    }
}
