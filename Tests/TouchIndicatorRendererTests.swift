// SPDX-License-Identifier: Apache-2.0
import CoreVideo
import Foundation
import Testing
@testable import iOSSimBackend
@testable import SimUseVideo

@Suite("Touch indicator renderer", .serialized)
struct TouchIndicatorRendererTests {
    private final class FakeClock {
        private(set) var currentNanoseconds: UInt64 = 0

        func now() -> UInt64 {
            currentNanoseconds
        }

        func advance(milliseconds: UInt64) {
            currentNanoseconds += milliseconds * 1_000_000
        }
    }

    private struct Pixel: Equatable {
        let blue: UInt8
        let green: UInt8
        let red: UInt8
        let alpha: UInt8
    }

    private struct PixelSnapshot {
        let data: Data
        let width: Int
        let height: Int
        let bytesPerRow: Int

        func pixel(x: Int, y: Int) -> Pixel {
            precondition((0..<width).contains(x) && (0..<height).contains(y))
            let offset = (y * bytesPerRow) + (x * 4)
            return Pixel(
                blue: data[offset],
                green: data[offset + 1],
                red: data[offset + 2],
                alpha: data[offset + 3]
            )
        }

        func nonTransparentXs(atY y: Int) -> [Int] {
            (0..<width).filter { pixel(x: $0, y: y).alpha > 0 }
        }

        var hasVisiblePixel: Bool {
            (0..<height).contains { y in
                (0..<width).contains { x in pixel(x: x, y: y).alpha > 0 }
            }
        }
    }

    private func makeRenderer(
        width: Int = 128,
        height: Int = 128,
        pixelsPerPoint: CGFloat = 1,
        color: TouchIndicatorColor = .blue,
        clock: FakeClock
    ) throws -> TouchIndicatorRenderer {
        try TouchIndicatorRenderer(
            pixelWidth: width,
            pixelHeight: height,
            pixelsPerPoint: pixelsPerPoint,
            color: color,
            hostUptimeNanoseconds: clock.now
        )
    }

    private func snapshot(_ pixelBuffer: CVPixelBuffer) throws -> PixelSnapshot {
        let status = CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        try #require(status == kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let baseAddress = try #require(CVPixelBufferGetBaseAddress(pixelBuffer))
        return PixelSnapshot(
            data: Data(bytes: baseAddress, count: CVPixelBufferGetDataSize(pixelBuffer)),
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer),
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer)
        )
    }

    private func update(
        _ phase: TouchIndicatorPhase,
        id: UInt32 = 0,
        x: CGFloat,
        y: CGFloat,
        at uptimeNanoseconds: UInt64 = 0
    ) -> TouchIndicatorContactUpdate {
        TouchIndicatorContactUpdate(
            contactID: id,
            phase: phase,
            position: CGPoint(x: x, y: y),
            uptimeNanoseconds: uptimeNanoseconds
        )
    }

    @Test("Semantic palette exposes only the approved CLI names and resolves every color in sRGB")
    func semanticPalette() throws {
        #expect(TouchIndicatorColor.allCases.map(\.rawValue) == [
            "blue", "red", "orange", "yellow", "green", "mint", "teal",
            "cyan", "indigo", "purple", "pink", "brown", "gray",
        ])

        for color in TouchIndicatorColor.allCases {
            let resolved = try color.resolveSRGB()
            #expect(resolved.red.isFinite)
            #expect(resolved.green.isFinite)
            #expect(resolved.blue.isFinite)
            #expect((0...1).contains(resolved.red))
            #expect((0...1).contains(resolved.green))
            #expect((0...1).contains(resolved.blue))
        }
    }

    @Test("Renderer rejects an invalid canvas instead of inventing geometry")
    func invalidCanvas() {
        #expect(throws: TouchIndicatorRendererError.invalidCanvas(
            pixelWidth: 0,
            pixelHeight: 128,
            pixelsPerPoint: 1
        )) {
            _ = try TouchIndicatorRenderer(
                pixelWidth: 0,
                pixelHeight: 128,
                pixelsPerPoint: 1
            )
        }
    }

    @Test("Active indicator is a 44-point circle with a true 3-point stroke and 50-percent fill")
    func visualStyleAtOnePixelPerPoint() throws {
        let clock = FakeClock()
        let renderer = try makeRenderer(clock: clock)
        let originalBuffer = renderer.pixelBuffer

        renderer.apply([update(.began, x: 64, y: 64)])
        let renderedBuffer = try renderer.render()

        #expect(originalBuffer === renderedBuffer)
        #expect(CVPixelBufferGetPixelFormatType(renderedBuffer) == kCVPixelFormatType_32BGRA)

        let pixels = try snapshot(renderedBuffer)
        let horizontalDiameter = pixels.nonTransparentXs(atY: 64)
        #expect(horizontalDiameter.count == 44)
        #expect(horizontalDiameter.first == 42)
        #expect(horizontalDiameter.last == 85)

        let center = pixels.pixel(x: 64, y: 64)
        #expect((127...128).contains(center.alpha))

        let resolvedBlue = try TouchIndicatorColor.blue.resolveSRGB()
        #expect(abs(Int(center.blue) - Int((resolvedBlue.blue * 0.5 * 255).rounded())) <= 1)
        #expect(abs(Int(center.green) - Int((resolvedBlue.green * 0.5 * 255).rounded())) <= 1)
        #expect(abs(Int(center.red) - Int((resolvedBlue.red * 0.5 * 255).rounded())) <= 1)

        let leftEdgeAlphas = (42...46).map { pixels.pixel(x: $0, y: 64).alpha }
        #expect(leftEdgeAlphas[0] > 240)
        #expect(leftEdgeAlphas[1] > 240)
        #expect(leftEdgeAlphas[2] > 240)
        #expect((127...128).contains(leftEdgeAlphas[4]))
        #expect(pixels.pixel(x: 41, y: 64).alpha == 0)
    }

    @Test("Point geometry scales to pixels without changing the 44-point diameter or 3-point stroke")
    func visualStyleAtTwoPixelsPerPoint() throws {
        let clock = FakeClock()
        let renderer = try makeRenderer(
            width: 256,
            height: 256,
            pixelsPerPoint: 2,
            clock: clock
        )
        renderer.apply([update(.began, x: 64, y: 64)])

        let pixels = try snapshot(renderer.render())
        let horizontalDiameter = pixels.nonTransparentXs(atY: 128)
        #expect(horizontalDiameter.count == 88)
        #expect(horizontalDiameter.first == 84)
        #expect(horizontalDiameter.last == 171)

        let leftEdgeAlphas = (84...92).map { pixels.pixel(x: $0, y: 128).alpha }
        #expect(leftEdgeAlphas.prefix(6).allSatisfy { $0 > 240 })
        #expect((127...128).contains(leftEdgeAlphas[8]))
    }

    @Test("Movement changes one contact position without disturbing another contact")
    func independentMovement() throws {
        let clock = FakeClock()
        let renderer = try makeRenderer(width: 160, clock: clock)
        renderer.apply([
            update(.began, id: 1, x: 40, y: 64),
            update(.began, id: 2, x: 120, y: 64),
        ])
        renderer.apply([update(.moved, id: 1, x: 70, y: 64)])

        let pixels = try snapshot(renderer.render())
        #expect(pixels.pixel(x: 40, y: 64).alpha == 0)
        #expect(pixels.pixel(x: 70, y: 64).alpha > 0)
        #expect(pixels.pixel(x: 120, y: 64).alpha > 0)
    }

    @Test("Terminal indicator uses Core Animation ease-in-out at quarter points")
    func terminalTimeline() throws {
        let clock = FakeClock()
        let renderer = try makeRenderer(clock: clock)
        #expect(!renderer.needsAnimationFrame)
        renderer.apply([update(.began, x: 64, y: 64)])
        #expect(!renderer.needsAnimationFrame)
        _ = try renderer.render()
        #expect(!renderer.needsAnimationFrame)
        renderer.apply([update(.ended, x: 64, y: 64)])
        #expect(renderer.needsAnimationFrame)

        clock.advance(milliseconds: 200)
        var pixels = try snapshot(renderer.render())
        #expect(pixels.nonTransparentXs(atY: 64).count == 44)
        #expect((127...128).contains(pixels.pixel(x: 64, y: 64).alpha))

        clock.advance(milliseconds: 50)
        pixels = try snapshot(renderer.render())
        #expect((110...112).contains(pixels.pixel(x: 64, y: 64).alpha))

        clock.advance(milliseconds: 50)
        pixels = try snapshot(renderer.render())
        #expect((41...42).contains(pixels.nonTransparentXs(atY: 64).count))
        #expect((63...64).contains(pixels.pixel(x: 64, y: 64).alpha))

        clock.advance(milliseconds: 50)
        pixels = try snapshot(renderer.render())
        #expect((15...18).contains(pixels.pixel(x: 64, y: 64).alpha))

        clock.advance(milliseconds: 50)
        pixels = try snapshot(renderer.render())
        #expect(!pixels.hasVisiblePixel)
        #expect(!renderer.needsAnimationFrame)
    }

    @Test("Cancelled contacts use the same hold, fade, and removal timeline as ended contacts")
    func cancelledTimeline() throws {
        let clock = FakeClock()
        let renderer = try makeRenderer(clock: clock)
        renderer.apply([update(.began, x: 64, y: 64)])
        renderer.apply([update(.cancelled, x: 64, y: 64)])

        clock.advance(milliseconds: 399)
        _ = try renderer.render()
        #expect(renderer.needsAnimationFrame)

        clock.advance(milliseconds: 1)
        #expect(try !snapshot(renderer.render()).hasVisiblePixel)
        #expect(!renderer.needsAnimationFrame)
    }

    @Test("A terminal update received more than 400 ms late clears without replaying stale animation")
    func lateTerminalUpdateCatchesUp() throws {
        let clock = FakeClock()
        let renderer = try makeRenderer(clock: clock)
        renderer.apply([update(.began, x: 64, y: 64, at: 0)])
        #expect(try snapshot(renderer.render()).hasVisiblePixel)

        clock.advance(milliseconds: 500)
        renderer.apply([update(.ended, x: 64, y: 64, at: 100_000_000)])

        #expect(try !snapshot(renderer.render()).hasVisiblePixel)
        #expect(!renderer.needsAnimationFrame)
    }

    @Test("Equal host-uptime timestamps preserve delivery order across apply calls")
    func equalTimestampInsertionOrder() throws {
        let clock = FakeClock()
        let renderer = try makeRenderer(width: 160, clock: clock)
        renderer.apply([update(.began, x: 30, y: 64, at: 100_000_000)])
        renderer.apply([update(.moved, x: 65, y: 64, at: 100_000_000)])
        renderer.apply([update(.ended, x: 120, y: 64, at: 100_000_000)])

        clock.advance(milliseconds: 100)
        let pixels = try snapshot(renderer.render())
        #expect(pixels.pixel(x: 30, y: 64).alpha == 0)
        #expect(pixels.pixel(x: 65, y: 64).alpha == 0)
        #expect(pixels.pixel(x: 120, y: 64).alpha > 0)
        #expect(renderer.needsAnimationFrame)
    }

    @Test("Reused contact ID starts a new active generation without clearing the previous fade")
    func reusedContactIDKeepsIndependentFade() throws {
        let clock = FakeClock()
        let renderer = try makeRenderer(width: 160, clock: clock)
        renderer.apply([update(.began, id: 0, x: 40, y: 64)])
        renderer.apply([update(.ended, id: 0, x: 40, y: 64)])

        clock.advance(milliseconds: 100)
        renderer.apply([update(.began, id: 0, x: 120, y: 64)])
        var pixels = try snapshot(renderer.render())
        #expect(pixels.pixel(x: 40, y: 64).alpha > 0)
        #expect(pixels.pixel(x: 120, y: 64).alpha > 0)

        clock.advance(milliseconds: 300)
        pixels = try snapshot(renderer.render())
        #expect(pixels.pixel(x: 40, y: 64).alpha == 0)
        #expect(pixels.pixel(x: 120, y: 64).alpha > 0)
    }

    @Test("Repeated began for an active ID moves the existing contact without leaving a trail")
    func repeatedActiveBeginMovesExistingContact() throws {
        let clock = FakeClock()
        let renderer = try makeRenderer(width: 180, clock: clock)
        renderer.apply([update(.began, id: 0, x: 30, y: 64, at: 0)])
        #expect(try snapshot(renderer.render()).pixel(x: 30, y: 64).alpha > 0)

        clock.advance(milliseconds: 100)
        renderer.apply([
            update(.began, id: 0, x: 145, y: 64, at: 100_000_000),
        ])
        let pixels = try snapshot(renderer.render())

        #expect(pixels.pixel(x: 30, y: 64).alpha == 0)
        #expect(pixels.pixel(x: 145, y: 64).alpha > 0)
        #expect(!renderer.needsAnimationFrame)
    }

    @Test("A delayed terminal update cannot close a newer lifecycle for a reused contact ID")
    func delayedTerminalDoesNotCloseNewerLifecycle() throws {
        let clock = FakeClock()
        let renderer = try makeRenderer(width: 180, clock: clock)
        renderer.apply([
            update(.began, id: 0, x: 30, y: 64, at: 10),
            update(.began, id: 1, x: 90, y: 64, at: 10),
        ])
        _ = try renderer.render()

        clock.advance(milliseconds: 1)
        renderer.apply([update(.began, id: 0, x: 145, y: 64, at: 150)])
        _ = try renderer.render()
        renderer.apply([update(.ended, id: 0, x: 30, y: 64, at: 100)])

        let pixels = try snapshot(renderer.render())
        #expect(pixels.pixel(x: 30, y: 64).alpha == 0)
        #expect(pixels.pixel(x: 90, y: 64).alpha > 0)
        #expect(pixels.pixel(x: 145, y: 64).alpha > 0)
        #expect(!renderer.needsAnimationFrame)
    }

    @Test("Unknown moved and terminal updates do not invent a visible contact")
    func unknownUpdatesAreNoOp() throws {
        let clock = FakeClock()
        let renderer = try makeRenderer(clock: clock)
        renderer.apply([
            update(.moved, id: 99, x: 64, y: 64),
            update(.ended, id: 99, x: 64, y: 64),
        ])

        #expect(try !snapshot(renderer.render()).hasVisiblePixel)
    }

    @Test("Clear removes every timeline, zeros the pixels, and preserves buffer identity")
    func clearAndReuse() throws {
        let clock = FakeClock()
        let renderer = try makeRenderer(width: 160, clock: clock)
        let buffer = renderer.pixelBuffer
        renderer.apply([
            update(.began, id: 1, x: 40, y: 64),
            update(.began, id: 2, x: 120, y: 64),
            update(.moved, id: 1, x: 80, y: 64),
        ])
        #expect(try snapshot(renderer.render()).hasVisiblePixel)

        try renderer.clear()
        #expect(renderer.pixelBuffer === buffer)
        #expect(!renderer.needsAnimationFrame)
        #expect(try !snapshot(renderer.pixelBuffer).hasVisiblePixel)
        clock.advance(milliseconds: 1_000)
        #expect(try renderer.render() === buffer)
        #expect(try !snapshot(renderer.pixelBuffer).hasVisiblePixel)
    }
}
