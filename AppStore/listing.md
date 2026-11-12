# App Store listing (draft)

Paste these into App Store Connect > KVM Console > the version page and App Information.
Character limits are Apple's; counts are given where they are close.

## App Information

| Field | Value |
| --- | --- |
| Name (30) | **KVM Console** (11). If App Store Connect says the name is taken, try `KVM Console for Mac` or `KVM Console: IP KVM Client`. |
| Subtitle (30) | **Control servers over IP KVM** (27). Alternative: `Remote consoles for your KVMs` (29). |
| Bundle ID | `com.badamsz.KVMConsole` |
| SKU | `kvmconsole-mac` (any unique string; never shown) |
| Primary category | Utilities |
| Secondary category | Developer Tools |
| Content rights | Does not contain, show or access third-party content. |
| Age rating | Answer **None/No** to every question. Result: 4+. |
| Copyright | `2026 <your legal name>` |

## Version page

### Promotional text (170, can change without review)

> One window for every machine behind your KVMs. See the screen, type, mount ISOs and press power, for PiKVM, Sipeed NanoKVM and Openterface.

### Description (4000)

> KVM Console is a native Mac app for KVM-over-IP devices. Connect to the machines in your rack, homelab or office and work on them as if you were sitting in front of them, from boot screen and BIOS to the desktop.
>
> CONSOLE
> • Low-latency H.264 video over WebRTC, with an MJPEG fallback
> • Keyboard with Mac shortcuts translated for the remote machine, and paste as typing
> • Absolute and relative mouse, remembered for each machine
> • Full screen with an auto-hiding toolbar
> • Sound from the remote machine, and optional microphone and camera passthrough
>
> VIRTUAL MEDIA
> • Upload an ISO or disk image from your Mac, or have the device download one from a web address
> • Mount, eject and switch between images as a CD-ROM or flash drive
>
> POWER
> • Power on, shut down, reset and force off through ATX control
> • Power and disk activity lights at a glance
>
> MANY MACHINES
> • A sidebar with every device and every port of a KVM switch, in your order
> • Live previews and a menu bar menu for quick access
> • Find devices on your network with Bonjour, or on your Tailscale tailnet
>
> SUPPORTED HARDWARE
> • PiKVM (v3, v4 Mini, v4 Plus) and the PiKVM Switch, including chained switches
> • Sipeed NanoKVM, NanoKVM Pro and NanoKVM Go
> • Openterface Mini-KVM and KVM-GO, plugged into this Mac over USB
>
> SECURE BY DESIGN
> • Passwords are kept in your Mac's Keychain
> • Self-signed certificates are pinned on first use; certificates from your own certificate authority are verified and renewals just work
> • Connections go straight from your Mac to your devices. Nothing passes through our servers, and the app collects no data.
>
> FOR AI AGENTS (OPTIONAL)
> An optional, off-by-default local server lets AI assistants on this Mac, such as Claude, list your machines and take screenshots. Control is a separate switch, and power actions always ask you first.
>
> KVM Console is an independent app. It is not affiliated with or endorsed by PiKVM, Sipeed or Openterface. You need one of the supported devices to use it.

### Keywords (100 bytes, comma separated, no spaces after commas)

```
kvm,ip kvm,kvm over ip,remote console,server,homelab,bios,iso,headless,power,usb,bmc,ipmi,oob
```

93 bytes. Brand names (PiKVM, NanoKVM, Openterface, Raspberry Pi, Tailscale) are left out on purpose: guideline 2.3.7 rejects other companies' trademarks in keywords. The name and description already make the app findable for them.

### What's New (first release)

> First release on the Mac App Store.

### URLs

| Field | Value |
| --- | --- |
| Support URL | `https://github.com/badamsz/KVM-Console/blob/main/docs/support.md` (or the Pages URL, see README) |
| Marketing URL | optional; the repository page |
| Privacy Policy URL | `https://github.com/badamsz/KVM-Console/blob/main/docs/privacy.md` (or the Pages URL) |

These only work if the repository is public, or once the two pages are published with GitHub Pages. See [README.md](README.md).

## Screenshots

Mac screenshots must be 16:10, one of 1280×800, 1440×900, 2560×1600 or 2880×1800, 1 to 10 of them. Take them on a Retina Mac with the window at 1440×900 points and save at 2880×1800 (or use Shift-Command-5 on a window, then resize the canvas). Suggested set, in order:

1. A console window showing a server's BIOS or OS installer, toolbar visible. Caption: "Your server's screen, on your Mac".
2. The main window: sidebar with several machines and Switch ports, live previews. Caption: "Every machine in one place".
3. Virtual media sheet mounting an ISO. Caption: "Mount ISOs from your Mac".
4. A machine page with power controls and the power/HDD lights. Caption: "Power control with ATX".
5. Find Devices with Bonjour/Tailscale results. Caption: "Find KVMs on your network".
6. An Openterface console. Caption: "Openterface over USB, no network needed".
7. Settings > AI Agents (optional). Caption: "Optional, off-by-default AI agent access".

Hide real host names, IP addresses and tailnet names, or use demo names, before capturing.

## App Preview (optional)

Up to three 15–30 second videos. Not required; skip for the first release.
