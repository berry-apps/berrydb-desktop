import AppKit
import BerryCore
import BerryDataSourceKit
import BerryDriverKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

public struct RestoreDumpState: Sendable, Equatable {
    public var cleanBeforeRestore: Bool = false
    public var inspectionResult: DumpInspectionResult?

    public init(cleanBeforeRestore: Bool = false, inspectionResult: DumpInspectionResult? = nil) {
        self.cleanBeforeRestore = cleanBeforeRestore
        self.inspectionResult = inspectionResult
    }
}

public struct RestoreDumpSheet: View {
    let session: Session?
    let dataSourceSession: DataSourceSession?
    var onDismiss: () -> Void
    var onSuccess: (() -> Void)?

    @State private var fileURL: URL?
    @State private var state = RestoreDumpState()
    @State private var isRestoring = false
    @State private var confirmDanger = false
    @State private var statusMessage: String?
    @State private var isFinished = false

    public init(session: Session?, dataSourceSession: DataSourceSession?, onDismiss: @escaping () -> Void, onSuccess: (() -> Void)? = nil) {
        self.session = session
        self.dataSourceSession = dataSourceSession
        self.onDismiss = onDismiss
        self.onSuccess = onSuccess
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(L("Restore Database from Dump"), systemImage: "arrow.counterclockwise.circle").font(.headline)
                Spacer()
            }
            .padding(12)
            Divider()

            Form {
                HStack {
                    TextField(L("Dump File"), text: .constant(fileURL?.path(percentEncoded: false) ?? L("Select dump file…")))
                        .disabled(true)
                    Button(L("Browse…")) { pickFile() }
                        .disabled(isRestoring)
                }

                if let inspection = state.inspectionResult {
                    Section {
                        HStack {
                            Text(L("Format:"))
                            Spacer()
                            Text(formatDescription(inspection.format))
                                .font(.callout.bold())
                        }
                        if let dialect = inspection.detectedDialectName {
                            HStack {
                                Text(L("Detected Engine:"))
                                Spacer()
                                Text(dialect)
                                    .font(.callout)
                            }
                        }
                    }
                }

                Toggle(L("Drop / Clean existing objects before restore"), isOn: $state.cleanBeforeRestore)
                    .disabled(isRestoring)
                
                Toggle(L("I understand this operation will overwrite existing database data"), isOn: $confirmDanger)
                    .disabled(isRestoring)
                    .foregroundStyle(.red)
            }
            .padding(16)

            if isRestoring || isFinished || statusMessage != nil {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        if isRestoring { ProgressView().controlSize(.small) }
                        Text(statusMessage ?? (isRestoring ? L("Restoring…") : L("Restore complete")))
                            .font(.callout)
                            .foregroundStyle(statusMessage != nil && !isRestoring && !isFinished ? .red : .primary)
                    }
                }
                .padding(12)
            }

            Spacer()
            Divider()
            HStack {
                Spacer()
                Button(L("Cancel"), action: onDismiss)
                    .disabled(isRestoring)
                Button(isFinished ? L("Done") : L("Restore"), action: isFinished ? onDismiss : startRestore)
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(!isFinished && (fileURL == nil || !confirmDanger || isRestoring))
            }
            .padding(12)
        }
        .frame(width: 540, height: 380)
    }

    private func formatDescription(_ format: DumpFormat) -> String {
        switch format {
        case .postgresCustomDump: return "PostgreSQL Custom Binary Dump (pg_dump -Fc)"
        case .postgresPlainSQL: return "PostgreSQL Plain SQL Script"
        case .mysqlPlainSQL: return "MySQL Plain SQL Dump"
        case .sqliteBinary: return "SQLite Database File"
        case .gzippedSQL: return "Gzip Compressed SQL Dump"
        case .berryBundle: return "BerryDB Multi-Table Bundle"
        case .genericSQL: return "Generic SQL Script"
        case .unknown: return "Unknown format"
        }
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            fileURL = url
            state.inspectionResult = nil
            statusMessage = nil
            do {
                state.inspectionResult = try DumpInspector.inspect(url: url)
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }

    private func runPGRestore(fileURL: URL, exeURL: URL, session: Session) async throws {
        var args = SQLCLIImporter.buildArguments(
            for: .pg_restore,
            fileURL: fileURL,
            host: session.config.host,
            port: session.config.port,
            database: session.config.database,
            user: session.config.username
        )
        if state.cleanBeforeRestore {
            args.insert("--clean", at: 0)
        }

        var env = ProcessInfo.processInfo.environment
        if let password = session.config.password, !password.isEmpty {
            env["PGPASSWORD"] = password
        }

        try await Task.detached {
            let process = Process()
            process.executableURL = exeURL
            process.arguments = args
            process.environment = env
            process.standardOutput = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice

            let errorPipe = Pipe()
            process.standardError = errorPipe

            // Concurrently drain stderr to prevent pipe buffer deadlock (>64KB output)
            let errorReadTask = Task.detached {
                errorPipe.fileHandleForReading.readDataToEndOfFile()
            }

            try process.run()
            process.waitUntilExit()

            let errorData = await errorReadTask.value

            if process.terminationStatus != 0 {
                let errorText = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                throw NSError(
                    domain: "SQLCLIImporter",
                    code: Int(process.terminationStatus),
                    userInfo: [
                        NSLocalizedDescriptionKey: (errorText?.isEmpty == false)
                            ? errorText!
                            : "pg_restore exited with status code \(process.terminationStatus)"
                    ]
                )
            }
        }.value
    }

    private func startRestore() {
        guard let url = fileURL else { return }
        isRestoring = true
        statusMessage = L("Starting restore…")

        Task {
            do {
                if let inspection = try? DumpInspector.inspect(url: url), inspection.format == .gzippedSQL {
                    throw NSError(
                        domain: "RestoreDumpSheet",
                        code: 5,
                        userInfo: [NSLocalizedDescriptionKey: L("Gzip-compressed SQL files (.sql.gz) must be decompressed before restoring.")]
                    )
                }

                if let session = session {
                    if state.inspectionResult?.format == .berryBundle {
                        throw NSError(
                            domain: "RestoreDumpSheet",
                            code: 2,
                            userInfo: [NSLocalizedDescriptionKey: L("BerryDB bundles cannot be restored into a SQL connection.")]
                        )
                    }

                    if state.inspectionResult?.format == .postgresCustomDump {
                        guard session.config.driver == .postgres else {
                            throw NSError(
                                domain: "RestoreDumpSheet",
                                code: 4,
                                userInfo: [NSLocalizedDescriptionKey: L("PostgreSQL custom dumps can only be restored into a PostgreSQL database.")]
                            )
                        }
                        if let exeURL = SQLCLIImporter.findExecutable(.pg_restore) {
                            try await runPGRestore(fileURL: url, exeURL: exeURL, session: session)
                            await MainActor.run {
                                statusMessage = L("Restore completed successfully via pg_restore.")
                                isRestoring = false
                                isFinished = true
                                onSuccess?()
                            }
                        } else {
                            throw NSError(
                                domain: "RestoreDumpSheet",
                                code: 1,
                                userInfo: [NSLocalizedDescriptionKey: L("pg_restore executable not found. Please install PostgreSQL client tools.")]
                            )
                        }
                    } else {
                        var count = 0
                        for try await stmt in SQLStreamReader.statements(from: url) {
                            for try await _ in QueryService.execute(stmt.sql, on: session, autoLimit: nil, recordHistory: false, dangerPreconfirmed: true) {}
                            count += 1
                        }
                        await MainActor.run {
                            statusMessage = String(format: L("Restore completed successfully: %d statement(s) executed."), count)
                            isRestoring = false
                            isFinished = true
                            onSuccess?()
                        }
                    }
                } else if let ds = dataSourceSession {
                    if state.inspectionResult?.format != .berryBundle && state.inspectionResult?.format != .unknown && state.inspectionResult != nil {
                        throw NSError(
                            domain: "RestoreDumpSheet",
                            code: 3,
                            userInfo: [NSLocalizedDescriptionKey: L("SQL dumps cannot be restored into a NoSQL/vector connection.")]
                        )
                    }
                    let result = try await DataSourceBackupService.restore(session: ds, from: url)
                    await MainActor.run {
                        statusMessage = String(format: L("Restore completed successfully: %d document(s) across %d collection(s)."), result.documents, result.collections)
                        isRestoring = false
                        isFinished = true
                        onSuccess?()
                    }
                } else {
                    await MainActor.run {
                        statusMessage = L("No active connection to restore into.")
                        isRestoring = false
                    }
                }
            } catch {
                await MainActor.run {
                    statusMessage = error.localizedDescription
                    isRestoring = false
                }
            }
        }
    }
}
