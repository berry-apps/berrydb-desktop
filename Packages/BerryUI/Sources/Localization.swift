import Foundation

/// `Bundle.module`'s generated accessor `Swift.fatalError`s when it can't
/// find this package's resource bundle. It only ever checks two paths: the
/// packaged app's TOP level (`Bundle.main.bundleURL`) — but macOS codesigning
/// rejects any content living there outside `Contents/`, so that check can
/// never succeed for a real signed `.app` — and a dev-machine absolute path
/// baked in at compile time, which only resolves on whichever Mac ran `swift
/// build`. Every real user is on a different Mac, so touching `.module`
/// directly crashed BerryUI's very first localized string on launch for a
/// real user despite working fine in every local/dev
/// test on the build machine itself. This checks the correct packaged-app
/// location first (`Contents/Resources`, where `scripts/make_app.sh` actually
/// copies it) and the raw build-output layout second (covers `swift
/// run`/`make run`, where the bundle sits beside the executable) — `.module`
/// itself is only reached as a last resort, which in practice means `swift
/// test`: its runner's `Bundle.main` matches neither check above, so it needs
/// `.module`'s own baked-in absolute dev path — safe there since tests only
/// ever run on the machine that built them, unlike a shipped `.app`.
let berryModuleBundle: Bundle = {
    let name = "BerryDB_BerryUI.bundle"
    if let url = Bundle.main.resourceURL?.appendingPathComponent(name), let bundle = Bundle(url: url) {
        return bundle
    }
    if let bundle = Bundle(url: Bundle.main.bundleURL.appendingPathComponent(name)) {
        return bundle
    }
    return .module
}()

/// Localized string lookup for BerryUI: the app follows the SYSTEM
/// language. English is the base; Vietnamese lives in `Resources/vi.lproj`.
/// Interpolations map to format keys automatically
/// (e.g. `L("Tables (\(n))")` looks up "Tables (%lld)").
///
/// Public so the App target's menu commands (which live outside BerryUI, where
/// the scenes are declared) resolve against the same `.lproj` catalog.
public func L(_ key: String.LocalizationValue) -> String {
    String(localized: key, bundle: berryModuleBundle)
}
