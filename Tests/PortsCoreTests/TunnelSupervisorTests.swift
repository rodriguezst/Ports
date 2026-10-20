import Foundation
import XCTest
@testable import PortsCore

@MainActor private final class FakeSession: SSHSession {
    var callback: (@MainActor (SSHEvent) -> Void)?
    var stops = 0
    func start(onEvent: @escaping @MainActor (SSHEvent) -> Void) throws { callback = onEvent }
    func stop() { stops += 1 }
    func emit(_ event: SSHEvent) { callback?(event) }
}

@MainActor private final class VirtualScheduler: Scheduler {
    final class Entry: Cancellation {
        let time: TimeInterval
        let action: @MainActor () -> Void
        var cancelled = false
        init(time: TimeInterval, action: @escaping @MainActor () -> Void) { self.time = time; self.action = action }
        func cancel() { cancelled = true }
    }
    var now: TimeInterval = 0
    var entries: [Entry] = []
    func schedule(after seconds: TimeInterval, action: @escaping @MainActor () -> Void) -> Cancellation {
        let entry = Entry(time: now + seconds, action: action)
        entries.append(entry)
        return entry
    }
    func advance(_ seconds: TimeInterval) {
        let target = now + seconds
        while let next = entries.filter({ !$0.cancelled && $0.time <= target }).min(by: { $0.time < $1.time }) {
            next.cancelled = true
            now = next.time
            next.action()
        }
        now = target
    }
}

@MainActor private final class Harness {
    let clock = VirtualScheduler()
    var sessions: [FakeSession] = []
    var launched: [Forwarding] = []
    var launchError: Error?
    lazy var supervisor = TunnelSupervisor(scheduler: clock) { [unowned self] forwarding in
        if let launchError { throw launchError }
        let session = FakeSession()
        sessions.append(session)
        launched.append(forwarding)
        return session
    }
}

@MainActor final class TunnelSupervisorTests: XCTestCase {
    func testEnableBecomesConnectedOnlyAfterReadinessAndUnchangedApplyDoesNotRestart() async {
        let h = Harness(), forwarding = sampleForwarding()
        h.supervisor.apply([forwarding])
        XCTAssertEqual(h.supervisor.states[forwarding.id], .connecting)
        h.sessions[0].emit(.ready)
        XCTAssertEqual(h.supervisor.states[forwarding.id], .connected)
        h.supervisor.apply([forwarding])
        XCTAssertEqual(h.sessions.count, 1)
        XCTAssertEqual(h.sessions[0].stops, 0)
    }

    func testDisconnectRetriesWithCappedBackoffWithoutClearingEnabledState() async {
        let h = Harness(), forwarding = sampleForwarding()
        h.supervisor.apply([forwarding])
        for delay in [1, 2, 4, 8, 16, 30, 30] {
            let session = h.sessions.last!
            session.emit(.ready)
            session.emit(.diagnostic("Connection reset by peer"))
            session.emit(.exited(255))
            XCTAssertEqual(h.supervisor.states[forwarding.id], .retrying(seconds: delay, reason: "Connection reset by peer"))
            let count = h.sessions.count
            h.clock.advance(TimeInterval(delay))
            XCTAssertEqual(h.sessions.count, count + 1)
            XCTAssertTrue(h.launched.last!.isEnabled)
        }
    }

    func testDisableCancelsPendingReconnect() async {
        let h = Harness()
        var forwarding = sampleForwarding()
        h.supervisor.apply([forwarding])
        h.sessions[0].emit(.exited(255))
        forwarding.isEnabled = false
        h.supervisor.apply([forwarding])
        h.clock.advance(300)
        XCTAssertEqual(h.sessions.count, 1)
        XCTAssertEqual(h.supervisor.states[forwarding.id], .disabled)
    }

    func testDisableActiveSessionIgnoresLateReadyAndExitDoesNotReconnect() async {
        let h = Harness()
        var forwarding = sampleForwarding()
        h.supervisor.apply([forwarding])
        forwarding.isEnabled = false
        h.supervisor.apply([forwarding])
        XCTAssertEqual(h.sessions[0].stops, 1)
        h.sessions[0].emit(.ready)
        XCTAssertEqual(h.supervisor.states[forwarding.id], .disabled)
        h.sessions[0].emit(.exited(15))
        h.clock.advance(300)
        XCTAssertEqual(h.sessions.count, 1)
    }

    func testNetworkRecoveryWaitsForOldProcessToReleaseListener() async {
        let h = Harness(), forwarding = sampleForwarding()
        h.supervisor.apply([forwarding])
        h.sessions[0].emit(.ready)
        h.supervisor.networkChanged(isAvailable: false)
        XCTAssertEqual(h.supervisor.states[forwarding.id], .waitingForNetwork)
        XCTAssertEqual(h.sessions[0].stops, 1)
        h.clock.advance(300)
        XCTAssertEqual(h.sessions.count, 1)
        h.supervisor.networkChanged(isAvailable: true)
        XCTAssertEqual(h.sessions.count, 1)
        h.sessions[0].emit(.exited(15))
        XCTAssertEqual(h.sessions.count, 2)
        h.sessions[1].emit(.ready)
        XCTAssertEqual(h.supervisor.states[forwarding.id], .connected)
        // Late callbacks from the retired generation cannot break the new session.
        h.sessions[0].emit(.exited(255))
        XCTAssertEqual(h.supervisor.states[forwarding.id], .connected)
    }

    func testNetworkRecoveryStartsEnabledConnectionsOnly() async {
        let h = Harness(), enabled = sampleForwarding(), disabled = sampleForwarding(enabled: false)
        h.supervisor.networkChanged(isAvailable: false)
        h.supervisor.apply([enabled, disabled])
        XCTAssertTrue(h.sessions.isEmpty)
        h.supervisor.networkChanged(isAvailable: true)
        XCTAssertEqual(h.sessions.count, 1)
        XCTAssertEqual(h.launched[0].id, enabled.id)
        XCTAssertEqual(h.supervisor.states[disabled.id], .disabled)
    }

    func testSleepWakeRestartsEnabledConnection() async {
        let h = Harness(), forwarding = sampleForwarding()
        h.supervisor.apply([forwarding])
        h.supervisor.setSleeping(true)
        h.sessions[0].emit(.exited(15))
        XCTAssertEqual(h.supervisor.states[forwarding.id], .sleeping)
        h.clock.advance(300)
        XCTAssertEqual(h.sessions.count, 1)
        h.supervisor.setSleeping(false)
        XCTAssertEqual(h.sessions.count, 2)
    }

    func testEditingEnabledConnectionUsesNewParametersAfterOldProcessExits() async {
        let h = Harness()
        var forwarding = sampleForwarding()
        h.supervisor.apply([forwarding])
        forwarding.localPort = 25432
        h.supervisor.apply([forwarding])
        XCTAssertEqual(h.sessions.count, 1)
        h.sessions[0].emit(.exited(15))
        XCTAssertEqual(h.launched.last?.localPort, 25432)
        XCTAssertEqual(h.sessions.count, 2)
    }

    func testLaunchFailureRetriesAndCanRecover() async {
        let h = Harness(), forwarding = sampleForwarding()
        h.launchError = ConfigurationError("Could not launch SSH")
        h.supervisor.apply([forwarding])
        XCTAssertEqual(h.supervisor.states[forwarding.id], .retrying(seconds: 1, reason: "Could not launch SSH"))
        h.launchError = nil
        h.clock.advance(1)
        XCTAssertEqual(h.sessions.count, 1)
        h.sessions[0].emit(.ready)
        XCTAssertEqual(h.supervisor.states[forwarding.id], .connected)
    }

    func testHandshakeDeadlineStopsHungSessionAndRetries() async {
        let h = Harness(), forwarding = sampleForwarding()
        h.supervisor.apply([forwarding])
        h.clock.advance(45)
        XCTAssertEqual(h.sessions[0].stops, 1)
        h.sessions[0].emit(.exited(15))
        XCTAssertEqual(h.supervisor.states[forwarding.id],
                       .retrying(seconds: 1, reason: "The SSH connection did not become ready within 45 seconds."))
        h.clock.advance(1)
        XCTAssertEqual(h.sessions.count, 2)
    }

    func testStableConnectionResetsRetryBackoff() async {
        let h = Harness(), forwarding = sampleForwarding()
        h.supervisor.apply([forwarding])
        h.sessions[0].emit(.exited(255))
        h.clock.advance(1)
        h.sessions[1].emit(.ready)
        h.clock.advance(60)
        h.sessions[1].emit(.exited(255))
        XCTAssertEqual(h.supervisor.states[forwarding.id],
                       .retrying(seconds: 1, reason: "SSH disconnected (exit 255). Ports will try again automatically."))
    }

    func testDeletingConnectionCancelsPendingRetry() async {
        let h = Harness(), forwarding = sampleForwarding()
        h.supervisor.apply([forwarding])
        h.sessions[0].emit(.exited(255))
        h.supervisor.apply([])
        h.clock.advance(300)
        XCTAssertEqual(h.sessions.count, 1)
        XCTAssertNil(h.supervisor.states[forwarding.id])
    }

    func testShutdownWaitsForActiveAndRecentlyDeletedSessionsAndNeverRetries() async {
        let h = Harness(), first = sampleForwarding(), second = sampleForwarding()
        h.supervisor.apply([first, second])
        h.supervisor.apply([second])
        var completed = false
        h.supervisor.shutdown { completed = true }
        XCTAssertFalse(completed)
        h.sessions[1].emit(.exited(15))
        XCTAssertFalse(completed)
        h.sessions[0].emit(.exited(15))
        XCTAssertTrue(completed)
        XCTAssertFalse(h.supervisor.hasRunningSessions)
        h.clock.advance(300)
        h.supervisor.networkChanged(isAvailable: true)
        XCTAssertEqual(h.sessions.count, 2)
    }
}
