# App Privacy answers (App Store Connect > App Privacy)

## Data collection

**Do you or your third-party partners collect data from this app?** → **No, we do not collect data from this app.**

The label then reads **Data Not Collected**. Apple defines "collect" as transmitting data off the device in a way that the developer or a third party can access it. KVM Console sends data only to the user's own devices:

| What the app handles | Where it goes | Collected? |
| --- | --- | --- |
| Device addresses, names, settings | A file in the app's sandbox container | No, stays on the Mac |
| Device passwords, Tailscale API token, MCP token | The Mac's Keychain | No |
| Keyboard, mouse, clipboard text typed into a console | The user's own KVM device | No, user-directed to their own hardware |
| Microphone and camera (only when Send Microphone/Camera is on) | The user's own PiKVM | No |
| Openterface video/audio | Shown and played locally | No |
| ISO and disk images the user picks | Uploaded to the user's own KVM | No |
| Tailscale device list (only if the user adds a token) | Fetched from Tailscale's API with the user's token | No; the request goes to Tailscale on the user's behalf, nothing reaches the developer |
| MCP server requests | Local loopback only, from clients the user configures | No |

No analytics, crash reporting, advertising or tracking SDKs are included. WebRTC (stasel/WebRTC, Google's libwebrtc) is used only for peer-to-peer media with the user's device.

## Tracking

**Does this app track?** → **No.** `PrivacyInfo.xcprivacy` sets `NSPrivacyTracking` to false and lists no tracking domains.

## Privacy manifest

`KVMConsole/PrivacyInfo.xcprivacy` declares UserDefaults (reason CA92.1). If App Store Connect emails an "ITMS-91053: Missing API declaration" warning after an upload, add the API it names to that file.

## Export compliance (asked on every build unless set in Info.plist)

KVM Console uses only standard encryption: HTTPS/TLS through Apple's URLSession and Network frameworks, and DTLS-SRTP inside WebRTC (BoringSSL). This normally qualifies for the mass-market exemption, so the usual answers are:

- Does your app use encryption? **Yes** (HTTPS and WebRTC).
- Does it qualify for an exemption (Category 5, Part 2)? **Yes**: it uses standard encryption only for authentication and protecting communications.

Because WebRTC brings its own copy of standard algorithms (not just Apple's), App Store Connect may ask whether the app uses "standard encryption algorithms instead of, or in addition to, Apple's"; the honest answer is **yes**, and it may then mention French encryption declaration requirements for distribution in France. This is a legal attestation, so the `ITSAppUsesNonExemptEncryption` key is **not** set in Info.plist yet. Once you have answered it in App Store Connect and are comfortable with the answer, add `ITSAppUsesNonExemptEncryption: false` to `info.properties` in `project.yml` so uploads stop asking.
