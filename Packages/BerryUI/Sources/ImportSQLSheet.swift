import AppKit
import BerryCore
import BerryDriverKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

public struct ImportSQLOptions: Sendable, Equatable {
    public var stopOnError: Bool = true
    public var useCLIIfAvailable: Bool = false
    public var wrapInTransaction: Bool = false

    public init(stopOnError: Bool = true, useCLIIfAvailable: Bool = false, wrapInTransaction: Bool = false) {
        self.stopOnError = stopOnError
        self.useCLIIfAvailable = useCLIIfAvailable
        self.wrapInTransaction = wrapInTransaction
    }
}

public struct ImportSQLSheet: View {
    let session: Session
    var onDismiss: () -> Void
    var onSuccess: (() -> Void)?

    @State private var selectedFileURL: URL?
    @State private var options = ImportSQLOptions()
    @State private var isRunning = false
    @State private var executedCount = 0
    @State private var failureCount = 0
    @State private var errorMessage: String?
    @State private var progressMessage: String?
    @State private var isFinished = false

    public init(session: Session, initialFileURL: URL? = nil, onDismiss: @escaping () -> Void, onSuccess: (() -> Void)? = nil) {
        self.session = session
        self._selectedFileURL = State(initialValue: initialFileURL)
        self.onDismiss = onDismiss
        self.onSuccess = onSuccess
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(L("Import SQL File"), systemImage: "arrow.down.doc").font(.headline)
                Spacer()
            }
            .padding(12)
            Divider()

            Form {
                HStack {
                    TextField(L("File"), text: .constant(selectedFileURL?.path(percentEncoded: false) ?? L("No file selected")))
                        .disabled(true)
                    Button(L("Browse…")) { pickFile() }
                        .disabled(isRunning)
                }

                Toggle(L("Stop on first error"), isOn: $options.stopOnError)
                Toggle(L("Wrap in single transaction"), isOn: $options.wrapInTransaction)

                if let size = fileSize, size > 500 * 1024 * 1024 {
                    Toggle(L("Use High-Performance CLI Engine (if installed)"), isOn: $options.useCLIIfAvailable)
                }
            }
            .padding(16)

            if isRunning || isFinished {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        if isRunning { ProgressView().controlSize(.small) }
                        Text(progressMessage ?? (isRunning ? L("Importing… \(executedCount) statements executed") : L("Import finished: \(executedCount) succeeded, \(failureCount) failed")))
                            .font(.callout)
                    }
                    if let errorMessage {
                        Text(errorMessage).font(.caption).foregroundStyle(.red)
                    }
                }
                .padding(12)
            }

            Spacer()
            Divider()
            HStack {
                Spacer()
                Button(L("Cancel"), action: onDismiss)
                    .disabled(isRunning)
                Button(isFinished ? L("Done") : L("Import"), action: isFinished ? onDismiss : startImport)
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedFileURL == nil || isRunning)
            }
            .padding(12)
        }
        .frame(width: 520, height: 360)
    }

    private var fileSize: Int64? {
        guard let url = selectedFileURL else { return nil }
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize else { return nil }
        return Int64(size)
    }

    private var cliExecutableForSession: CLIExecutable? {
        switch session.config.driver {
        case .postgres:
            return .psql
        case .mysql:
            return .mysql
        case .sqlite:
            return .sqlite3
        default:
            return nil
        }
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "sql")].compactMap(\.self)
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK {
            selectedFileURL = panel.url
        }
    }

    private func runCLIImport(fileURL: URL, executable: CLIExecutable, exeURL: URL) async throws {
        let dbName: String?
        if session.config.driver == .sqlite {
            dbName = session.config.filePath ?? session.config.database
        } else {
            dbName = session.config.database
        }

        let args = SQLCLIImporter.buildArguments(
            for: executable,
            fileURL: fileURL,
            host: session.config.host,
            port: session.config.port,
            database: dbName,
            user: session.config.username
        )

        var env = ProcessInfo.processInfo.environment
        if let password = session.config.password, !password.isEmpty {
            switch executable {
            case .psql, .pg_restore:
                env["PGPASSWORD"] = password
            case .mysql:
                env["MYSQL_PWD"] = password
            default:
                break
            }
        }

        try await Task.detached {
            let process = Process()
            process.executableURL = exeURL
            process.arguments = args
            process.environment = env
            process.standardOutput = FileHandle.nullDevice

            let errorPipe = Pipe()
            process.standardError = errorPipe

            var stdinFileHandle: FileHandle?
            if executable == .mysql || executable == .sqlite3 {
                let handle = try FileHandle(forReadingFrom: fileURL)
                stdinFileHandle = handle
                process.standardInput = handle
            } else {
                process.standardInput = FileHandle.nullDevice
            }
            defer { try? stdinFileHandle?.close() }

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
                            : "CLI exited with status code \(process.terminationStatus)"
                    ]
                )
            }
        }.value
    }

    private func startImport() {
        guard let fileURL = selectedFileURL else { return }
        isRunning = true
        errorMessage = nil
        progressMessage = nil
        executedCount = 0
        failureCount = 0

        Task {
            if let inspection = try? DumpInspector.inspect(url: fileURL), inspection.format == .gzippedSQL {
                await MainActor.run {
                    errorMessage = L("Gzip-compressed SQL files (.sql.gz) must be decompressed before importing.")
                    isRunning = false
                    isFinished = true
                }
                return
            }

            if options.useCLIIfAvailable,
               let cliExe = cliExecutableForSession,
               let exeURL = SQLCLIImporter.findExecutable(cliExe) {
                await MainActor.run {
                    progressMessage = String(format: L("Importing via %@…"), cliExe.binaryName)
                }
                do {
                    try await runCLIImport(fileURL: fileURL, executable: cliExe, exeURL: exeURL)
                    await MainActor.run {
                        executedCount = 1
                        progressMessage = nil
                        isRunning = false
                        isFinished = true
                        onSuccess?()
                    }
                } catch {
                    await MainActor.run {
                        failureCount = 1
                        errorMessage = error.localizedDescription
                        progressMessage = nil
                        isRunning = false
                        isFinished = true
                    }
                }
                return
            }

            var transactionStarted = false
            var fatalErrorEncountered = false
            var localExecuted = 0
            var localFailed = 0

            do {
                if options.wrapInTransaction {
                    for try await _ in QueryService.execute("BEGIN;", on: session, autoLimit: nil, recordHistory: false, dangerPreconfirmed: true) {}
                    transactionStarted = true
                }

                for try await stmt in SQLStreamReader.statements(from: fileURL) {
                    do {
                        for try await _ in QueryService.execute(stmt.sql, on: session, autoLimit: nil, recordHistory: false, dangerPreconfirmed: true) {}
                        localExecuted += 1
                        if localExecuted % 50 == 0 {
                            let count = localExecuted
                            await MainActor.run { executedCount = count }
                        }
                    } catch {
                        localFailed += 1
                        let count = localExecuted
                        let fails = localFailed
                        let errDesc = error.localizedDescription
                        await MainActor.run {
                            executedCount = count
                            failureCount = fails
                            if options.stopOnError || errorMessage == nil {
                                errorMessage = errDesc
                            }
                        }
                        if options.stopOnError {
                            fatalErrorEncountered = true
                            break
                        }
                    }
                }

                let finalExecuted = localExecuted
                let finalFailed = localFailed
                await MainActor.run {
                    executedCount = finalExecuted
                    failureCount = finalFailed
                }

                if options.wrapInTransaction && transactionStarted {
                    if fatalErrorEncountered || localFailed > 0 {
                        do {
                            for try await _ in QueryService.execute("ROLLBACK;", on: session, autoLimit: nil, recordHistory: false, dangerPreconfirmed: true) {}
                        } catch {}
                    } else {
                        for try await _ in QueryService.execute("COMMIT;", on: session, autoLimit: nil, recordHistory: false, dangerPreconfirmed: true) {}
                    }
                }
            } catch {
                await MainActor.run { errorMessage = error.localizedDescription }
                if options.wrapInTransaction && transactionStarted {
                    do {
                        for try await _ in QueryService.execute("ROLLBACK;", on: session, autoLimit: nil, recordHistory: false, dangerPreconfirmed: true) {}
                    } catch {}
                }
            }

            await MainActor.run {
                isRunning = false
                isFinished = true
                if !fatalErrorEncountered && errorMessage == nil {
                    onSuccess?()
                }
            }
        }
    }
}
