# Security policy

Pocket Control Lab is pre-release hardware-control software. Its most important
security boundary is that unknown USB/vendor commands are never sent and UVC
writes require a deliberate local opt-in.

## Supported boundary

- Only the verified Pocket 4 USB profile (the known `VID 2CA3`/`PID 0023`
  pair plus an observed normalized `OsmoPocket4` product token) can reach the
  direct UVC bridge.
- The bridge permits UVC reads for the three whitelisted Camera Terminal
  controls and read-only DJI Extension Unit inspection.
- `SET_CUR` is permitted only for Zoom Absolute, Pan/Tilt Absolute, and Roll
  Absolute after the in-app safety latch is enabled.
- The bridge has no API for Extension Unit writes, vendor requests, firmware
  update/DFU, USB reset/configuration, interface seize, Bluetooth, Wi-Fi, or
  DJI Mimo/DUML traffic.

## Reporting a vulnerability

A private public-release reporting channel has not been configured yet. Until
one exists, do not publish a possible vulnerability together with serials,
USB locations, raw Extension Unit payloads, logs, or camera screenshots in a
public issue. Contact a project maintainer through an agreed private channel
and include a minimal redacted reproduction.

Before the first public release, maintainers must configure GitHub private
vulnerability reporting or publish a monitored security contact here. This is
a release blocker, not an optional documentation task.

## Scope for reports

Useful reports include a way to bypass the UVC write latch, any path that can
send an unknown USB request, exposure of locally identifying data in a default
export, unsafe behavior during disconnect/re-enumeration, and signing or
notarization weaknesses in a distributed build.
