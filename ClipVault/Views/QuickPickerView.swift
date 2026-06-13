//
//  QuickPickerView.swift
//  ClipVault
//
//  Compact hold-and-cycle picker shown by QuickPickerManager next to the
//  cursor while ⌘⇧ is held. Read-only list of the most recent items with a
//  single highlighted selection.
//

import SwiftUI
import AppKit

final class QuickPickerViewModel: ObservableObject {
    @Published var items: [ClipItem]
    @Published var selectedIndex: Int = 0

    var onRowClicked: ((Int) -> Void)?

    init(items: [ClipItem]) {
        self.items = items
    }

    func moveSelection(by delta: Int) {
        guard !items.isEmpty else { return }
        let count = items.count
        selectedIndex = (selectedIndex + delta + count) % count
    }
}

struct QuickPickerView: View {
    @ObservedObject var viewModel: QuickPickerViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if viewModel.items.isEmpty {
                Text("No clipboard history")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            } else {
                ForEach(Array(viewModel.items.enumerated()), id: \.offset) { index, item in
                    row(for: item, at: index)
                }
            }

            Divider()
                .padding(.top, 2)

            Text("release to paste · esc cancel")
                .font(.caption2)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 4)
        }
        .padding(8)
        .frame(width: 380)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
        )
    }

    private func row(for item: ClipItem, at index: Int) -> some View {
        let isSelected = index == viewModel.selectedIndex

        return HStack(spacing: 8) {
            Text("\(index + 1)")
                .font(.caption.monospacedDigit())
                .foregroundColor(isSelected ? .white : .secondary)
                .frame(width: 16)

            appIcon(for: item)

            Text(item.getPreviewText(maxLength: 50))
                .lineLimit(1)
                .foregroundColor(isSelected ? .white : .primary)

            Spacer(minLength: 4)

            Text(item.getRelativeTimeString())
                .font(.caption2)
                .foregroundColor(isSelected ? Color.white.opacity(0.8) : .secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            viewModel.onRowClicked?(index)
        }
    }

    @ViewBuilder
    private func appIcon(for item: ClipItem) -> some View {
        if let bundleID = item.appBundleID,
           let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: appURL.path))
                .resizable()
                .frame(width: 16, height: 16)
        } else {
            Image(systemName: "questionmark.app")
                .frame(width: 16, height: 16)
                .foregroundColor(.secondary)
        }
    }
}
