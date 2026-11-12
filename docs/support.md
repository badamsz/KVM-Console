# KVM Console Support

## Getting help

- **In the app:** Help > KVM Console Help covers adding devices, certificates, virtual media, power control, Openterface and the AI agent server.
- **Report a problem or ask a question:** open an issue at https://github.com/badamsz/KVM-Console/issues. Please include your macOS version, the app version (KVM Console > About), the device model, and what you expected to happen.

## Common questions

**The app can't find or reach my device.** Check that macOS allowed local network access: System Settings > Privacy & Security > Local Network > KVM Console. Then try the device's address in a web browser on the same Mac.

**"The certificate is different from the one saved."** The device's certificate changed. If you replaced it on purpose, edit the device, press Forget Certificate and save.

**My device uses a certificate from my own certificate authority.** Install the CA's root certificate in Keychain Access and set it to Always Trust. KVM Console then accepts every certificate that CA issues for the device, including renewals.

**My Openterface isn't detected.** Unplug it and plug it back in, try another USB port or cable, and allow camera and microphone access when asked (System Settings > Privacy & Security).

**Which devices are supported?** PiKVM (v3, v4 Mini, v4 Plus, PiKVM Switch), Sipeed NanoKVM, NanoKVM Pro and NanoKVM Go, and Openterface Mini-KVM and KVM-GO.

KVM Console is an independent app and is not affiliated with PiKVM, Sipeed or Openterface.

## Privacy

See the [privacy policy](privacy.md). The app collects no data.
