# PiKVM Console

A native macOS app (macOS 14+) for remote control and management of [PiKVM](https://docs.pikvm.org) devices.

## Status

Step 2 of 4: the console, with H.264 video and audio over WebRTC and MJPEG as a fallback.

1. **Foundation**: device list, LAN → Tailscale fallback, Keychain credentials, kvmd API client, PiKVM Switch ports as targets, per-port mouse mode. ✅
2. **Console**: H.264 video and audio (WebRTC), MJPEG fallback, keyboard and mouse (absolute and relative), full screen. ✅
3. **Management**: ISO upload and mounting, ATX power, switch port control.
4. **Polish**: menu bar quick view, shortcuts, signed build.

## Building

```sh
brew install xcodegen
xcodegen generate
open PiKVMConsole.xcodeproj
```

Run the library tests without Xcode with `swift test --package-path Packages/PiKVMKit`.

### Signing (stops the repeated Keychain prompt)

Without a signing team, Xcode signs each build "to run locally", and every rebuild looks like a new app to the Keychain. macOS then asks again for permission to read the saved device passwords ("PiKVM Console wants to use your confidential information stored in com.badamsz.PiKVMConsole"). To sign with a stable identity:

```sh
cp Config/Local.xcconfig.example Config/Local.xcconfig
# edit Config/Local.xcconfig and set DEVELOPMENT_TEAM to your 10-character team ID
xcodegen generate
```

A free personal team works. `Config/Local.xcconfig` is ignored by git and survives `xcodegen generate`. The first launch after this asks once more; choose **Always Allow** and it stays quiet from then on.

## Layout

- `Packages/PiKVMKit`: models, the kvmd client (`/api/auth`, `/api/info`, `/api/atx`, `/api/hid`, `/api/switch`, `/api/ws`), Keychain and JSON storage.
- `PiKVMConsole`: the SwiftUI app.

## Using the console

- Select a machine and choose **Open Console** (⌘↩). Each machine gets its own window; ⌃⌘F toggles full screen. In full screen the toolbar is hidden so the video fills the display. **View → Hide Toolbar in Full Screen** (⌃⌘T) brings it back or hides it again; move the pointer to the top edge to reach the menu bar.
- **Absolute mouse**: the pointer follows your cursor. **Relative mouse**: click the video to capture the cursor, press Control+Option to release it. The mode is saved per machine (per Switch port).
- While the console has focus, Command shortcuts go to the remote machine (⌘ is sent as the Windows/Super key). macOS keeps a few for itself, such as ⌘Tab; use the **Send Keys** menu for Ctrl+Alt+Del and similar.
- When a machine has ATX wired up (directly or through the Switch), the console toolbar shows its power and disk-activity lights and a **Power** menu with Power On, Shut Down, Reset and Force Off. Reset and Force Off ask first. Machines without ATX don't show them.
- **Video** menu: H.264 (WebRTC) is the default and carries audio; MJPEG is the fallback and is used automatically if H.264 can't connect. The **Audio** menu appears when the PiKVM offers audio.
- **Paste as typing** (⌥⌘V, or the Send Keys menu) types the Mac clipboard's text on the remote machine. Pick the typing speed in the same menu; slower speeds suit BIOS screens and laggy machines. Text longer than 200 characters or with line breaks asks first. The PiKVM maps characters using its own keymap setting (US by default), so the remote machine's layout must match it.
- Keys are sent by physical position, so the remote machine's keyboard layout decides the character.

## Updating a PiKVM

**Update PiKVM OS…** (toolbar, or right-click a device) runs `pikvm-update` through the PiKVM's web terminal, so it works over the same HTTPS connection as everything else and needs no SSH access. It asks for the device's root password, which can be saved in the Keychain. The update is started detached from the terminal and its log is followed, so a dropped connection or closing the window doesn't interrupt it. The PiKVM reboots itself when updates were installed.

Requires the web terminal (`kvmd-webterm`), which PiKVM OS enables by default.

## Notes

- PiKVMs use self-signed certificates. The app pins the certificate's SHA-256 the first time it connects and rejects a different one after that. Editing a device's addresses clears the pin.
- If 2FA is on, append the current TOTP code to the password.
- Relative mouse mode needs kvmd's alternate mouse enabled. Without it, `usb_rel` isn't offered.
- Machines behind a PiKVM Switch use the switch's ATX endpoints (`/api/switch/atx/*`).
