import Foundation

// Apple Foundation Models on-device provider.
// Gated on canImport so the package still builds on toolchains without the
// framework (it needs Xcode 27 / macOS 26). The FoundationModels branch is
// written against the WWDC-2025 API and MUST be verified on a real Apple
// Intelligence device before shipping (doc).

#if canImport(FoundationModels)
import FoundationModels
#endif

public struct AppleFoundationProvider: LocalCompletionProvider {
    public init() {}

    public static func isAvailable() -> Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }

    /// Human-readable availability for diagnostics — distinguishes "not enabled",
    /// "model still downloading", and "device not eligible" from plain false.
    public static func availabilityDescription() -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return "available"
            case .unavailable(let reason):
                return "unavailable: \(reason)"
            @unknown default:
                return "unavailable: unknown"
            }
        }
        return "FoundationModels present but OS < 26"
        #else
        return "FoundationModels not compiled in"
        #endif
    }

    public func complete(prompt: String) async throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *) {
            let session = LanguageModelSession()
            return try await session.respond(to: prompt).content
        }
        #endif
        throw Self.unavailable
    }

 /// Streamed generation: yields text deltas so the panel fills
    /// progressively instead of waiting for the whole reply.
    public func stream(prompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                #if canImport(FoundationModels)
                if #available(macOS 26.0, iOS 26.0, *) {
                    do {
                        let session = LanguageModelSession()
                        var last = ""
                        // Each snapshot carries the cumulative content; emit the new suffix.
                        for try await snapshot in session.streamResponse(to: prompt) {
                            let text = snapshot.content
                            if text.count > last.count {
                                continuation.yield(String(text.dropFirst(last.count)))
                                last = text
                            }
                        }
                        continuation.finish()
                        return
                    } catch {
                        continuation.finish(throwing: error)
                        return
                    }
                }
                #endif
                continuation.finish(throwing: Self.unavailable)
            }
        }
    }

    private static var unavailable: NSError {
        NSError(
            domain: "BerryAI",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Apple Foundation Models is not available on this device/toolchain."]
        )
    }
}
