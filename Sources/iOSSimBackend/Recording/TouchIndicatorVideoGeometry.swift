// SPDX-License-Identifier: Apache-2.0
import CoreGraphics
import Foundation

/// Canvas dimensions matching the pinned FBSimulator video compositor.
///
/// The stream scales source pixels with `floor`, then rounds each H.264/NV12
/// dimension up to an even value. Touch coordinates remain logical HID points,
/// so the renderer scale is the simulator's pixels-per-point multiplied by the
/// requested video scale.
///
/// Do not swap these dimensions or rotate touch points for interface
/// orientation. The pinned stream applies no rotation, and a live Xcode 27
/// landscape probe confirmed that its mounted IOSurface and HID remain in
/// fixed native-portrait axes while UI content rotates inside the raw buffer.
/// Revalidate this if the pinned framebuffer contract changes.
struct TouchIndicatorVideoGeometry: Equatable, Sendable {
    let pixelWidth: Int
    let pixelHeight: Int
    let pixelsPerPoint: CGFloat

    init(
        screenPixelWidth: Int,
        screenPixelHeight: Int,
        screenScale: CGFloat,
        videoScale: Double
    ) throws {
        guard screenPixelWidth > 0,
              screenPixelHeight > 0,
              screenScale.isFinite,
              screenScale > 0,
              videoScale.isFinite,
              videoScale > 0,
              videoScale <= 1
        else {
            throw TouchIndicatorVideoGeometryError.invalidScreen(
                pixelWidth: screenPixelWidth,
                pixelHeight: screenPixelHeight,
                screenScale: screenScale,
                videoScale: videoScale
            )
        }

        pixelWidth = Self.evenDimension(screenPixelWidth, scale: videoScale)
        pixelHeight = Self.evenDimension(screenPixelHeight, scale: videoScale)
        pixelsPerPoint = screenScale * CGFloat(videoScale)
    }

    private static func evenDimension(_ source: Int, scale: Double) -> Int {
        let scaled = scale < 1 ? Int(floor(Double(source) * scale)) : source
        return scaled + (scaled % 2)
    }
}

enum TouchIndicatorVideoGeometryError: Error, LocalizedError, Equatable {
    case invalidScreen(
        pixelWidth: Int,
        pixelHeight: Int,
        screenScale: CGFloat,
        videoScale: Double
    )

    var errorDescription: String? {
        switch self {
        case let .invalidScreen(width, height, screenScale, videoScale):
            "Cannot create a touch-indicator canvas from a \(width)x\(height) screen at scale \(screenScale) and video scale \(videoScale)."
        }
    }
}
