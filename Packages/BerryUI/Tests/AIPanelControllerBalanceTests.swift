import Foundation
import Testing

@testable import BerryUI

/// `AIPanelController.Balance.isExhausted` — reported: a "pro" plan account
/// with an admin `token_budget` override (`check_ai_allowance`'s
/// `budget_override.is_some()` fallback) kept showing the quota-exhausted
/// banner forever, even though chat kept working. Verified against real
/// account data: `tan@tan.com`, plan "pro", `token_budget=1_000_000`,
/// `used=67_430` (plenty of headroom, so the backend's `Ok(false)` path let
/// every turn through) but `balance_micros=0` (a comped key, never topped
/// up for real). `isExhausted` used to key off `plan == "trial"` alone, so
/// this exact non-trial-but-overridden shape read as `balanceMicros <= 0`
/// unconditionally, ignoring the healthy token budget entirely.
@Suite("AIPanelController.Balance.isExhausted")
struct AIPanelControllerBalanceTests {
    private func makeBalance(
        plan: String, used: Int, limit: Int, balanceMicros: Int, quotaFallbackActive: Bool
    ) -> AIPanelController.Balance {
        AIPanelController.Balance(
            plan: plan,
            tokenQuota: .init(used: used, limit: limit),
            balanceMicros: balanceMicros,
            totalTokensUsed: nil,
            lowBalance: false,
            totalBudgetUsedPercent: nil,
            models: [],
            quotaFallbackActive: quotaFallbackActive
        )
    }

    @Test func aNonTrialPlanWithAnAdminOverrideAndHeadroomIsNotExhaustedEvenAtZeroBalance() {
        // The exact reported shape, real numbers.
        let balance = makeBalance(plan: "pro", used: 67_430, limit: 1_000_000, balanceMicros: 0, quotaFallbackActive: true)
        #expect(!balance.isExhausted)
    }

    @Test func aNonTrialPlanWithAnAdminOverrideIsExhaustedOnceBothTheQuotaAndTheBalanceAreGone() {
        let balance = makeBalance(plan: "pro", used: 1_000_000, limit: 1_000_000, balanceMicros: 0, quotaFallbackActive: true)
        #expect(balance.isExhausted)
    }

    @Test func aNonTrialPlanWithAnAdminOverrideFallsThroughToBalanceOnceTheQuotaIsSpent() {
        let balance = makeBalance(plan: "pro", used: 1_000_000, limit: 1_000_000, balanceMicros: 5_000, quotaFallbackActive: true)
        #expect(!balance.isExhausted)
    }

    @Test func plainPayAsYouGoWithNoFallbackIsExhaustedPurelyByBalanceRegardlessOfTokenQuota() {
        let balance = makeBalance(plan: "topup", used: 0, limit: 0, balanceMicros: 0, quotaFallbackActive: false)
        #expect(balance.isExhausted)
    }

    @Test func plainPayAsYouGoWithNoFallbackIsNotExhaustedWithAPositiveBalance() {
        let balance = makeBalance(plan: "topup", used: 0, limit: 0, balanceMicros: 5_000, quotaFallbackActive: false)
        #expect(!balance.isExhausted)
    }

    @Test func aTrialAccountIsExhaustedOnceBothTheQuotaAndTheBalanceAreGone() {
        let balance = makeBalance(plan: "trial", used: 50_000, limit: 50_000, balanceMicros: 0, quotaFallbackActive: true)
        #expect(balance.isExhausted)
    }
}
