// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation
import CompanionUtilities
import FBSimulatorControl
@preconcurrency import FBControlCore
import AVFoundation
import SimUseCore
import SimUseVideo

/// iOS Simulator backend for the `record-video` verb. Recording uses idb's
/// native in-process file recorder (`FBSimulator.startRecording(toFile:
/// configuration:)`), which drives `FBSimulatorVideoStream` in eager
/// (fixed-rate) H.264 mode and muxes straight into an `.mp4` via its own
/// `AVAssetWriter`-backed file writer — the same passthrough-muxing
/// architecture this command used to hand-roll, now upstream's own
/// maintained implementation. `--fps` maps directly to the stream's eager
/// cadence, so the requested rate is honored and playback is smooth.
public struct IOSSimRecordVideoCommand: SimUseExecutableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "record-video",
        abstract: "Record the iOS Simulator display to an MP4 (H.264) or animated GIF file"
    )

    public struct ExecutionResult: Codable {
        public let path: String
        public init(path: String) {
            self.path = path
        }
    }

    /// Raised only when idb's native recorder cannot be set up (private
    /// CoreSimulator API unavailable, recording fails to start). Triggers the
    /// screenshot-capture fallback; mid-recording failures propagate as-is.
    private struct RecordingUnavailableError: Error {
        let underlying: String
    }

    @OptionGroup public var device: DeviceOptions

    @Option(help: "Frames per second (1-60; default: 30 for mp4, 10 for gif).")
    public var fps: Int?

    @Option(help: "Quality factor (1-100) controlling bitrate (default: 80)")
    public var quality: Int = 80

    @Option(help: "Scale factor (0.1-1.0; default: 1.0 for mp4, 0.5 for gif)")
    public var scale: Double?

    @Option(help: "Output format: mp4, gif. Defaults to the --output extension when recognized, else mp4.")
    public var format: RecordingFormat?

    @Flag(help: "Bracket a GIF with START/END marker frames (opt-in; ignored for mp4).")
    public var gifMarkers: Bool = false

    @Option(help: "Output file path. Defaults to sim-use-video-<timestamp>.<format> in the current directory.")
    public var output: String?

    @OptionGroup public var json: JSONOutputOptions

    public var jsonOutput: Bool { json.enabled }

    public init() {}

    public mutating func resolveDeferredArguments() throws {
        try device.resolve()
    }

    public var simulatorUDIDForDaemon: String? { device.resolved }

    public var daemonBypass: Bool { true }

    public func format(_ result: ExecutionResult) -> CommandOutput {
        CommandOutput(
            stdout: result.path + "\n",
            stderr: "Recording saved to \(result.path)\n"
        )
    }

    public func validate() throws {
        try VideoRecordingOptions.validate(fps: fps, quality: quality, scale: scale)
    }

    public func execute() async throws -> ExecutionResult {
        let logger = SimUseLogger()
        try await setup(logger: logger)
        try await performGlobalSetup(logger: logger)

        let trimmedUDID = device.resolved.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUDID.isEmpty else {
            throw CLIError(errorDescription: "Simulator UDID cannot be empty. Use --udid to specify a simulator.")
        }

        let simulatorSet = try await getSimulatorSet(deviceSetPath: nil, logger: logger, reporter: EmptyEventReporter.shared)
        guard let targetSimulator = simulatorSet.allSimulators.first(where: { $0.udid == trimmedUDID }) else {
            throw CLIError(errorDescription: "Simulator with UDID \(trimmedUDID) not found.")
        }

        guard targetSimulator.state == .booted else {
            let stateDescription = FBiOSTargetStateStringFromState(targetSimulator.state)
            throw CLIError(errorDescription: "Simulator \(trimmedUDID) is not booted. Current state: \(stateDescription)")
        }

        // GIF is transcoded from a finished MP4 (see GIFTranscoder); the
        // capture loop itself always writes H.264, to plan.recordTarget.
        let plan = try RecordingOutputPlan(format: format, output: output, fps: fps, scale: scale, gifMarkers: gifMarkers)
        let options = plan.options
        let recordTarget = plan.recordTarget
        FileHandle.standardError.write(Data("Recording simulator \(targetSimulator.udid) to \(plan.outputURL.path)\n".utf8))
        FileHandle.standardError.write(Data("Press Ctrl+C to stop recording\n".utf8))

        let cancellationFlag = CancellationFlag()
        let recordingFinished = CancellationFlag()
        let signalObserver = SignalObserver(signals: [SIGINT, SIGTERM]) {
            cancellationFlag.cancel()
            RecordingFinishWatchdog.arm(recordingFinished: recordingFinished)
        }
        defer { signalObserver.invalidate() }

        do {
            try await recordVideoViaNativeRecording(
                simulator: targetSimulator,
                outputURL: recordTarget,
                fps: options.fps ?? 30,
                quality: quality,
                scale: options.scale,
                cancellationFlag: cancellationFlag
            )
            recordingFinished.cancel()
        } catch let unavailable as RecordingUnavailableError {
            FileHandle.standardError.write(Data("warning: native H.264 recording unavailable (\(unavailable.underlying)); falling back to screenshot capture\n".utf8))
            do {
                try await recordVideoViaScreenshots(
                    simulator: targetSimulator,
                    outputURL: recordTarget,
                    fps: options.fps ?? 10,
                    quality: quality,
                    scale: options.scale,
                    cancellationFlag: cancellationFlag
                )
                recordingFinished.cancel()
            } catch {
                recordingFinished.cancel()
                throw CLIError(errorDescription: "Failed to record video: \(error.localizedDescription)")
            }
        } catch {
            recordingFinished.cancel()
            throw CLIError(errorDescription: "Failed to record video: \(error.localizedDescription)")
        }

        // Tear the observer down before the transcode so Ctrl+C during a
        // long GIF encode kills the process instead of being swallowed by
        // a handler that has nothing left to cancel (invalidate is
        // idempotent; the defer covers the error paths above).
        signalObserver.invalidate()
        try await plan.finalizeRecording()
        return ExecutionResult(path: plan.outputURL.path)
    }

    // MARK: - H.264 native recording

    private func recordVideoViaNativeRecording(
        simulator: FBSimulator,
        outputURL: URL,
        fps: Int,
        quality: Int,
        scale: Double,
        cancellationFlag: CancellationFlag
    ) async throws {
        let config = FBVideoStreamConfiguration(
            format: .compressedVideo(withCodec: .h264, transport: .annexB),
            framesPerSecond: fps,
            rateControl: .quality(Double(quality) / 100.0),
            scaleFactor: scale,
            keyFrameRate: 2.0
        )

        let framebuffer: FBFramebuffer
        do {
            framebuffer = try await simulator.connectToFramebuffer()
        } catch {
            throw RecordingUnavailableError(underlying: error.localizedDescription)
        }

        let recording = FBSimulatorVideo.video(
            withFramebuffer: framebuffer,
            configuration: config,
            filePath: outputURL.path,
            logger: SimUseLogger()
        )

        guard let screenInfo = simulator.screenInfo,
              screenInfo.widthPixels > 0,
              screenInfo.heightPixels > 0,
              screenInfo.scale > 0
        else {
            throw RecordingUnavailableError(underlying: "Simulator screen info is unavailable")
        }

        let transform = FBOverlayCoordinateTransform(
            screenPixelWidth: Int(screenInfo.widthPixels),
            screenPixelHeight: Int(screenInfo.heightPixels),
            retinaScale: CGFloat(screenInfo.scale),
            videoScale: CGFloat(scale),
            borderTop: 0,
            scaledBorderTop: 0,
            borderBottom: 0,
            scaledBorderBottom: 0,
            coordSpace: .device
        )
        let renderer = FBOverlayRenderer(transform: transform)
        recording.stream.updateOverlayBuffer(renderer.buffer)

        do {
            try await recording.startRecording()
        } catch {
            throw RecordingUnavailableError(underlying: error.localizedDescription)
        }

        let eventPath = ProcessInfo.processInfo.environment["SIM_USE_TOUCH_OVERLAY_PROBE_EVENT_FILE"]
        var lastEventPayload: String?

        while !(Task.isCancelled || cancellationFlag.isCancelled()) {
            if let eventPath,
               let payload = try? String(contentsOfFile: eventPath, encoding: .utf8),
               payload != lastEventPayload
            {
                lastEventPayload = payload
                let fields = payload.split(separator: "|", omittingEmptySubsequences: false)

                if fields.count == 4,
                   fields[0] == "tap",
                   let x = Double(fields[2]),
                   let y = Double(fields[3])
                {
                    let fade = FBOverlayShape.Effect.fadeout(.init(durationMs: 900))
                    renderer.render(overlays: [
                        .circle(.init(x: CGFloat(x), y: CGFloat(y), radius: 22, rgba: [53.55, 155.55, 234.6, 1], effect: fade)),
                        .circle(.init(x: CGFloat(x), y: CGFloat(y), radius: 19, rgba: [53.55, 155.55, 234.6, 0.5], effect: fade)),
                    ])
                    recording.stream.updateOverlayBuffer(renderer.buffer)
                    renderer.startEffectTimer {
                        recording.stream.updateOverlayBuffer(renderer.buffer)
                    }
                } else if fields.count == 7,
                          fields[0] == "swipe",
                          let startX = Double(fields[2]),
                          let startY = Double(fields[3]),
                          let endX = Double(fields[4]),
                          let endY = Double(fields[5]),
                          let duration = Double(fields[6])
                {
                    let translate = FBOverlayShape.Effect.translate(.init(
                        x: CGFloat(endX),
                        y: CGFloat(endY),
                        durationMs: CGFloat(duration * 1_000)
                    ))
                    renderer.render(overlays: [
                        .circle(.init(x: CGFloat(startX), y: CGFloat(startY), radius: 22, rgba: [53.55, 155.55, 234.6, 1], effect: translate)),
                        .circle(.init(x: CGFloat(startX), y: CGFloat(startY), radius: 19, rgba: [53.55, 155.55, 234.6, 0.5], effect: translate)),
                    ])
                    recording.stream.updateOverlayBuffer(renderer.buffer)
                    renderer.startEffectTimer {
                        recording.stream.updateOverlayBuffer(renderer.buffer)
                    }
                } else if fields.count == 4,
                          fields[0] == "swipeEnd",
                          let x = Double(fields[2]),
                          let y = Double(fields[3])
                {
                    renderer.clear()
                    let fade = FBOverlayShape.Effect.fadeout(.init(durationMs: 650))
                    renderer.render(overlays: [
                        .circle(.init(x: CGFloat(x), y: CGFloat(y), radius: 22, rgba: [53.55, 155.55, 234.6, 1], effect: fade)),
                        .circle(.init(x: CGFloat(x), y: CGFloat(y), radius: 19, rgba: [53.55, 155.55, 234.6, 0.5], effect: fade)),
                    ])
                    recording.stream.updateOverlayBuffer(renderer.buffer)
                    renderer.startEffectTimer {
                        recording.stream.updateOverlayBuffer(renderer.buffer)
                    }
                }
            }

            try? await cancellableSleep(seconds: 1.0 / 60.0, flag: cancellationFlag)
        }

        do {
            renderer.clear()
            recording.stream.updateOverlayBuffer(renderer.buffer)
            _ = try await recording.stop()
        } catch {
            // Whether a usable file survived a mid-recording failure is not
            // knowable from here (idb owns finalization internally) — check
            // the filesystem directly rather than guessing, matching the
            // Android branch's "partial recording saved" wording so the
            // caller doesn't discard a usable recording on faith alone.
            if FileManager.default.fileExists(atPath: outputURL.path) {
                throw CLIError(errorDescription: "\(error.localizedDescription); partial recording saved to \(outputURL.path)")
            }
            throw error
        }
    }

    // MARK: - Screenshot fallback

    /// Last-resort recorder used only when the H.264 stream API is
    /// unavailable (e.g. after an Xcode update breaks the private
    /// CoreSimulator surface). Polls screenshots and re-encodes through
    /// `H264StreamRecorder`; caps near ~8-10 fps.
    private func recordVideoViaScreenshots(
        simulator: FBSimulator,
        outputURL: URL,
        fps: Int,
        quality: Int,
        scale: Double,
        cancellationFlag: CancellationFlag
    ) async throws {
        let initialFrameData = try await VideoFrameUtilities.captureScreenshotData(from: simulator)
        guard let initialImage = VideoFrameUtilities.makeCGImage(from: initialFrameData) else {
            throw CLIError(errorDescription: "Failed to decode simulator screenshot")
        }

        let dimensions = VideoFrameUtilities.computeDimensions(for: initialImage, scale: scale)
        let recorder = try H264StreamRecorder(
            outputURL: outputURL,
            width: dimensions.width,
            height: dimensions.height,
            fps: fps,
            quality: quality
        )
        defer { recorder.invalidate() }

        var lastPresentationTime = CMTime.zero
        let frameInterval = 1.0 / Double(fps)
        try recorder.append(image: initialImage, presentationTime: .zero)
        let writerStartTime = Date()

        while true {
            if Task.isCancelled || cancellationFlag.isCancelled() { break }
            let frameStart = Date()

            do {
                let frameData = try await VideoFrameUtilities.captureScreenshotData(from: simulator)
                if let cgImage = VideoFrameUtilities.makeCGImage(from: frameData) {
                    let now = Date()
                    var presentationTime = CMTime(seconds: now.timeIntervalSince(writerStartTime), preferredTimescale: 600)
                    if presentationTime <= lastPresentationTime {
                        presentationTime = CMTimeAdd(lastPresentationTime, CMTime(value: 1, timescale: 600))
                    }
                    try recorder.append(image: cgImage, presentationTime: presentationTime)
                    lastPresentationTime = presentationTime
                }
            } catch let error as VideoWriterStallError {
                throw error
            } catch {
                FileHandle.standardError.write(Data("Error capturing frame: \(error.localizedDescription)\n".utf8))
            }

            let elapsed = Date().timeIntervalSince(frameStart)
            let sleepTime = frameInterval - elapsed
            if sleepTime > 0 {
                try await cancellableSleep(seconds: sleepTime, flag: cancellationFlag)
            }
        }

        try await recorder.finish()
    }
}
