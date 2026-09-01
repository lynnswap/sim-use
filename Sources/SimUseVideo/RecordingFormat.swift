// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation

/// Output container for the `record-video` verb, shared by every
/// surface (top-level forwarder, `ios record-video`,
/// `android record-video`) so the contract cannot drift between
/// platforms.
public enum RecordingFormat: String, ExpressibleByArgument, Codable, Sendable {
    case mp4
    case gif

    /// Infer a format from an explicit `--output` path extension.
    /// Returns nil when the extension is absent or unrecognized so the
    /// caller can fall through to the mp4 default.
    public static func infer(fromOutput output: String?) -> RecordingFormat? {
        guard let output else { return nil }
        let ext = (output.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).pathExtension.lowercased()
        return RecordingFormat(rawValue: ext)
    }

    /// One stderr note when an explicit `--format` contradicts the
    /// `--output` extension — explicit always wins, but silently writing
    /// mp4 bytes into a `.gif` path would read as a bug.
    public static func warnIfOverridingExtension(explicit: RecordingFormat?, output: String?) {
        guard let explicit, let inferred = infer(fromOutput: output), inferred != explicit else { return }
        FileHandle.standardError.write(Data("note: --format \(explicit.rawValue) overrides the --output .\(inferred.rawValue) extension\n".utf8))
    }
}

/// Resolved touch-indicator policy for one recording.
///
/// The CLI keeps color optional so it can diagnose an explicitly supplied
/// `--touch-color` without `--touch-indicators`; internal layers receive only
/// a valid disabled or enabled-with-color state.
public enum TouchIndicatorConfiguration: Equatable, Sendable {
    case disabled
    case enabled(color: TouchIndicatorColor)

    public init(enabled: Bool, color: TouchIndicatorColor?) throws {
        guard enabled else {
            if color != nil {
                throw ValidationError("--touch-color requires --touch-indicators")
            }
            self = .disabled
            return
        }
        self = .enabled(color: color ?? .blue)
    }

    public var isEnabled: Bool {
        if case .enabled = self { return true }
        return false
    }

    public var color: TouchIndicatorColor? {
        guard case let .enabled(color) = self else { return nil }
        return color
    }
}

/// Resolve the `--format` / `--fps` / `--scale` interplay in one place
/// so every surface applies identical semantics. Explicit `--format`
/// wins over the `--output` extension; GIF gets lower fps/scale
/// defaults because full-rate, full-scale GIFs are enormous.
public struct ResolvedRecordingOptions: Equatable, Sendable {
    public let format: RecordingFormat
    public let fps: Int?
    public let scale: Double
    /// The rate GIF sampling runs at — always resolved, so the default
    /// lives here and nowhere else.
    public let gifSampleFPS: Int
    /// Whether a GIF is bracketed with START/END marker frames. No
    /// default here or downstream — the opt-in policy lives on the
    /// `--gif-markers` flag of the three command surfaces, and every
    /// internal caller passes it explicitly.
    public let gifMarkers: Bool
    /// Whether the native capture carries sim-use-issued touch indicators.
    /// This is already resolved, so enabled state always carries its color.
    public let touchIndicators: TouchIndicatorConfiguration

    public init(
        format: RecordingFormat?,
        output: String?,
        fps: Int?,
        scale: Double?,
        gifMarkers: Bool,
        touchIndicators: TouchIndicatorConfiguration
    ) {
        let resolvedFormat = format ?? RecordingFormat.infer(fromOutput: output) ?? .mp4
        let sampleFPS = fps ?? 10
        self.format = resolvedFormat
        self.gifSampleFPS = sampleFPS
        self.fps = fps ?? (resolvedFormat == .gif ? sampleFPS : nil)
        self.scale = scale ?? (resolvedFormat == .gif ? 0.5 : 1.0)
        self.gifMarkers = gifMarkers
        self.touchIndicators = touchIndicators
    }

    /// Where the H.264 capture should land: the final URL for mp4, an
    /// intermediate sibling for gif (transcoded after stop, removed on
    /// success, preserved on failure).
    public func recordTarget(for outputURL: URL) -> URL {
        format == .gif ? URL(fileURLWithPath: outputURL.path + ".recording.mp4") : outputURL
    }
}

/// The per-run output plan every `record-video` surface goes through:
/// resolve the format/fps/scale interplay, emit the extension-mismatch
/// note, resolve the output URL, and clear a stale GIF intermediate left
/// by a failed or killed previous run (the AVAssetWriter-based recorders
/// refuse to open an existing file, and `prepareOutputURL` only clears
/// the final path). Owning the whole sequence here keeps the three
/// surfaces from drifting.
public struct RecordingOutputPlan {
    public let options: ResolvedRecordingOptions
    public let outputURL: URL
    public let recordTarget: URL

    public init(
        format: RecordingFormat?,
        output: String?,
        fps: Int?,
        scale: Double?,
        gifMarkers: Bool,
        touchIndicators: Bool,
        touchColor: TouchIndicatorColor?
    ) throws {
        options = ResolvedRecordingOptions(
            format: format,
            output: output,
            fps: fps,
            scale: scale,
            gifMarkers: gifMarkers,
            touchIndicators: try TouchIndicatorConfiguration(
                enabled: touchIndicators,
                color: touchColor
            )
        )
        RecordingFormat.warnIfOverridingExtension(explicit: format, output: output)
        outputURL = try VideoOutputFile.prepareOutputURL(output: output, fileExtension: options.format.rawValue)
        recordTarget = options.recordTarget(for: outputURL)
        if recordTarget != outputURL, FileManager.default.fileExists(atPath: recordTarget.path) {
            try FileManager.default.removeItem(at: recordTarget)
        }
    }

    /// GIF post-step; a no-op for mp4. Call after capture has finalized
    /// `recordTarget` — and after the capture signal observer has been
    /// invalidated, so a stuck transcode stays interruptible.
    public func finalizeRecording() async throws {
        guard options.format == .gif else { return }
        try await GIFTranscoder.transcodeRecording(
            tempMP4: recordTarget,
            to: outputURL,
            fps: options.gifSampleFPS,
            markers: options.gifMarkers
        )
    }
}
