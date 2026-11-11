# KVM Console

A native macOS app (macOS 14+) for remote control and management of [PiKVM](https://docs.pikvm.org) devices, of [Sipeed NanoKVM](https://wiki.sipeed.com/hardware/en/kvm/) devices (NanoKVM, NanoKVM Pro, NanoKVM Go), and of [Openterface](https://openterface.com) USB KVMs plugged into the Mac.

Formerly **PiKVM Console**. The app keeps the old bundle ID (`com.badamsz.PiKVMConsole`) and Keychain service name, so saved settings, passwords and camera/microphone permissions carry over. The device list moves from `~/Library/Application Support/PiKVM Console` to `…/KVM Console` on first launch. After upgrading, delete the old `PiKVMConsole.app` if you had copied it to Applications.

## Status

All four planned steps are in. Nothing has been through a wide range of hardware yet, so expect rough edges.

1. **Foundation**: device list, LAN → Tailscale fallback, Keychain credentials, kvmd API client, PiKVM Switch ports as targets, per-port mouse mode. ✅
2. **Console**: H.264 video and audio (WebRTC), MJPEG fallback, keyboard and mouse (absolute and relative), full screen. ✅
3. **Management**: ISO upload and mounting ✅, ATX power ✅, switch port control ✅.
4. **Polish**: menu bar quick view, screen previews, shortcuts, release builds (local script and GitHub Actions). ✅

## Openterface

An Openterface Mini-KVM or KVM-GO (USB 2.0 or 3.0; any unit with an MS2109/MS2109S/MS2130S capture chip and a CH9329 or CH32V208 controller) plugged into the Mac shows up under **Find Devices > Plugged into this Mac**, or add it with **Add Device** and the *Openterface (USB)* model. The app finds its parts by USB vendor and product ID:

- **Video and audio** come from the unit's USB camera and microphone through AVFoundation. macOS asks for camera and microphone access the first time.
- **Keyboard and mouse** go out as CH9329 serial commands (absolute and relative mouse, per machine like the other devices). The controller is tried at 115200 baud, then 9600.
- Pasting types the text as key presses with a US keyboard layout.
- On a KVM-GO (CH32V208 controller), the console's **MicroSD Card** menu connects the unit's microSD card to the target or to the Mac, and follows the unit's own switch button.
- A KVM-GO's capture chip runs at USB 3 speed on the port's SuperSpeed side while its serial controller sits behind a USB 2 hub on the same port, so the two are matched by port path with the root port left out.

The serial protocol is implemented from WCH's published CH9329 command set rather than from Openterface's own app, which is AGPL-licensed. Quit the Openterface app first; only one app can hold the serial port.

## Building

You need macOS 14 or later, Xcode 15.3 or later (the package uses Swift 5.10) and [XcodeGen](https://github.com/yonaskolb/XcodeGen). The Xcode project is not committed: `project.yml` describes it, and `xcodegen generate` writes `KVMConsole.xcodeproj` from it. Run `xcodegen generate` again after pulling changes that add files or edit `project.yml`.

### First build

```sh
brew install xcodegen
cp Config/Local.xcconfig.example Config/Local.xcconfig
# edit Config/Local.xcconfig and set DEVELOPMENT_TEAM to your 10-character team ID
xcodegen generate
open KVMConsole.xcodeproj
```

Build and run the **KVMConsole** scheme (⌘R). The product is `KVM Console.app`.

`Config/Local.xcconfig` gives the app a stable signing identity. A free personal team works; the example file explains how to find the team ID. The file is ignored by git and survives `xcodegen generate`. Without it the project still builds, but Xcode signs each build "to run locally", every rebuild looks like a new app to the Keychain, and macOS asks again for permission to read the saved device passwords ("KVM Console wants to use your confidential information stored in com.badamsz.PiKVMConsole"). With it, the first launch asks once more; choose **Always Allow** and it stays quiet from then on.

### Tests

- **PiKVMKit** (models, clients, storage, discovery): ⌘U in Xcode, or `swift test --package-path Packages/PiKVMKit` without Xcode.
- **On-device configuration helper** (Python): `python3 -m unittest discover -s Packages/PiKVMKit/Tests/HelperTests`. Needs `pip install ruamel.yaml pyyaml`.

### Release builds

There are two ways to make a Release build. CI is the usual one; the local script is for testing a Release build or signing on your own Mac.

#### In CI (GitHub Actions)

`.github/workflows/release.yml` builds Release on GitHub's macOS runners. It does not need `Config/Local.xcconfig`; signing comes from repository secrets.

- Every pull request and push to `main` produces an ad-hoc signed build, attached to the workflow run as an artifact (`.zip`, `.dmg`, `SHA256SUMS.txt`). macOS blocks its first launch; use **Open Anyway** in System Settings > Privacy & Security.
- Pushing a tag such as `v0.2.0` (or running the workflow by hand from the Actions tab) signs with Developer ID and notarizes when the secrets below exist. A tag also publishes a GitHub Release with the files. A tag with a hyphen (`v0.2.0-beta.1`) becomes a pre-release. The version in the tag becomes the app's version, so there is no need to edit `MARKETING_VERSION` in `project.yml` first.

Without the secrets, tagged builds still publish, unsigned. To sign and notarize, add these under Settings > Secrets and variables > Actions (all need a paid Apple Developer Program membership):

| Secret | What it is |
| --- | --- |
| `APPLE_TEAM_ID` | Your 10-character team ID (developer.apple.com > Account > Membership details). |
| `MACOS_CERTIFICATE_P12_BASE64` | A **Developer ID Application** certificate with its private key. Create it in Xcode > Settings > Accounts > Manage Certificates > + > Developer ID Application, export it from Keychain Access as a `.p12`, then `base64 -i DeveloperID.p12 \| pbcopy`. |
| `MACOS_CERTIFICATE_PASSWORD` | The password you set when exporting the `.p12`. |
| `NOTARY_API_KEY_P8_BASE64` | An App Store Connect API key for notarization: App Store Connect > Users and Access > Integrations > Team Keys, role **Developer**. Download the `.p8` (only possible once), then `base64 -i AuthKey_XXXX.p8 \| pbcopy`. |
| `NOTARY_API_KEY_ID` | That key's Key ID. |
| `NOTARY_API_ISSUER_ID` | The Issuer ID shown above the keys list. |

The workflow calls `scripts/ci/package.sh` to sign, notarize and package the app.

#### On your Mac

`scripts/release.sh` runs `xcodegen generate` and builds a Release copy into `dist/`. It needs `Config/Local.xcconfig` (see [First build](#first-build)). The version comes from `MARKETING_VERSION` in `project.yml`.

- `scripts/release.sh` signs with your development identity and leaves `dist/KVM Console.app`. Good for your own Macs.
- `scripts/release.sh --notarize` signs with Developer ID, has Apple notarize it, and leaves `dist/KVMConsole-<version>.zip`, which opens on any Mac without a warning. This needs a paid Apple Developer Program membership and notary credentials stored once in the Keychain under the profile name `kvm-console`:

  ```sh
  xcrun notarytool store-credentials kvm-console \
      --apple-id you@example.com --team-id XXXXXXXXXX --password <app-specific password>
  ```

  Set `NOTARY_PROFILE` to use a profile with another name.

## Layout

- `Packages/PiKVMKit`: models, the kvmd client (`/api/auth`, `/api/info`, `/api/atx`, `/api/hid`, `/api/msd`, `/api/switch`, `/api/ws`), the NanoKVM client (`NanoKVMClient.swift`), Keychain and JSON storage, and network discovery (`Discovery/`: Bonjour, subnet scan, HTTP fingerprints, Tailscale API).
- `KVMConsole`: the SwiftUI app.

## Help

**Help > KVM Console Help** (⌘?) opens a help window with topics on adding and finding devices, the console, mouse modes, virtual media, power control, the PiKVM Switch, NanoKVM, Openterface, configuring and updating a PiKVM, certificates (including your own CA), shortcuts and troubleshooting. Typing in the Help menu's search field lists matching topics too, and sheets such as the device editor and virtual media have a **?** button that opens the relevant topic. The text lives in `KVMConsole/Help/HelpTopics.swift`; update it along with this README when features change.

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
