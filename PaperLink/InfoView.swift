//
//  InfoView.swift
//  PaperLink
//
//  Created by Ben Chen on 2/2/26.
//

import SwiftUI
import SwiftData

struct InfoView: View {
    @EnvironmentObject private var theme: PLThemeStore
    @Environment(\.plDockedSidebarInset) private var dockedSidebarInset
    @Query(sort: \PLNote.createdAt, order: .reverse) private var allNotes: [PLNote]

    @State private var serverStorageBytes: Int64?
    @State private var serverNoteCounts: RemoteUsageNoteCounts?
    @State private var loadingStats = false
    @State private var statsError: String?

    private var headerMenuClearance: CGFloat {
#if canImport(UIKit)
        UIDevice.current.userInterfaceIdiom == .phone ? 58 : max(68, dockedSidebarInset)
#else
        68
#endif
    }

    private var liveNotes: [PLNote] {
        allNotes.filter { $0.deletedAt == nil }
    }

    private var fallbackCounts: RemoteUsageNoteCounts {
        let text = liveNotes.filter { $0.kind == .text }.count
        let drawing = liveNotes.filter { $0.kind == .drawing }.count
        let photo = liveNotes.filter { $0.kind == .photo }.count
        return RemoteUsageNoteCounts(text: text, drawing: drawing, photo: photo, all: text + drawing + photo)
    }

    private var displayedCounts: RemoteUsageNoteCounts {
        serverNoteCounts ?? fallbackCounts
    }

    var body: some View {
        let p = theme.palette

        ZStack {
            p.background.ignoresSafeArea()

            HStack(alignment: .top, spacing: 14) {
                Color.clear
                    .frame(width: headerMenuClearance, height: 1)

                VStack(alignment: .leading, spacing: 12) {
                    Text("PaperLink")
                        .font(.system(size: 34, weight: .heavy))
                        .foregroundStyle(p.textPrimary)

                    Text("Workspace information")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(p.textSecondary)

                    VStack(alignment: .leading, spacing: 10) {
                        infoRow(title: "Theme", value: theme.theme.rawValue)
                        infoRow(title: "Storage used", value: formattedStorageLabel)
                        infoRow(title: "Text notes", value: "\(displayedCounts.text)")
                        infoRow(title: "Drawing notes", value: "\(displayedCounts.drawing)")
                        infoRow(title: "Photo notes", value: "\(displayedCounts.photo)")
                        infoRow(title: "All notes", value: "\(displayedCounts.all)")
                        infoRow(title: "Platform", value: UIDevice.current.userInterfaceIdiom == .phone ? "iPhone" : "iPad")

                        if loadingStats {
                            Text("Refreshing stats from server…")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(p.textSecondary)
                        } else if let statsError {
                            Text(statsError)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(p.textSecondary)
                        }
                    }
                    .padding(16)
                    .background(p.card)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18)
                            .stroke(p.outline, lineWidth: 1)
                    )

                    Spacer()
                }

                Spacer(minLength: 0)
            }
            .padding(22)
        }
        .task {
            await refreshStats()
        }
    }

    private func infoRow(title: String, value: String) -> some View {
        let p = theme.palette

        return HStack {
            Text(title)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(p.textSecondary)

            Spacer()

            Text(value)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(p.textPrimary.opacity(0.90))
        }
        .padding(.vertical, 2)
    }

    private var formattedStorageLabel: String {
        guard let serverStorageBytes else { return "Unavailable" }
        return formatStorage(bytes: serverStorageBytes)
    }

    private func formatStorage(bytes: Int64) -> String {
        let mb = Double(bytes) / 1_048_576.0
        let gb = Double(bytes) / 1_073_741_824.0
        if gb >= 1 {
            return String(format: "%.2f GB", gb)
        }
        return String(format: "%.1f MB", mb)
    }

    private func refreshStats() async {
        guard !loadingStats else { return }
        loadingStats = true
        defer { loadingStats = false }

        do {
            let usage = try await PaperLinkSyncManager.shared.fetchUsageStats()
            serverStorageBytes = usage.storageBytes
            serverNoteCounts = usage.noteCounts
            statsError = nil
        } catch {
            statsError = "Server stats unavailable. Showing local note counts."
        }
    }
}
