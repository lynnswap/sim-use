# Touch-indicator recording bridge

This document defines the ownership and lifecycle contract for showing
sim-use-issued touches in iOS Simulator recordings. It is the design source of
truth for contributors changing the HID-to-recording bridge, contact identity,
or touch-indicator rendering.

## Outcome

Touch indicators remain an opt-in visual aid. They must not change HID gesture
timing or cause an otherwise successful input command to fail. The recording
process receives small, ordered touch primitives from each publisher session;
the recording process alone owns visible contact lifecycle and animation.

The public command surface remains:

```sh
sim-use record-video --device "$UDID" --touch-indicators --output demo.mp4
sim-use record-video --device "$UDID" --touch-indicators --touch-color orange --output demo.mp4
```

Semantic system colors remain intentional. The default disappearance animation
uses UIKit's default ease-in-out timing while preserving the ShowTime-inspired
44-point ring, 3-point stroke, 50-percent fill, 200 ms hold, 200 ms fade, and
0.85 final scale.

## Scope contract

The bridge covers taps, swipes, multi-touch gestures, batch HID operations, and
split down/up operations issued through one live publisher connection.

A publisher connection defines the lifetime of its contacts. When that
connection closes, the recorder cancels all contacts owned by it. A daemon
restart or standalone publisher-process exit therefore ends its visible
contacts; split touches do not continue across publisher process replacement.

The following are not goals:

- observing touches that were not issued by sim-use;
- proving that the foreground app handled an acknowledged HID primitive;
- preserving contacts across daemon or standalone-process replacement;
- supporting Android touch indicators in this change;
- introducing a reusable public framework or a second consumer.

No compatibility layer is required because the touch-indicator implementation
has not shipped. The existing CLI flags and semantic color names are retained.

## Current findings

The baseline at `be7b762` adds 6,893 lines. Recorded-touch wire, transport,
recovery, and their tests account for about 4,100 of those lines.

1. `HIDEventDispatchExecutor` flattens a composite before publishing. The
   production producer therefore emits one primitive with one sample and at
   most two contacts; multi-sample fragmentation and reassembly are not
   reachable from the production call graph.
2. The synchronous HID observer performs filesystem inspection, JSON encoding,
   socket creation and configuration, and delivery before the next gesture
   delay. Touch visualization therefore lengthens the gesture it observes.
3. Publisher-side normalization and recorder-side rendering both own active
   contact state.
4. Per-process contact IDs `0`, `1`, and `2` collide when publishers overlap.
5. The recovery journal, reassembler, tombstones, and renderer generation gates
   jointly maintain one terminal-delivery invariant across multiple owners.
6. The live recording test checks MP4 validity but does not inspect the rendered
   indicator.

## Target and owner graph

No package or target is added. All iOS-only bridge and rendering implementation
belongs to `iOSSimBackend`.

```text
HIDInteractor
  -> RecordedTouchPublisher
       -> ordered local stream connection
            -> RecordingTouchOverlaySession
                 -> TouchIndicatorRenderer
                      -> FBSimulatorVideoStream overlay buffer
```

`SimUseVideo` keeps the shared recording option and semantic color types used by
the top-level, iOS, and Android command surfaces. The touch renderer moves to
`iOSSimBackend` because it has no second consumer and implements an iOS-only
recording capability.

Owner responsibilities are:

| Owner | State and lifecycle |
|---|---|
| `HIDInteractor` | Dispatches HID primitives and reports an immutable acknowledged primitive. It performs no overlay I/O. |
| `RecordedTouchPublisher` | Owns one publisher ID, the outbound ordered queue, connection, framing, bounded buffering, flush, and close. |
| `RecordedTouchListener` | Owns the exclusive per-UDID endpoint, accepted publisher connections, decoding, and publisher-close events. |
| `RecordingTouchOverlaySession` | Owns listener attachment, activation, render cadence, health, and teardown for one recording. |
| `TouchIndicatorRenderer` | Owns visible contact identity, position, terminal animation, and the reusable overlay buffer. |
| `FBSimulatorVideoStream` | Owns frame cadence and composition of the current overlay buffer into encoded frames. |

## Internal interface

The bridge has no new public API. Its internal value boundary is intentionally
smaller than `FBSimulatorHIDEvent`:

```swift
struct RecordedTouchPrimitive: Codable, Sendable {
    enum Phase: String, Codable, Sendable { case down, up }

    struct Contact: Codable, Sendable {
        let localID: UInt8
        let x: Double
        let y: Double
    }

    let dispatchUptimeNanoseconds: UInt64
    let phase: Phase
    let contacts: [Contact] // exactly one or two
}

enum RecordedTouchInput: Sendable {
    case update(publisherID: UUID, primitive: RecordedTouchPrimitive)
    case publisherClosed(publisherID: UUID, uptimeNanoseconds: UInt64)
}
```

The publisher owns the publisher ID and sends it during connection setup. The
renderer keys a visible contact by `(publisherID, localID)`. A repeated `down`
for an active key moves it; `up` ends it; an unknown `up` is a normal no-op.
Publisher close cancels only that publisher's active contacts.

## Delivery and failure semantics

- The HID callback only enqueues an immutable primitive in memory.
- A serial publisher owner connects, encodes, and writes outside the HID
  primitive sequence.
- Messages are ordered within one publisher connection.
- The outbound queue is bounded. Overflow or connection failure closes that
  publisher session instead of dropping an arbitrary terminal update. EOF then
  cancels its active contacts at the recorder.
- Missing listener is a normal no-op. Delivery failure is diagnostic and never
  changes the HID command result.
- `flush()` hands queued updates to the connection after the whole HID event;
  it does not insert work between gesture primitives.
- `close()` stops new enqueue, drains or terminates the connection, and waits
  for owned work to finish. Deinitialization is only a synchronous cleanup
  backstop.

The wire uses one framed primitive per message. There are no sample arrays,
relative offsets, chunks, reassembly, event tombstones, persistent recovery
files, or fixed contact-expiry timeout.

## Rendering contract

The renderer keeps a reusable BGRA overlay buffer because the pinned idb stream
accepts that buffer for frame composition. A dedicated renderer remains local:
idb's generic circle renderer does not provide a true stroke, delayed fade, or
combined opacity-and-scale animation.

The terminal animation uses the public Core Animation `easeInEaseOut` timing
function. The curve is resolved once and tested away from the midpoint; testing
only 0, 0.5, and 1 cannot distinguish it from a linear curve.

Render ticks use the recording FPS rather than a fixed 60 Hz. Geometry uses the
actual even-rounded encoded width when deriving pixels per point, matching the
uniform width scale used by the pinned idb compositor.

## Variants and absorption points

| Variation | Absorption point | Variant-addition check |
|---|---|---|
| Touch primitive kind | `RecordedTouchPrimitive` conversion at `HIDInteractor` | A new supported primitive adds one conversion case; listener and framing remain unchanged. |
| Publisher lifetime | `RecordedTouchPublisher` connection | A second publisher needs a new instance and ID, not renderer or listener branches. |
| Touch color | `TouchIndicatorColor` | A semantic color adds one enum case and one AppKit mapping. |
| Recording FPS | `RecordingTouchOverlaySession` timer configuration | A different FPS changes configuration only. |
| Live/test I/O | Publisher/listener transport dependency | Tests substitute the transport boundary without production test flags. |

## Deletions

The migration removes the following implementations and their dedicated tests:

- `RecordedTouchRecoveryJournal`;
- `RecordedTouchEventReassembler`, chunk metadata, and tombstones;
- multi-sample `RecordedTouchEvent` and relative timestamps;
- `RecordedTouchEventNormalizer`;
- `RecordedTouchStateStore`;
- recovery mailbox, large-event, chunk-order, and future-sample tests.

`TouchIndicatorRenderer` remains, but its future-update queue is removed and its
contact key becomes publisher-scoped.

## Avoided shapes

- Do not retain the datagram implementation as a fallback beside the ordered
  connection.
- Do not perform path inspection, encoding, connection setup, or writes from
  `didSendPrimitive`.
- Do not keep publisher active state in parallel with renderer active state.
- Do not reintroduce process-replacement recovery through files, retries, or a
  fixed contact timeout.
- Do not add a production code path that exists only to make tests observe
  queue progress.
- Do not move semantic color choice back to a fixed ShowTime RGB value.

## Test contract

| Boundary | Required proof |
|---|---|
| Primitive conversion | Single- and two-contact HID leaves produce bounded down/up messages with the dispatch uptime. |
| Publisher | Enqueue is ordered; flush completes; missing listener is a no-op; overflow and write failure close the publisher session. |
| Listener | Two publishers with the same local ID stay distinct; EOF emits one publisher-close event; close removes only owned endpoint resources. |
| Renderer | Down/move/up, publisher close, ID reuse, semantic colors, actual geometry scale, and quarter-point ease-in-out animation use an injected clock. |
| Recording integration | Extracted MP4 frames contain the expected ring near the dispatched point and later contain no ring. A recording without the flag contains no injected ring. |
| Regression | Ordinary HID gestures do not synchronously perform overlay filesystem or socket I/O between primitive sends. |

The completed migration must pass `make build`, `make test`, the targeted bridge
and renderer suites, `make e2e-ios`, and branch-wide Codex review.

## Finding-to-design mapping

| Finding | Resolution |
|---|---|
| Unreachable generalized wire | One primitive per framed message; delete sample/chunk/reassembly types. |
| HID timing pollution | In-memory enqueue in the observer; publisher owns asynchronous I/O. |
| Duplicate contact state | Renderer is the only visual contact owner. |
| Cross-publisher ID collision | `(publisherID, localID)` identity. |
| Terminal recovery spread across owners | Ordered connection plus EOF cancellation; delete recovery journal. |
| Consumer behavior untested | Decode final MP4 frames and inspect indicator pixels. |

