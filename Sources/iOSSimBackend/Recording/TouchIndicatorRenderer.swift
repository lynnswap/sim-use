// SPDX-License-Identifier: Apache-2.0
import CoreGraphics
import CoreVideo
import Dispatch
import Foundation
import QuartzCore
import SimUseVideo

/// A lifecycle update for one touch contact in the renderer's top-left-origin
/// canvas point space.
///
/// `contactID` is stable for a contact's began/moved/ended (or cancelled)
/// lifecycle. The renderer keeps a completed generation separate from the
/// active ID, so a subsequent contact may reuse the ID while the previous
/// indicator is still fading.
package struct TouchIndicatorContactID: Equatable, Hashable, Sendable {
    package let publisherID: UUID
    package let localID: UInt8

    package init(publisherID: UUID, localID: UInt8) {
        self.publisherID = publisherID
        self.localID = localID
    }
}

package struct TouchIndicatorContactUpdate: Equatable, Sendable {
    package let contactID: TouchIndicatorContactID
    package let phase: TouchIndicatorPhase
    package let position: CGPoint
    /// Absolute host monotonic time, in the same uptime epoch used by
    /// `DispatchTime.now().uptimeNanoseconds` in every local process.
    package let uptimeNanoseconds: UInt64

    package init(
        contactID: TouchIndicatorContactID,
        phase: TouchIndicatorPhase,
        position: CGPoint,
        uptimeNanoseconds: UInt64
    ) {
        self.contactID = contactID
        self.phase = phase
        self.position = position
        self.uptimeNanoseconds = uptimeNanoseconds
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
    /// render tick. Active contacts redraw only when another input update
    /// arrives; ended/cancelled contacts keep this true through their final
    /// clearing render. Query after `render()` to decide whether to keep the
    /// tick armed.
    package var needsAnimationFrame: Bool {
        timelines.values.contains { $0.endedAtNanoseconds != nil }
    }

    private struct ContactTimeline {
        let sequence: UInt64
        var generationStartedAtNanoseconds: UInt64
        var position: CGPoint
        var endedAtNanoseconds: UInt64?
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
        static let holdNanoseconds: UInt64 = 200_000_000
        static let fadeNanoseconds: UInt64 = 200_000_000
        static let totalTerminalNanoseconds = holdNanoseconds + fadeNanoseconds
        static let finalScale: CGFloat = 0.85
        static let terminalTiming = UnitBezierTimingFunction(
            CAMediaTimingFunction(name: .easeInEaseOut)
        )
    }

    private let color: ResolvedTouchIndicatorColor
    private let colorSpace: CGColorSpace
    private let reusablePixelBuffer: CVPixelBuffer
    private let hostUptimeNanoseconds: () -> UInt64

    /// The active generation for each wire contact ID. Completed generations
    /// remain in `timelines` until their independent fade finishes.
    private var activeSequences: [TouchIndicatorContactID: UInt64] = [:]
    private var timelines: [UInt64: ContactTimeline] = [:]
    private var nextContactSequence: UInt64 = 0

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
            hostUptimeNanoseconds: { DispatchTime.now().uptimeNanoseconds }
        )
    }

    init(
        pixelWidth: Int,
        pixelHeight: Int,
        pixelsPerPoint: CGFloat,
        color: TouchIndicatorColor = .blue,
        hostUptimeNanoseconds: @escaping () -> UInt64
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
        self.hostUptimeNanoseconds = hostUptimeNanoseconds

        try clearPixelBuffer()
    }

    /// Applies one ordered group of updates delivered by the recording session.
    /// Timestamps preserve lifecycle ordering and anchor terminal animation;
    /// the bridge, rather than the renderer, owns update delivery order.
    package func apply(_ updates: [TouchIndicatorContactUpdate]) {
        for update in updates {
            switch update.phase {
            case .began:
                begin(update)
            case .moved:
                move(update)
            case .ended, .cancelled:
                end(update)
            }
        }
    }

    /// Ends every active contact owned by one disconnected publisher. The
    /// ordered stream connection is the publisher lifetime owner, so EOF is a
    /// normal terminal input rather than a recovery condition.
    package func cancelContacts(
        from publisherID: UUID,
        uptimeNanoseconds: UInt64
    ) {
        let contactIDs = activeSequences.keys.filter {
            $0.publisherID == publisherID
        }
        for contactID in contactIDs {
            guard let sequence = activeSequences[contactID],
                  var timeline = timelines[sequence],
                  uptimeNanoseconds >= timeline.generationStartedAtNanoseconds
            else { continue }
            activeSequences.removeValue(forKey: contactID)
            timeline.endedAtNanoseconds = uptimeNanoseconds
            timelines[sequence] = timeline
        }
    }

    /// Rebuilds the transparent overlay from the current contact timelines and
    /// returns the same buffer instance exposed by `pixelBuffer`.
    @discardableResult
    package func render() throws -> CVPixelBuffer {
        let uptimeNanoseconds = hostUptimeNanoseconds()
        let presentations = presentations(at: uptimeNanoseconds)

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
        nextContactSequence = 0
        try clearPixelBuffer()
    }

    private func begin(_ update: TouchIndicatorContactUpdate) {
        if let sequence = activeSequences[update.contactID],
           var timeline = timelines[sequence] {
            // Repeated began for an active contact is movement by the rendering
            // contract. It also starts a newer lifecycle epoch so an older
            // terminal update cannot close the current contact.
            guard update.uptimeNanoseconds >= timeline.generationStartedAtNanoseconds
            else { return }
            timeline.generationStartedAtNanoseconds = update.uptimeNanoseconds
            timeline.position = update.position
            timelines[sequence] = timeline
            return
        }

        let sequence = nextContactSequence
        nextContactSequence += 1
        activeSequences[update.contactID] = sequence
        timelines[sequence] = ContactTimeline(
            sequence: sequence,
            generationStartedAtNanoseconds: update.uptimeNanoseconds,
            position: update.position,
            endedAtNanoseconds: nil
        )
    }

    private func move(_ update: TouchIndicatorContactUpdate) {
        guard let sequence = activeSequences[update.contactID],
              var timeline = timelines[sequence],
              update.uptimeNanoseconds >= timeline.generationStartedAtNanoseconds
        else { return }
        timeline.position = update.position
        timelines[sequence] = timeline
    }

    private func end(_ update: TouchIndicatorContactUpdate) {
        guard let sequence = activeSequences[update.contactID],
              var timeline = timelines[sequence],
              update.uptimeNanoseconds >= timeline.generationStartedAtNanoseconds
        else { return }
        activeSequences.removeValue(forKey: update.contactID)
        timeline.position = update.position
        timeline.endedAtNanoseconds = update.uptimeNanoseconds
        timelines[sequence] = timeline
    }

    private func presentations(at uptimeNanoseconds: UInt64) -> [Presentation] {
        var expiredSequences: [UInt64] = []
        var presentations: [Presentation] = []
        presentations.reserveCapacity(timelines.count)

        for timeline in timelines.values {
            guard let endedAtNanoseconds = timeline.endedAtNanoseconds else {
                presentations.append(Presentation(
                    sequence: timeline.sequence,
                    position: timeline.position,
                    opacity: 1,
                    scale: 1
                ))
                continue
            }

            let elapsedNanoseconds = uptimeNanoseconds - endedAtNanoseconds
            if elapsedNanoseconds >= Style.totalTerminalNanoseconds {
                expiredSequences.append(timeline.sequence)
                continue
            }

            let fadeProgress: CGFloat
            if elapsedNanoseconds <= Style.holdNanoseconds {
                fadeProgress = 0
            } else {
                fadeProgress = CGFloat(
                    Double(elapsedNanoseconds - Style.holdNanoseconds)
                        / Double(Style.fadeNanoseconds)
                )
            }
            let easedProgress = Style.terminalTiming.value(at: fadeProgress)
            presentations.append(Presentation(
                sequence: timeline.sequence,
                position: timeline.position,
                opacity: 1 - easedProgress,
                scale: 1 - ((1 - Style.finalScale) * easedProgress)
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
}

/// Resolves a Core Animation unit cubic Bezier by inverting its x component.
/// The control points come from the SDK-provided timing function rather than
/// duplicating UIKit's curve constants in this renderer.
private struct UnitBezierTimingFunction: Sendable {
    private let firstControlPoint: (x: Double, y: Double)
    private let secondControlPoint: (x: Double, y: Double)

    init(_ timingFunction: CAMediaTimingFunction) {
        var first = [Float](repeating: 0, count: 2)
        var second = [Float](repeating: 0, count: 2)
        timingFunction.getControlPoint(at: 1, values: &first)
        timingFunction.getControlPoint(at: 2, values: &second)
        firstControlPoint = (Double(first[0]), Double(first[1]))
        secondControlPoint = (Double(second[0]), Double(second[1]))
    }

    func value(at progress: CGFloat) -> CGFloat {
        let input = Double(progress)
        var lowerBound = 0.0
        var upperBound = 1.0

        for _ in 0..<32 {
            let parameter = (lowerBound + upperBound) / 2
            if sample(firstControlPoint.x, secondControlPoint.x, at: parameter) < input {
                lowerBound = parameter
            } else {
                upperBound = parameter
            }
        }

        return CGFloat(sample(
            firstControlPoint.y,
            secondControlPoint.y,
            at: (lowerBound + upperBound) / 2
        ))
    }

    private func sample(_ first: Double, _ second: Double, at parameter: Double) -> Double {
        let inverse = 1 - parameter
        return (3 * inverse * inverse * parameter * first)
            + (3 * inverse * parameter * parameter * second)
            + (parameter * parameter * parameter)
    }
}
