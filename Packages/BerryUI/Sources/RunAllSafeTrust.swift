import BerryCore

/// Which statements the approval card's Run All Safe button covers. It trusts
/// only what the auto-run setting would run: a statement rated safe and that
/// the executor proves read-only throughout. A danger rating of safe alone is
/// not enough, because it covers INSERT, UPDATE with a WHERE, DDL and grants
/// off production, and multi-statement text that leads with a read.
enum RunAllSafeTrust {
    /// The button appears only on a card for such a statement.
    static func offersButton(danger: DangerLevel, readOnly: Bool) -> Bool {
        readOnly && danger == .safe
    }

    /// Once the button was used this turn, a later statement skips its card
    /// only if the button could have been offered for it too.
    static func skipsCard(danger: DangerLevel, readOnly: Bool, trustedThisTurn: Bool) -> Bool {
        trustedThisTurn && offersButton(danger: danger, readOnly: readOnly)
    }
}
