import BerryDriverBootstrap

/// Process composition root for the BerryDB MCP helper.
///
/// Registers exactly the same built-in drivers as the desktop app; the
/// protocol server is composed here on top of that registration.
public enum BerryDBMCPComposition {
    @discardableResult
    public static func registerDrivers(
        using registrar: BerryDriverRegistrar = .live
    ) -> BerryDriverRegistration {
        BerryDriverBootstrap.registerAll(using: registrar)
    }
}
