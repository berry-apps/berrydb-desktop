import Foundation
import Testing

@testable import BerryCore

/// Where the running app was launched from.
///
/// A crash report from 2026-09-14 showed the app dying with SIGBUS and
/// "backing vnode was force unmounted": it had been launched straight out of
/// the mounted .dmg, and the volume went away eight minutes later. No frame in
/// that crash belonged to BerryDB — once the volume holding the executable
/// disappears, the next page-in kills the process wherever it happens to be.
/// Nothing can be caught. The only fix is to not be running from there.
@Suite("InstallLocation")
struct InstallLocationTests {
    @Test func applicationsFolderIsFine() {
        let where_ = InstallLocation.of(
            bundlePath: "/Applications/BerryDB.app", isRemovable: false, isReadOnly: false)
        #expect(where_ == .installed)
        #expect(where_.needsMoving == false)
    }

    @Test func mountedDiskImageIsNotFine() {
        let where_ = InstallLocation.of(
            bundlePath: "/Volumes/BerryDB/BerryDB.app", isRemovable: true, isReadOnly: true)
        #expect(where_ == .diskImage)
        #expect(where_.needsMoving)
    }

    /// Gatekeeper runs a quarantined app from a read-only copy under
    /// AppTranslocation. Same failure mode, different path.
    @Test func translocatedCopyIsNotFine() {
        let path = "/private/var/folders/qx/T/AppTranslocation/4A1F/d/BerryDB.app"
        let where_ = InstallLocation.of(bundlePath: path, isRemovable: false, isReadOnly: true)
        #expect(where_ == .translocated)
        #expect(where_.needsMoving)
    }

    @Test func anyOtherReadOnlyVolumeIsNotFine() {
        let where_ = InstallLocation.of(
            bundlePath: "/Users/tan/Downloads/BerryDB.app", isRemovable: false, isReadOnly: true)
        #expect(where_ == .readOnlyVolume)
        #expect(where_.needsMoving)
    }

    /// "/Volumes" has to be matched as a path prefix, not as a substring —
    /// a folder a user happens to call Volumes is an ordinary folder.
    @Test func aFolderNamedVolumesIsStillFine() {
        let where_ = InstallLocation.of(
            bundlePath: "/Users/tan/Volumes/BerryDB.app", isRemovable: false, isReadOnly: false)
        #expect(where_ == .installed)
    }

    /// A removable but writable volume — an external SSD someone keeps apps on.
    /// It can still be unplugged mid-run, so it gets the same warning.
    @Test func removableWritableVolumeIsNotFine() {
        let where_ = InstallLocation.of(
            bundlePath: "/Users/tan/Apps/BerryDB.app", isRemovable: true, isReadOnly: false)
        #expect(where_ == .readOnlyVolume)
        #expect(where_.needsMoving)
    }
}
