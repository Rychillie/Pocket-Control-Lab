# Pocket Control Lab

> A safe path from a macOS UVC investigation tool to a dependable companion
> app for controlling a DJI Osmo Pocket 4 from a Mac.

Pocket Control Lab is a native macOS app written in Swift and SwiftUI. Today it
is an engineering lab for a DJI Osmo Pocket 4 connected by USB-C in **Webcam
Mode**. The long-term goal is a polished, trustworthy application that lets an
operator preview, inspect, and deliberately control a compatible camera from
their Mac without touching the camera itself.

In this project, **remote control** means *local control from a Mac over the
camera's USB Webcam Mode connection*. It does not mean internet, Bluetooth,
Wi-Fi, DJI Mimo, or a vendor cloud service. Those transports are outside the
current scope and must not be added without a separately reviewed protocol,
privacy, and safety design.

## Product direction

The desired end state is an operator-focused macOS app that can:

- detect a supported Pocket 4 automatically after it is connected by USB;
- show clear device status and start a live preview only after explicit
  operator action and camera consent;
- inspect compatible controls only through deliberate, read-only actions;
- expose only controls whose protocol, range, and behavior have been verified;
- let an operator position the camera deliberately from the Mac;
- preserve an evidence trail for every control operation, including the camera
  response and a human observation of the visible result; and
- fail safely when macOS, the cable, the camera, or its UVC driver is not in a
  usable state.

The current lab is deliberately conservative: it is how we learn what the
camera and macOS actually support before turning that behavior into a product
promise. An operator has reported successful preview and camera
positioning/control from the Mac. Individual control mappings, firmware
coverage, and the physical-versus-digital effect of each UVC request still need
repeatable recorded evidence.

Read the full [product direction and roadmap](Docs/PRODUCT_DIRECTION.md).

## What works today

- One app-scoped `DeviceSession` starts passive USB monitoring once at launch.
  It polls published IORegistry properties every 1.5 seconds, independently of
  camera permission. Passive discovery does not request permission, start a
  preview, perform UVC I/O, or send a UVC write.
- A typed, privacy-safe connection presentation state drives both the menu-bar
  status item and Diagnostics header. It combines passive discovery, USB
  profile evidence, non-prompting camera authorization, read-only camera
  visibility, and any cached direct-UVC inspection result without exposing
  hardware identifiers or causing platform work merely to render a status.
- The menu bar offers only safe context actions: **Refresh Detection** asks the
  existing passive monitor for a fresh IORegistry snapshot, and **Open
  Diagnostics** opens the laboratory window. It never requests camera access,
  starts preview, or opens the UVC transport. Direct-UVC availability remains
  unknown until the operator explicitly starts the existing read-only
  inspection.
- A **verified Pocket 4 control profile** requires the known `VID 2CA3` / `PID
  0023` pair and an observed normalized `OsmoPocket4` product token.
- Other DJI Osmo Pocket-family devices can be shown as detected, but they are
  never allowed to enter the Pocket 4 UVC-control path.
- **Start Preview** is explicit. It requests camera access only after the
  operator acts (when needed), then starts a local preview only for a verified
  Pocket 4. A denied permission leaves passive discovery active and preview
  stopped.
- **Refresh Read-Only Inspection** explicitly runs safe, read-only UVC inspection for
  Zoom Absolute, Pan/Tilt Absolute, and Roll Absolute. macOS driver ownership
  can safely prevent direct access; no inspection runs merely because the app
  launched or a device connected.
- UVC writes remain off until an operator explicitly unlocks them, and only
  the three whitelisted standard Camera Terminal controls can use `SET_CUR`.
- DJI Extension Unit selectors 1–3 are inspected read-only with `GET_INFO`,
  `GET_LEN`, and conditionally `GET_CUR`; there is no Extension Unit write
  path.
- Explicit lock, disconnect, re-enumeration, sleep, termination, and discovery
  stop use the same safe teardown: writes are disabled, pending work is
  cancelled, stale results are rejected, transport is invalidated, and preview
  stops where required. Wake restarts passive discovery only.

## Safety is a product feature

The app is designed to be useful precisely because it does **not** guess,
force, or hide unsafe behavior:

- no vendor-specific USB request;
- no DJI Extension Unit `SET_CUR`;
- no firmware update, DFU, memory write, reset, configuration change, or
  forced USB-interface ownership;
- no termination or disabling of `UVCAssistant`;
- no Bluetooth, Wi-Fi, DJI Mimo, DUML, networking, analytics, telemetry, or
  video recording; and
- no automatic permission request, preview start, UVC inspection, or UVC write
  at launch, on device connection, or after wake.

When macOS refuses direct UVC access because its own camera driver owns the
interface, the app reports the block and leaves the device alone. A successful
protocol response is also not treated as proof that a physical gimbal moved:
the operator is asked to verify the observable effect.

## Architecture at a glance

```text
App lifecycle owner
   │
   └── shared DeviceSession
          ├── SwiftUI scenes issue semantic intents
          ├── typed connection presentation for menu bar and Diagnostics
          ├── AVFoundation preview
          ├── passive IORegistry USB discovery
          ├── guarded standard UVC transport
          ├── read-only DJI Extension Unit inspector
          └── local investigation log, snapshots, and diffs
```

The UI never owns a monitor, preview session, transport, or raw USB request.
The low-level bridge has a strict request whitelist, and `DeviceSession` adds
explicit operator intent, range validation, connection identity, and
disconnect guards above it.

## Run locally

1. Open `PocketControlLab.xcodeproj` in Xcode.
2. Select the `PocketControlLab` scheme and **My Mac**.
3. Connect the camera by USB-C and choose **Webcam Mode** on the camera.
4. Run the app. It begins passive USB discovery without prompting for camera
   access, starting preview, or probing UVC controls.
5. Once a verified Pocket 4 is shown, choose **Start Preview**. Grant camera
   access only if macOS asks for it after that action.
6. Choose **Refresh Read-Only Inspection** when you want a read-only UVC inspection.
   Unlock UVC writes only when you are ready to observe the camera and record
   the result.

USB presence is detected even when camera permission is denied. A denied
permission blocks preview; it does not prove that the physical camera is
absent.

## Documentation map

| Document | Purpose |
| --- | --- |
| [Product direction](Docs/PRODUCT_DIRECTION.md) | Product goal, scope, roadmap, and acceptance criteria |
| [Engineering history](Docs/ENGINEERING_HISTORY.md) | Public-safe chronology, decisions, fixes, and current evidence |
| [Experiment log](Docs/EXPERIMENT_LOG.md) | Append-only template and baseline for reproducible hardware tests |
| [Technical lab documentation](Docs/POCKET_CONTROL_LAB.md) | Current architecture, UVC flow, limitations, and detailed observations |
| [Original USB/UVC investigation](POCKET_4_USB_INVESTIGATION.md) | Sanitized single-device descriptor-level evidence |
| [Privacy](PRIVACY.md) | What is read, shown, exported, and redacted |
| [Security](SECURITY.md) | Safety boundary and vulnerability-reporting status |
| [Release checklist](Docs/RELEASE_CHECKLIST.md) | Source, signing, notarization, test, and governance requirements |
| [Contributing](CONTRIBUTING.md) | Development, hardware safety, and data-hygiene rules |

## Privacy

The app has no account, cloud service, or automatic persistence. It does not
read USB serial numbers. USB locations and camera unique IDs are used only in
memory where necessary for matching and are not displayed or exported.

The on-screen log can contain raw DJI Extension Unit bytes for local analysis.
Copied and saved investigations redact those bytes and potentially identifying
diagnostic details by default; an explicit local toggle is required to include
them. Review [PRIVACY.md](PRIVACY.md) before sharing logs, screenshots, or a
build.

## Before the first public release

The codebase is not yet a distributable public release. Important remaining
work includes choosing an open-source license, configuring private security
reporting, adding automated tests and CI, signing with Developer ID,
notarization, and re-testing the exact notarized build with hardware.

The current Release build is universal and uses Hardened Runtime, but it is
still ad-hoc signed and rejected by Gatekeeper. See the
[release checklist](Docs/RELEASE_CHECKLIST.md) for the exact status.

## Contributing

Contributions are welcome once the repository is published. Please do not add
unknown device commands or broaden the control surface merely because a
descriptor advertises a bit. Every new capability needs an evidence record,
safe failure behavior, privacy review, and a test plan.

Read [CONTRIBUTING.md](CONTRIBUTING.md) before working with hardware or sharing
diagnostic output.

## Disclaimer

Pocket Control Lab is an independent project intended for open-source release.
It is not affiliated with, endorsed by, or supported by DJI. DJI and Osmo
Pocket are trademarks of their respective owners.
