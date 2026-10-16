# Security Policy

## What GlobeFlip does with your input

GlobeFlip observes keyboard events through a CGEvent tap in order to detect a
standalone Globe/Fn tap. This requires the macOS Input Monitoring permission.
The project commits to the following:

- Events are observed, never modified or injected.
- No typed keys or text are stored. GlobeFlip writes no logs.
- No network requests of any kind. No analytics, telemetry, or update checks.
- Only public user-space APIs. IOKit HID is used only to notice keyboards
  connecting or disconnecting; no HID input values are read. No root, setuid,
  DriverKit, virtual device, private API, or helper entitlement.
- Release builds enable Hardened Runtime.

Any pull request that weakens these guarantees will be declined.

## Supported versions

Only the latest release receives fixes.

## Reporting a vulnerability

Please do not open a public issue for security problems. Use GitHub's private
vulnerability reporting on this repository, or email
orbismartyrer@gmail.com. Include steps to reproduce and the macOS version.
You should receive a response within 7 days.
