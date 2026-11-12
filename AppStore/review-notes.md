# Notes for App Review (App Store Connect > App Review Information > Notes)

Paste the text below. Fill in the video link, and the demo device if you offer one. Sign-in information: tick **Sign-in required: No** (the app has no account of its own).

---

KVM Console is a client for KVM-over-IP hardware (PiKVM, Sipeed NanoKVM, Openterface). These are devices the user owns that capture another computer's screen and act as its keyboard, mouse and USB drive. The app has no account system and no server of its own: it connects only to devices the user adds.

Testing without hardware: the app needs one of these devices to show a console. A screen recording of the full feature set on real hardware is here: <VIDEO LINK, e.g. unlisted YouTube or a shared iCloud link>. Without a device you can still open the app, use Add Device and Find Devices, browse Settings (including AI Agents) and the Help window.
<OPTIONAL: A demo PiKVM is reachable at https://<host> with user "review" / password "<password>" until <date>. It controls a test machine with nothing on it.>

Permissions:
- Local Network: to connect to KVM devices on the user's network and to find them with Bonjour (_pikvm._tcp, _http._tcp, _https._tcp, _ssh._tcp).
- Camera and Microphone: an Openterface appears to macOS as a USB camera and microphone carrying the remote computer's video and sound. A user can also send their own microphone or camera to a PiKVM; this is off until they turn it on in a console.
- Serial (com.apple.security.device.serial): an Openterface's keyboard and mouse controller is a USB serial port.
- Incoming network connections (com.apple.security.network.server): WebRTC receives video on UDP ports it opens, and the optional local server described below listens on 127.0.0.1.
- User-selected files (read-only): ISO and disk images the user picks to upload to their device.

Optional AI agent server (Settings > AI Agents): off by default. When the user turns it on, the app runs a Model Context Protocol server bound to 127.0.0.1 only, so AI assistants on the same Mac (for example Claude) can list the user's machines and take screenshots. Every request needs a random token kept in the Keychain, and requests from web pages are refused. Keyboard, virtual media and power tools are offered only after the user turns on a second, separate "Allow control" switch. Power actions always show a confirmation alert on the Mac that defaults to Don't Allow. Nothing from this feature leaves the Mac.

The app does not download or run code on the Mac. "Configure" and "Update" on a PiKVM's page change settings on the user's own PiKVM, using the PiKVM's root password that the user enters; those commands run on the PiKVM, not on the Mac.

KVM Console is an independent app and is not affiliated with PiKVM, Sipeed or Openterface; their names are used only to say which hardware it works with.
