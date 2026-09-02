// SPDX-License-Identifier: Apache-2.0
import ArgumentParser

/// Flag validation shared by every surface of the cross-platform
/// `record-video` verb (top-level forwarder, `ios record-video`,
/// `android record-video`) so the contract cannot drift between
/// platforms.
public enum VideoRecordingOptions {
    /// `scale` is optional because its default is format-dependent
    /// (1.0 for mp4, 0.5 for gif — see `ResolvedRecordingOptions`);
    /// nil means "not user-supplied" and needs no range check.
    public static func validate(
        fps: Int?,
        quality: Int,
        scale: Double?,
        touchIndicators: Bool,
        touchColor: TouchIndicatorColor?
    ) throws {
        if let fps {
            guard fps >= 1 && fps <= 60 else {
                throw ValidationError("FPS must be between 1 and 60")
            }
        }
        guard quality >= 1 && quality <= 100 else {
            throw ValidationError("Quality must be between 1 and 100")
        }
        guard scale.map({ $0 >= 0.1 && $0 <= 1.0 }) ?? true else {
            throw ValidationError("Scale must be between 0.1 and 1.0")
        }
        _ = try TouchIndicatorConfiguration(
            enabled: touchIndicators,
            color: touchColor
        )
    }

    /// The `stream-video` variant: streaming caps FPS at 30 (screenshot/
    /// screencap capture cannot sustain more, and the h264 passthrough
    /// ignores the flag entirely).
    public static func validateStreaming(fps: Int?, quality: Int, scale: Double) throws {
        if let fps {
            guard fps >= 1 && fps <= 30 else {
                throw ValidationError("FPS must be between 1 and 30")
            }
        }
        guard quality >= 1 && quality <= 100 else {
            throw ValidationError("Quality must be between 1 and 100")
        }
        guard scale >= 0.1 && scale <= 1.0 else {
            throw ValidationError("Scale must be between 0.1 and 1.0")
        }
    }
}
