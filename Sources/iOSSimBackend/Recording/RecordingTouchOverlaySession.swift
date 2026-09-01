// SPDX-License-Identifier: Apache-2.0
import CoreGraphics
import Dispatch
import Foundation
import FBSimulatorControl
import SimUseCore
import SimUseVideo

/// Recorder-side owner for one indicator-enabled recording.
///
/// The listener callback and render timer feed a private serial queue. The
/// renderer's reusable buffer is attached to the eager video stream once;
/// cadence ticks read its updated contents without swapping the buffer.
final class RecordingTouchOverlaySession {
    private let stream: FBSimulatorVideoStream
    private let state: State
    private let listener: RecordedTouchEventListener
    private let closeCondition = NSCondition()
    private var closeState = CloseState.open

    init(
        udid: String,
        stream: FBSimulatorVideoStream,
        geometry: TouchIndicatorVideoGeometry,
        color: TouchIndicatorColor,
        baseDirectory: URL? = nil
    ) throws {
        let renderer = try TouchIndicatorRenderer(
            pixelWidth: geometry.pixelWidth,
            pixelHeight: geometry.pixelHeight,
            pixelsPerPoint: geometry.pixelsPerPoint,
            color: color
        )
        let state = State(renderer: renderer)
        stream.updateOverlayBuffer(renderer.pixelBuffer)

        do {
            listener = try RecordedTouchEventListener(
                udid: udid,
                baseDirectory: baseDirectory,
                onEvent: { [state] event in
                    state.enqueue(event)
                },
                onDiagnostic: { diagnostic in
                    Self.writeWarning(diagnostic.description)
                }
            )
        } catch {
            stream.updateOverlayBuffer(nil)
            throw error
        }

        self.stream = stream
        self.state = state
    }

    /// Starts accepting events only after native recording has started. Events
    /// received during setup are deliberately discarded instead of appearing
    /// before the first captured frame.
    func activate() {
        state.activate()
    }

    func checkHealth() throws {
        if let error = state.firstError.first {
            throw error
        }
    }

    /// Stops intake, drains the render queue, clears/detaches the buffer, and
    /// surfaces any render failure observed during recording.
    func close() throws {
        closeCondition.lock()
        switch closeState {
        case .closed:
            closeCondition.unlock()
            try checkHealth()
            return
        case .closing:
            while closeState != .closed {
                closeCondition.wait()
            }
            closeCondition.unlock()
            try checkHealth()
            return
        case .open:
            closeState = .closing
            closeCondition.unlock()
        }

        listener.close()
        state.close()
        stream.updateOverlayBuffer(nil)

        closeCondition.lock()
        closeState = .closed
        closeCondition.broadcast()
        closeCondition.unlock()
        try checkHealth()
    }

    deinit {
        do {
            try close()
        } catch {
            Self.writeWarning("Touch indicator cleanup failed: \(error.localizedDescription)")
        }
    }

    fileprivate static func writeWarning(_ message: String) {
        FileHandle.standardError.write(Data("warning: \(message)\n".utf8))
    }

    private enum CloseState {
        case open
        case closing
        case closed
    }
}

/// All mutable renderer/timer state is confined to `queue`. Listener callbacks
/// cross into that queue with immutable Sendable values; synchronous close
/// drains it before the stream is detached. This is the complete enforcement
/// for the narrow Dispatch callback bridge.
private final class State: @unchecked Sendable {
    let firstError = FirstErrorBox()

    private let renderer: TouchIndicatorRenderer
    private let queue = DispatchQueue(label: "com.lycorp.sim-use.touch-indicator-render")
    private let queueKey = DispatchSpecificKey<UInt8>()
    private var timer: DispatchSourceTimer?
    private var isActive = false
    private var isClosed = false
    private var eventsAwaitingActivation: [RecordedTouchEvent] = []

    init(renderer: TouchIndicatorRenderer) {
        self.renderer = renderer
        queue.setSpecific(key: queueKey, value: 1)
    }

    func activate() {
        sync {
            guard !isClosed else { return }
            isActive = true
            let pendingEvents = eventsAwaitingActivation
            eventsAwaitingActivation.removeAll(keepingCapacity: false)
            for event in pendingEvents {
                apply(event)
            }
        }
    }

    func enqueue(_ event: RecordedTouchEvent) {
        queue.async { [weak self] in
            self?.consume(event)
        }
    }

    func close() {
        sync {
            guard !isClosed else { return }
            isClosed = true
            isActive = false
            eventsAwaitingActivation.removeAll(keepingCapacity: false)
            cancelTimer()
            do {
                try renderer.clear()
            } catch {
                recordRendererFailure(error)
            }
        }
    }

    private func consume(_ event: RecordedTouchEvent) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !isClosed else { return }
        guard isActive else {
            eventsAwaitingActivation.append(event)
            return
        }
        apply(event)
    }

    private func apply(_ event: RecordedTouchEvent) {
        dispatchPrecondition(condition: .onQueue(queue))

        var updates: [TouchIndicatorContactUpdate] = []
        updates.reserveCapacity(event.samples.reduce(0) { $0 + $1.contacts.count })
        for sample in event.samples {
            let (uptimeNanoseconds, overflow) = event.dispatchUptimeNanoseconds
                .addingReportingOverflow(sample.relativeNanoseconds)
            guard !overflow else {
                RecordingTouchOverlaySession.writeWarning(
                    "Discarded touch indicator event \(event.eventID): its monotonic timestamp overflowed."
                )
                return
            }
            for contact in sample.contacts {
                updates.append(TouchIndicatorContactUpdate(
                    contactID: contact.contactID,
                    phase: Self.phase(contact.phase),
                    position: CGPoint(x: contact.x, y: contact.y),
                    uptimeNanoseconds: uptimeNanoseconds
                ))
            }
        }

        renderer.apply(updates)
        renderAndUpdateTimer()
    }

    private func renderAndUpdateTimer() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !isClosed, firstError.first == nil else {
            cancelTimer()
            return
        }
        do {
            try renderer.render()
        } catch {
            recordRendererFailure(error)
            cancelTimer()
            return
        }

        if renderer.needsAnimationFrame {
            ensureTimer()
        } else {
            cancelTimer()
        }
    }

    private func ensureTimer() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + .milliseconds(16),
            repeating: .milliseconds(16),
            leeway: .milliseconds(2)
        )
        timer.setEventHandler { [weak self] in
            self?.renderAndUpdateTimer()
        }
        self.timer = timer
        timer.activate()
    }

    private func cancelTimer() {
        dispatchPrecondition(condition: .onQueue(queue))
        timer?.cancel()
        timer = nil
    }

    private func recordRendererFailure(_ error: Error) {
        firstError.set(RecordingTouchOverlayError.renderingFailed(
            underlying: error.localizedDescription
        ))
    }

    private func sync(_ body: () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            body()
        } else {
            queue.sync(execute: body)
        }
    }

    private static func phase(_ phase: RecordedTouchPhase) -> TouchIndicatorPhase {
        switch phase {
        case .began: .began
        case .moved: .moved
        case .ended: .ended
        case .cancelled: .cancelled
        }
    }
}

enum RecordingTouchOverlayError: Error, LocalizedError, Equatable {
    case renderingFailed(underlying: String)

    var errorDescription: String? {
        switch self {
        case let .renderingFailed(underlying):
            "Touch indicator rendering failed: \(underlying)"
        }
    }
}
