// SPDX-License-Identifier: Apache-2.0
@testable import SimUse
@testable import iOSSimBackend
import AndroidBackend
import ArgumentParser
import Foundation
import SimUseCore
import SimUseVideo
import Testing

// Pins the opt-in presentation flags between top-level `RecordVideo`,
// `IOSSimRecordVideoCommand`, and `AndroidRecordVideoCommand`. The recording
// layers take every value as a required parameter, so the compiler rejects an
// unwired Android forwarder; the shape check makes that contract explicit.
@Suite("RecordVideo forwarder")
struct RecordVideoForwarderTests {
    private let iosUDID = "9CD7C6E7-45B3-4E59-BBF2-4D12A9457CD0"

    // MARK: - Flag-surface parity

    @Test("--gif-markers defaults to off on all three surfaces")
    func gifMarkersDefaultOff() throws {
        #expect(try RecordVideo.parse([]).gifMarkers == false)
        #expect(try IOSSimRecordVideoCommand.parse([]).gifMarkers == false)
        #expect(try AndroidRecordVideoCommand.parse([]).gifMarkers == false)
    }

    @Test("--gif-markers parses as true on all three surfaces")
    func gifMarkersParsesTrue() throws {
        #expect(try RecordVideo.parse(["--gif-markers"]).gifMarkers == true)
        #expect(try IOSSimRecordVideoCommand.parse(["--gif-markers"]).gifMarkers == true)
        #expect(try AndroidRecordVideoCommand.parse(["--gif-markers"]).gifMarkers == true)
    }

    @Test("--touch-indicators defaults off with no explicit color on all three surfaces")
    func touchIndicatorsDefaultOff() throws {
        let top = try RecordVideo.parse([])
        let ios = try IOSSimRecordVideoCommand.parse([])
        let android = try AndroidRecordVideoCommand.parse([])
        #expect(!top.touchIndicators && top.touchColor == nil)
        #expect(!ios.touchIndicators && ios.touchColor == nil)
        #expect(!android.touchIndicators && android.touchColor == nil)
    }

    @Test("Every semantic touch color parses identically on all three surfaces")
    func touchColorsParse() throws {
        for color in TouchIndicatorColor.allCases {
            let arguments = ["--touch-indicators", "--touch-color", color.rawValue]
            #expect(try RecordVideo.parse(arguments).touchColor == color)
            #expect(try IOSSimRecordVideoCommand.parse(arguments).touchColor == color)
            #expect(try AndroidRecordVideoCommand.parse(arguments).touchColor == color)
        }
    }

    @Test("--touch-color without --touch-indicators is rejected")
    func touchColorRequiresIndicators() {
        #expect(throws: (any Error).self) {
            _ = try RecordVideo.parse(["--touch-color", "orange"])
        }
        #expect(throws: (any Error).self) {
            _ = try IOSSimRecordVideoCommand.parse(["--touch-color", "orange"])
        }
        #expect(throws: (any Error).self) {
            _ = try AndroidRecordVideoCommand.parse(["--touch-color", "orange"])
        }
    }

    // MARK: - Forwarding

    @Test("Top-level forwarder copies --gif-markers to the iOS subcommand")
    func gifMarkersForwardsToIOS() throws {
        let on = try RecordVideo.parse(["--gif-markers", "--udid", iosUDID])
        #expect(on.makeIOSSubcommand().gifMarkers == true)

        let off = try RecordVideo.parse(["--udid", iosUDID])
        #expect(off.makeIOSSubcommand().gifMarkers == false)
    }

    @Test("Top-level forwarder copies touch indicator enablement and color to iOS")
    func touchIndicatorsForwardToIOS() throws {
        let on = try RecordVideo.parse([
            "--touch-indicators", "--touch-color", "orange", "--udid", iosUDID,
        ])
        #expect(on.makeIOSSubcommand().touchIndicators)
        #expect(on.makeIOSSubcommand().touchColor == .orange)

        let off = try RecordVideo.parse(["--udid", iosUDID])
        #expect(!off.makeIOSSubcommand().touchIndicators)
        #expect(off.makeIOSSubcommand().touchColor == nil)
    }

    @Test("AndroidRecordVideoCommand.record requires every presentation option in the forwarder shape")
    func androidRecordContract() {
        let _: (
            String,
            String?,
            RecordingFormat?,
            Int?,
            Int,
            Double?,
            Bool,
            Bool,
            TouchIndicatorColor?
        ) async throws -> URL = AndroidRecordVideoCommand.record
    }

    @Test("Android rejects touch indicators before attempting adb discovery")
    func androidRejectsTouchIndicatorsBeforeADB() async {
        do {
            _ = try await AndroidRecordVideoCommand.record(
                serial: "definitely-not-a-device",
                output: nil,
                format: nil,
                fps: nil,
                quality: 80,
                scale: nil,
                gifMarkers: false,
                touchIndicators: true,
                touchColor: .orange
            )
            Issue.record("Expected the iOS-only capability error")
        } catch {
            #expect(error.localizedDescription.contains("only for iOS Simulator recordings"))
            #expect(!error.localizedDescription.contains("adb"))
        }
    }
}
