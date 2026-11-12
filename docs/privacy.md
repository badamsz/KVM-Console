# KVM Console Privacy Policy

_Last updated: November 12, 2026_

KVM Console is a Mac app for controlling computers through KVM-over-IP devices such as PiKVM, Sipeed NanoKVM and Openterface. This policy explains what the app does with your information. In short: **the developer collects nothing.**

## What we collect

Nothing. KVM Console has no accounts, analytics, advertising, crash reporting or tracking, and it does not send any information to the developer or to any server the developer runs.

## What stays on your Mac

- The devices you add (names, addresses, settings) are saved in the app's own storage on your Mac.
- Device passwords and tokens are saved in your Mac's Keychain.
- Removing the app removes its storage. Keychain items can be removed in Keychain Access (search for `com.badamsz.KVMConsole`).

## Where your data goes

The app connects only to places you choose:

- **Your KVM devices.** Video, sound, keyboard and mouse input, text you paste, disk images you upload, and, only if you turn them on, your microphone and camera, are exchanged directly between your Mac and your own devices.
- **Tailscale**, only if you enter a Tailscale API token to find devices on your tailnet. The app then asks Tailscale for your device list. Tailscale's own privacy policy applies to that request.
- **Web addresses you enter** for disk images are passed to your KVM device, which downloads the file itself.
- **AI agents on your Mac**, only if you turn on Settings > AI Agents. The server listens only on your Mac (127.0.0.1) and answers only apps that have its token. What an AI assistant does with the information it receives is governed by that assistant's own policy.

## Permissions

The app may ask for access to your local network (to reach and find devices), the camera and microphone (an Openterface's video and sound arrive this way, and you can choose to send your own to a PiKVM), and files you pick (disk images to upload). You can change these at any time in System Settings > Privacy & Security.

## Children

The app is a technical tool and is not directed at children. It collects no information from anyone.

## Changes

If this policy changes, the new version will be published at this address with a new date.

## Contact

Questions: open an issue at https://github.com/badamsz/KVM-Console/issues, or see the [support page](support.md).
