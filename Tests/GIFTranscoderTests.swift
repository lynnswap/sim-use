// SPDX-License-Identifier: Apache-2.0
import Testing
import Foundation
import AVFoundation
import CoreMedia
import ImageIO
import UniformTypeIdentifiers
@testable import SimUseVideo

// .serialized: the round-trip tests each drive a real VideoToolbox
// H.264 encode session (makeSyntheticMP4). Two such sessions ran
// concurrently for weeks of green CI; the third one added with the
// marker feature deadlocked the encoder on GitHub's virtualized
// macOS runners in 4 of 4 runs (#100/#101), wedging the entire
// swift-test process until the job timeout. One session at a time
// costs well under a second locally.
@Suite("GIFTranscoder", .serialized)
struct GIFTranscoderTests {
    // MARK: - Sampling plan (pure logic)

    @Test("Constant-rate input at the target fps keeps every frame")
    func planKeepsAllFramesAtTargetRate() {
        let times = (0..<20).map { Double($0) * 0.1 } // 10 fps source
        let plan = GIFTranscoder.plan(presentationTimes: times, fps: 10)
        #expect(plan.timestamps == times)
        #expect(plan.delays.count == times.count)
        #expect(plan.delays.dropLast().allSatisfy { abs($0 - 0.1) < 0.0001 })
        #expect(abs(plan.delays.last! - 0.1) < 0.0001) // last frame holds one interval
    }

    @Test("High-rate input is downsampled to the target fps")
    func planDownsamplesHighRateInput() {
        let times = (0..<60).map { Double($0) / 30.0 } // 2 s of 30 fps
        let plan = GIFTranscoder.plan(presentationTimes: times, fps: 10)
        // ~10 fps over 2 s → about 20 frames, never the full 60.
        #expect(plan.timestamps.count >= 15 && plan.timestamps.count <= 25)
        for (index, pts) in plan.timestamps.enumerated().dropFirst() {
            #expect(pts - plan.timestamps[index - 1] >= 0.1 - 0.05)
        }
    }

    @Test("Variable-frame-rate input derives delays from actual gaps")
    func planHandlesVariableFrameRate() {
        let times = [0.0, 0.1, 0.5, 0.6, 2.0] // Android screenrecord-style VFR
        let plan = GIFTranscoder.plan(presentationTimes: times, fps: 10)
        #expect(plan.timestamps == times)
        #expect(abs(plan.delays[1] - 0.4) < 0.0001) // gap 0.1 → 0.5
        #expect(abs(plan.delays[3] - 1.4) < 0.0001) // gap 0.6 → 2.0
    }

    @Test("Unsorted timestamps are ordered before sampling")
    func planSortsTimestamps() {
        let plan = GIFTranscoder.plan(presentationTimes: [0.2, 0.0, 0.1], fps: 10)
        #expect(plan.timestamps == [0.0, 0.1, 0.2])
    }

    @Test("Delays are clamped to the 2-centisecond GIF floor")
    func planClampsTinyDelays() {
        let times = (0..<10).map { Double($0) / 60.0 }
        let plan = GIFTranscoder.plan(presentationTimes: times, fps: 60)
        #expect(plan.delays.allSatisfy { $0 >= GIFTranscoder.minimumDelay })
    }

    @Test("Sampling caps at 50 fps so clamped delays cannot stretch playback")
    func planCapsSamplingRate() {
        let times = (0..<120).map { Double($0) / 120.0 } // 1 s of 120 fps
        let capped = GIFTranscoder.plan(presentationTimes: times, fps: 60)
        #expect(capped == GIFTranscoder.plan(presentationTimes: times, fps: GIFTranscoder.maximumFPS))
        // Total GIF duration stays close to the 1 s of source footage.
        let duration = capped.delays.reduce(0, +)
        #expect(abs(duration - 1.0) <= 0.02)
    }

    @Test("High-rate sources keep wall-clock duration to centisecond tolerance", arguments: [60, 120])
    func planPreservesWallClockAtHighSourceRates(sourceFPS: Int) {
        // 10 s of source footage — long enough for per-frame rounding to
        // accumulate visibly if selection or quantization loses debt
        // (independent 2 cs clamping used to stretch this to ~10.65 s
        // for a 60 fps source and ~10.8 s for 120 fps).
        let times = (0..<(10 * sourceFPS)).map { Double($0) / Double(sourceFPS) }
        let plan = GIFTranscoder.plan(presentationTimes: times, fps: 60)

        #expect(plan.delays.allSatisfy { $0 >= GIFTranscoder.minimumDelay })
        let duration = plan.delays.reduce(0, +)
        #expect(abs(duration - 10.0) <= 0.02)
    }

    @Test("Empty input yields an empty plan")
    func planEmptyInput() {
        let plan = GIFTranscoder.plan(presentationTimes: [], fps: 10)
        #expect(plan.timestamps.isEmpty)
        #expect(plan.delays.isEmpty)
    }

    // MARK: - Format resolution

    @Test("Format is inferred from the --output extension")
    func formatInference() {
        #expect(RecordingFormat.infer(fromOutput: "demo.gif") == .gif)
        #expect(RecordingFormat.infer(fromOutput: "/tmp/x/demo.GIF") == .gif)
        #expect(RecordingFormat.infer(fromOutput: "demo.mp4") == .mp4)
        #expect(RecordingFormat.infer(fromOutput: "demo.mov") == nil)
        #expect(RecordingFormat.infer(fromOutput: "demo") == nil)
        #expect(RecordingFormat.infer(fromOutput: nil) == nil)
    }

    @Test("GIF gets lower fps/scale defaults; explicit flags win")
    func resolvedOptionsDefaults() {
        typealias Options = ResolvedRecordingOptions

        let mp4 = Options(format: nil, output: nil, fps: nil, scale: nil, gifMarkers: false, touchIndicators: .disabled)
        #expect(mp4.format == .mp4)
        #expect(mp4.fps == nil) // capture-path default (30 native / 10 fallback)
        #expect(mp4.scale == 1.0)

        let gif = Options(format: .gif, output: nil, fps: nil, scale: nil, gifMarkers: false, touchIndicators: .disabled)
        #expect(gif.format == .gif)
        #expect(gif.fps == 10)
        #expect(gif.gifSampleFPS == 10)
        #expect(gif.scale == 0.5)

        let inferred = Options(format: nil, output: "demo.gif", fps: nil, scale: nil, gifMarkers: false, touchIndicators: .disabled)
        #expect(inferred.format == .gif)

        let explicit = Options(format: .mp4, output: "demo.gif", fps: 24, scale: 0.8, gifMarkers: false, touchIndicators: .disabled)
        #expect(explicit.format == .mp4) // explicit --format beats the extension
        #expect(explicit.fps == 24)
        #expect(explicit.gifSampleFPS == 24)
        #expect(explicit.scale == 0.8)
    }

    @Test("RecordingOutputPlan clears a stale GIF intermediate from a previous failed run")
    func outputPlanClearsStaleIntermediate() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("gif-plan-test-\(UUID().uuidString).gif")
        defer {
            try? FileManager.default.removeItem(at: base)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: base.path + ".recording.mp4"))
        }
        let stale = URL(fileURLWithPath: base.path + ".recording.mp4")
        try Data([0x00]).write(to: stale)

        let plan = try RecordingOutputPlan(format: nil, output: base.path, fps: nil, scale: nil, gifMarkers: false, touchIndicators: false, touchColor: nil)
        #expect(plan.options.format == .gif)
        #expect(plan.recordTarget == stale)
        #expect(!FileManager.default.fileExists(atPath: stale.path))
    }

    @Test("RecordingOutputPlan records mp4 straight to the output path")
    func outputPlanMP4Passthrough() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("gif-plan-test-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: base) }
        let plan = try RecordingOutputPlan(format: nil, output: base.path, fps: nil, scale: nil, gifMarkers: false, touchIndicators: false, touchColor: nil)
        #expect(plan.recordTarget == plan.outputURL)
    }

    @Test("Default output filename uses the resolved format's extension")
    func prepareOutputURLExtension() throws {
        let gifURL = try VideoOutputFile.prepareOutputURL(output: nil, fileExtension: "gif")
        #expect(gifURL.pathExtension == "gif")
        let mp4URL = try VideoOutputFile.prepareOutputURL(output: nil)
        #expect(mp4URL.pathExtension == "mp4")
    }

    // MARK: - Real transcode round-trip

    /// Write `frameCount` solid-color frames through the H.264 recorder
    /// so the transcoder has a real MP4 to chew on — no simulator needed.
    private func makeSyntheticMP4(frameCount: Int, fps: Int, width: Int = 64, height: Int = 64) async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gif-transcoder-test-\(UUID().uuidString).mp4")
        let recorder = try H264StreamRecorder(outputURL: url, width: width, height: height, fps: fps, quality: 80)

        for frame in 0..<frameCount {
            let image = try #require(Self.makeFrame(width: width, height: height, hue: Double(frame) / Double(frameCount)))
            let pts = CMTime(seconds: Double(frame) / Double(fps), preferredTimescale: 600)
            try recorder.append(image: image, presentationTime: pts)
        }
        try await recorder.finish()
        return url
    }

    private static func makeFrame(width: Int, height: Int, hue: Double) -> CGImage? {
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )
        guard let context else { return nil }
        context.setFillColor(CGColor(red: hue, green: 1.0 - hue, blue: 0.5, alpha: 1.0))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // A moving square so the encoder emits more than one distinct frame.
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1.0))
        context.fill(CGRect(x: Int(hue * Double(width - 8)), y: 8, width: 8, height: 8))
        return context.makeImage()
    }

    @Test("MP4 round-trip produces a looping GIF with the sampled frame count")
    func transcodeRoundTrip() async throws {
        let mp4URL = try await makeSyntheticMP4(frameCount: 20, fps: 10)
        defer { try? FileManager.default.removeItem(at: mp4URL) }
        let gifURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("gif-transcoder-test-\(UUID().uuidString).gif")
        defer { try? FileManager.default.removeItem(at: gifURL) }

        let written = try await GIFTranscoder.transcode(mp4URL: mp4URL, to: gifURL, fps: 10, markers: false)

        let source = try #require(CGImageSourceCreateWithURL(gifURL as CFURL, nil))
        let type = try #require(CGImageSourceGetType(source) as String?)
        #expect(UTType(type)?.conforms(to: .gif) == true)

        let frameCount = CGImageSourceGetCount(source)
        #expect(frameCount == written)
        // Encoder may drop nothing here: 10 fps source sampled at 10 fps.
        #expect(frameCount >= 18 && frameCount <= 20)

        let containerProps = try #require(CGImageSourceCopyProperties(source, nil) as? [CFString: Any])
        let gifDict = try #require(containerProps[kCGImagePropertyGIFDictionary] as? [CFString: Any])
        #expect(gifDict[kCGImagePropertyGIFLoopCount] as? Int == 0)

        let frameProps = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let frameGIF = try #require(frameProps[kCGImagePropertyGIFDictionary] as? [CFString: Any])
        let delay = try #require(frameGIF[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
        #expect(abs(delay - 0.1) < 0.02)

        let width = try #require(frameProps[kCGImagePropertyPixelWidth] as? Int)
        #expect(width == 64)
    }

    @Test("30 fps MP4 sampled at 10 fps drops about two thirds of the frames")
    func transcodeDownsamples() async throws {
        let mp4URL = try await makeSyntheticMP4(frameCount: 30, fps: 30)
        defer { try? FileManager.default.removeItem(at: mp4URL) }
        let gifURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("gif-transcoder-test-\(UUID().uuidString).gif")
        defer { try? FileManager.default.removeItem(at: gifURL) }

        let written = try await GIFTranscoder.transcode(mp4URL: mp4URL, to: gifURL, fps: 10, markers: false)
        #expect(written >= 8 && written <= 12)
        #expect(CGImageSourceGetCount(try #require(CGImageSourceCreateWithURL(gifURL as CFURL, nil))) == written)
    }

    @Test("Opt-in markers bracket the GIF with START/END cards")
    func transcodeAddsMarkerCards() async throws {
        let mp4URL = try await makeSyntheticMP4(frameCount: 10, fps: 10)
        defer { try? FileManager.default.removeItem(at: mp4URL) }
        let gifURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("gif-transcoder-test-\(UUID().uuidString).gif")
        defer { try? FileManager.default.removeItem(at: gifURL) }

        let written = try await GIFTranscoder.transcode(mp4URL: mp4URL, to: gifURL, fps: 10, markers: true)

        let source = try #require(CGImageSourceCreateWithURL(gifURL as CFURL, nil))
        let frameCount = CGImageSourceGetCount(source)
        #expect(frameCount == written)
        // 10 sampled content frames (±2 encoder variance) + 2 marker cards.
        #expect(frameCount >= 10 && frameCount <= 12)

        // Marker cards hold for the marker delay; content frames pace at 0.1 s.
        for index in [0, frameCount - 1] {
            let props = try #require(CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any])
            let gif = try #require(props[kCGImagePropertyGIFDictionary] as? [CFString: Any])
            let delay = try #require(gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
            #expect(abs(delay - GIFTranscoder.markerDelay) < 0.02)
        }

        // The cards match the content frame size.
        let first = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(first.width == 64 && first.height == 64)
    }

    @Test("Marker card renders a light label on a dark background")
    func markerCardRendering() throws {
        let card = try #require(GIFTranscoder.makeMarkerCard(width: 120, height: 60, label: "START"))
        #expect(card.width == 120 && card.height == 60)

        var pixels = [UInt8](repeating: 0, count: 120 * 60 * 4)
        let context = try #require(CGContext(
            data: &pixels,
            width: 120,
            height: 60,
            bitsPerComponent: 8,
            bytesPerRow: 120 * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(card, in: CGRect(x: 0, y: 0, width: 120, height: 60))

        // Corner pixel is background (dark); the card must also contain
        // bright text pixels somewhere.
        #expect(pixels[0] < 60 && pixels[1] < 60 && pixels[2] < 60)
        let hasBrightPixel = stride(from: 0, to: pixels.count, by: 4).contains { pixels[$0] > 200 }
        #expect(hasBrightPixel)
    }

    @Test("A file with no video track throws noVideoTrack")
    func transcodeRejectsNonVideo() async throws {
        let bogusURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("gif-transcoder-test-\(UUID().uuidString).mp4")
        try Data([0x00, 0x01, 0x02, 0x03]).write(to: bogusURL)
        defer { try? FileManager.default.removeItem(at: bogusURL) }
        let gifURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("gif-transcoder-test-\(UUID().uuidString).gif")

        await #expect(throws: (any Error).self) {
            try await GIFTranscoder.transcode(mp4URL: bogusURL, to: gifURL, fps: 10, markers: false)
        }
    }

    @Test("A failed transcode preserves the intermediate MP4 and removes the partial GIF")
    func transcodeRecordingFailureCleansGIF() async throws {
        let bogusURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("gif-transcoder-test-\(UUID().uuidString).mp4")
        try Data([0x00, 0x01, 0x02, 0x03]).write(to: bogusURL)
        defer { try? FileManager.default.removeItem(at: bogusURL) }
        let gifURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("gif-transcoder-test-\(UUID().uuidString).gif")
        try Data([0x47, 0x49, 0x46]).write(to: gifURL) // partial/garbage GIF on disk

        await #expect(throws: (any Error).self) {
            try await GIFTranscoder.transcodeRecording(tempMP4: bogusURL, to: gifURL, fps: 10, markers: false)
        }
        #expect(FileManager.default.fileExists(atPath: bogusURL.path)) // footage preserved
        #expect(!FileManager.default.fileExists(atPath: gifURL.path)) // garbage removed
    }
}
