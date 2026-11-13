import BerryDriverKit
import Foundation
import os

enum HranaValue: Sendable, Equatable {
    case null
    case integer(Int64)
    case float(Double)
    case text(String)
    case blob(Data)

    func toBerryValue() -> BerryValue {
        switch self {
        case .null: .null
        case .integer(let v): .int(v)
        case .float(let v): .double(v)
        case .text(let v): .text(v)
        case .blob(let v): .bytes(v)
        }
    }

    static func from(_ parameter: SQLParameter) throws -> HranaValue {
        switch parameter {
        case .null:
            return .null
        case .bool(let value):
            return .integer(value ? 1 : 0)
        case .int(let value):
            return .integer(value)
        case .double(let value):
            guard value.isFinite else {
                throw DriverError.queryFailed(
                    message: "Non-finite floating-point parameters cannot be encoded in JSON.",
                    code: nil
                )
            }
            return .float(value)
        case .text(let value):
            return .text(value)
        }
    }
}

extension HranaValue: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case value
        case base64
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "null":
            self = .null
        case "integer":
            if let str = try? container.decode(String.self, forKey: .value),
               let parsed = Int64(str) {
                self = .integer(parsed)
            } else if let num = try? container.decode(Int64.self, forKey: .value) {
                self = .integer(num)
            } else {
                throw DecodingError.dataCorruptedError(
                    forKey: .value,
                    in: container,
                    debugDescription: "Invalid Hrana integer value"
                )
            }
        case "float":
            if let num = try? container.decode(Double.self, forKey: .value) {
                self = .float(num)
            } else if let str = try? container.decode(String.self, forKey: .value),
                      let parsed = Double(str) {
                self = .float(parsed)
            } else {
                throw DecodingError.dataCorruptedError(
                    forKey: .value,
                    in: container,
                    debugDescription: "Invalid Hrana float value"
                )
            }
        case "text":
            let text = try container.decode(String.self, forKey: .value)
            self = .text(text)
        case "blob":
            let encoded = try container.decode(String.self, forKey: .base64)
            guard let data = Self.decodeBase64Flexible(encoded) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .base64,
                    in: container,
                    debugDescription: "Invalid base64 blob payload"
                )
            }
            self = .blob(data)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unsupported Hrana value type '\(type)'"
            )
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .null:
            try container.encode("null", forKey: .type)
        case .integer(let value):
            try container.encode("integer", forKey: .type)
            try container.encode(String(value), forKey: .value)
        case .float(let value):
            try container.encode("float", forKey: .type)
            try container.encode(value, forKey: .value)
        case .text(let value):
            try container.encode("text", forKey: .type)
            try container.encode(value, forKey: .value)
        case .blob(let data):
            try container.encode("blob", forKey: .type)
            try container.encode(data.base64EncodedString(), forKey: .base64)
        }
    }

    /// sqld omits trailing '=' padding in Hrana JSON blob payloads (RFC 4648 unpadded base64),
    /// whereas Foundation's `Data(base64Encoded:)` requires 4-character padding.
    private static func decodeBase64Flexible(_ raw: String) -> Data? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = Data(base64Encoded: trimmed) {
            return data
        }
        let remainder = trimmed.count % 4
        guard remainder != 1 else { return nil }
        let padded = remainder == 0 ? trimmed : trimmed + String(repeating: "=", count: 4 - remainder)
        return Data(base64Encoded: padded)
    }
}

struct HranaStatement: Encodable, Sendable {
    let sql: String
    let args: [HranaValue]?
    let want_rows: Bool?
}

enum HranaStreamRequest: Encodable, Sendable {
    case execute(HranaStatement)
    case close

    private enum CodingKeys: String, CodingKey {
        case type
        case stmt
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .execute(let stmt):
            try container.encode("execute", forKey: .type)
            try container.encode(stmt, forKey: .stmt)
        case .close:
            try container.encode("close", forKey: .type)
        }
    }
}

struct HranaPipelineRequest: Encodable, Sendable {
    let baton: String?
    let requests: [HranaStreamRequest]
}

struct HranaColumn: Decodable, Sendable {
    let name: String?
    let decltype: String?
}

struct HranaExecuteResult: Decodable, Sendable {
    let cols: [HranaColumn]
    let rows: [[HranaValue]]
    let affected_row_count: Int64?
    let last_insert_rowid: String?
}

struct HranaErrorPayload: Decodable, Sendable {
    let message: String
    let code: String?
}

enum HranaStepResponse: Decodable, Sendable {
    case execute(HranaExecuteResult)
    case close

    private enum CodingKeys: String, CodingKey {
        case type
        case result
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "execute":
            let result = try container.decode(HranaExecuteResult.self, forKey: .result)
            self = .execute(result)
        case "close":
            self = .close
        default:
            self = .close
        }
    }
}

struct HranaStepOutcome: Decodable, Sendable {
    let type: String
    let response: HranaStepResponse?
    let error: HranaErrorPayload?
}

struct HranaPipelineResponse: Decodable, Sendable {
    let baton: String?
    let base_url: String?
    let results: [HranaStepOutcome]
}

private struct TaskTransferState: @unchecked Sendable {
    let maxBytes: Int
    var buffer = Data()
    var response: URLResponse?
    var exceededLimitError: DriverError?
    let continuation: CheckedContinuation<(Data, URLResponse), Error>
    let onComplete: @Sendable () -> Void
}

private final class PipelineSessionDelegate: NSObject, URLSessionDataDelegate, Sendable {
    private let transfers = OSAllocatedUnfairLock<[Int: TaskTransferState]>(initialState: [:])

    func register(
        taskID: Int,
        maxBytes: Int,
        continuation: CheckedContinuation<(Data, URLResponse), Error>,
        onComplete: @escaping @Sendable () -> Void
    ) {
        let state = TaskTransferState(
            maxBytes: maxBytes,
            continuation: continuation,
            onComplete: onComplete
        )
        transfers.withLock { $0[taskID] = state }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        // Never follow HTTP redirects automatically so Bearer tokens cannot be forwarded off-origin.
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        let disposition: URLSession.ResponseDisposition = transfers.withLock { dict in
            guard var state = dict[dataTask.taskIdentifier] else {
                return .cancel
            }
            state.response = response
            if response.expectedContentLength > Int64(state.maxBytes) {
                state.exceededLimitError = Self.limitExceededError(
                    byteCount: response.expectedContentLength,
                    maxBytes: state.maxBytes
                )
                state.buffer.removeAll(keepingCapacity: false)
                dict[dataTask.taskIdentifier] = state
                return .cancel
            }
            dict[dataTask.taskIdentifier] = state
            return .allow
        }
        completionHandler(disposition)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        let shouldCancel = transfers.withLock { dict -> Bool in
            guard var state = dict[dataTask.taskIdentifier], state.exceededLimitError == nil else {
                return false
            }
            if data.count > state.maxBytes || state.buffer.count > state.maxBytes - data.count {
                let observedBytes = Int64(state.buffer.count) + Int64(data.count)
                state.exceededLimitError = Self.limitExceededError(
                    byteCount: observedBytes,
                    maxBytes: state.maxBytes
                )
                state.buffer.removeAll(keepingCapacity: false)
                dict[dataTask.taskIdentifier] = state
                return true
            }
            state.buffer.append(data)
            dict[dataTask.taskIdentifier] = state
            return false
        }
        if shouldCancel {
            dataTask.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        guard let state = transfers.withLock({ $0.removeValue(forKey: task.taskIdentifier) }) else {
            return
        }
        state.onComplete()

        if let limitError = state.exceededLimitError {
            state.continuation.resume(throwing: limitError)
            return
        }
        if let error {
            if let urlError = error as? URLError, urlError.code == .cancelled {
                state.continuation.resume(throwing: DriverError.cancelled)
            } else if (error as NSError).domain == NSURLErrorDomain,
                      (error as NSError).code == NSURLErrorCancelled {
                state.continuation.resume(throwing: DriverError.cancelled)
            } else {
                state.continuation.resume(throwing: DriverError.connectionFailed(error.localizedDescription))
            }
            return
        }
        guard let response = state.response ?? task.response else {
            state.continuation.resume(throwing: DriverError.connectionFailed("Empty response from libSQL server"))
            return
        }
        state.continuation.resume(returning: (state.buffer, response))
    }

    private static func limitExceededError(byteCount: Int64, maxBytes: Int) -> DriverError {
        DriverError.queryFailed(
            message: "libSQL response size (\(byteCount) bytes) exceeds the \(maxBytes)-byte safety limit. Add a LIMIT clause to paginate large result sets.",
            code: nil
        )
    }
}

final class LibSQLHTTPClient: Sendable {
    static let defaultMaxResponseBytes = LibSQLDriver.defaultMaxResponseBytes

    let baseURL: URL
    private let authToken: String?
    private let tlsMode: TLSMode
    private let timeoutSeconds: TimeInterval
    let maxResponseBytes: Int
    private let delegate: PipelineSessionDelegate
    private let session: URLSession
    private let inFlightTask = OSAllocatedUnfairLock<URLSessionDataTask?>(initialState: nil)

    init(
        baseURL: URL,
        authToken: String?,
        tlsMode: TLSMode,
        timeoutSeconds: TimeInterval,
        maxResponseBytes: Int = LibSQLHTTPClient.defaultMaxResponseBytes,
        sessionConfiguration: URLSessionConfiguration? = nil
    ) {
        self.baseURL = baseURL
        self.authToken = authToken
        self.tlsMode = tlsMode
        self.timeoutSeconds = timeoutSeconds
        self.maxResponseBytes = max(1, maxResponseBytes)
        let delegate = PipelineSessionDelegate()
        self.delegate = delegate
        let config = sessionConfiguration ?? URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeoutSeconds
        config.timeoutIntervalForResource = max(timeoutSeconds * 2, 60)
        self.session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    func validateStickyBaseURL(_ rawBaseURL: String) throws -> URL {
        guard let candidate = URL(string: rawBaseURL),
              let components = URLComponents(url: candidate, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host?.lowercased(), !host.isEmpty
        else {
            throw DriverError.connectionFailed("Rejected invalid base_url from libSQL server: \(rawBaseURL)")
        }
        if components.user != nil || components.password != nil
            || components.query != nil || components.fragment != nil
            || components.path.split(separator: "/").contains("..") {
            throw DriverError.connectionFailed("Rejected unsafe base_url components from libSQL server: \(rawBaseURL)")
        }
        try validateTargetBaseURL(candidate)
        return candidate
    }

    func validateTargetBaseURL(_ target: URL) throws {
        let expectedScheme = baseURL.scheme?.lowercased()
        let targetScheme = target.scheme?.lowercased()
        guard targetScheme == "http" || targetScheme == "https" else {
            throw DriverError.connectionFailed("Unsupported libSQL URL scheme '\(targetScheme ?? "nil")'")
        }
        if (tlsMode != .disable || expectedScheme == "https") && targetScheme != "https" {
            throw DriverError.connectionFailed(
                "Refusing to send libSQL request over insecure scheme '\(targetScheme ?? "nil")'"
            )
        }
        guard targetScheme == expectedScheme else {
            throw DriverError.connectionFailed(
                "Rejected libSQL base_url scheme change from '\(expectedScheme ?? "")' to '\(targetScheme ?? "")'"
            )
        }
        let expectedHost = baseURL.host?.lowercased()
        let targetHost = target.host?.lowercased()
        guard let expectedHost, !expectedHost.isEmpty, targetHost == expectedHost else {
            throw DriverError.connectionFailed(
                "Rejected cross-host libSQL base_url '\(targetHost ?? "")' (expected '\(expectedHost ?? "")')"
            )
        }
        let expectedPort = Self.effectivePort(for: baseURL)
        let targetPort = Self.effectivePort(for: target)
        guard targetPort == expectedPort else {
            throw DriverError.connectionFailed(
                "Rejected cross-port libSQL base_url port \(targetPort ?? -1) (expected \(expectedPort ?? -1))"
            )
        }
    }

    private static func effectivePort(for url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "https": return 443
        case "http": return 80
        default: return nil
        }
    }

    func executePipeline(
        _ requests: [HranaStreamRequest],
        baton: String?,
        stickyBaseURL: URL?,
        timeoutOverride: TimeInterval? = nil
    ) async throws -> HranaPipelineResponse {
        let targetBase = stickyBaseURL ?? baseURL
        try validateTargetBaseURL(targetBase)
        let endpoint = targetBase
            .appendingPathComponent("v2")
            .appendingPathComponent("pipeline")

        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = timeoutOverride ?? timeoutSeconds
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        if let authToken, !authToken.isEmpty {
            urlRequest.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        }

        let payload = HranaPipelineRequest(baton: baton, requests: requests)
        urlRequest.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await performDataRequest(urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw DriverError.connectionFailed("Invalid non-HTTP response from libSQL server")
        }
        if (300...399).contains(http.statusCode) {
            throw DriverError.connectionFailed("Refused HTTP \(http.statusCode) redirect from libSQL server")
        }
        if let responseURL = http.url {
            try validateTargetBaseURL(responseURL)
        }

        switch http.statusCode {
        case 200...299:
            break
        case 401, 403:
            let detail = extractServerMessage(from: data) ?? "HTTP \(http.statusCode) Unauthorized"
            throw DriverError.connectionFailed("Authentication failed (HTTP \(http.statusCode)): \(detail)")
        default:
            let detail = extractServerMessage(from: data) ?? "HTTP \(http.statusCode)"
            if http.statusCode == 404 || http.statusCode >= 500 {
                throw DriverError.connectionFailed("libSQL HTTP \(http.statusCode): \(detail)")
            }
            throw DriverError.queryFailed(message: "libSQL HTTP \(http.statusCode): \(detail)", code: nil)
        }

        if data.count > maxResponseBytes {
            throw DriverError.queryFailed(
                message: "libSQL response size (\(data.count) bytes) exceeds the \(maxResponseBytes)-byte safety limit. Add a LIMIT clause to paginate large result sets.",
                code: nil
            )
        }

        do {
            return try JSONDecoder().decode(HranaPipelineResponse.self, from: data)
        } catch {
            throw DriverError.connectionFailed("Failed to decode libSQL Hrana response: \(error.localizedDescription)")
        }
    }

    func cancelCurrentRequest() {
        let task = inFlightTask.withLock { current -> URLSessionDataTask? in
            let active = current
            current = nil
            return active
        }
        task?.cancel()
    }

    func invalidate() {
        cancelCurrentRequest()
        session.invalidateAndCancel()
    }

    static func mapHranaError(_ payload: HranaErrorPayload) -> DriverError {
        let rawCode = payload.code?.uppercased() ?? ""
        let lowerMsg = payload.message.lowercased()
        if rawCode.contains("READONLY")
            || lowerMsg.contains("readonly")
            || lowerMsg.contains("read-only")
            || lowerMsg.contains("unauthorized") && rawCode == "AUTHORIZATION" {
            return .queryFailed(message: payload.message, code: 8)
        }
        if rawCode == "SQL_AUTH_ERROR" || rawCode == "AUTH_ERROR" {
            return .connectionFailed("Authentication failed: \(payload.message)")
        }
        return .queryFailed(message: payload.message, code: nil)
    }

    private func performDataRequest(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request)
                let taskID = task.taskIdentifier
                delegate.register(
                    taskID: taskID,
                    maxBytes: maxResponseBytes,
                    continuation: continuation,
                    onComplete: { [weak self] in
                        self?.inFlightTask.withLock { current in
                            if current?.taskIdentifier == taskID {
                                current = nil
                            }
                        }
                    }
                )
                inFlightTask.withLock { current in
                    current = task
                }
                task.resume()
                if Task.isCancelled {
                    task.cancel()
                }
            }
        } onCancel: {
            cancelCurrentRequest()
        }
    }

    private func extractServerMessage(from data: Data) -> String? {
        if let envelope = try? JSONDecoder().decode(HranaErrorEnvelope.self, from: data) {
            return envelope.error ?? envelope.message
        }
        let raw = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (raw?.isEmpty == false) ? raw : nil
    }

    private struct HranaErrorEnvelope: Decodable {
        let error: String?
        let message: String?
    }
}
