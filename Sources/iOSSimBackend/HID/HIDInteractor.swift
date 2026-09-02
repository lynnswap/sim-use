// SPDX-License-Identifier: Apache-2.0
import Foundation
import CompanionUtilities
import FBControlCore
import FBSimulatorControl
import SimUseCore

// MARK: - HID Interactor
@MainActor
public struct HIDInteractor {

    /// A HID session against one simulator boot. Commands that hold a
    /// Session across many events (type, batch, gesture) do not re-check
    /// boot identity per event: a mid-burst reboot fails the burst —
    /// loudly, via the send deadline — and the next command recovers
    /// through the boot gate in `getOrCreateHIDConnection`.
    public struct Session {
        public let simulatorUDID: String
        public let simulator: FBSimulator
        public let hid: FBSimulatorHID
        let recordedTouchNormalizer: RecordedTouchEventNormalizer
    }

    // Cache for HID connections per simulator. Each entry carries the
    // boot token it was created against (see HIDBootIdentity): the
    // connection's mach port dies with that boot, and a send through a
    // dead port hangs or silently drops input (issue #55), so reuse
    // must be gated on the token before anything is sent.
    // `transportTrusted` is false when the transport was auto-selected
    // inside the boot-attach trust window (issue #67): the entry may
    // serve the command that created it but must not be reused, so the
    // next command re-derives the selection.
    private struct CachedConnection {
        let hid: FBSimulatorHID
        let bootToken: HIDBootToken
        let transportTrusted: Bool
    }

    private static var hidConnections: [String: CachedConnection] = [:]
    private static let recordedTouchStateStore = RecordedTouchStateStore()

    private final class HIDDispatchAttempt {
        var didScheduleTouch = false
    }

    /// Configurable stabilization delay to ensure HID events are fully processed
    /// Can be set via SIM_USE_HID_STABILIZATION_MS environment variable
    private static var stabilizationDelayMs: UInt64 {
        if let envValue = ProcessInfo.processInfo.environment["SIM_USE_HID_STABILIZATION_MS"],
           let milliseconds = UInt64(envValue) {
            return min(milliseconds, 1000)
        }
        return 25
    }

    /// Debug override for the HID transport, via SIM_USE_HID_TRANSPORT
    /// (`indigo` | `dtuhid`). Unset (the default) lets upstream's
    /// auto-selection pick: the DTUHID transport on simulators whose
    /// legacy HID is dtuhidd-suppressed (booted with Device Hub open),
    /// the legacy Indigo path otherwise. Note the daemon keeps the
    /// environment it was spawned with — combine with SIM_USE_NO_DAEMON=1
    /// or a daemon restart for ad-hoc experiments.
    private static var transportOverride: FBSimulatorHIDTransportType? {
        switch ProcessInfo.processInfo.environment["SIM_USE_HID_TRANSPORT"]?.lowercased() {
        case "indigo": return .indigo
        case "dtuhid": return .dtuhid
        default: return nil
        }
    }

    /// Deadline for a single HID send (see HIDSendDeadline). A single
    /// perform can legitimately run ~10 s (swipe/press durations), so
    /// the default leaves generous headroom. Override via
    /// SIM_USE_HID_SEND_TIMEOUT_MS; 0 disables the deadline.
    private static var sendTimeoutMs: UInt64 {
        if let envValue = ProcessInfo.processInfo.environment["SIM_USE_HID_SEND_TIMEOUT_MS"],
           let milliseconds = UInt64(envValue) {
            return milliseconds
        }
        return 30_000
    }

    public static func makeSession(for simulatorUDID: String, logger: SimUseLogger) async throws -> Session {
        logger.info().log("Loading private frameworks for HID operations...")
        let frameworkLoader = FBSimulatorControlFrameworkLoader.xcodeFrameworks
        // Xcode 27 removed SimulatorKit; surface an actionable message
        // (select Xcode 26.x) before the loader fails cryptically.
        try XcodeCompatibility.assertSimulatorKitAvailable(logger: logger)
        // Keep this explicit preload while the pinned idb constructs its
        // Indigo client before loading SimulatorKit (facebook/idb#941).
        do {
            try frameworkLoader.loadPrivateFrameworks(logger)
            logger.info().log("Private frameworks loaded successfully.")
        } catch {
            logger.error().log("Failed to load private frameworks: \(error)")
            throw CLIError(errorDescription: "SimulatorKit is required for HID interactions. Error: \(error)")
        }

        let simulatorSet = try await getSimulatorSet(deviceSetPath: nil, logger: logger, reporter: EmptyEventReporter.shared)
        logger.info().log("FBSimulatorSet obtained.")

        guard let simulator = simulatorSet.allSimulators.first(where: { $0.udid == simulatorUDID }) else {
            throw CLIError(errorDescription: "Simulator with UDID \(simulatorUDID) not found in set.")
        }

        logger.info().log("Target (FBSimulator) obtained: \(simulator.udid)")
        logger.info().log("Simulator name: \(simulator.name)")

        guard simulator.state == .booted else {
            throw CLIError(errorDescription: "Simulator with UDID \(simulatorUDID) is not booted. Current state: \(simulator.state)")
        }
        logger.info().log("Simulator state verified: booted")

        let connection = try await getOrCreateHIDConnection(for: simulator, logger: logger)
        let normalizer = recordedTouchStateStore.normalizer(
            for: simulatorUDID,
            bootToken: connection.bootToken
        )
        return Session(
            simulatorUDID: simulatorUDID,
            simulator: simulator,
            hid: connection.hid,
            recordedTouchNormalizer: normalizer
        )
    }

    public static func performHIDEvent(_ event: FBSimulatorHIDEvent, in session: Session, logger: SimUseLogger) async throws {
        let initialAttempt = HIDDispatchAttempt()
        do {
            try await performHIDEventOnce(
                event,
                in: session,
                attempt: initialAttempt,
                logger: logger
            )
        } catch {
            // Fail-invalidate + cautious retry-once: see HIDPerformRecovery
            // for the decision rules and why only dead-transport errors
            // are safe to re-perform.
            do {
                try await HIDPerformRecovery.recover(
                    from: error,
                    wholeEventRetryIsSafe: !initialAttempt.didScheduleTouch,
                    invalidate: {
                        logger.error().log("HID event failed (\(error.localizedDescription)); dropping cached HID connection for \(session.simulatorUDID)")
                        clearHIDConnection(for: session.simulatorUDID)
                    }, rebuildAndRetry: {
                        logger.info().log("Dead HID transport for \(session.simulatorUDID); rebuilding session and retrying once...")
                        let freshSession = try await makeSession(for: session.simulatorUDID, logger: logger)
                        let retryAttempt = HIDDispatchAttempt()
                        do {
                            try await performHIDEventOnce(
                                event,
                                in: freshSession,
                                attempt: retryAttempt,
                                logger: logger
                            )
                        } catch {
                            // Keep the "a failed perform never leaves its
                            // connection cached" invariant on the retry path too.
                            clearHIDConnection(for: session.simulatorUDID)
                            throw error
                        }
                    }
                )
            } catch {
                publishRecordedTouchCancellation(for: session.simulatorUDID, logger: logger)
                throw error
            }
        }
    }

    private static func publishRecordedTouchEvent(
        _ event: FBSimulatorHIDEvent,
        for simulatorUDID: String,
        normalizer: RecordedTouchEventNormalizer,
        dispatchUptimeNanoseconds: UInt64,
        logger: SimUseLogger
    ) {
        do {
            guard let recordedEvent = try normalizer.event(
                from: event,
                udid: simulatorUDID,
                dispatchUptimeNanoseconds: dispatchUptimeNanoseconds
            ) else { return }
            logRecordedTouchPublishResult(
                RecordedTouchEventPublisher(udid: simulatorUDID).publish(recordedEvent),
                logger: logger
            )
        } catch {
            logger.error().log("Touch indicator event normalization failed; HID input will continue: \(error.localizedDescription)")
        }
    }

    private static func publishRecordedTouchCancellation(
        for simulatorUDID: String,
        logger: SimUseLogger
    ) {
        guard let event = recordedTouchStateStore.currentNormalizer(for: simulatorUDID)?.cancellationEvent(
            udid: simulatorUDID
        ) else { return }
        logRecordedTouchPublishResult(
            RecordedTouchEventPublisher(udid: simulatorUDID).publish(event),
            logger: logger
        )
    }

    private static func logRecordedTouchPublishResult(
        _ result: RecordedTouchPublishResult,
        logger: SimUseLogger
    ) {
        if case let .failed(diagnostic) = result {
            logger.error().log("Touch indicator event delivery failed; HID input will continue: \(diagnostic.description)")
        }
    }

    private static func performHIDEventOnce(
        _ event: FBSimulatorHIDEvent,
        in session: Session,
        attempt: HIDDispatchAttempt,
        logger: SimUseLogger
    ) async throws {
        logger.info().log("Performing HID event...")
        let timeoutMs = sendTimeoutMs
        // Capture the hid handle, not the whole Session: FBSimulatorHID is
        // @unchecked Sendable upstream, while Session carries the
        // non-Sendable FBSimulator and would trip strict-concurrency
        // checking inside the @Sendable deadline closure.
        let hid = session.hid
        let udid = session.simulatorUDID
        try await HIDEventDispatchExecutor.perform(
            event,
            sendPrimitive: { primitive in
                logger.info().log("Sending \(primitive)")
                if timeoutMs > 0 {
                    return try await HIDSendDeadline.run(milliseconds: timeoutMs) {
                        let dispatchUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
                        try await primitive.sendAsync(on: hid)
                        return dispatchUptimeNanoseconds
                    } onTimeout: {
                        Self.hidTimeoutError(timeoutMs: timeoutMs, simulatorUDID: udid)
                    }
                }
                let dispatchUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
                try await primitive.sendAsync(on: hid)
                return dispatchUptimeNanoseconds
            },
            sleep: { duration in
                logger.info().log("Delay \(duration)s")
                try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            },
            flush: {
                // Do not call `hid.send` for every primitive: that would flush
                // the DTUHID transport after every phase and break gesture
                // timing. The pinned FB API exposes primitive `sendAsync` but
                // keeps `flush()` internal; an empty composite is its public
                // zero-payload path to the same one-shot final flush.
                if timeoutMs > 0 {
                    try await HIDSendDeadline.run(milliseconds: timeoutMs) {
                        try await hid.send(event: .composite([]), logger: logger)
                    } onTimeout: {
                        Self.hidTimeoutError(timeoutMs: timeoutMs, simulatorUDID: udid)
                    }
                } else {
                    try await hid.send(event: .composite([]), logger: logger)
                }
            },
            didSendPrimitive: { primitive, dispatchUptimeNanoseconds in
                guard Self.isTouchPrimitive(primitive) else { return }
                attempt.didScheduleTouch = true
                publishRecordedTouchEvent(
                    primitive,
                    for: udid,
                    normalizer: session.recordedTouchNormalizer,
                    dispatchUptimeNanoseconds: dispatchUptimeNanoseconds,
                    logger: logger
                )
            }
        )
        logger.info().log("HID event performed successfully.")

        if stabilizationDelayMs > 0 {
            logger.info().log("Applying stabilization delay of \(stabilizationDelayMs)ms...")
            try await Task.sleep(nanoseconds: stabilizationDelayMs * 1_000_000)
        }
    }

    nonisolated private static func hidTimeoutError(
        timeoutMs: UInt64,
        simulatorUDID: String
    ) -> CLIError {
        CLIError(errorDescription: """
        HID event delivery timed out after \(timeoutMs) ms; the connection to \
        simulator \(simulatorUDID) may be dead (rebooted mid-command?). The cached \
        connection is dropped and rebuilt on the next command.
        """)
    }

    private static func isTouchPrimitive(_ event: FBSimulatorHIDEvent) -> Bool {
        switch event {
        case .touch, .twoFingerTouch:
            true
        default:
            false
        }
    }

    public static func performHIDEvent(_ event: FBSimulatorHIDEvent, for simulatorUDID: String, logger: SimUseLogger) async throws {
        let session = try await makeSession(for: simulatorUDID, logger: logger)
        try await performHIDEvent(event, in: session, logger: logger)
    }

    // Get or create a cached HID connection (matching CompanionLib's connectToHID behavior)
    private static func getOrCreateHIDConnection(
        for simulator: FBSimulator,
        logger: SimUseLogger
    ) async throws -> CachedConnection {
        let currentToken = HIDBootIdentity.token(dataDirectory: simulator.dataDirectory, udid: simulator.udid)
        if let cached = hidConnections[simulator.udid] {
            let sameBoot = HIDBootIdentity.isReusable(cachedToken: cached.bootToken, currentToken: currentToken)
            if sameBoot && cached.transportTrusted {
                logger.info().log("Using existing HID connection for simulator \(simulator.udid)")
                return cached
            }
            if sameBoot {
                // Same boot, but the transport was auto-selected inside
                // the boot-attach trust window (issue #67): dtuhidd may
                // have appeared since the probe, so the selection must
                // be re-derived rather than pinned for the whole boot.
                logger.info().log("Cached HID connection for \(simulator.udid) was created inside the transport trust window; discarding it to re-derive the transport selection")
            } else {
                // The simulator was re-booted (or the boot identity is
                // unknowable) since the connection was made: the cached
                // handle's mach port is dead and must not be sent through.
                logger.info().log("Boot identity changed for simulator \(simulator.udid) (cached: \(cached.bootToken); current: \(currentToken)); discarding cached HID connection")
            }
            cached.hid.disconnect()
            hidConnections.removeValue(forKey: simulator.udid)
        }

        logger.info().log("Creating new HID connection for simulator \(simulator.udid)...")
        // Upstream does not expose which transport its auto-selection
        // resolved to, so log the input signals instead: the forced
        // override when present, otherwise the dtuhidd-presence fact the
        // selection keys on (a ~1–2 ms sysctl probe we already pay for
        // the boot-identity token).
        if let transportOverride {
            logger.info().log("HID transport forced via SIM_USE_HID_TRANSPORT: \(transportOverride)")
        } else {
            let presence = dtuhiddPresenceHint(forUDID: simulator.udid)
                .map { $0 ? "present" : "absent" } ?? "unknown"
            logger.info().log("HID transport: auto (dtuhidd in this simulator's process tree: \(presence); upstream selects DTUHID when present)")
        }
        // Bare construction, not `simulator.connectToHID()`: upstream's
        // lifecycle wrapper keeps its own per-simulator cache with no
        // boot-identity gate, which would resurrect exactly the stale
        // handles this cache invalidates (issue #55). Transport selection
        // stays automatic (`FBSimulator.defaultHIDTransport`) unless the
        // debug override is set.
        let hid = try FBSimulatorHID(for: simulator, transport: transportOverride)

        // A forced transport cannot race dtuhidd's boot-time attach;
        // only the auto-selection is window-gated.
        let transportTrusted = transportOverride != nil
            || HIDBootIdentity.isTransportSelectionTrustworthy(token: currentToken, now: Date())
        let connection = CachedConnection(
            hid: hid,
            bootToken: currentToken,
            transportTrusted: transportTrusted
        )
        hidConnections[simulator.udid] = connection
        if transportTrusted {
            logger.info().log("HID connection created and cached for simulator \(simulator.udid)")
        } else {
            logger.info().log("HID connection created for simulator \(simulator.udid) inside the transport trust window (launchd_sim uptime < \(Int(HIDBootIdentity.transportTrustWindow)) s); the next command re-derives the transport selection")
        }

        return connection
    }

    /// Whether a `dtuhidd` currently lives in the simulator's
    /// `launchd_sim` subtree — the signal upstream's transport
    /// auto-selection keys on. Diagnostic only (logged above); nil when
    /// the process table cannot be read.
    private static func dtuhiddPresenceHint(forUDID udid: String) -> Bool? {
        guard let table = LaunchdSimLocator.processTable(),
              let launchdSim = LaunchdSimLocator.record(
                  forUDID: udid, in: table,
                  argumentsForPID: LaunchdSimLocator.argumentBlob(forPID:))
        else {
            return nil
        }
        return table.contains { $0.ppid == launchdSim.pid && $0.command == "dtuhidd" }
    }

    public static func clearHIDConnections() {
        for cached in hidConnections.values {
            cached.hid.disconnect()
        }
        hidConnections.removeAll()
        recordedTouchStateStore.removeAll()
    }

    /// Drop the cached HID connection for a single UDID. A same-boot
    /// dead-transport retry preserves touch state from previously successful
    /// commands. Successful touch primitives commit immediately, and a whole
    /// event is retried only when the failed attempt committed none. Daemon
    /// stale-simulator cleanup passes
    /// `resetRecordedTouchState: true`, because contacts from the previous
    /// simulator boot cannot continue into the next boot.
    public static func clearHIDConnection(
        for simulatorUDID: String,
        resetRecordedTouchState: Bool = false
    ) {
        hidConnections[simulatorUDID]?.hid.disconnect()
        hidConnections.removeValue(forKey: simulatorUDID)
        if resetRecordedTouchState {
            recordedTouchStateStore.removeValue(for: simulatorUDID)
        }
    }
}
