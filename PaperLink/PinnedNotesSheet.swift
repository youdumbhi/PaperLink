//
//  PinnedNotesSheet.swift
//  PaperLink
//
//  Created by Ben Chen on 2/2/26.
//

import SwiftUI
import SwiftData

struct PinnedNotesSheet: View {
    @EnvironmentObject private var theme: PLThemeStore
    @Environment(\.dismiss) private var dismiss

    @Query(
        filter: #Predicate<PLNote> { $0.pinned == true },
        sort: \PLNote.updatedAt,
        order: .reverse
    )
    private var pinned: [PLNote]

    var body: some View {
        let p = theme.palette

        NavigationStack {
            List {
                if pinned.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No pinned notes")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(p.textPrimary)
                        Text("Pin notes from the Library to keep them here.")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(p.textSecondary)
                    }
                    .padding(.vertical, 10)
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(pinned) { note in
                        HStack(spacing: 12) {
                            Image(systemName: "pin.fill")
                                .foregroundStyle(p.textSecondary)

                            VStack(alignment: .leading, spacing: 4) {
                                Text(note.title)
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundStyle(p.textPrimary)

                                Text(note.kindRaw.uppercased())
                                    .font(.system(size: 11, weight: .heavy))
                                    .foregroundStyle(p.textSecondary)
                            }

                            Spacer()

                            Image(systemName: "chevron.right")
                                .opacity(0.25)
                                .foregroundStyle(p.textSecondary)
                        }
                        .padding(.vertical, 6)
                        .listRowBackground(p.card.opacity(0.55))
                        .overlay(
                            RoundedRectangle(cornerRadius: 0)
                                .stroke(p.outline.opacity(0.0), lineWidth: 0)
                        )
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(p.canvas)
            .navigationTitle("Pinned")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(.system(size: 16, weight: .bold))
                }
            }
        }
        .presentationBackground(p.background)
    }
}
