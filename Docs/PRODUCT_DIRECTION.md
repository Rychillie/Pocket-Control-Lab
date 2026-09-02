# Product Direction: Pocket Control Lab

## Product statement

Pocket Control Lab will become a trustworthy macOS companion that lets an
operator view and control a DJI Osmo Pocket 4 from a Mac over USB Webcam Mode,
with explicit safety boundaries and evidence for every supported capability.

## What “remote” means here

The initial product is **USB-local remote control**: the operator can be away
from the camera while it remains connected to the Mac by USB-C in Webcam Mode.
This is useful for a desk rig, studio, overhead setup, tripod placement, and
other situations where touching the camera is inconvenient.

It is not a promise of internet or LAN control, Bluetooth or Wi-Fi control,
DJI Mimo compatibility, a cloud account, multi-user service, video upload, or
undocumented DJI protocol support. Those ideas can be evaluated later only
when there is a clear user need, an auditable protocol, explicit maintainer
approval, and a privacy/security design.

## The operator experience we want

An operator should be able to:

1. Connect a Pocket 4 in Webcam Mode.
2. See a clear connection state and live preview.
3. Know whether the app has a verified control profile or has merely detected
   an unsupported Pocket-family device.
4. See each control's supported range, current value, and safety state.
5. Deliberately enable writes and make a controlled Zoom, Pan, Tilt, or Roll
   adjustment.
6. See what was requested, what the camera returned, and a reminder to confirm
   the visible physical/digital effect.
7. Export a privacy-aware diagnostic if something behaves unexpectedly.

The experience should be calm and legible rather than clever: clear states,
predictable failure, no hidden background movement, and no claim that a
hardware action occurred unless a human has observed it.

## Product principles

### Evidence before promise

Descriptor bits, driver object names, and a successful UVC response are useful
signals, but they are not equivalent to a supported product feature. A feature
becomes supported only after its protocol, range, error behavior, and visible
camera effect have been recorded across a meaningful hardware matrix.

### Least privilege around hardware

The app must coexist with macOS's camera architecture. It must not seize USB
interfaces, kill `UVCAssistant`, reset the device, or use an unknown vendor
request to work around a driver limitation.

### Explicit movement

No write occurs by default. A person must enable write mode, and every write
must remain constrained to a known control, validated range, rate limit, and
currently connected device identity.

### Privacy by default

The product is local-first. Identifiers and raw diagnostic payloads are kept
out of default exports, and no data leaves the Mac unless an operator chooses
to save or copy it.

### Honest compatibility

The UI must distinguish:

- **detected** — a related device is visible over USB;
- **verified profile** — this app recognizes the exact Pocket 4 profile it can
  safely inspect;
- **available** — the current macOS/device session actually exposed a usable
  control; and
- **supported product feature** — repeatable behavior has been documented.

## Capability maturity model

| Level | Meaning | Example |
| --- | --- | --- |
| 0 — Unknown | No useful evidence yet | A potential DJI-only command |
| 1 — Advertised | A descriptor or driver reports it | UVC Zoom/PanTilt/Roll bits |
| 2 — Readable | The current device returns valid read-only values | A complete `GET_*` range |
| 3 — Operable | A deliberate write is accepted and read back | `SET_CUR` plus later `GET_CUR` |
| 4 — Observed | A human recorded the visible camera effect | Physical gimbal move, digital PTZ, or no effect |
| 5 — Supported | Repeated tests define user-facing behavior and limits | A documented operator control |

The current app contains mechanisms for Levels 1–4. Its public product claims
must remain at the level supported by recorded evidence, not merely by code
paths or a single session.

## Current position

The project began as a USB/UVC investigation lab. It now has a working local
foundation: automatic discovery, AVFoundation preview, guarded standard UVC
controls, a read-only DJI Extension Unit inspector, detailed logging, and
privacy-aware exports.

An operator has reported successful control of camera positioning from the Mac
in an interactive session. This is valuable product-direction evidence, but it
is not yet a complete compatibility claim: the app still needs a repeatable
per-control test record with macOS version, firmware, cable/hub, request,
response, and observed result.

## Roadmap

### Phase 0 — Safe laboratory foundation (current)

- Keep the protocol boundary narrow and observable.
- Gather real UVC ranges and response data without inventing semantics.
- Capture Extension Unit snapshots only through read-only requests.
- Make disconnect, permissions, and driver ownership fail safely.

**Exit evidence:** a documented baseline for one or more real Pocket 4
sessions, including exact test conditions and per-control observations.

### Phase 1 — Reliable operator controls

- Turn proven Zoom/Pan/Tilt/Roll flows into clear, accessible control UI.
- Add device/session state, recoverable error guidance, and operator-oriented
  control feedback.
- Add unit tests for profile selection, request whitelisting, write latches,
  disconnect/re-enumeration, and export redaction.
- Build a repeatable hardware compatibility matrix.

**Exit evidence:** repeatable behavior on supported macOS and firmware
combinations, including failure/reconnect behavior.

### Phase 2 — Product-quality macOS release

- Add release branding, app icon, release notes, and user documentation.
- Configure license, contribution governance, private vulnerability reporting,
  CI, Developer ID signing, notarization, and a clean distribution process.
- Validate the signed/notarized app on a clean macOS account or machine with
  real hardware.

**Exit evidence:** Gatekeeper acceptance, reproducible build/release process,
and documented hardware support.

### Phase 3 — Carefully expanded capability

- Consider additional standard controls only when the camera advertises and
  tests validate them.
- Continue Extension Unit research through read-only snapshots and controlled
  evidence gathering.
- Treat any future vendor-specific capability as a new design and review
  project, never as a quick extension of the existing bridge.

**Exit evidence:** an independently reviewed protocol specification, safety
plan, privacy assessment, and opt-in test implementation.

## Non-goals until explicitly changed

- Firmware/DFU/update tools.
- Camera reset or forced USB configuration.
- Driver termination, interface seizure, or bypassing `UVCAssistant`.
- Automatic recentering through an unknown DJI command.
- Cloud, accounts, analytics, tracking, or background network behavior.
- Inferring physical gimbal movement from a successful USB response.

## How contributors should make a proposal

Every new hardware capability proposal should answer:

1. What direct evidence identifies the protocol and payload layout?
2. What can fail, and how does the app fail closed?
3. Is it a standard UVC operation, a read-only observation, or an unknown
   vendor action?
4. What user consent is required before it can run?
5. How will request, response, and observed camera behavior be recorded?
6. Does it add personal data, persistent storage, networking, or a release
   entitlement?

Use [EXPERIMENT_LOG.md](EXPERIMENT_LOG.md) to record the evidence before
promoting an experiment into a product feature.
