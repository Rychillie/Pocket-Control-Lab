# Engineering History and Evidence Ledger

## Purpose

This is a public-safe record of how Pocket Control Lab became a candidate
open-source project. It turns useful engineering context into reproducible
facts; it is not a transcript of private conversations, local logs, or
developer-machine history.

Do not add serial numbers, USB locations/topology, camera or CoreMediaIO IDs,
hostnames, usernames, absolute paths, screenshots containing those values, or
unredacted Extension Unit payloads. Use [EXPERIMENT_LOG.md](EXPERIMENT_LOG.md)
for new results and keep the source material private unless it has been
reviewed and redacted.

## Evidence vocabulary

| Label | Meaning | What it does not prove |
| --- | --- | --- |
| **Observed hardware** | A fact was recorded from a real, connected device. | Compatibility with every Pocket, cable, macOS release, or firmware. |
| **Code/build verified** | Source, static analysis, or a local build was checked. | A real camera session or distributable signed release. |
| **Operator-reported** | A human described an interactive result. | A complete protocol map or independently reproduced result. |
| **Unverified** | The project has no sufficient evidence yet. | That the feature is absent or impossible. |

## Timeline

### 2026-08-22 — USB and UVC reconnaissance

**Observed hardware.** A DJI Osmo Pocket 4 in Webcam Mode was observed as a
USB High-Speed UVC + UAC1 device. The device profile used by this project is
VID `0x2CA3` / PID `0x0023`. Its Camera Terminal descriptor advertised Zoom
Absolute, Pan/Tilt Absolute, and Roll Absolute. A DJI Extension Unit was also
observed at Unit ID 6 with GUID
`41769EA2-04DE-E347-8B2B-F4341AFF003B`.

The observed Extension Unit descriptor was internally inconsistent:
`bNumControls = 2` while `bmControls = 0x07`. Selectors 1, 2, and 3 were
therefore treated as candidates for read-only inspection, never as understood
commands. The original descriptor report is a sanitized single-device sample:
[POCKET_4_USB_INVESTIGATION.md](../POCKET_4_USB_INVESTIGATION.md).

**Decision.** The first investigation would only inspect descriptors. It did
not send UVC `GET_*` or `SET_CUR`, vendor-specific requests, firmware actions,
or Extension Unit writes. A descriptor bit is evidence of an advertised
capability, not evidence that a control works in macOS or moves hardware.

### 2026-08-22 to 2026-08-23 — Laboratory application created

**Code/build verified.** The native macOS lab was structured so that SwiftUI
views do not issue USB requests: app state coordinates discovery and safety;
AVFoundation owns preview; IOKit/IOUSBLib is isolated behind a guarded UVC
transport; the Extension Unit inspector remains read-only; and logs and
snapshots support investigation.

**Decision.** The standard UVC control surface is deliberately narrow. Only
Camera Terminal Zoom Absolute, Pan/Tilt Absolute, and Roll Absolute can ever
reach `SET_CUR`, and only after an explicit write opt-in, successful read-only
range discovery, validation, rate limiting, and connection-identity checks.

### 2026-08-23 — USB discovery diagnosis

**Observed hardware and code diagnosis.** Camera permission was granted in an
early run, yet the app did not find the connected Pocket. IORegistry evidence
showed the device was present. The scanner's service-iterator lifetime was the
root cause: a deferred release could release the next service before it was
examined.

**Fix.** Each service is now inspected before it is released. Discovery begins
at launch, independently of camera permission, and passively polls published
IORegistry properties every 1.5 seconds. It does not open, seize, or reset a
USB interface.

### 2026-08-23 — Preview lifecycle diagnosis

**Observed runtime failure and code diagnosis.** An early preview attempt
raised `AVCaptureSession startRunning may not be called between calls to
beginConfiguration and commitConfiguration`.

**Fix.** The preview controller now completes configuration before starting
the session and serializes its session work. This distinction matters because
camera permission or USB presence alone is not proof that preview is ready.

### 2026-08-23 — Xcode project navigation cleanup

**Code/project verified.** The Project Navigator was adjusted to use Xcode
groups that mirror the real source folders. This was a project-presentation
fix: source files were not moved, replaced, or generated merely to change how
they appear in Xcode.

### 2026-09-02 — Interactive operator report

**Operator-reported.** In an interactive local session, the operator reported
that live preview worked and that the camera could be positioned and adjusted
from the Mac without touching it.

This is an encouraging product-direction result, not a broad support claim.
That report did not preserve a per-selector request/response table, camera
firmware, macOS version, cable/hub topology, or a full distinction between
physical gimbal movement and digital PTZ. Those details remain unverified
until recorded in the experiment log.

### 2026-09-02 — Open-source and release hardening

**Code/build verified.** The project was prepared for a future public
repository: source and documentation were sanitized; local Xcode/Finder state
and generated artifacts were ignored; default diagnostic exports were made
privacy-aware; USB classification was tightened; and release, privacy,
security, and contribution documents were added.

The current source distinguishes a verified Pocket 4 control profile from a
generic DJI Osmo Pocket-family detection. The verified profile requires the
known VID/PID pair plus an observed normalized `OsmoPocket4` product token. A
family-only match is informational and cannot enter preview, UVC inspection,
or UVC write paths.

Local Debug and universal Release build checks, static analysis, and strict
ad-hoc signature verification were completed during this preparation. They do
not constitute Developer ID signing, notarization, Gatekeeper acceptance, a
clean-machine test, or public release readiness. See
[RELEASE_CHECKLIST.md](RELEASE_CHECKLIST.md).

## Enduring engineering decisions

### Profile identity is stronger than a USB port

USB location can be reused after disconnect or re-enumeration. The app tracks
connection generation and registry identity so a delayed discovery or write
cannot be applied to a replacement device merely because it appears at the
same location.

### macOS driver ownership is respected

If macOS's camera architecture does not make a compatible user client
available, the app surfaces the limitation and leaves the device alone. It
does not terminate `UVCAssistant`, force interface ownership, open with seize,
reset the device, or alter USB configuration.

### Extension Unit research is observation only

The DJI Extension Unit can use only `GET_INFO`, `GET_LEN`, and a valid-length
`GET_CUR` for the three candidate selectors. Snapshot A/B comparison is for
finding byte changes after a person changes a setting on the camera; it never
interprets those bytes as a command and never sends `SET_CUR` to the unit.

### A USB response is not a visible outcome

After Pan/Tilt/Roll writes, the app records acceptance and a later `GET_CUR`,
then asks the operator to verify whether the physical gimbal moved. A success
response may reflect physical movement, digital PTZ, no visible effect, or a
firmware-dependent behavior.

### Diagnostics are useful only when safe to share

The app is local-first and has no network, account, telemetry, or automatic
persistence path. Identifiers are needed transiently for matching but are not
shown or exported by default. Raw Extension Unit bytes are local diagnostic
data and require deliberate handling before sharing.

## Current evidence boundary

| Area | Current status | Next evidence needed |
| --- | --- | --- |
| USB Webcam Mode identity | Observed on a single sanitized Pocket 4 sample | More firmware, cable, hub, and macOS combinations |
| AVFoundation preview | Operator-reported working in a local session | Recorded matrix on a clean signed build |
| Multiple DJI camera matching | Unverified | A controlled test with another DJI camera connected at the same time |
| Zoom / Pan / Tilt / Roll | Advertised by descriptor; guarded implementation exists | Per-control `GET_*`, `SET_CUR`, read-back, and visible-result records |
| Physical gimbal effect | Unverified per control | Human observation recorded for each tested request |
| DJI Extension Unit semantics | Unverified | Read-only snapshot diffs correlated with controlled camera changes |
| Public distribution | Unverified | Tests, CI, license, Developer ID signing, notarization, clean-machine test |
| Mac App Store / sandbox support | Unverified | Separate entitlement and hardware compatibility investigation |

## Maintaining this document

Add durable decisions and corrected history here, but place raw test detail in
[EXPERIMENT_LOG.md](EXPERIMENT_LOG.md). When a previous statement is corrected,
append a dated correction rather than silently rewriting the evidence trail.
Never upgrade an operator report, descriptor advertisement, or successful
build into a compatibility claim without a reproducible test record.
