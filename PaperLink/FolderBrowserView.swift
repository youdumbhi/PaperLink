//
//  FolderBrowserView.swift
//  PaperLink
//

import SwiftUI
import SwiftData

struct FolderBrowserView: View {
    @EnvironmentObject private var theme: PLThemeStore
    @Environment(\.plDockedSidebarInset) private var dockedSidebarInset

    @Query(sort: \PLFolder.createdAt, order: .forward) private var folders: [PLFolder]
    @Query(sort: \PLNote.updatedAt, order: .reverse) private var notes: [PLNote]

    @State private var query: String = ""
    @State private var currentFolderID: UUID? = nil

    private var isPhone: Bool {
#if canImport(UIKit)
        UIDevice.current.userInterfaceIdiom == .phone
#else
        false
#endif
    }

    private var headerMenuClearance: CGFloat {
        isPhone ? 58 : (dockedSidebarInset > 0 ? 0 : 68)
    }

    private var contentLeadingInset: CGFloat {
        isPhone ? 0 : dockedSidebarInset
    }

    private var liveFolders: [PLFolder] {
        folders.filter { $0.deletedAt == nil }
    }

    private var liveNotes: [PLNote] {
        notes.filter { $0.deletedAt == nil }
    }

    private var currentFolder: PLFolder? {
        guard let currentFolderID else { return nil }
        return liveFolders.first(where: { $0.id == currentFolderID })
    }

    private var displayedFolders: [PLFolder] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if trimmed.isEmpty {
            return liveFolders
                .filter { $0.parentFolderID == currentFolderID }
                .sorted { lhs, rhs in
                    lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
        }

        return liveFolders
            .filter { folder in
                folder.name.lowercased().contains(trimmed) || folderPath(for: folder).lowercased().contains(trimmed)
            }
            .sorted { lhs, rhs in
                let lhsDepth = folderDepth(lhs)
                let rhsDepth = folderDepth(rhs)
                if lhsDepth == rhsDepth {
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
                return lhsDepth < rhsDepth
            }
    }

    private var gridColumns: [GridItem] {
#if canImport(UIKit)
        if isPhone {
            return [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 12)]
        }
#endif
        return [GridItem(.adaptive(minimum: 210, maximum: 270), spacing: 16)]
    }

    var body: some View {
        let p = theme.palette

        ZStack {
            p.background.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    searchBar

                    if currentFolder != nil && query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        breadcrumb
                    }

                    if displayedFolders.isEmpty {
                        emptyState
                    } else {
                        LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 16) {
                            ForEach(displayedFolders, id: \.id) { folder in
                                folderCard(folder)
                            }
                        }
                    }
                }
                .padding(.horizontal, isPhone ? 14 : 22)
                .padding(.top, 14)
                .padding(.bottom, isPhone ? 18 : 26)
                .padding(.leading, contentLeadingInset)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .animation(.spring(response: 0.30, dampingFraction: 0.90), value: currentFolderID)
        .animation(.spring(response: 0.24, dampingFraction: 0.92), value: query)
    }

    private var header: some View {
        let p = theme.palette

        return HStack(alignment: .top, spacing: 14) {
            Color.clear
                .frame(width: headerMenuClearance, height: 1)

            VStack(alignment: .leading, spacing: 8) {
                Text("Folders")
                    .font(.system(size: 30, weight: .heavy))
                    .foregroundStyle(p.textPrimary)

                Text(query.isEmpty
                     ? "\(displayedFolders.count) folder\(displayedFolders.count == 1 ? "" : "s") here"
                     : "\(displayedFolders.count) result\(displayedFolders.count == 1 ? "" : "s")")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(p.textSecondary)
            }

            Spacer(minLength: 0)
        }
    }

    private var searchBar: some View {
        let p = theme.palette

        return HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(p.textSecondary.opacity(0.9))

            TextField("Search folders", text: $query)
                .textFieldStyle(.plain)
                .submitLabel(.search)
                .foregroundStyle(p.textPrimary)

            if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(p.textSecondary.opacity(0.7))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
        .background(p.card.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(p.outline, lineWidth: 1)
        )
    }

    private var breadcrumb: some View {
        let p = theme.palette

        return HStack(spacing: 10) {
            if let currentFolder {
                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.90)) {
                        currentFolderID = currentFolder.parentFolderID
                    }
                } label: {
                    Label("Back", systemImage: "chevron.left")
                        .font(.system(size: 14, weight: .bold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(p.railButton)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(p.outline, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .foregroundStyle(p.textPrimary)
            }

            Button {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.90)) {
                    currentFolderID = nil
                }
            } label: {
                Label("Root", systemImage: "house")
                    .font(.system(size: 14, weight: .bold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(p.railButton)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(p.outline, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .foregroundStyle(p.textPrimary)

            if let currentFolder {
                Text(currentFolder.name)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(p.textPrimary.opacity(0.95))
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
    }

    private var emptyState: some View {
        let p = theme.palette
        let hasQuery = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        return VStack(alignment: .leading, spacing: 10) {
            Image(systemName: hasQuery ? "magnifyingglass" : "folder")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(p.accent)

            Text(hasQuery ? "No matching folders" : "No folders here yet")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(p.textPrimary)

            Text(hasQuery
                 ? "Try a different search."
                 : "Create folders from the home tab and they’ll show up here.")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(p.textSecondary)
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

    private func folderCard(_ folder: PLFolder) -> some View {
        let previewNote = previewNote(for: folder)
        let path = folderPath(for: folder)
        let stats = folderCardStats(for: folder)

        return Button {
            withAnimation(.spring(response: 0.30, dampingFraction: 0.90)) {
                currentFolderID = folder.id
                query = ""
            }
        } label: {
            FolderCardSquare(folder: folder, previewNote: previewNote, stats: stats, pathLabel: path)
                .frame(height: isPhone ? 164 : 208)
        }
        .buttonStyle(.plain)
    }

    private func folderCardStats(for folder: PLFolder) -> FolderCardStats {
        FolderCardStats(
            folderCount: liveFolders.filter { $0.parentFolderID == folder.id }.count,
            noteCount: liveNotes.filter { $0.folderID == folder.id }.count
        )
    }

    private func previewNote(for folder: PLFolder) -> PLNote? {
        let ids = collectFolderSubtreeIDs(root: folder.id)
        return liveNotes
            .filter { note in
                guard let folderID = note.folderID else { return false }
                return ids.contains(folderID)
            }
            .sorted { $0.updatedAt > $1.updatedAt }
            .first
    }

    private func collectFolderSubtreeIDs(root: UUID) -> Set<UUID> {
        var ids: Set<UUID> = [root]
        var queue: [UUID] = [root]

        while let current = queue.first {
            queue.removeFirst()
            let children = liveFolders.filter { $0.parentFolderID == current }
            for child in children where !ids.contains(child.id) {
                ids.insert(child.id)
                queue.append(child.id)
            }
        }

        return ids
    }

    private func folderPath(for folder: PLFolder) -> String {
        var names: [String] = [folder.name]
        var cursor = folder.parentFolderID

        while let id = cursor, let parent = liveFolders.first(where: { $0.id == id }) {
            names.insert(parent.name, at: 0)
            cursor = parent.parentFolderID
        }

        return names.joined(separator: " / ")
    }

    private func folderDepth(_ folder: PLFolder) -> Int {
        var depth = 0
        var cursor = folder.parentFolderID
        while let id = cursor, let parent = liveFolders.first(where: { $0.id == id }) {
            depth += 1
            cursor = parent.parentFolderID
        }
        return depth
    }
}
