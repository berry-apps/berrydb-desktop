import AppKit
import BerryCore
import SwiftUI

/// Backup manager tab (docs/feature/04), Navicat-style: an icon toolbar
/// (New Backup / Restore / Delete / Reveal / Refresh) over the list of a
/// connection's past backups. New Backup opens the object-selection sheet;
/// Restore runs the selected backup (`.sql` dump or Mongo/Qdrant bundle).
struct BackupManagerView: View {
    @Bindable var viewModel: WorkspaceViewModel
    var onClose: () -> Void

    @State private var selection: BackupFile.ID?
    @State private var showNewBackup = false
    @State private var confirmRestore = false
    @State private var isRestoring = false
    @State private var status: String?
    @State private var progress = BackupProgress()

    private var selectedFile: BackupFile? {
        viewModel.backupFiles.first { $0.id == selection }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
            if isRestoring || status != nil {
                Divider()
                HStack(spacing: 8) {
                    if isRestoring {
                        if let fraction = progress.fraction {
                            ProgressView(value: fraction).frame(width: 120)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                        Text(progress.label.map { L("Restoring \($0)…") } ?? L("Restoring…"))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    } else if let status {
                        Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer()
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { viewModel.refreshBackups() }
        .sheet(isPresented: $showNewBackup) { newBackupSheet }
        .confirmationDialog(
            L("Restore this backup? Existing objects may be overwritten."),
            isPresented: $confirmRestore, titleVisibility: .visible
        ) {
            Button(L("Restore"), role: .destructive) { restore() }
            Button(L("Cancel"), role: .cancel) {}
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 4) {
            toolButton(L("New Backup"), "plus", enabled: viewModel.session != nil || viewModel.dataSourceSession != nil) {
                showNewBackup = true
            }
            toolButton(L("Restore"), "arrow.up.doc", enabled: selectedFile != nil && !isRestoring) {
                confirmRestore = true
            }
            toolButton(L("Delete"), "trash", enabled: selectedFile != nil) {
                if let file = selectedFile { viewModel.deleteBackup(file); selection = nil }
            }
            toolButton(L("Show in Finder"), "folder", enabled: selectedFile != nil) {
                if let file = selectedFile { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
            }
            toolButton(L("Refresh"), "arrow.clockwise", enabled: true) { viewModel.refreshBackups() }
            Spacer()
            Button(L("Close"), action: onClose)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(.bar)
    }

    private func toolButton(_ title: String, _ icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon) }
            .buttonStyle(.borderless)
            .focusEffectDisabled()
            .disabled(!enabled)
            .help(title)
            .accessibilityLabel(title)
    }

    // MARK: List

    @ViewBuilder
    private var content: some View {
        if viewModel.backupFiles.isEmpty {
            ContentUnavailableView(
                L("No backups yet"),
                systemImage: "externaldrive",
                description: Text(L("Create one with New Backup."))
            )
            .frame(maxHeight: .infinity)
        } else {
            List(selection: $selection) {
                ForEach(viewModel.backupFiles) { file in
                    HStack(spacing: 8) {
                        Image(systemName: file.isBundle ? "shippingbox" : "doc.text")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(file.name).font(.callout)
                            Text(file.modified, format: .dateTime.day().month().year().hour().minute())
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(file.isBundle ? L("Bundle") : L("SQL"))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .tag(file.id)
                    .padding(.vertical, 2)
                }
            }
            .listStyle(.inset)
        }
    }

    // MARK: New Backup sheet

    @ViewBuilder
    private var newBackupSheet: some View {
        if let session = viewModel.session {
            BackupSheet(
                session: session,
                objects: viewModel.objects,
                directory: viewModel.backupDirectory,
                onCreated: { showNewBackup = false; viewModel.refreshBackups() },
                onCancel: { showNewBackup = false }
            )
        } else if let ds = viewModel.dataSourceSession {
            DataSourceBackupSheet(
                session: ds,
                collections: viewModel.collections.map(\.name),
                directory: viewModel.backupDirectory,
                onCreated: { showNewBackup = false; viewModel.refreshBackups() },
                onCancel: { showNewBackup = false }
            )
        } else {
            Text(L("No connection")).padding()
        }
    }

    // MARK: Restore

    private func restore() {
        guard let file = selectedFile else { return }
        isRestoring = true
        status = nil
        progress.reset()
        let progress = progress
        let onProgress: @Sendable (Int, Int, String) -> Void = { done, total, label in
            Task { @MainActor in progress.update(done: done, total: total, label: label) }
        }
        Task {
            do {
                if let session = viewModel.session, !file.isBundle {
                    let result = try await BackupService.restoreSQL(session: session, from: file.url, progress: onProgress)
                    status = L("Ran \(result.executed) statement(s), \(result.failures.count) failed.")
                } else if let ds = viewModel.dataSourceSession, file.isBundle {
                    let result = try await DataSourceBackupService.restore(session: ds, from: file.url, progress: onProgress)
                    status = L("Restored \(result.documents) document(s) across \(result.collections) collection(s).")
                } else {
                    status = L("This backup doesn't match the current connection type.")
                }
                viewModel.refreshSchema()
            } catch {
                status = error.localizedDescription
            }
            isRestoring = false
        }
    }
}
