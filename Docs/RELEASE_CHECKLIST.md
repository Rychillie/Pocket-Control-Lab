# Public release checklist

This checklist deliberately separates source-code readiness from a signed
macOS release. Do not mark the app as released until every applicable item is
verified on the exact artifact users will download.

## Source hygiene

- [x] Ignore Finder metadata, Xcode user state, build products, archives,
  logs, and local environment files.
- [x] Remove known machine paths, USB location/topology, serial, and
  device-specific product suffixes from public documentation.
- [x] Redact raw Extension Unit data and potentially identifying diagnostic
  details in copied/saved logs by default.
- [x] Make the diagnostic CLIs redact device and camera identifiers by default.
- [x] Use a neutral bundle ID in source: `org.pocketcontrollab.PocketControlLab`.
- [ ] Select and add a repository-wide open-source license. Do not infer this
  choice from an old file header.
- [ ] Configure a private vulnerability-reporting channel and update
  `SECURITY.md` with it.

## Product and verification

- [ ] Add an app icon, copyright/attribution information, and final release
  notes.
- [ ] Add a test target covering protocol whitelist, write latch, generic
  Pocket-family blocking, connection transitions, and export redaction.
- [ ] Run unit tests and static analysis from a clean checkout.
- [ ] Test camera permission denied/restricted, USB reconnect/re-enumeration,
  direct-transport denial by `UVCAssistant`, and a second DJI camera connected
  at the same time.
- [ ] Record a repeatable hardware matrix: macOS, app version, Pocket
  firmware, cable/hub, preview result, GET values, SET result, GET-after-set,
  and human observation of physical versus digital movement.

## Distribution

- [ ] Enroll/configure the intended Apple Developer team and Developer ID
  Application certificate. The source tree intentionally contains no personal
  signing identity or team ID.
- [ ] Archive a Release build with Hardened Runtime, `get-task-allow` absent,
  a timestamped Developer ID signature, and dSYM output.
- [ ] Verify the exact archive with `codesign --verify --deep --strict` and
  inspect its entitlements.
- [ ] Submit the signed app for notarization, staple the result, and check it
  with Gatekeeper (`spctl`) on a clean macOS account or machine.
- [ ] Re-test the notarized build with a real Pocket before publishing. Do not
  assume an ad-hoc debug build proves Developer ID behavior.
- [ ] Create the public archive from a clean Git checkout or `git archive`,
  not from an Xcode working directory.

## Current local artifact evidence (2026-09-02)

- [x] A universal Release build (`arm64` + `x86_64`) completed successfully.
- [x] `codesign --verify --deep --strict` passed for that local artifact; its
  bundle ID is `org.pocketcontrollab.PocketControlLab` and its signature has
  the Hardened Runtime flag.
- [x] No entitlements were emitted for the local artifact, including no
  `get-task-allow` entitlement.
- [x] Gatekeeper (`spctl`) rejected the local artifact because it is ad-hoc,
  has no Team ID, and is not notarized. This is the expected pre-distribution
  state, not a release pass.

## Distribution choice

Developer ID distribution is the current working hypothesis because the app
uses IOKit/IOUSBLib behavior that has not been validated inside the Mac App
Sandbox. A Mac App Store path must first prove that its sandbox entitlements
preserve the required safe, non-seizing UVC behavior.
