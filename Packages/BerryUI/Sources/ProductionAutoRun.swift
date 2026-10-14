import Foundation

/// Auto-run of read-only statements is off on a production connection until
/// someone turns it on there. The stored per-connection setting cannot carry
/// that rule alone: it defaults to `true`, and every connection that ever
/// turned AI on stored that default with its other AI settings. On
/// production the stored value is therefore honored only once a choice made
/// on that connection, while it was production, is recorded here. The record
/// is kept in user defaults per connection profile, beside the setting in the
/// store, so the store needs no migration.
enum ProductionAutoRun {
    /// The auto-run setting a connection starts with when it is bound.
    /// Without a profile there is nowhere to keep a choice, so production
    /// starts off and an opt-in lasts for the session.
    static func restored(stored: Bool?, isProduction: Bool, profileID: UUID?, defaults: UserDefaults) -> Bool {
        guard isProduction else { return stored ?? true }
        guard let profileID, defaults.bool(forKey: choiceKey(profileID)) else { return false }
        return stored ?? false
    }

    /// Called when the setting is changed by hand; only a change made on a
    /// production connection counts as a choice for it.
    static func recordChoice(isProduction: Bool, profileID: UUID?, defaults: UserDefaults) {
        guard isProduction, let profileID else { return }
        defaults.set(true, forKey: choiceKey(profileID))
    }

    static func choiceKey(_ profileID: UUID) -> String {
        "berry.ai.productionAutoRunChoice.\(profileID.uuidString)"
    }
}
