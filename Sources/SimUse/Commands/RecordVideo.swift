// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation
import SimUseCore
import SimUseVideo
import AndroidBackend
import iOSSimBackend

/// Top-level cross-platform `record-video` verb. Owns the flag
/// surface and resolves the target platform, then delegates to:
///
///   * `IOSSimRecordVideoCommand.execute()` for iOS Simulator UDIDs
///     (which drives `FBSimulatorVideoStream` eager H.264 at `--fps`).
///   * `AndroidRecordVideoCommand.record()` for adb serials (which
///     streams `adb exec-out screenrecord --output-format=h264` into
///     the shared H.264 → MP4 passthrough muxer).
struct RecordVideo: SimUseExecutableCommand {
    typealias ExecutionResult = IOSSimRecordVideoCommand.ExecutionResult

    static let configuration = CommandConfiguration(
        commandName: "record-video",
        abstract: "Record the simulator display to an MP4 (H.264) or animated GIF file"
    )

    @OptionGroup var device: DeviceOptions

    @Option(help: "Frames per second (1-60; default: 30 for mp4, 10 for gif). Ignored by Android capture (screenrecord uses the device's native variable frame rate), but still applied when sampling a GIF.")
    var fps: Int?

    @Option(help: "Quality factor (1-100) controlling bitrate (default: 80)")
    var quality: Int = 80

    @Option(help: "Scale factor (0.1-1.0; default: 1.0 for mp4, 0.5 for gif)")
    var scale: Double?

    @Option(help: "Output format: mp4, gif. Defaults to the --output extension when recognized, else mp4.")
    var format: RecordingFormat?

    @Flag(help: "Bracket a GIF with START/END marker frames (opt-in; ignored for mp4).")
    var gifMarkers: Bool = false

    @Flag(help: "Overlay indicators for touch input issued through sim-use (opt-in; iOS Simulator only).")
    var touchIndicators: Bool = false

    @Option(help: "Semantic color for --touch-indicators: blue, red, orange, yellow, green, mint, teal, cyan, indigo, purple, pink, brown, gray (default: blue).")
    var touchColor: TouchIndicatorColor?

    @Option(help: "Output file path. Defaults to sim-use-video-<timestamp>.<format> in the current directory.")
    var output: String?

    @OptionGroup var json: JSONOutputOptions

    var jsonOutput: Bool { json.enabled }

    mutating func resolveDeferredArguments() throws {
        try device.resolve(allowPhysical: true)
    }

    var simulatorUDIDForDaemon: String? { device.resolved }

    var daemonBypass: Bool { true }

    func format(_ result: ExecutionResult) -> CommandOutput {
        CommandOutput(
            stdout: result.path + "\n",
            stderr: "Recording saved to \(result.path)\n"
        )
    }

    func validate() throws {
        try VideoRecordingOptions.validate(
            fps: fps,
            quality: quality,
            scale: scale,
            touchIndicators: touchIndicators,
            touchColor: touchColor
        )
    }

    func execute() async throws -> ExecutionResult {
        switch PlatformRouter.resolve(udid: device.resolved) {
        case .android:
            return try await executeAndroid()
        case .iOSDevice:
            throw TargetCapabilityError.physicalIOS(
                verb: "record-video",
                reason: "video capture is not wired up for physical devices (CoreDevice screen recording is capability-gated per device).",
                alternative: "Capture stills instead: `sim-use screenshot` works on any screen, system apps included."
            )
        case .iOSSim, .none:
            return try await executeIOSSim()
        }
    }

    private func executeIOSSim() async throws -> ExecutionResult {
        let sub = makeIOSSubcommand()
        return try await sub.execute()
    }

    /// Construct the backend command and copy every parsed flag across.
    /// A missed field stays in ArgumentParser's wrapper-definition state
    /// and traps on first read (#42) — pinned by
    /// `ForwarderInitializationGuardTests`.
    func makeIOSSubcommand() -> IOSSimRecordVideoCommand {
        var sub = IOSSimRecordVideoCommand()
        sub.fps = fps
        sub.quality = quality
        sub.scale = scale
        sub.format = format
        sub.gifMarkers = gifMarkers
        sub.touchIndicators = touchIndicators
        sub.touchColor = touchColor
        sub.output = output
        sub.device = device
        sub.json = json
        return sub
    }

    private func executeAndroid() async throws -> ExecutionResult {
        let outputURL = try await AndroidRecordVideoCommand.record(
            serial: device.resolved,
            output: output,
            format: format,
            fps: fps,
            quality: quality,
            scale: scale,
            gifMarkers: gifMarkers,
            touchIndicators: touchIndicators,
            touchColor: touchColor
        )
        return ExecutionResult(path: outputURL.path)
    }
}
