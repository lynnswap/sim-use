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

    private struct TouchIndicatorRecordingUnavailableError: Error, LocalizedError {
        let underlying: String

        var errorDescription: String? {
            "Touch indicators could not be enabled for this recording: \(underlying) Omit --touch-indicators to use the ordinary recording path."
        }
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

    @Flag(help: "Overlay indicators for touch input issued through sim-use (opt-in).")
    public var touchIndicators: Bool = false

    @Option(help: "Semantic color for --touch-indicators: blue, red, orange, yellow, green, mint, teal, cyan, indigo, purple, pink, brown, gray (default: blue).")
    public var touchColor: TouchIndicatorColor?

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
        try VideoRecordingOptions.validate(
            fps: fps,
            quality: quality,
            scale: scale,
            touchIndicators: touchIndicators,
            touchColor: touchColor
        )
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
        let plan = try RecordingOutputPlan(
            format: format,
            output: output,
            fps: fps,
            scale: scale,
            gifMarkers: gifMarkers,
            touchIndicators: touchIndicators,
            touchColor: touchColor
        )
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
            switch options.touchIndicators {
            case .disabled:
                try await recordVideoViaNativeRecording(
                    simulator: targetSimulator,
                    outputURL: recordTarget,
                    fps: options.fps ?? 30,
                    quality: quality,
                    scale: options.scale,
                    cancellationFlag: cancellationFlag
                )
            case let .enabled(color):
                try await recordVideoViaNativeRecordingWithTouchIndicators(
                    simulator: targetSimulator,
                    outputURL: recordTarget,
                    fps: options.fps ?? 30,
                    quality: quality,
                    scale: options.scale,
                    color: color,
                    cancellationFlag: cancellationFlag,
                    logger: logger
                )
            }
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
        let config = videoStreamConfiguration(
            fps: fps,
            quality: quality,
            scale: scale
        )

        let recording: any FBVideoRecording
        do {
            recording = try await simulator.startRecording(toFile: outputURL.path, configuration: config)
        } catch {
            throw RecordingUnavailableError(underlying: error.localizedDescription)
        }

        while !(Task.isCancelled || cancellationFlag.isCancelled()) {
            try? await cancellableSleep(seconds: 0.1, flag: cancellationFlag)
        }

        do {
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

    private func recordVideoViaNativeRecordingWithTouchIndicators(
        simulator: FBSimulator,
        outputURL: URL,
        fps: Int,
        quality: Int,
        scale: Double,
        color: TouchIndicatorColor,
        cancellationFlag: CancellationFlag,
        logger: SimUseLogger
    ) async throws {
        guard let screenInfo = simulator.screenInfo else {
            throw TouchIndicatorRecordingUnavailableError(
                underlying: "Simulator screen information is unavailable."
            )
        }

        let geometry: TouchIndicatorVideoGeometry
        do {
            geometry = try TouchIndicatorVideoGeometry(
                screenPixelWidth: Int(screenInfo.widthPixels),
                screenPixelHeight: Int(screenInfo.heightPixels),
                screenScale: CGFloat(screenInfo.scale),
                videoScale: scale
            )
        } catch {
            throw TouchIndicatorRecordingUnavailableError(
                underlying: error.localizedDescription
            )
        }

        let framebuffer: FBFramebuffer
        do {
            framebuffer = try await simulator.connectToFramebuffer()
        } catch {
            throw TouchIndicatorRecordingUnavailableError(
                underlying: "Could not connect to the Simulator framebuffer: \(error.localizedDescription)"
            )
        }

        let recording = FBSimulatorVideo.video(
            withFramebuffer: framebuffer,
            configuration: videoStreamConfiguration(
                fps: fps,
                quality: quality,
                scale: scale
            ),
            filePath: outputURL.path,
            logger: logger
        )

        let overlaySession: RecordingTouchOverlaySession
        do {
            overlaySession = try RecordingTouchOverlaySession(
                udid: simulator.udid,
                stream: recording.stream,
                geometry: geometry,
                color: color
            )
        } catch {
            throw TouchIndicatorRecordingUnavailableError(
                underlying: error.localizedDescription
            )
        }

        var recordingStarted = false
        var primaryError: Error?
        do {
            try await recording.startRecording()
            recordingStarted = true
            overlaySession.activate()

            while !(Task.isCancelled || cancellationFlag.isCancelled()) {
                try overlaySession.checkHealth()
                try? await cancellableSleep(seconds: 0.1, flag: cancellationFlag)
            }
            try overlaySession.checkHealth()
        } catch {
            primaryError = error
        }

        do {
            try overlaySession.close()
        } catch {
            if primaryError == nil { primaryError = error }
        }

        if recordingStarted {
            do {
                _ = try await recording.stop()
            } catch {
                let stopError = recordingStopError(error, outputURL: outputURL)
                if let primaryError {
                    throw CLIError(errorDescription: "\(primaryError.localizedDescription) Additionally, \(stopError.localizedDescription)")
                }
                throw stopError
            }
        }

        if let primaryError {
            if FileManager.default.fileExists(atPath: outputURL.path) {
                throw CLIError(errorDescription: "\(primaryError.localizedDescription); recording saved with incomplete touch indicators to \(outputURL.path)")
            }
            throw primaryError
        }
    }

    private func videoStreamConfiguration(
        fps: Int,
        quality: Int,
        scale: Double
    ) -> FBVideoStreamConfiguration {
        FBVideoStreamConfiguration(
            format: .compressedVideo(withCodec: .h264, transport: .annexB),
            framesPerSecond: fps,
            rateControl: .quality(Double(quality) / 100.0),
            scaleFactor: scale,
            keyFrameRate: 2.0
        )
    }

    private func recordingStopError(_ error: Error, outputURL: URL) -> Error {
        if FileManager.default.fileExists(atPath: outputURL.path) {
            return CLIError(errorDescription: "\(error.localizedDescription); partial recording saved to \(outputURL.path)")
        }
        return error
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
