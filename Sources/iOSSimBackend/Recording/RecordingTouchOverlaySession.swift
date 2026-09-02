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
    private let listener: RecordedTouchStreamListener
    private let closeCondition = NSCondition()
    private var closeState = CloseState.open

    init(
        udid: String,
        stream: FBSimulatorVideoStream,
        geometry: TouchIndicatorVideoGeometry,
        color: TouchIndicatorColor,
        framesPerSecond: Int,
        baseDirectory: URL? = nil
    ) throws {
        precondition(
            (1...60).contains(framesPerSecond),
            "VideoRecordingOptions owns the 1...60 FPS invariant."
        )
        let renderer = try TouchIndicatorRenderer(
            pixelWidth: geometry.pixelWidth,
            pixelHeight: geometry.pixelHeight,
            pixelsPerPoint: geometry.pixelsPerPoint,
            color: color
        )
        let state = State(
            renderer: renderer,
            framesPerSecond: framesPerSecond
        )
        stream.updateOverlayBuffer(renderer.pixelBuffer)

        do {
            listener = try RecordedTouchStreamListener(
                udid: udid,
                baseDirectory: baseDirectory,
                onInput: { [state] input in
                    state.enqueue(input)
                },
                onDiagnostic: { message in
                    Self.writeWarning(message)
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
    private let frameIntervalNanoseconds: Int
    private let queue = DispatchQueue(label: "com.lycorp.sim-use.touch-indicator-render")
    private let queueKey = DispatchSpecificKey<UInt8>()
    private var timer: DispatchSourceTimer?
    private var activationUptimeNanoseconds: UInt64?
    private var isClosed = false

    init(renderer: TouchIndicatorRenderer, framesPerSecond: Int) {
        self.renderer = renderer
        self.frameIntervalNanoseconds = Int(
            1_000_000_000 / UInt64(framesPerSecond)
        )
        queue.setSpecific(key: queueKey, value: 1)
    }

    func activate() {
        sync {
            guard !isClosed else { return }
            activationUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
        }
    }

    func enqueue(_ input: RecordedTouchInput) {
        queue.async { [weak self] in
            self?.consume(input)
        }
    }

    func close() {
        sync {
            guard !isClosed else { return }
            isClosed = true
            activationUptimeNanoseconds = nil
            cancelTimer()
            do {
                try renderer.clear()
            } catch {
                recordRendererFailure(error)
            }
        }
    }

    private func consume(_ input: RecordedTouchInput) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !isClosed else { return }
        guard let activationUptimeNanoseconds else { return }

        switch input {
        case let .update(publisherID, primitive):
            guard primitive.dispatchUptimeNanoseconds >= activationUptimeNanoseconds
            else { return }
            let phase: TouchIndicatorPhase = primitive.phase == .down
                ? .began
                : .ended
            let updates = primitive.contacts.map { contact in
                TouchIndicatorContactUpdate(
                    contactID: TouchIndicatorContactID(
                        publisherID: publisherID,
                        localID: contact.localID
                    ),
                    phase: phase,
                    position: CGPoint(x: contact.x, y: contact.y),
                    uptimeNanoseconds: primitive.dispatchUptimeNanoseconds
                )
            }
            renderer.apply(updates)

        case let .publisherClosed(publisherID, uptimeNanoseconds):
            guard uptimeNanoseconds >= activationUptimeNanoseconds else { return }
            renderer.cancelContacts(
                from: publisherID,
                uptimeNanoseconds: uptimeNanoseconds
            )
        }
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
            deadline: .now() + .nanoseconds(frameIntervalNanoseconds),
            repeating: .nanoseconds(frameIntervalNanoseconds),
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
