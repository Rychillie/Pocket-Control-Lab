# PocketInspector

This folder contains two small, read-only command-line investigation tools for
the physically connected DJI Osmo Pocket 4 in Webcam Mode. They are
diagnostics, not a camera controller.

`pocket_usb_descriptor_inspector.c` inspects the USB descriptor cache.
`main.swift` inventories the AVFoundation and CoreMediaIO layers visible to
the current process.

## Safety boundary

The USB descriptor tool is intentionally descriptor-only. It does **not** call
any of these APIs:

- `USBDeviceOpen` or `USBDeviceOpenSeize`
- `DeviceRequest` / `DeviceRequestTO`
- `SetConfiguration`, `ResetDevice`, or re-enumeration APIs
- endpoint/pipe reads or writes
- UVC `GET_*` or `SET_CUR` requests

It matches the device by `VID 0x2CA3` and `PID 0x0023`, reads already-published
IORegistry properties, and calls only
`IOUSBDeviceInterface::GetConfigurationDescriptorPtr(0)`. Apple's installed
`IOUSBLib.h` documents that method as not requiring the device to be open. The
source contains no raw USB request API and never calls `USBDeviceOpen`; it also
makes no claim about how the framework fulfils that pointer internally if it is
reached. It does not take over the UVC interface deliberately, change a
setting, or start video capture.

The tool prints:

- cached device identity fields;
- the complete raw Configuration Descriptor in hexadecimal;
- every standard Interface, Interface Association, and Endpoint Descriptor;
- all class-specific UVC Video Control and Video Streaming descriptors;
- Camera Terminal and Processing Unit control bitmaps;
- Extension Unit GUID, input source IDs, advertised control bitmap, and raw
  descriptor;
- advertised UVC formats, frame sizes, and frame intervals.

## Privacy defaults

The tools redact device-specific identifiers by default so their output is
safer to attach to an issue or discussion. The USB inspector hides the product
string, serial number, and USB location; the AVFoundation/CoreMediaIO inspector
hides camera and CMIO unique IDs. To reveal them for a local diagnostic that
will not be shared, pass `--include-identifiers` explicitly.

## Build

From this directory:

```bash
xcrun clang -std=c11 -Wall -Wextra -Wpedantic \
  Tools/PocketInspector/pocket_usb_descriptor_inspector.c \
  -framework IOKit -framework CoreFoundation \
  -o /private/tmp/PocketUSBInspector
```

## Run

With the Pocket 4 physically connected in Webcam Mode:

```bash
/private/tmp/PocketUSBInspector
```

To include device-specific identifiers in local output:

```bash
/private/tmp/PocketUSBInspector --include-identifiers
```

The process must be allowed to inspect USB devices normally. If the device is
not found, confirm that macOS lists `DJI` with `VID 0x2CA3` and `PID 0x0023` in
the IORegistry. The tool deliberately stops instead of trying to reset,
reconfigure, or claim the device.

On the current macOS installation, the device identity section succeeds but
macOS returns `0xE00002BE` (`kIOReturnNoResources`) when it is asked to create
the legacy `IOUSBLib` plug-in user client while `UVCAssistant` owns the active
UVC interfaces. That is an expected safe failure mode: the program exits
before `QueryInterface` or `GetConfigurationDescriptorPtr(0)`. It must not be
changed to use `USBDeviceOpenSeize`, reset the device, or terminate
`UVCAssistant` merely to work around that refusal.

## Scope limitation

This first tool establishes what the descriptor *advertises*. It does not
probe value ranges or current values via UVC `GET_INFO`, `GET_MIN`, `GET_MAX`,
`GET_RES`, `GET_DEF`, or `GET_CUR`; those are additional USB control transfers
and require an explicit review before being added. It never sends `SET_CUR`.

## AVFoundation / CoreMediaIO inspector

`main.swift` uses only device enumeration and property getters. It never
creates an `AVCaptureSession`, starts capture, locks configuration, calls a
setter, or issues a USB request. When a camera is visible, it prints identity,
formats, frame-rate ranges, safe AVFoundation support flags, and CoreMediaIO
device/control objects.

Build and run:

```bash
xcrun swiftc \
  -module-cache-path /private/tmp/PocketInspectorSwiftModuleCache \
  -Xcc -fmodules-cache-path=/private/tmp/PocketInspectorClangModuleCache \
  -framework AVFoundation \
  -framework CoreMediaIO \
  -framework CoreMedia \
  Tools/PocketInspector/main.swift \
  -o /private/tmp/PocketInspector

/private/tmp/PocketInspector
```

To include camera/CMIO unique IDs in local output:

```bash
/private/tmp/PocketInspector --include-identifiers
```

During this investigation the current process had video authorization
`denied`, and its AVFoundation discovery showed zero visible cameras while the
CoreMediaIO getter yielded no visible device IDs. This is a process-visibility
observation, not proof that the physically connected UVC camera is absent; the
USB/UVCAssistant evidence remains authoritative for hardware enumeration.
