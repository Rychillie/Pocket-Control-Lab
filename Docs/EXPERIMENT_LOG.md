# Pocket Control Lab Experiment Log

## Why this log exists

This file is the evidence trail between an engineering experiment and a public product claim. It records what was attempted, what the camera returned, and what a human actually observed. It must never turn a descriptor bit, a USB success code, or a recollection into an unsupported compatibility promise.

Add new entries below the existing ones. Keep source logs privately, then copy only redacted, reproducible facts here. Do not publish serials, USB location or topology IDs, camera/CMIO IDs, product suffixes, usernames, hostnames, absolute paths, screenshots with identifiers, or raw Extension Unit bytes by default.

## Status vocabulary

| Status | Use when |
| --- | --- |
| `observed-hardware` | A fact was captured from a physical device. |
| `code-build-verified` | Source or build behavior was checked without a hardware claim. |
| `operator-reported` | A person described a result without a complete reproducible record. |
| `blocked-by-macos` | A safe API/driver limitation prevented the requested observation. |
| `unsupported` | The current device/session clearly rejects a known safe request. |
| `inconclusive` | The result is incomplete, ambiguous, or needs a controlled repeat. |

## Baseline records

### EXP-2026-08-22-USB-DESCRIPTOR

| Field | Record |
| --- | --- |
| Status | `observed-hardware` |
| Scope | USB descriptor and IORegistry observation only |
| Device | Sanitized DJI Osmo Pocket 4 Webcam Mode sample; VID `0x2CA3`, PID `0x0023` |
| Observed interfaces | UVC + UAC1, USB High-Speed |
| Advertised Camera Terminal controls | Zoom Absolute, Pan/Tilt Absolute, Roll Absolute |
| Observed DJI Extension Unit | Unit 6; selectors 1–3 are candidates because `bmControls = 0x07` conflicts with `bNumControls = 2` |
| Requests sent | None beyond descriptor/registry observation; no UVC `GET_*`, no `SET_CUR`, no vendor request |
| Conclusion | The device advertised controls worth safely investigating; no operational behavior was established |

### EXP-2026-09-02-LOCAL-INTERACTIVE-REPORT

| Field | Record |
| --- | --- |
| Status | `operator-reported` |
| Scope | Local interactive use of the macOS laboratory app |
| Reported result | Live preview worked, and the operator could position and adjust the camera from the Mac without touching it |
| Missing conditions | Exact macOS version, app revision, camera firmware, cable/hub, per-control payloads, response/read-back values, and observation classification |
| Conclusion | Strong motivation to continue product work; not sufficient as a per-control support matrix |

## Minimum test matrix

Every new hardware session should capture the following at a minimum. Use generic versions such as `macOS 26.x` and `Pocket firmware x.y.z`; do not publish machine-specific identifiers.

| Field | Required record |
| --- | --- |
| Test ID / date | Stable ID and local date |
| App revision | Git commit or release version after the repository exists |
| macOS / Mac architecture | OS version and Apple silicon or Intel, without a machine serial/name |
| Camera firmware | Version reported by the camera, if the operator can verify it safely |
| Connection | Direct USB-C or generic hub/dock type; never location IDs |
| Camera state | Webcam Mode, battery/power state if relevant, and whether other camera apps were closed |
| Profile state | Verified Pocket 4, Pocket-family-only, or no match |
| Preview | Permission state, selected format, and result/error |
| Control discovery | `GET_INFO`, `GET_MIN`, `GET_MAX`, `GET_RES`, `GET_DEF`, and `GET_CUR` results or safe error |
| Write attempt | Explicit write opt-in state, old value, requested value, response, and post-write `GET_CUR` |
| Human observation | Physical gimbal movement, digital PTZ/crop, no visible effect, error, or inconclusive |
| Reconnect behavior | Whether safe state and pending writes were cleared after disconnect/re-enumeration |
| Notes | Redacted context needed to reproduce an ambiguity |

## Safe test procedure

1. Connect one verified Pocket 4 by USB-C and select Webcam Mode.
2. Start with UVC writes disabled and record USB/profile/preview state.
3. Run read-only discovery. Treat a failed `GET_*`, stall, short transfer, or unavailable macOS user client as a valid result; do not work around it by taking driver ownership.
4. If discovery returns a complete valid range and the operator is prepared to observe the camera, explicitly enable UVC writes.
5. Change one standard control slowly, within its returned range and step. The app rate-limits requests; do not add manual scripts or raw requests to increase the rate.
6. Record `SET_CUR` acceptance/error and a later `GET_CUR`. For Pan/Tilt, ensure the unchanged axis was preserved.
7. Record the visible result separately from the USB result. Do not infer physical movement from a successful request.
8. Disable writes after the test. Disconnect/reconnect once and verify that write permission and stale work are cleared.

## Control result template

Copy this section for one control at a time. Use `not recorded` rather than guessing.

```text
Test ID:
Date:
Status: observed-hardware | blocked-by-macos | unsupported | inconclusive

Environment:
  App revision:
  macOS / architecture:
  Pocket firmware:
  Connection: direct cable | hub/dock (generic description)
  Camera state:

Profile and preview:
  Profile state:
  Camera permission:
  Preview / format:

Control:
  Name: Zoom Absolute | Pan/Tilt Absolute | Roll Absolute
  GET_INFO:
  GET_MIN:
  GET_MAX:
  GET_RES:
  GET_DEF:
  GET_CUR before write:

Write (only after explicit in-app opt-in):
  Requested value:
  SET_CUR result:
  GET_CUR after write:

Human observation:
  Result: physical movement | digital PTZ/crop | no visible effect | error | inconclusive
  Notes:

Privacy review:
  Identifiers and raw payloads removed: yes | no (do not publish until yes)
```

## Extension Unit snapshot template

The Extension Unit is observation-only. The app may use `GET_INFO`, `GET_LEN`, and valid-length `GET_CUR` for selectors 1–3. Never add `SET_CUR`, a vendor-specific request, or a guessed payload to this log or the codebase.

```text
Test ID:
Status:
Camera setting changed manually on device:
Selector:
GET_INFO result:
GET_LEN result:
GET_CUR available: yes | no
Snapshot diff recorded: yes | no
Public payload policy: redacted by default
Interpretation: none unless independently evidenced
```

When a snapshot diff is useful to share, describe changed byte offsets and their before/after values only after confirming that the payload contains no personal/device-specific data. A byte difference is a correlation, not a protocol definition.

## Questions this log must eventually answer

- Which macOS, firmware, cable, and hub conditions expose a usable safe UVC transport?
- What valid ranges and resolutions does each standard control return?
- Does each successful write yield the requested value on a later `GET_CUR`?
- Is the visible result physical gimbal movement, digital PTZ, no effect, or something that depends on camera state?
- What disconnect and re-enumeration behavior is safe and predictable?
- Which read-only Extension Unit bytes change with a manually altered camera setting, without assigning semantics too early?
