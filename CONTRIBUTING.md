# Contributing

Thank you for helping make Pocket Control Lab safe and reproducible.

## Local development

Open `PocketControlLab.xcodeproj` in Xcode and build the
`PocketControlLab` scheme for **My Mac**. A connected Pocket is optional for a
compile-only check. Never use a personal investigation log, descriptor dump,
or screenshot as a test fixture without redacting it first.

Run the hardware-free test suite with:

```sh
xcodebuild test -project PocketControlLab.xcodeproj -scheme PocketControlLab \
  -configuration Debug -destination "platform=macOS,arch=$(uname -m)" \
  -derivedDataPath .build/PocketControlLabDerivedData \
  CODE_SIGNING_ALLOWED=NO -quiet
```

## Hardware safety rules

Do not add any of the following without a separately reviewed protocol design,
hardware test plan, and explicit maintainer approval:

- DJI Extension Unit `SET_CUR` or any vendor-specific request;
- firmware, DFU, memory write, device reset, configuration change, forced
  interface ownership, or driver termination;
- Bluetooth, Wi-Fi, DJI Mimo, DUML, or background control behavior;
- a default-enabled UVC write or a control outside Zoom/Pan/Tilt/Roll.

Preserve the direct bridge's fail-closed behavior if macOS owns the camera
interface. Do not work around `UVCAssistant` by killing, disabling, or seizing
it.

## Data hygiene

Read [PRIVACY.md](PRIVACY.md) before opening an issue or pull request. Keep
machine-specific artifacts out of Git, including Xcode `xcuserdata`, Finder
metadata, build products, Archives, logs, and exported investigations.

Use a clean checkout to review the first commit and release archive. Do not
copy a working Xcode directory directly into a public repository.
