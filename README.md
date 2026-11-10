# PiKVM Console

A native macOS app (macOS 14+) for remote control and management of [PiKVM](https://docs.pikvm.org) devices.

## Status

Step 2 of 4 in progress: the console works over MJPEG; H.264 and audio (WebRTC) come next.

1. **Foundation**: device list, LAN → Tailscale fallback, Keychain credentials, kvmd API client, PiKVM Switch ports as targets, per-port mouse mode. ✅
2. **Console**: MJPEG video, keyboard and mouse (absolute and relative), full screen. ✅ H.264 video and audio over WebRTC: next.
3. **Management**: ISO upload and mounting, ATX power, switch port control.
4. **Polish**: menu bar quick view, shortcuts, signed build.

## Building

```sh
brew install xcodegen
xcodegen generate
open PiKVMConsole.xcodeproj
```

Run the library tests without Xcode with `swift test --package-path Packages/PiKVMKit`.

## Layout

- `Packages/PiKVMKit`: models, the kvmd client (`/api/auth`, `/api/info`, `/api/atx`, `/api/hid`, `/api/switch`, `/api/ws`), Keychain and JSON storage.
- `PiKVMConsole`: the SwiftUI app.

## Using the console

- Select a machine and choose **Open Console** (⌘↩). Each machine gets its own window; ⌃⌘F toggles full screen.
- **Absolute mouse**: the pointer follows your cursor. **Relative mouse**: click the video to capture the cursor, press Control+Option to release it. The mode is saved per machine (per Switch port).
- While the console has focus, Command shortcuts go to the remote machine (⌘ is sent as the Windows/Super key). macOS keeps a few for itself, such as ⌘Tab; use the **Send Keys** menu for Ctrl+Alt+Del and similar.
- Keys are sent by physical position, so the remote machine's keyboard layout decides the character.

## Updating a PiKVM

**Update PiKVM OS…** (toolbar, or right-click a device) runs `pikvm-update` through the PiKVM's web terminal, so it works over the same HTTPS connection as everything else and needs no SSH access. It asks for the device's root password, which can be saved in the Keychain. The update is started detached from the terminal and its log is followed, so a dropped connection or closing the window doesn't interrupt it. The PiKVM reboots itself when updates were installed.

Requires the web terminal (`kvmd-webterm`), which PiKVM OS enables by default.

## Notes

- PiKVMs use self-signed certificates. The app pins the certificate's SHA-256 the first time it connects and rejects a different one after that. Editing a device's addresses clears the pin.
- If 2FA is on, append the current TOTP code to the password.
- Relative mouse mode needs kvmd's alternate mouse enabled. Without it, `usb_rel` isn't offered.
- Machines behind a PiKVM Switch use the switch's ATX endpoints (`/api/switch/atx/*`).
