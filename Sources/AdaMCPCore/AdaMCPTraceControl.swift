import AdaUtils
import Foundation

/// Keeps automatic engine tracing active while a live consumer owns this lease.
/// Releasing the last lease restores the configured continuous/file recording mode.
public final class AdaMCPTraceLease: Sendable {
    private let release: @Sendable () -> Void

    init(release: @escaping @Sendable () -> Void) {
        self.release = release
    }

    deinit { release() }
}

/// All state is protected by lock. Engine hot paths read AdaTrace's atomic gate;
/// acquiring/releasing a consumer or starting/stopping a file is the control path.
final class AdaMCPTraceControl: @unchecked Sendable {
    private let lock = NSLock()
    private var continuous: Bool
    private var fileActive = false
    private var leases = 0
    private var installed = false

    init(continuous: Bool) { self.continuous = continuous }

    var isEnabled: Bool { lock.withLock { continuous || fileActive || leases > 0 } }
    var isContinuous: Bool { lock.withLock { continuous } }

    func install() {
        lock.withLock {
            guard !installed else {
                return
            }
            installed = true
            updateGate()
        }
    }

    func setContinuous(_ enabled: Bool) {
        lock.withLock {
            continuous = enabled
            updateGate()
        }
    }

    func setFileActive(_ active: Bool) {
        lock.withLock {
            fileActive = active
            updateGate()
        }
    }

    func acquireLease() -> AdaMCPTraceLease {
        lock.withLock {
            leases += 1
            updateGate()
        }
        return AdaMCPTraceLease { [self] in
            lock.withLock {
                leases -= 1
                updateGate()
            }
        }
    }

    private func updateGate() {
        guard installed else {
            return
        }
        AdaTrace.isEnabled = continuous || fileActive || leases > 0
    }
}
