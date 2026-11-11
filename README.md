# PiKVM Console

A native macOS app (macOS 14+) for remote control and management of [PiKVM](https://docs.pikvm.org) devices.

## Status

All four planned steps are in. Nothing has been through a wide range of hardware yet, so expect rough edges.

1. **Foundation**: device list, LAN → Tailscale fallback, Keychain credentials, kvmd API client, PiKVM Switch ports as targets, per-port mouse mode. ✅
2. **Console**: H.264 video and audio (WebRTC), MJPEG fallback, keyboard and mouse (absolute and relative), full screen. ✅
3. **Management**: ISO upload and mounting ✅, ATX power ✅, switch port control ✅.
4. **Polish**: menu bar quick view, screen previews, shortcuts, release build script. ✅

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

### Release build

`scripts/release.sh` builds a Release copy into `dist/`. It needs `Config/Local.xcconfig` (above).

- `scripts/release.sh` signs with your development identity. Good for your own Macs.
- `scripts/release.sh --notarize` signs with Developer ID and has Apple notarize it, so it opens on any Mac without a warning. This needs a paid Apple Developer Program membership and notary credentials stored once with `xcrun notarytool store-credentials pikvm-console`; the script's header has the full command.

## Layout

- `Packages/PiKVMKit`: models, the kvmd client (`/api/auth`, `/api/info`, `/api/atx`, `/api/hid`, `/api/msd`, `/api/switch`, `/api/ws`), Keychain and JSON storage.
- `PiKVMConsole`: the SwiftUI app.

## Menu bar and previews

- The menu bar item lists every machine with its power state. Each one has Open Console, Show in Main Window and, with ATX, the power actions. Turn the item off in **Settings** (⌘,).
- A machine's page shows a still picture of its screen. **Refresh** takes a new one, and double-clicking it opens the console. PiKVM only runs its video while someone is watching, so a refresh may take a few seconds while the video starts. Behind a Switch, only the active port can be refreshed.

## Using the console

- Select a machine and choose **Open Console** (⌘↩). Each machine gets its own window; ⌃⌘F toggles full screen. In full screen the toolbar is hidden so the video fills the display. **View → Hide Toolbar in Full Screen** (⌃⌘T) brings it back or hides it again; move the pointer to the top edge to reach the menu bar.
- **Absolute mouse**: the pointer follows your cursor. **Relative mouse**: click the video to capture the cursor, press Control+Option to release it. The mode is saved per machine (per Switch port).
- While the console has focus, Command shortcuts go to the remote machine (⌘ is sent as the Windows/Super key). macOS keeps a few for itself, such as ⌘Tab; use the **Send Keys** menu for Ctrl+Alt+Del and similar.
- When a machine has ATX wired up (directly or through the Switch), the console toolbar shows its power and disk-activity lights and a **Power** menu with Power On, Shut Down, Reset and Force Off. Reset and Force Off ask first. Machines without ATX don't show them.
- **Video** menu: H.264 (WebRTC) is the default and carries audio; MJPEG is the fallback and is used automatically if H.264 can't connect. The **Audio** menu appears when the PiKVM offers audio.
- **Paste as typing** (⌥⌘V, or the Send Keys menu) types the Mac clipboard's text on the remote machine. Pick the typing speed in the same menu; slower speeds suit BIOS screens and laggy machines. Text longer than 200 characters or with line breaks asks first. The PiKVM maps characters using its own keymap setting (US by default), so the remote machine's layout must match it.
- The **Console** menu has shortcuts for the window in front: ⌃⌘⌫ sends Ctrl+Alt+Del, ⌃⌘M switches the mouse mode, ⌃⌘I opens virtual media, and ⌃⌘R reconnects. These Control+Command combinations stay on the Mac and are not sent to the remote machine.
- Keys are sent by physical position, so the remote machine's keyboard layout decides the character.

## Virtual media (ISOs and disk images)

**Manage Images…** on a machine's page, or the disc button in a console's toolbar, opens the PiKVM's virtual drive.

- **Upload Image…** copies an ISO or disk image from the Mac to the PiKVM, with progress and a Cancel button. A cancelled or failed upload leaves nothing behind.
- Pick an image, choose **CD/DVD** or **Flash drive**, and press **Connect**. The remote machine sees it as a USB drive. **Eject** unplugs it.
- A flash drive can be made writable. A CD/DVD is always read-only.
- Uploading, deleting and changing the image all need the drive ejected first; that is a PiKVM rule.
- Each PiKVM has one virtual drive. Behind a Switch it goes to whichever port is active.

## Updating a PiKVM

**Update PiKVM OS…** (toolbar, or right-click a device) runs `pikvm-update` through the PiKVM's web terminal, so it works over the same HTTPS connection as everything else and needs no SSH access. It asks for the device's root password, which can be saved in the Keychain. The update is started detached from the terminal and its log is followed, so a dropped connection or closing the window doesn't interrupt it. The PiKVM reboots itself when updates were installed.

Requires the web terminal (`kvmd-webterm`), which PiKVM OS enables by default.

## Notes

- Certificates: PiKVMs ship with self-signed certificates. The app pins a self-signed certificate's SHA-256 the first time it connects and rejects a different one after that.
- If a PiKVM's certificate is issued by a certificate authority this Mac trusts (for example an internal step-ca that the PiKVM renews from with ACME), the app notices on the first connection and from then on accepts any certificate that CA issues for the device, so renewals keep working. It also stops accepting certificates the Mac doesn't trust for that device. A certificate issued for one of the device's names (say its LAN name) is accepted when connecting through another (say Tailscale). Install your CA's root certificate in Keychain Access and set it to Always Trust. The machine's page shows which kind of certificate the device uses.
- Editing a device's addresses forgets what it learned about the certificate.
- If 2FA is on, append the current TOTP code to the password.
- Relative mouse mode needs kvmd's alternate mouse enabled. Without it, `usb_rel` isn't offered.
- Machines behind a PiKVM Switch use the switch's ATX endpoints (`/api/switch/atx/*`). A Switch port's page can also blink that port's light on the Switch, to find it on the hardware.
