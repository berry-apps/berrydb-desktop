import BerryCore
import BerryUI
import Testing
@testable import BerryApp

struct DangerConfirmerInstallTests {
    /// The app's composition root is the only place the NSAlert-based gate is
    /// installed; without it a DELETE or UPDATE without WHERE runs with no
    /// confirmation at all. The installer is injected so this test never puts
    /// a real modal alert into the process-wide slot every other suite in the
    /// same test process reads.
    @Test func appCompositionInstallsTheAlertConfirmer() {
        var installed: [any DangerConfirmer] = []

        BerryDBAppComposition.installDangerConfirmer { installed.append($0) }

        #expect(installed.count == 1)
        #expect(installed.first is AlertDangerConfirmer)
    }
}
