// SPDX-License-Identifier: Apache-2.0
import CoreGraphics
import CoreVideo
import Foundation

/// A lifecycle update for one touch contact in the renderer's top-left-origin
/// canvas point space.
///
/// `contactID` is stable for a contact's began/moved/ended (or cancelled)
/// lifecycle. The renderer keeps a completed generation separate from the
/// active ID, so a subsequent contact may reuse the ID while the previous
/// indicator is still fading.
package struct TouchIndicatorContactUpdate: Equatable, Sendable {
    package let contactID: UInt32
    package let phase: TouchIndicatorPhase
    package let position: CGPoint

    package init(contactID: UInt32, phase: TouchIndicatorPhase, position: CGPoint) {
        self.contactID = contactID
        self.phase = phase
        self.position = position
    }
}

package enum TouchIndicatorPhase: Equatable, Sendable {
    case began
    case moved
    case ended
    case cancelled
}

package enum TouchIndicatorRendererError: Error, LocalizedError, Equatable {
    case invalidCanvas(pixelWidth: Int, pixelHeight: Int, pixelsPerPoint: CGFloat)
    case sRGBColorSpaceUnavailable
    case pixelBufferAllocationFailed(status: CVReturn)
    case pixelBufferLockFailed(status: CVReturn)
    case drawingContextCreationFailed

    package var errorDescription: String? {
        switch self {
        case let .invalidCanvas(pixelWidth, pixelHeight, pixelsPerPoint):
            "Invalid touch indicator canvas: \(pixelWidth)x\(pixelHeight) pixels at \(pixelsPerPoint) pixels per point."
        case .sRGBColorSpaceUnavailable:
            "The sRGB color space is unavailable, so touch indicators cannot be rendered."
        case let .pixelBufferAllocationFailed(status):
            "Failed to allocate the touch indicator pixel buffer (CoreVideo status \(status))."
        case let .pixelBufferLockFailed(status):
            "Failed to access the touch indicator pixel buffer (CoreVideo status \(status))."
        case .drawingContextCreationFailed:
            "Failed to create the touch indicator drawing context."
        }
    }
}

/// Synchronously draws touch-contact timelines into one reusable transparent
/// BGRA pixel buffer.
///
/// Call updates, rendering, and clearing from one owner. The renderer creates
/// no task, timer, subscription, or external I/O; the recording session owns
/// the render tick and attaches `pixelBuffer` to its native video stream.
package final class TouchIndicatorRenderer {
    package let pixelWidth: Int
    package let pixelHeight: Int
    package let pixelsPerPoint: CGFloat

    /// The stable buffer attached to the recording stream. `render()` mutates
    /// this buffer in place instead of allocating a new buffer for each tick.
    package var pixelBuffer: CVPixelBuffer { reusablePixelBuffer }

    /// Whether a terminal contact still needs the recording session's managed
    /// render tick. Active contacts redraw only when an input update arrives;
    /// ended/cancelled contacts keep this true through their final clearing
    /// render. Query after `render()` to decide whether to keep the tick armed.
    package var needsAnimationFrame: Bool {
        timelines.values.contains { $0.endedAt != nil }
    }

    private struct ContactTimeline {
        let sequence: UInt64
        var position: CGPoint
        var endedAt: ContinuousClock.Instant?
    }

    private struct Presentation {
        let sequence: UInt64
        let position: CGPoint
        let opacity: CGFloat
        let scale: CGFloat
    }

    private enum Style {
        static let diameter: CGFloat = 44
        static let strokeWidth: CGFloat = 3
        static let fillAlpha: CGFloat = 0.5
        static let holdDuration: Duration = .milliseconds(200)
        static let fadeDuration: Duration = .milliseconds(200)
        static let finalScale: CGFloat = 0.85
    }

    private let color: ResolvedTouchIndicatorColor
    private let colorSpace: CGColorSpace
    private let reusablePixelBuffer: CVPixelBuffer
    private let now: () -> ContinuousClock.Instant

    /// The active generation for each wire contact ID. Completed generations
    /// remain in `timelines` until their independent fade finishes.
    private var activeSequences: [UInt32: UInt64] = [:]
    private var timelines: [UInt64: ContactTimeline] = [:]
    private var nextSequence: UInt64 = 0

    package convenience init(
        pixelWidth: Int,
        pixelHeight: Int,
        pixelsPerPoint: CGFloat,
        color: TouchIndicatorColor = .blue
    ) throws {
        try self.init(
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            pixelsPerPoint: pixelsPerPoint,
            color: color,
            now: { ContinuousClock.now }
        )
    }

    init(
        pixelWidth: Int,
        pixelHeight: Int,
        pixelsPerPoint: CGFloat,
        color: TouchIndicatorColor = .blue,
        now: @escaping () -> ContinuousClock.Instant
    ) throws {
        guard pixelWidth > 0,
              pixelHeight > 0,
              pixelsPerPoint.isFinite,
              pixelsPerPoint > 0
        else {
            throw TouchIndicatorRendererError.invalidCanvas(
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight,
                pixelsPerPoint: pixelsPerPoint
            )
        }
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw TouchIndicatorRendererError.sRGBColorSpaceUnavailable
        }

        var pixelBuffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        let status = CVPixelBufferCreate(
            nil,
            pixelWidth,
            pixelHeight,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw TouchIndicatorRendererError.pixelBufferAllocationFailed(status: status)
        }

        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.pixelsPerPoint = pixelsPerPoint
        self.color = try color.resolveSRGB()
        self.colorSpace = colorSpace
        self.reusablePixelBuffer = pixelBuffer
        self.now = now

        try clearPixelBuffer()
    }

    /// Applies one ordered group of contact updates at a single monotonic
    /// instant. A moved/terminal update without a matching active contact is a
    /// no-op, which avoids inventing a touch when recording starts mid-input.
    package func apply(_ updates: [TouchIndicatorContactUpdate]) {
        let instant = now()
        for update in updates {
            switch update.phase {
            case .began:
                begin(update, at: instant)
            case .moved:
                move(update)
            case .ended, .cancelled:
                end(update, at: instant)
            }
        }
    }

    /// Rebuilds the transparent overlay from the current contact timelines and
    /// returns the same buffer instance exposed by `pixelBuffer`.
    @discardableResult
    package func render() throws -> CVPixelBuffer {
        let presentations = presentations(at: now())

        let lockStatus = CVPixelBufferLockBaseAddress(reusablePixelBuffer, [])
        guard lockStatus == kCVReturnSuccess else {
            throw TouchIndicatorRendererError.pixelBufferLockFailed(status: lockStatus)
        }
        defer { CVPixelBufferUnlockBaseAddress(reusablePixelBuffer, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(reusablePixelBuffer) else {
            throw TouchIndicatorRendererError.drawingContextCreationFailed
        }
        memset(baseAddress, 0, CVPixelBufferGetDataSize(reusablePixelBuffer))

        guard let context = CGContext(
            data: baseAddress,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(reusablePixelBuffer),
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            throw TouchIndicatorRendererError.drawingContextCreationFailed
        }

        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        context.translateBy(x: 0, y: CGFloat(pixelHeight))
        context.scaleBy(x: pixelsPerPoint, y: -pixelsPerPoint)

        for presentation in presentations {
            draw(presentation, in: context)
        }

        return reusablePixelBuffer
    }

    /// Removes every contact timeline and makes the reusable buffer fully
    /// transparent. It is safe to call repeatedly during recording teardown.
    package func clear() throws {
        activeSequences.removeAll(keepingCapacity: true)
        timelines.removeAll(keepingCapacity: true)
        nextSequence = 0
        try clearPixelBuffer()
    }

    private func begin(_ update: TouchIndicatorContactUpdate, at instant: ContinuousClock.Instant) {
        if let previousSequence = activeSequences.removeValue(forKey: update.contactID),
           var previous = timelines[previousSequence]
        {
            previous.endedAt = instant
            timelines[previousSequence] = previous
        }

        let sequence = nextSequence
        nextSequence += 1
        activeSequences[update.contactID] = sequence
        timelines[sequence] = ContactTimeline(
            sequence: sequence,
            position: update.position,
            endedAt: nil
        )
    }

    private func move(_ update: TouchIndicatorContactUpdate) {
        guard let sequence = activeSequences[update.contactID],
              var timeline = timelines[sequence]
        else { return }
        timeline.position = update.position
        timelines[sequence] = timeline
    }

    private func end(_ update: TouchIndicatorContactUpdate, at instant: ContinuousClock.Instant) {
        guard let sequence = activeSequences.removeValue(forKey: update.contactID),
              var timeline = timelines[sequence]
        else { return }
        timeline.position = update.position
        timeline.endedAt = instant
        timelines[sequence] = timeline
    }

    private func presentations(at instant: ContinuousClock.Instant) -> [Presentation] {
        var expiredSequences: [UInt64] = []
        var presentations: [Presentation] = []
        presentations.reserveCapacity(timelines.count)

        for timeline in timelines.values {
            guard let endedAt = timeline.endedAt else {
                presentations.append(Presentation(
                    sequence: timeline.sequence,
                    position: timeline.position,
                    opacity: 1,
                    scale: 1
                ))
                continue
            }

            let elapsed = instant - endedAt
            let totalDuration = Style.holdDuration + Style.fadeDuration
            if elapsed >= totalDuration {
                expiredSequences.append(timeline.sequence)
                continue
            }

            let fadeProgress: CGFloat
            if elapsed <= Style.holdDuration {
                fadeProgress = 0
            } else {
                fadeProgress = CGFloat(
                    Self.seconds(elapsed - Style.holdDuration)
                        / Self.seconds(Style.fadeDuration)
                )
            }
            presentations.append(Presentation(
                sequence: timeline.sequence,
                position: timeline.position,
                opacity: 1 - fadeProgress,
                scale: 1 - ((1 - Style.finalScale) * fadeProgress)
            ))
        }

        for sequence in expiredSequences {
            timelines.removeValue(forKey: sequence)
        }
        return presentations.sorted { $0.sequence < $1.sequence }
    }

    private func draw(_ presentation: Presentation, in context: CGContext) {
        let diameter = Style.diameter * presentation.scale
        let strokeWidth = Style.strokeWidth * presentation.scale
        let bounds = CGRect(
            x: presentation.position.x - (diameter / 2),
            y: presentation.position.y - (diameter / 2),
            width: diameter,
            height: diameter
        ).insetBy(
            dx: strokeWidth / 2,
            dy: strokeWidth / 2
        )

        context.setLineWidth(strokeWidth)
        context.setStrokeColor(
            red: color.red,
            green: color.green,
            blue: color.blue,
            alpha: presentation.opacity
        )
        context.setFillColor(
            red: color.red,
            green: color.green,
            blue: color.blue,
            alpha: Style.fillAlpha * presentation.opacity
        )
        context.addEllipse(in: bounds)
        context.drawPath(using: .fillStroke)
    }

    private func clearPixelBuffer() throws {
        let lockStatus = CVPixelBufferLockBaseAddress(reusablePixelBuffer, [])
        guard lockStatus == kCVReturnSuccess else {
            throw TouchIndicatorRendererError.pixelBufferLockFailed(status: lockStatus)
        }
        defer { CVPixelBufferUnlockBaseAddress(reusablePixelBuffer, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(reusablePixelBuffer) else {
            throw TouchIndicatorRendererError.drawingContextCreationFailed
        }
        memset(baseAddress, 0, CVPixelBufferGetDataSize(reusablePixelBuffer))
    }

    private static func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + (Double(components.attoseconds) / 1e18)
    }
}
