# Changelog

## 1.1.0 - 2026-10-23

- Restored PiP startup on TVer 7.2.4.
- Fixed PiP closing immediately after returning to the Home Screen.
- Restored inline playback when returning to the app or using the PiP return control.

## 1.0.0 - 2026-08-25

- Initial public release.
- Added automatic PiP when returning to the Home Screen.
- Added PiP and Control Center media commands.
- Added bounded silent-audio keepalive with failure and foreground cleanup.
- Added TrollStore and standard sideloading build support.
- Removed device-specific `UISupportedDevices` metadata during patching.
- Added a single-output `build.sh` and a manual GitHub Actions build workflow.
