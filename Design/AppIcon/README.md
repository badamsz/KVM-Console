# App icon

Original artwork for PiKVM Console: a display with a remote pointer and signal arcs.

| File | Use |
| --- | --- |
| `icon.svg` | App icon at 128 px and up, and the in-app `AppLogo` image |
| `icon-small.svg` | Simplified drawing for the 16 and 32 pt slots, so it stays legible |
| `menubar.svg` | Monochrome `MenuBarIcon` template image (18 pt) for a menu bar extra |

The SVGs follow the macOS icon grid: a 1024 canvas with an 824 px rounded body and room for the shadow.

To regenerate `PiKVMConsole/Assets.xcassets` after editing an SVG, run from the repo root:

```sh
node Design/AppIcon/generate.js
```

It needs Node and Playwright with Chromium. `project.yml` sets `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon`; run `xcodegen generate` after pulling.

In code: `Image("AppLogo")` for the logo, and `MenuBarExtra { … } label: { Image("MenuBarIcon") }` for the menu bar.
