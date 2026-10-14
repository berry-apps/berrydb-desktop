import Dispatch
import Foundation

/// Calls `store.releaseMemory()` after `idle` without activity (`touch()`
/// resets the timer) and on every memory-pressure event. GRDB's automatic
/// memory management is iOS-only, so a macOS process must do this itself
/// (https://github.com/groue/GRDB.swift/blob/v7.11.1/README.md#memory-management).
/// A memory-pressure event also runs `onPressure`, for memory the process
/// keeps outside the store.
public final class StoreMemoryManager: @unchecked Sendable {
    private let store: BerryStore
    private let idle: TimeInterval
    private let queue: DispatchQueue
    private let onPressure: (@Sendable () -> Void)?
    private let lock = NSLock()
    private var idleTimer: DispatchSourceTimer?
    private var pressureSource: DispatchSourceMemoryPressure?
    private var stopped = false

    public init(
        store: BerryStore, idle: TimeInterval = 5, queue: DispatchQueue = .global(qos: .utility),
        onPressure: (@Sendable () -> Void)? = nil
    ) {
        self.store = store
        self.idle = idle
        self.queue = queue
        self.onPressure = onPressure
        let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: queue)
        pressure.setEventHandler { [weak self] in self?.handleMemoryPressure() }
        pressure.activate()
        pressureSource = pressure
    }

    func handleMemoryPressure() {
        onPressure?()
        releaseNow()
    }

    deinit {
        stop()
    }

    /// Activity happened: the store is in use, so the idle release moves to
    /// `idle` seconds from now. One timer is re-armed rather than recreated,
    /// so frequent calls stay cheap and never release memory mid-burst.
    public func touch() {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return }
        let timer = idleTimer ?? makeIdleTimer()
        idleTimer = timer
        timer.schedule(deadline: .now() + idle)
    }

    public func releaseNow() {
        store.releaseMemory()
    }

    /// Cancels the idle timer and the memory-pressure source; later calls to
    /// `touch()` do nothing.
    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        stopped = true
        idleTimer?.cancel()
        idleTimer = nil
        pressureSource?.cancel()
        pressureSource = nil
    }

    private func makeIdleTimer() -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.setEventHandler { [weak self] in self?.releaseNow() }
        timer.activate()
        return timer
    }
}
