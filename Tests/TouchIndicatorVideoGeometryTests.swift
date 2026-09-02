// SPDX-License-Identifier: Apache-2.0
import CoreGraphics
import Testing
@testable import iOSSimBackend

@Suite("Touch indicator video geometry")
struct TouchIndicatorVideoGeometryTests {
    @Test("Identity video scale preserves even source pixels and Retina point scale")
    func identityScale() throws {
        let geometry = try TouchIndicatorVideoGeometry(
            screenPixelWidth: 1170,
            screenPixelHeight: 2532,
            screenScale: 3,
            videoScale: 1
        )

        #expect(geometry.pixelWidth == 1170)
        #expect(geometry.pixelHeight == 2532)
        #expect(geometry.pixelsPerPoint == 3)
    }

    @Test("Scaled dimensions mirror floor then even round-up in the pinned stream")
    func scaledAndEven() throws {
        let geometry = try TouchIndicatorVideoGeometry(
            screenPixelWidth: 1179,
            screenPixelHeight: 2557,
            screenScale: 3,
            videoScale: 0.5
        )

        #expect(geometry.pixelWidth == 590)
        #expect(geometry.pixelHeight == 1278)
        #expect(geometry.pixelsPerPoint == CGFloat(590 * 3) / 1179)
    }

    @Test("Invalid screen facts fail instead of inventing an overlay canvas")
    func invalidScreen() {
        #expect(throws: TouchIndicatorVideoGeometryError.invalidScreen(
            pixelWidth: 0,
            pixelHeight: 100,
            screenScale: 2,
            videoScale: 1
        )) {
            _ = try TouchIndicatorVideoGeometry(
                screenPixelWidth: 0,
                screenPixelHeight: 100,
                screenScale: 2,
                videoScale: 1
            )
        }
    }
}
