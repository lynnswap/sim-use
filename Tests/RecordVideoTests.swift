// SPDX-License-Identifier: Apache-2.0
import Testing
import Foundation
import Darwin
import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import ImageIO
import SimUseCore
@testable import iOSSimBackend

@Suite("Record Video Command Tests", .serialized, .enabled(if: isE2EEnabled))
struct RecordVideoTests {
    // Regression for issue #35: under short-grace SIGTERM (process supervisor
    // pattern) the mp4 must still finalise with a moov atom. The stream path
    // finishes the writer (moov) before stopping the stream, so the trailer is
    // on disk before a tight SIGKILL can land.
    @Test("Record video survives short-grace SIGTERM with a valid mp4")
    func recordVideoShortGraceSIGTERM() async throws {
        let udid = try TestHelpers.requireSimulatorUDID()
        let simUsePath = try TestHelpers.getSimUsePath()

        let iterations = 5
        let graceMillis: UInt64 = 100
        let recordDurationNanos: UInt64 = 3_000_000_000
        var failures: [String] = []

        for i in 1...iterations {
            let outputURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("sim-use-sigterm-test-\(UUID().uuidString).mp4")

            let process = Process()
            process.executableURL = URL(fileURLWithPath: simUsePath)
            process.arguments = [
                "record-video",
                "--udid", udid,
                "--output", outputURL.path
            ]
            process.standardOutput = Pipe()
            process.standardError = Pipe()

            try process.run()
            try await Task.sleep(nanoseconds: recordDurationNanos)

            kill(process.processIdentifier, SIGTERM)
            try await Task.sleep(nanoseconds: graceMillis * 1_000_000)
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }

            try await TestHelpers.waitForProcessExit(
                process,
                timeout: 10.0,
                description: "record-video did not exit after SIGTERM/SIGKILL on iter \(i)"
            )

            let validity = await Self.validateMP4(at: outputURL)
            switch validity {
            case .valid:
                break
            case .missing:
                failures.append("iter \(i): output file missing")
            case .invalid(let reason):
                failures.append("iter \(i): \(reason)")
            }

            try? FileManager.default.removeItem(at: outputURL)
        }

        #expect(
            failures.isEmpty,
            "Recording must produce a valid mp4 even when SIGKILLed \(graceMillis) ms after SIGTERM. Failures (\(failures.count)/\(iterations)): \(failures.joined(separator: "; "))"
        )
    }

    private enum MP4Validity: Equatable {
        case valid
        case missing
        case invalid(String)
    }

    private static func validateMP4(at url: URL) async -> MP4Validity {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .missing
        }
        let asset = AVURLAsset(url: url)
        do {
            let tracks = try await asset.load(.tracks)
            guard !tracks.isEmpty else {
                return .invalid("mp4 has no tracks (moov atom likely missing)")
            }
            return .valid
        } catch {
            return .invalid("mp4 not loadable: \(error.localizedDescription)")
        }
    }

    @Test("Record video writes an MP4 file with default options")
    func recordVideoDefault() async throws {
        let result = try await invokeRecordVideo(duration: 3.0)
        defer { try? FileManager.default.removeItem(at: result.outputURL) }

        #expect(result.exitCode == 0)
        #expect(result.fileSize > 10_000, "Recorded file should be non-empty and usable (got: \(result.fileSize))")
        #expect(result.stderr.contains("Recording simulator"))
        #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == result.outputURL.path)
    }

    @Test("Record video honours FPS, scale, and quality settings")
    func recordVideoCustomOptions() async throws {
        let result = try await invokeRecordVideo(fps: 5, quality: 60, scale: 0.5, duration: 2.0)
        defer { try? FileManager.default.removeItem(at: result.outputURL) }

        #expect(result.exitCode == 0)
        #expect(result.fileSize > 10_000)
        #expect(result.stderr.contains("Press Ctrl+C"))
    }

    @Test("Touch indicator recording composites a daemon-routed tap at the dispatched point")
    func recordVideoWithTouchIndicators() async throws {
        let udid = try TestHelpers.requireSimulatorUDID()
        try await TestHelpers.launchPlaygroundApp(
            to: "orientation-test",
            simulatorUDID: udid
        )
        let screen = try await Self.currentScreen(udid: udid)
        let touchPoint = CGPoint(
            x: screen.width * 0.5,
            y: screen.height * 0.72
        )

        let controlURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sim-use-touch-control-\(UUID().uuidString).mp4")
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sim-use-touch-indicators-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: controlURL) }
        let control = try await invokeRecordVideo(
            duration: 1,
            outputPath: controlURL.path
        )
        #expect(control.exitCode == 0, "control stderr: \(control.stderr)")
        let controlEvidence = try await Self.touchIndicatorEvidence(
            at: control.outputURL,
            touchPoint: touchPoint,
            screen: screen
        )

        let result = try await invokeRecordVideo(
            duration: 2,
            outputPath: outputURL.path,
            touchIndicators: true,
            touchColor: "pink",
            interactionArguments: [
                "tap",
                "-x", "\(Int(touchPoint.x))",
                "-y", "\(Int(touchPoint.y))",
            ]
        )
        defer { try? FileManager.default.removeItem(at: result.outputURL) }

        #expect(result.exitCode == 0, "stderr: \(result.stderr)")
        #expect(result.fileSize > 10_000)
        #expect(await Self.validateMP4(at: result.outputURL) == .valid)

        let evidence = try await Self.touchIndicatorEvidence(
            at: result.outputURL,
            touchPoint: touchPoint,
            screen: screen
        )
        #expect(
            evidence.peakExpectedDifference > max(
                controlEvidence.peakExpectedDifference + 8,
                evidence.peakControlDifference + 8
            ),
            "expected the largest frame change at the touch point; control=\(controlEvidence), touch=\(evidence)"
        )
        #expect(
            evidence.finalExpectedDifference < evidence.peakExpectedDifference * 0.35,
            "touch ring should disappear before the final frame: \(evidence)"
        )
    }

    @Test("Record video uses provided directory without deleting its contents")
    func recordVideoOutputDirectory() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sim-use-record-output-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let sentinel = tempDir.appendingPathComponent("sentinel.txt")
        try "sentinel".write(to: sentinel, atomically: true, encoding: .utf8)

        // 3 s, not 1 s: this exercises directory handling, and the H.264
        // stream needs a beat to attach and deliver its first frame.
        let result = try await invokeRecordVideo(duration: 3.0, outputPath: tempDir.path)

        #expect(FileManager.default.fileExists(atPath: sentinel.path))
        #expect(result.exitCode == 0)
        #expect(result.fileSize > 0)
        #expect(result.outputURL.path.hasPrefix(tempDir.path))
        #expect(FileManager.default.fileExists(atPath: result.outputURL.path))

        try? FileManager.default.removeItem(at: tempDir)
    }

    @Test("Record video validates FPS input")
    func recordVideoInvalidFPS() async throws {
        let udid = try TestHelpers.requireSimulatorUDID()
        let simUsePath = try TestHelpers.getSimUsePath()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: simUsePath)
        process.arguments = [
            "record-video",
            "--udid", udid,
            "--fps", "70"
        ]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = Pipe()

        try process.run()
        process.waitUntilExit()

        let errorOutput = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        #expect(process.terminationStatus != 0)
        #expect(errorOutput.contains("FPS must be between 1 and 60"))
    }

    @Test("Explicit --fps records at that constant frame rate")
    func recordVideoEagerFrameRate() async throws {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sim-use-fps-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let result = try await invokeRecordVideo(fps: 20, duration: 4.0, outputPath: outputURL.path)
        #expect(result.exitCode == 0)

        let asset = AVURLAsset(url: result.outputURL)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try #require(tracks.first)
        // Eager H.264 streaming lays frames out at the requested rate — far
        // above the ~8-10 fps the old screenshot polling was capped at, and
        // close to the requested 20 (a few percent under is normal).
        let nominal = try await track.load(.nominalFrameRate)
        #expect(nominal >= 16 && nominal <= 24, "expected ~20 fps, got \(nominal)")
    }

    @Test("A .gif output records, transcodes, and cleans up the intermediate MP4")
    func recordVideoGIFOutput() async throws {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sim-use-record-gif-\(UUID().uuidString).gif")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        // Format is inferred from the .gif extension — the path the skill
        // documents for evidence GIFs.
        let result = try await invokeRecordVideo(duration: 3.0, outputPath: outputURL.path)

        #expect(result.exitCode == 0, "unexpected exit \(result.exitCode); stderr: \(result.stderr)")
        #expect(result.stderr.contains("Transcoding to GIF"), "stderr: \(result.stderr)")
        #expect(result.stderr.contains("GIF written"), "stderr: \(result.stderr)")
        #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == outputURL.path)

        let frameCount = try Self.animatedGIFFrameCount(at: outputURL)
        #expect(frameCount > 1, "expected an animated GIF, got \(frameCount) frame(s)")

        let intermediateMP4 = URL(fileURLWithPath: outputURL.path + ".recording.mp4")
        #expect(
            !FileManager.default.fileExists(atPath: intermediateMP4.path),
            "intermediate MP4 should be removed after a successful transcode"
        )
    }

    // MARK: - Helpers

    /// Asserts the GIF magic and returns the frame count.
    private static func animatedGIFFrameCount(at url: URL) throws -> Int {
        let data = try Data(contentsOf: url)
        let magic = String(decoding: data.prefix(6), as: UTF8.self)
        #expect(magic == "GIF89a" || magic == "GIF87a", "not a GIF file (magic: \(magic))")
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil), "GIF not readable by ImageIO")
        return CGImageSourceGetCount(source)
    }

    private struct TouchIndicatorEvidence: CustomStringConvertible {
        let frameCount: Int
        let peakExpectedDifference: Double
        let peakControlDifference: Double
        let finalExpectedDifference: Double

        var description: String {
            "frames=\(frameCount), peakExpected=\(peakExpectedDifference), peakControl=\(peakControlDifference), finalExpected=\(finalExpectedDifference)"
        }
    }

    private struct DescribeScreenEnvelope: Decodable {
        struct Payload: Decodable {
            struct Screen: Decodable {
                let width: Double
                let height: Double
            }

            let screen: Screen
        }

        let data: Payload
    }

    private static func currentScreen(udid: String) async throws -> CGSize {
        let result = try await TestHelpers.runSimUseCommand(
            "describe-ui --json --no-raw",
            simulatorUDID: udid
        )
        guard let jsonStart = result.output.firstIndex(of: "{") else {
            throw TestError.invalidJSON("describe-ui returned no JSON object")
        }
        let data = Data(result.output[jsonStart...].utf8)
        let envelope = try JSONDecoder().decode(DescribeScreenEnvelope.self, from: data)
        guard envelope.data.screen.width > 0, envelope.data.screen.height > 0 else {
            throw TestError.unexpectedState("describe-ui returned an empty screen")
        }
        return CGSize(
            width: envelope.data.screen.width,
            height: envelope.data.screen.height
        )
    }

    private static func touchIndicatorEvidence(
        at url: URL,
        touchPoint: CGPoint,
        screen: CGSize
    ) async throws -> TouchIndicatorEvidence {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else {
            throw TestError.unexpectedState("recording has no video track")
        }

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? TestError.unexpectedState("video reader did not start")
        }

        let controlPoint = CGPoint(
            x: screen.width * 0.15,
            y: touchPoint.y
        )
        var baselineExpected: [UInt8]?
        var baselineControl: [UInt8]?
        var peakExpectedDifference = 0.0
        var peakControlDifference = 0.0
        var finalExpectedDifference = 0.0
        var frameCount = 0

        while let sample = output.copyNextSampleBuffer(),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sample) {
            let expected = try pixelRegion(
                in: pixelBuffer,
                point: touchPoint,
                screen: screen
            )
            let control = try pixelRegion(
                in: pixelBuffer,
                point: controlPoint,
                screen: screen
            )
            frameCount += 1

            guard let expectedBaseline = baselineExpected,
                  let controlBaseline = baselineControl else {
                baselineExpected = expected
                baselineControl = control
                continue
            }

            let expectedDifference = meanRGBDifference(
                expected,
                from: expectedBaseline
            )
            let controlDifference = meanRGBDifference(
                control,
                from: controlBaseline
            )
            peakExpectedDifference = max(peakExpectedDifference, expectedDifference)
            peakControlDifference = max(peakControlDifference, controlDifference)
            finalExpectedDifference = expectedDifference
        }

        if reader.status == .failed {
            throw reader.error ?? TestError.unexpectedState("video reader failed")
        }
        guard frameCount >= 3, baselineExpected != nil else {
            throw TestError.unexpectedState(
                "recording produced only \(frameCount) decodable frames"
            )
        }
        return TouchIndicatorEvidence(
            frameCount: frameCount,
            peakExpectedDifference: peakExpectedDifference,
            peakControlDifference: peakControlDifference,
            finalExpectedDifference: finalExpectedDifference
        )
    }

    private static func pixelRegion(
        in pixelBuffer: CVPixelBuffer,
        point: CGPoint,
        screen: CGSize
    ) throws -> [UInt8] {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else {
            throw TestError.unexpectedState("video reader did not produce BGRA frames")
        }
        let scale = Double(CVPixelBufferGetWidth(pixelBuffer)) / screen.width
        let centerX = Int((Double(point.x) * scale).rounded())
        let centerY = Int((Double(point.y) * scale).rounded())
        let radius = max(2, Int((26 * scale).rounded(.up)))
        let minX = max(0, centerX - radius)
        let maxX = min(CVPixelBufferGetWidth(pixelBuffer) - 1, centerX + radius)
        let minY = max(0, centerY - radius)
        let maxY = min(CVPixelBufferGetHeight(pixelBuffer) - 1, centerY + radius)

        let status = CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        guard status == kCVReturnSuccess,
              let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw TestError.unexpectedState("could not read decoded video pixels")
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let base = baseAddress.assumingMemoryBound(to: UInt8.self)
        var rgb: [UInt8] = []
        rgb.reserveCapacity((maxX - minX + 1) * (maxY - minY + 1) * 3)
        for y in minY...maxY {
            let row = base.advanced(by: y * bytesPerRow)
            for x in minX...maxX {
                let pixel = row.advanced(by: x * 4)
                rgb.append(pixel[0])
                rgb.append(pixel[1])
                rgb.append(pixel[2])
            }
        }
        return rgb
    }

    private static func meanRGBDifference(
        _ pixels: [UInt8],
        from baseline: [UInt8]
    ) -> Double {
        guard pixels.count == baseline.count, !pixels.isEmpty else {
            return .infinity
        }
        let total = zip(pixels, baseline).reduce(0) { partial, pair in
            partial + abs(Int(pair.0) - Int(pair.1))
        }
        return Double(total) / Double(pixels.count)
    }

    private struct RecordingResult {
        let outputURL: URL
        let stdout: String
        let stderr: String
        let fileSize: Int
        let exitCode: Int32
    }

    private func invokeRecordVideo(
        fps: Int? = nil,
        quality: Int = 80,
        scale: Double = 1.0,
        duration: TimeInterval = 2.0,
        outputPath: String? = nil,
        touchIndicators: Bool = false,
        touchColor: String? = nil,
        interactionArguments: [String]? = nil
    ) async throws -> RecordingResult {
        let udid = try TestHelpers.requireSimulatorUDID()
        let simUsePath = try TestHelpers.getSimUsePath()

        let defaultOutputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sim-use-record-test-\(UUID().uuidString).mp4")
        let configuredOutputPath = outputPath ?? defaultOutputURL.path

        let process = Process()
        process.executableURL = URL(fileURLWithPath: simUsePath)
        var arguments = ["record-video", "--udid", udid]
        if let fps {
            arguments.append(contentsOf: ["--fps", "\(fps)"])
        }
        if touchIndicators {
            arguments.append("--touch-indicators")
        }
        if let touchColor {
            arguments.append(contentsOf: ["--touch-color", touchColor])
        }
        arguments.append(contentsOf: [
            "--quality", "\(quality)",
            "--scale", "\(scale)",
            "--output", configuredOutputPath,
        ])
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        if let interactionArguments {
            try await Self.waitForTouchIndicatorRecording(
                udid: udid,
                outputPath: configuredOutputPath
            )
            let interaction = Process()
            interaction.executableURL = URL(fileURLWithPath: simUsePath)
            interaction.arguments = interactionArguments + ["--udid", udid]
            interaction.standardOutput = Pipe()
            let interactionError = Pipe()
            interaction.standardError = interactionError
            try interaction.run()
            try await TestHelpers.waitForProcessExit(
                interaction,
                timeout: 10,
                description: "touch interaction did not finish during recording"
            )
            let errorText = String(
                data: interactionError.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            #expect(interaction.terminationStatus == 0, "interaction stderr: \(errorText)")
        }

        try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))

        process.interrupt()
        try await TestHelpers.waitForProcessExit(
            process,
            timeout: 10.0,
            description: "record-video process did not exit after interrupt"
        )

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        let resolvedOutputPath = String(data: stdoutData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let resolvedURL = resolvedOutputPath.isEmpty ? defaultOutputURL : URL(fileURLWithPath: resolvedOutputPath)

        var fileSize = 0
        if let attributes = try? FileManager.default.attributesOfItem(atPath: resolvedURL.path),
           let sizeNumber = attributes[.size] as? NSNumber {
            fileSize = sizeNumber.intValue
        }

        if outputPath == nil {
            try? FileManager.default.removeItem(at: resolvedURL)
        }

        return RecordingResult(
            outputURL: resolvedURL,
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? "",
            fileSize: fileSize,
            exitCode: process.terminationStatus
        )
    }

    private static func waitForTouchIndicatorRecording(
        udid: String,
        outputPath: String
    ) async throws {
        let socketURL = RecordedTouchStreamPaths(udid: udid).socketURL
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while true {
            let endpointExists = FileManager.default.fileExists(atPath: socketURL.path)
            let attributes = try? FileManager.default.attributesOfItem(atPath: outputPath)
            let outputSize = (attributes?[.size] as? NSNumber)?.intValue ?? 0
            if endpointExists, outputSize > 0 { return }
            guard ContinuousClock.now < deadline else {
                throw TouchIndicatorEndpointTimeout(
                    path: socketURL.path,
                    outputPath: outputPath
                )
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private struct TouchIndicatorEndpointTimeout: Error, LocalizedError {
        let path: String
        let outputPath: String

        var errorDescription: String? {
            "Touch indicator recording did not become ready: endpoint=\(path), output=\(outputPath)"
        }
    }
}
