# PiKVM Console

A native macOS app (macOS 14+) for remote control and management of [PiKVM](https://docs.pikvm.org) devices, and of [Sipeed NanoKVM](https://wiki.sipeed.com/hardware/en/kvm/) devices (NanoKVM, NanoKVM Pro, NanoKVM Go).

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

Run the library tests without Xcode with `swift test --package-path Packages/PiKVMKit`. The on-device configuration helper has its own tests: `python3 -m unittest discover -s Packages/PiKVMKit/Tests/HelperTests` (needs `pip install ruamel.yaml pyyaml`).

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

### Release builds in CI

`.github/workflows/release.yml` builds Release on GitHub's macOS runners.

- Every pull request and push to `main` produces an ad-hoc signed build, attached to the workflow run as an artifact (`.zip`, `.dmg`, checksums). macOS blocks its first launch; use **Open Anyway** in System Settings > Privacy & Security.
- Pushing a tag such as `v0.2.0` (or running the workflow by hand from the Actions tab) signs with Developer ID and notarizes when the secrets below exist. A tag also publishes a GitHub Release with the files. A tag with a hyphen (`v0.2.0-beta.1`) becomes a pre-release. The version in the tag becomes the app's version.

Without the secrets, tagged builds still publish, unsigned. To sign and notarize, add these under Settings > Secrets and variables > Actions (all need a paid Apple Developer Program membership):

| Secret | What it is |
| --- | --- |
| `APPLE_TEAM_ID` | Your 10-character team ID (developer.apple.com > Account > Membership details). |
| `MACOS_CERTIFICATE_P12_BASE64` | A **Developer ID Application** certificate with its private key. Create it in Xcode > Settings > Accounts > Manage Certificates > + > Developer ID Application, export it from Keychain Access as a `.p12`, then `base64 -i DeveloperID.p12 \| pbcopy`. |
| `MACOS_CERTIFICATE_PASSWORD` | The password you set when exporting the `.p12`. |
| `NOTARY_API_KEY_P8_BASE64` | An App Store Connect API key for notarization: App Store Connect > Users and Access > Integrations > Team Keys, role **Developer**. Download the `.p8` (only possible once), then `base64 -i AuthKey_XXXX.p8 \| pbcopy`. |
| `NOTARY_API_KEY_ID` | That key's Key ID. |
| `NOTARY_API_ISSUER_ID` | The Issuer ID shown above the keys list. |

## Layout

- `Packages/PiKVMKit`: models, the kvmd client (`/api/auth`, `/api/info`, `/api/atx`, `/api/hid`, `/api/msd`, `/api/switch`, `/api/ws`), the NanoKVM client (`NanoKVMClient.swift`), Keychain and JSON storage, and network discovery (`Discovery/`: Bonjour, subnet scan, HTTP fingerprints, Tailscale API).
- `PiKVMConsole`: the SwiftUI app.

## Finding devices on the network

**File → Find Devices on Network…** (⇧⌘F, or the antenna button in the sidebar) lists the KVMs it can find, and **Add…** opens the device editor with the name, model and addresses filled in. Devices you already have are marked Added.

- **Bonjour** runs while the window is open. PiKVM OS announces `_pikvm._tcp` with its model once Avahi is on: add `ENABLE_AVAHI=1` to `/boot/pikvm.txt` (or run `systemctl enable --now avahi-daemon` after `rw`). NanoKVMs answer Bonjour under their host name and are recognised by their web page.
- **Network scan** checks every address on the Mac's local networks (narrowed to the /24 around the Mac on bigger networks) for a web server on ports 443 and 80, and recognises kvmd (PiKVM) and NanoKVM by what they return to a visitor who isn't logged in. No passwords are sent. The first time, macOS asks to allow local network access; allow it and scan again.
- **Tailscale** lists your tailnet's online Linux machines and checks each one the same way. The app is sandboxed and can't talk to the Tailscale app, so it uses the Tailscale API with an access token you create in the admin console (Settings → Keys); the token is stored in the Keychain. A Tailscale machine with the same host name as a LAN find is merged into one entry with both addresses.
- A NanoKVM found over plain HTTP is guessed to be a classic NanoKVM and one over HTTPS a NanoKVM Pro; change the model in the editor if the guess is wrong. NanoKVM addresses are saved without a scheme, so the app tries HTTPS first and falls back to HTTP.

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

## Microphone and camera passthrough

On a PiKVM set up for it, the console's **Microphone and Camera** menu sends this Mac's microphone and camera to the remote machine, which sees them as a USB microphone and webcam. It needs H.264 video (WebRTC) and a recent PiKVM OS, with the USB microphone and/or webcam enabled in the PiKVM's OTG settings (`otg.devices.audio.enabled` for the microphone, `otg.devices.camera.enabled` for the webcam, in `/etc/kvmd/override.yaml`); the menu only appears when the PiKVM offers them. Both are off whenever a console opens. The camera only starts once an app on the remote machine opens the PiKVM's webcam, at the size that app asks for. Turning either on or off reconnects the video briefly. macOS asks for permission the first time.

## Virtual media (ISOs and disk images)

**Manage Images…** on a machine's page, or the disc button in a console's toolbar, opens the PiKVM's virtual drive.

- **Upload Image…** copies an ISO or disk image from the Mac to the PiKVM, with progress and a Cancel button. A cancelled or failed upload leaves nothing behind.
- Pick an image, choose **CD/DVD** or **Flash drive**, and press **Connect**. The remote machine sees it as a USB drive. **Eject** unplugs it.
- A flash drive can be made writable. A CD/DVD is always read-only.
- Uploading, deleting and changing the image all need the drive ejected first; that is a PiKVM rule.
- Each PiKVM has one virtual drive. Behind a Switch it goes to whichever port is active.

## Sipeed NanoKVM, NanoKVM Pro and NanoKVM Go

Add one with **Model** set to Sipeed NanoKVM (Cube, Lite, PCIe), Sipeed NanoKVM Pro or Sipeed NanoKVM Go, and the login you use on its web page (admin / admin until you change it). The model picks the protocol, so get it right: the NanoKVM and the NanoKVM Pro run different server software. The Go runs the Pro's.

What works:

- Console with MJPEG video, keyboard, and absolute or relative mouse (saved per machine, like on a PiKVM). The NanoKVM takes standard USB HID reports over its `/api/ws` socket. Keyboard input needs NanoKVM 2.3.2 or newer.
- Paste as typing, through the NanoKVM's paste API. It always types with a US layout.
- ATX power on NanoKVMs with the ATX board: power and disk lights, Power On and Shut Down (a short press of the power button, only when the light says it's needed), Force Off (an 8-second press) and Reset. Models without ATX show no power controls.
- Virtual media (**Manage Images…**):
  - Mount an image as a CD/DVD or a flash drive, and eject it. On a classic NanoKVM, Eject goes back to sharing its data partition, and an image is always read-only. On the Pro and Go, a flash drive can be made writable.
  - Delete images.
  - **Upload Image…** copies an .iso or .img from the Mac, with progress and Cancel. A cancelled upload is removed. The Pro and Go take 8 MiB chunks. A classic NanoKVM needs firmware 2.5.3 or newer, and it may ask you to eject the drive on the remote machine and turn off its Virtual Disk switch first.
  - **Download from URL…** makes the device download an image from the internet itself. It keeps going if you close the window, and the classic NanoKVM can cancel it.
  - A classic NanoKVM on 2.5.3+ also reports image sizes, free space, and which images can be a CD/DVD.
- Screen preview.

Not yet: H.264 video and audio (they use NanoKVM's own WebRTC signalling), and microphone and camera passthrough.

Addresses: a NanoKVM serves plain HTTP unless HTTPS is turned on in its settings, while the Pro and Go use HTTPS with a self-signed certificate. The app tries HTTPS first and falls back to HTTP. After it has seen a certificate for the device it only uses HTTPS. To force one, write the scheme into the address, such as `http://192.168.1.60`. macOS only allows plain HTTP to IP addresses, `.local` and bare host names, and Tailscale `*.ts.net` names. Use HTTPS for any other host name.

## Configuring a PiKVM

**Configure PiKVM…** (toolbar gear, or right-click a device) views and changes the PiKVM's settings in `/etc/kvmd/override.yaml`. kvmd's API can't read or change its configuration and the file sits on a read-only filesystem, so, like the updater, this works as root through the PiKVM's web terminal: no SSH needed, but it asks for the root password (shared with the updater and optionally saved in the Keychain).

- **Settings**: switches for the common options: USB audio, webcam, Ethernet, serial and extra drives (`otg.devices.*`, which need a reboot), video quality, frame rate and H.264 bitrate, the mouse jiggler, and turning ATX and the virtual drive on or off. Options the PiKVM's kvmd doesn't know are hidden. The VNC and IPMI services can be turned on and off here too. **Apply…** lists the changes before saving; **Edit in override.yaml** writes them into the file instead so you can review them first.
- **override.yaml**: the file itself, in a plain editor (no smart quotes). **Check** asks kvmd whether it accepts the file without saving. **Save and Restart…** saves it.
- **Backups**: every save keeps the previous version in `/etc/kvmd/pikvm-console-backups` (the last 20). Pick one to see it, open it in the editor, or restore it (which backs up the current file first).

Every save goes through the same steps on the device: kvmd validates the new file together with all the other config files (`kvmd -m --override-config`), the filesystem is made writable only while the file is replaced (and set back to read-only), then only the services that read the changed sections restart (kvmd for `kvmd:`, kvmd-vnc for `vnc:` and so on). If a restarted service doesn't stay up, the previous file is put back automatically and the service log is shown. Changes under `otg:` only take effect after a reboot; the app says so and offers **Reboot Now**.

## Updating a PiKVM

**Update PiKVM OS…** (toolbar, or right-click a device) runs `pikvm-update` through the PiKVM's web terminal, so it works over the same HTTPS connection as everything else and needs no SSH access. It asks for the device's root password, which can be saved in the Keychain. The update is started detached from the terminal and its log is followed, so a dropped connection or closing the window doesn't interrupt it. The PiKVM reboots itself when updates were installed.

Requires the web terminal (`kvmd-webterm`), which PiKVM OS enables by default.

## Notes

- Certificates: PiKVMs ship with self-signed certificates. The app pins a self-signed certificate's SHA-256 the first time it connects and rejects a different one after that.
- If a PiKVM's certificate is issued by a certificate authority this Mac trusts (for example an internal step-ca that the PiKVM renews from with ACME), the app notices on the first connection and from then on accepts any certificate that CA issues for the device, so renewals keep working. It also stops accepting certificates the Mac doesn't trust for that device. A certificate issued for one of the device's names (say its LAN name) is accepted when connecting through another (say Tailscale). Install your CA's root certificate in Keychain Access and set it to Always Trust. The machine's page shows which kind of certificate the device uses.
- Editing a device's addresses forgets what it learned about the certificate.
- If 2FA is on, append the current TOTP code to the password.
- Relative mouse mode needs kvmd's alternate mouse enabled. Without it, `usb_rel` isn't offered.
- Machines behind a PiKVM Switch use the switch's ATX endpoints (`/api/switch/atx/*`). A Switch port's page can also blink that port's light on the Switch, to find it on the hardware. Double-click a machine behind a Switch in the sidebar (or select it and press Return) to make its port active; its right-click menu has the same action. Double-clicking a machine that is already on screen (an active port, or a PiKVM without a Switch) opens its console.
