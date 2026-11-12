# Mac App Store

Everything needed to put KVM Console on the Mac App Store. The app side is ready; what is left needs the Apple Developer Program membership and a few choices only the account holder can make.

| File | What it is |
| --- | --- |
| [listing.md](listing.md) | Name, subtitle, description, keywords, categories, screenshot plan |
| [review-notes.md](review-notes.md) | Text for App Review Information > Notes |
| [privacy-labels.md](privacy-labels.md) | App Privacy answers, privacy manifest, export compliance |
| [../docs/privacy.md](../docs/privacy.md) | Privacy policy (needs a public URL) |
| [../docs/support.md](../docs/support.md) | Support page (needs a public URL) |
| [../KVMConsole/PrivacyInfo.xcprivacy](../KVMConsole/PrivacyInfo.xcprivacy) | Privacy manifest, bundled into the app |
| [../scripts/ci/appstore.sh](../scripts/ci/appstore.sh) | CI: archive, sign and upload for the App Store |

## Sandbox review

The app already runs in the App Sandbox (every build since the entitlements were added), so the Mac App Store's main technical requirement is met. What each entitlement is for, and what was checked:

| Entitlement | Used for | Notes |
| --- | --- | --- |
| `app-sandbox` | Required by the Mac App Store | |
| `network.client` | PiKVM/NanoKVM HTTP, WebSocket and WebRTC, Tailscale API, Bonjour browsing | Bonjour also needs `NSBonjourServices` and `NSLocalNetworkUsageDescription`; both are in Info.plist. |
| `network.server` | WebRTC's UDP ports, and the MCP server's `NWListener` on 127.0.0.1 | The MCP listener is bound to loopback (`MCPHTTPServer.swift`). |
| `device.camera`, `device.audio-input` | Openterface video and audio (a UVC camera and USB microphone), camera and microphone passthrough to a PiKVM | Usage strings are in Info.plist. |
| `device.serial` | Openterface CH9329 keyboard/mouse controller (`/dev/cu.*`) | `OpenterfaceScanner` only reads the IORegistry to match ports to devices; that needs no USB entitlement, so `device.usb` is deliberately not requested. |
| `files.user-selected.read-only` | ISO and disk images chosen with the file importer | `DeviceSession.startUpload` calls `startAccessingSecurityScopedResource()`. |
| Keychain | Device passwords, Tailscale and MCP tokens | A sandboxed app reaches its own Keychain items with no extra entitlement. |

Other checks:

- **Custom CA (step-ca) trust:** `CertificatePinning.swift` uses `SecTrustEvaluateWithError`, which asks `trustd`. Roots set to Always Trust in Keychain Access work the same inside the sandbox.
- **No temporary-exception entitlements, no helper tools, no `Process` launches, no self-updater, no login item.** The Python file in KVMKit's resources is sent to a PiKVM and runs there, never on the Mac.
- **Storage:** devices are saved under Application Support, which the sandbox maps into the app's container.
- **Privacy manifest:** added (`PrivacyInfo.xcprivacy`, UserDefaults reason CA92.1). Required for uploads since May 2024.
- **Icon:** the asset catalog has the 1024×1024 image App Store Connect needs.

Things to expect when you test the App Store build:

- **Keychain prompt once.** An App Store build is signed by Apple, not with your Developer ID or development certificate. Keychain items saved by another build ask "KVM Console wants to use your confidential information" the first time each is read; choose **Always Allow**. Device settings carry over because all builds share the same container.
- **Local network prompt** appears again for a newly signed build on some macOS versions.

## Release paths

| Path | Signing | Where it goes |
| --- | --- | --- |
| Tag `v*` (CI, `build` job) | Developer ID + notarized | GitHub Release `.dmg`/`.zip` |
| Tag `v*` (CI, `app-store` job) | Apple Distribution (cloud signing) | Uploaded to App Store Connect, appears in TestFlight |
| Manual run of "Release build" | both | App Store `.pkg` kept as a workflow artifact; tick **Upload to App Store Connect** to upload it too |
| `scripts/release.sh --app-store` | your Xcode account | Uploaded to App Store Connect |

The `app-store` job is skipped (with a note in the run summary) until its secrets exist, so nothing changes for current releases. Every upload needs a build number higher than the last for that version; CI uses the workflow run number, the same one the Developer ID build of that run gets.

## What Bryan needs to do

Once enrollment finishes:

1. **Choose the seller name.** An individual membership shows your legal name on the store; an organization membership shows the company name and needs a D-U-N-S number. This is set at enrollment and is hard to change later.
2. **Sign the agreements.** App Store Connect > Business: accept the Free Apps agreement (automatic) or, to charge, the Paid Apps agreement plus tax and banking.
3. **Create the app record.** App Store Connect > Apps > + > New App: platform macOS, name **KVM Console** (see listing.md if taken), primary language English (U.S.), bundle ID `com.badamsz.KVMConsole` (register it first under Certificates, Identifiers & Profiles > Identifiers if it is not offered; no capabilities need ticking), SKU `kvmconsole-mac`.
4. **Create an API key for CI.** App Store Connect > Users and Access > Integrations > App Store Connect API > Team Keys > +, access **Admin** (needed for cloud-managed distribution certificates). Download the `.p8` (only once). Add these repository secrets under Settings > Secrets and variables > Actions:
   - `APPLE_TEAM_ID` (already used by the Developer ID path, if you have set it)
   - `ASC_API_KEY_P8_BASE64`: `base64 -i AuthKey_XXXX.p8 | pbcopy`
   - `ASC_API_KEY_ID`
   - `ASC_API_ISSUER_ID`

   One Admin key can also serve as the notary key (`NOTARY_API_*`), but separate keys are easier to revoke.
5. **Publish the privacy policy and support pages.** App Store Connect needs public URLs. If the repository is public, the `docs/privacy.md` and `docs/support.md` GitHub links in listing.md work as they are. If it is private, turn on GitHub Pages for the `docs/` folder (Settings > Pages > Deploy from a branch > main, /docs; Pages on a private repository needs GitHub Pro) or host the two pages anywhere else, and use those URLs.
6. **Take screenshots** (plan and sizes in listing.md) and record a short **demo video** for App Review, since reviewers have no KVM hardware. Optionally offer a demo PiKVM reachable from the internet with a throwaway account.
7. **Answer export compliance** (privacy-labels.md), then optionally set `ITSAppUsesNonExemptEncryption` so uploads stop asking.
8. **Pick a price and availability** (free or paid, which countries).
9. **Test through TestFlight first.** Push a tag or run the workflow with upload ticked, install the build from the TestFlight app on your Mac, and check: PiKVM and NanoKVM consoles, a step-ca device, Bonjour and Tailscale discovery, ISO upload, an Openterface over USB (video, audio, keyboard), and the AI Agents server with Claude.
10. **Submit.** Fill in the version page from listing.md, App Privacy from privacy-labels.md, review notes from review-notes.md, attach the build, and submit for review.
