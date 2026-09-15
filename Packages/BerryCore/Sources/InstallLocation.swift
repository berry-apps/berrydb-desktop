import Foundation

/// Where the running app was launched from, and whether that place can vanish
/// underneath it.
///
/// macOS maps an executable's pages from the file on disk and pages them in
/// lazily. If the volume holding that file goes away — the .dmg is ejected, the
/// external drive is unplugged — the next page-in has no source and the kernel
/// kills the process with SIGBUS. It cannot be caught, and the crash report
/// blames whatever code happened to need a new page: a 2026-09-14 report showed
/// the process dying inside WebKit's preference archiver with not one BerryDB
/// frame on the stack, and "backing vnode was force unmounted" in the kernel
/// triage. The app had been launched straight out of the mounted disk image.
///
/// So this is not a crash to handle. It is a place not to be running from, and
/// the only useful moment to say so is before any work is under way.
public enum InstallLocation: Sendable, Equatable {
    /// On a normal, writable, non-removable volume.
    case installed
    /// Inside a mounted disk image — almost always the downloaded .dmg.
    case diskImage
    /// Gatekeeper's read-only copy of a quarantined app.
    case translocated
    /// Any other volume that is read-only or can be detached mid-run.
    case readOnlyVolume

    public var needsMoving: Bool { self != .installed }

    public static func of(
        bundlePath: String,
        isRemovable: Bool,
        isReadOnly: Bool
    ) -> InstallLocation {
        // Translocation first: those paths live under /private/var, so the
        // volume flags alone would report them as an ordinary read-only mount
        // and the advice ("move it to Applications") would be right but the
        // diagnosis wrong.
        if bundlePath.contains("/AppTranslocation/") { return .translocated }

        // Prefix, not substring. A folder someone named "Volumes" is a folder.
        if bundlePath == "/Volumes" || bundlePath.hasPrefix("/Volumes/") { return .diskImage }

        // Removable but writable still counts: an external disk can be
        // unplugged mid-run and produces exactly the same SIGBUS.
        if isReadOnly || isRemovable { return .readOnlyVolume }

        return .installed
    }
}
