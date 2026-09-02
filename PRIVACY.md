# Privacy

Pocket Control Lab is designed for local hardware investigation. It has no
accounts, network client, analytics SDK, telemetry service, cloud sync, or
automatic recording.

## Data used while the app is open

The app reads published macOS USB registry properties to detect a compatible
camera. It uses vendor/product IDs, product text, a registry identifier, and a
USB location internally to identify the connection and route only the
whitelisted Pocket 4 protocol. It does **not** read the USB serial number.

AVFoundation may provide an opaque camera unique ID. The app keeps that ID in
memory only to keep the preview and CoreMediaIO observation associated with the
same camera; it does not show it in the UI, write it to the log, or include it
in exported investigations.

The visible app shows non-unique diagnostic data such as model, manufacturer,
VID/PID, connection state, supported formats, UVC responses, and USB link
speed. Treat any hardware diagnostic as potentially sensitive when sharing a
screenshot.

## Logs and snapshots

The on-screen investigation log can show raw Extension Unit response bytes so
an operator can compare them locally. **Copy Log** and **Save Investigation**
redact those raw payloads and potentially identifying diagnostic details by
default. The operator must turn on **Include raw Extension Unit data and
sensitive diagnostic details in copied/saved logs** to export them.

The app does not persist logs, camera frames, snapshots, USB descriptors, or
settings automatically. Saving is an explicit user action through the macOS
save panel.

The command-line inspectors under `Tools/PocketInspector` redact product,
serial, USB location, AVFoundation unique IDs, and CoreMediaIO unique IDs by
default. Pass `--include-identifiers` only for a local, controlled diagnostic
session; do not attach that output to a public issue without reviewing it.

## Contributor rules

- Never commit `.DS_Store`, `xcuserdata`, DerivedData, a local archive, or an
  exported investigation log.
- Redact serial numbers, USB topology/location values, camera/CMIO IDs, host
  names, home-directory paths, and raw Extension Unit payloads from issues,
  screenshots, fixtures, and documentation unless their publication is
  explicitly necessary and approved.
- Create a release archive from a clean Git checkout or `git archive`, not by
  compressing a development folder; macOS extended attributes and Finder state
  can otherwise leak local metadata.

This document describes the current code path, not a promise about future
features. Update it with every new diagnostic field or export option.
