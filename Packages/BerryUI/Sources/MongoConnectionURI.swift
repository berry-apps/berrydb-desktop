import BerryDriverKit
import Foundation

/// Parses a pasted `mongodb://` connection string into the Connection sheet's
/// Host/Port/Username/Password/Database/TLS fields ("paste a URI" convenience).
/// Deliberately **unidirectional** (paste → fields populate once) — not a live bidirectional URI↔fields sync.
/// Pure/free of SwiftUI so it's unit-testable on its own.
public enum MongoConnectionURI {
    public struct ParsedFields: Equatable {
        public var host: String
        public var port: Int
        public var username: String?
        public var password: String?
        public var database: String?
        /// `nil` means the URI didn't specify TLS — the caller should leave
        /// the sheet's current TLS mode untouched rather than forcing `.disable`.
        public var tlsMode: TLSMode?
        /// Replica-set seed members beyond `host`/`port`, from a
        /// comma-separated host list — `"host:port"` entries, empty when the
 /// URI named only one host (replica-set v1).
        public var additionalHosts: [String]
        /// `replicaSet=<name>` query param, if present.
        public var replicaSet: String?

        public init(
            host: String, port: Int, username: String? = nil, password: String? = nil,
            database: String? = nil, tlsMode: TLSMode? = nil,
            additionalHosts: [String] = [], replicaSet: String? = nil
        ) {
            self.host = host
            self.port = port
            self.username = username
            self.password = password
            self.database = database
            self.tlsMode = tlsMode
            self.additionalHosts = additionalHosts
            self.replicaSet = replicaSet
        }
    }

    public enum ParseError: Error, Equatable {
        /// Doesn't start with "mongodb://" (and isn't the +srv case below).
        case notMongoDBScheme
        /// "mongodb+srv://" — needs DNS SRV lookup, not implemented
 /// (tracked as a known gap).
        case srvNotSupported
        case missingHost
        case malformed

        public var message: String {
            switch self {
            case .notMongoDBScheme:
                L("Not a valid MongoDB URI — must start with “mongodb://”.")
            case .srvNotSupported:
                L("“mongodb+srv://” isn't supported yet — DNS SRV lookup isn't implemented. Paste a single mongodb://host:port URI instead.")
            case .missingHost:
                L("No host found in this URI.")
            case .malformed:
                L("Could not parse this URI.")
            }
        }
    }

    private static let scheme = "mongodb://"
    private static let srvScheme = "mongodb+srv://"

    /// Supports: `mongodb://[username:password@]host1[:port1][,host2[:port2]...][/database][?options]`
    /// with URL-decoded credentials, default port 27017, and the `authSource`/
    /// `tls`/`ssl`/`replicaSet` query params (see field-level comments below).
    /// A comma-separated host list becomes `host`/`additionalHosts` — replica
 /// set seeds (v1: seeds tried in order to find
    /// the primary at connect time, no topology monitoring). Rejects
    /// `mongodb+srv://` outright instead of guessing — see `ParseError`.
    public static func parse(_ uriString: String) -> Result<ParsedFields, ParseError> {
        let trimmed = uriString.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix(srvScheme) {
            return .failure(.srvNotSupported)
        }
        guard trimmed.lowercased().hasPrefix(scheme) else {
            return .failure(.notMongoDBScheme)
        }
        var rest = String(trimmed.dropFirst(scheme.count))
        guard !rest.isEmpty else { return .failure(.missingHost) }

        // Query string (options) — split off first, it may contain '/' itself.
        var queryString: String?
        if let qIndex = rest.firstIndex(of: "?") {
            queryString = String(rest[rest.index(after: qIndex)...])
            rest = String(rest[rest.startIndex..<qIndex])
        }

        // Database path — the first '/' after the host list.
        var databasePart: String?
        if let slashIndex = rest.firstIndex(of: "/") {
            let candidate = String(rest[rest.index(after: slashIndex)...])
            databasePart = candidate.isEmpty ? nil : candidate
            rest = String(rest[rest.startIndex..<slashIndex])
        }

        // Userinfo — split off the LAST '@' (credentials must be
        // percent-encoded per RFC 3986, so an unescaped '@' belongs to the
        // host boundary, matching how other Mongo drivers parse this).
        var hostList = rest
        var username: String?
        var password: String?
        if let atIndex = rest.lastIndex(of: "@") {
            let userinfo = String(rest[rest.startIndex..<atIndex])
            hostList = String(rest[rest.index(after: atIndex)...])
            guard !userinfo.isEmpty else { return .failure(.malformed) }
            if let colonIndex = userinfo.firstIndex(of: ":") {
                guard let decodedUser = percentDecode(String(userinfo[userinfo.startIndex..<colonIndex])),
                      let decodedPass = percentDecode(String(userinfo[userinfo.index(after: colonIndex)...]))
                else { return .failure(.malformed) }
                username = decodedUser
                password = decodedPass
            } else {
                guard let decodedUser = percentDecode(userinfo) else { return .failure(.malformed) }
                username = decodedUser
            }
        }

        guard !hostList.isEmpty else { return .failure(.missingHost) }
 // Replica set support (v1): a comma-separated
        // host list becomes the first host/port pair plus `additionalHosts` —
        // normalized to "host:port" (default port filled in) so
        // `ConnectionConfig.additionalHosts` entries are unambiguous.
        let hostEntries = hostList.split(separator: ",", omittingEmptySubsequences: true).map(String.init)
        guard let firstHostEntry = hostEntries.first else { return .failure(.missingHost) }
        let (host, parsedPort) = splitHostPort(firstHostEntry)
        guard !host.isEmpty else { return .failure(.missingHost) }
        let additionalHosts: [String] = hostEntries.dropFirst().compactMap { entry in
            let (extraHost, extraPort) = splitHostPort(entry)
            guard !extraHost.isEmpty else { return nil }
            return "\(extraHost):\(extraPort ?? 27017)"
        }

        var authSource: String?
        var tlsRequested = false
        var replicaSet: String?
        if let queryString {
            for pair in queryString.split(separator: "&") {
                let parts = pair.split(separator: "=", maxSplits: 1)
                guard parts.count == 2 else { continue }
                switch String(parts[0]).lowercased() {
                case "authsource":
                    authSource = percentDecode(String(parts[1]))
                case "tls", "ssl":
                    if String(parts[1]).lowercased() == "true" { tlsRequested = true }
                case "replicaset":
                    replicaSet = percentDecode(String(parts[1]))
                default:
                    break
                }
            }
        }

        // `ConnectionConfig`/`ConnectionProfile` only have one `database`
        // field, used as BOTH the SCRAM authSource and the working database
 // (point 2 — a documented
        // gap, not something this parser can fix). When the URI's authSource
        // differs from its path database, prefer authSource: it's what
        // `MongoWireClient` actually authenticates against, so it's the value
        // that makes "Test Connection" succeed.
        let resolvedDatabase = authSource ?? databasePart.flatMap(percentDecode)

        return .success(ParsedFields(
            host: host,
            port: parsedPort ?? 27017,
            username: username,
            password: password,
            database: resolvedDatabase,
            tlsMode: tlsRequested ? .require : nil,
            additionalHosts: additionalHosts,
            replicaSet: replicaSet
        ))
    }

    /// RFC 3986 percent-decoding (NOT form/`+`-as-space decoding — a literal
    /// `+` in a Mongo URI credential stays a `+`).
    private static func percentDecode(_ raw: String) -> String? {
        raw.removingPercentEncoding
    }

    /// Same "split on the last colon when the suffix is purely numeric" rule
    /// as `ConnectionSheet.splitHostPort` — duplicated (not called directly)
    /// so this parser stays free of `ConnectionSheet`'s `@MainActor` isolation
    /// (inferred from `View` conformance) and is callable/testable from any
    /// context, per this feature's "pure, testable" requirement.
    private static func splitHostPort(_ raw: String) -> (host: String, port: Int?) {
        guard let colonIndex = raw.lastIndex(of: ":") else { return (raw, nil) }
        let hostPart = String(raw[raw.startIndex..<colonIndex])
        let portPart = String(raw[raw.index(after: colonIndex)...])
        guard !hostPart.isEmpty, let port = Int(portPart) else { return (raw, nil) }
        return (hostPart, port)
    }
}
