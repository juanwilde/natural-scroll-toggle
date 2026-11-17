# Natural Scroll Toggle

A tiny macOS menu bar app that toggles **Natural Scrolling** — manually with
one click, or automatically depending on whether a mouse is connected.

![macOS](https://img.shields.io/badge/macOS-26%20%7C%2027-blue) ![Arch](https://img.shields.io/badge/arch-arm64%20%7C%20x86__64-lightgrey) ![License](https://img.shields.io/badge/license-MIT-green)

> **Requires macOS 26 or later.** Older versions are not supported: the app
> operates the real System Settings switch via the Accessibility API, and
> the Trackpad pane structure differs in earlier macOS releases. The
> installer and the app itself warn if run on an unsupported version.

## Why

Natural scrolling feels great on a **trackpad** — content follows your
fingers. But with a **mouse wheel** most people prefer the classic direction
(roll the wheel down → content goes down). If you constantly switch between
trackpad and mouse, you end up fighting the scroll direction every time you
plug the mouse in or out.

This app puts a small icon in the menu bar:

- 🟢 **Green arrows** — Natural scrolling is **on** (trackpad mode)
- 🔴 **Red arrows** — Natural scrolling is **off** (mouse mode)

And it can switch for you: connect a mouse → classic scrolling; unplug it →
back to natural.

## Features

- **Automatic mode (default)**: watches for external mice (USB, Bluetooth,
  2.4 GHz dongles) and applies the matching scroll direction on every
  connect/disconnect.
- **Manual override**: click the state item in the menu to flip the setting
  yourself; this disables automatic mode until you re-enable it.
- The icon stays in sync if you change the setting from System Settings, and
  the app starts automatically at login.

## How it works (and why it's not just a `defaults write`)

Natural scrolling is stored in the global preference key
`com.apple.swipescrolldirection`. On modern macOS, **writing that key
directly does not apply the change to the running system** — new values are
only picked up by processes that read the preference again, so the scroll
direction stays the same until apps relaunch (or the session restarts). That's
why so many "one-liner" solutions for toggling scroll direction feel broken.

This app instead **operates the real System Settings switch**:

1. Opens the **Trackpad** pane of System Settings in the background.
2. Presses the "Scroll & Zoom" tab and then the **Natural scrolling**
   checkbox through the macOS **Accessibility API** (`AXPress` on the real
   UI control) — the exact code path a human toggle takes, so the change is
   applied live system-wide by Apple's own machinery.
3. If anything fails (no Accessibility permission, unexpected UI, …), it
   falls back to writing the preference directly and restarting
   `cfprefsd`/`hidd`.

### Mouse detection (automatic mode)

Mouse presence is detected with `IOHIDManager` (USB, Bluetooth and wireless
dongles all show up as HID devices). A few quirks are handled:

- The internal trackpad is filtered out (it reports itself as a HID "mouse").
- Keyboards, audio interfaces and docks often expose a dormant "mouse"
  interface for boot compatibility. Devices to ignore can be listed in
  `~/Library/Application Support/natural-scroll-toggle/ignore.txt` (one exact
  product name per line — detected names are written to the log).
- A heartbeat re-checks every 3 seconds, because Thunderbolt/USB-C docks can
  silently drop attach/detach notifications.

Debug log: `~/Library/Logs/natural-scroll-toggle.log`.

The app is written in Swift, uses only public frameworks (AppKit,
ApplicationServices, CoreFoundation, IOKit) and has no third-party
dependencies.

## Requirements

- **macOS 26 or 27** (the installer and the app warn on older versions and
  won't work correctly there)
- Apple Silicon or Intel
- **Accessibility permission** — macOS asks the first time the app needs to
  operate the switch (System Settings ▸ Privacy & Security ▸ Accessibility).
  Without it, the app falls back to the direct (non-live) write. For local
  development builds, `build.sh` signs with your *Apple Development* identity
  when available so the permission survives rebuilds.

## Install

### PKG (recommended)

Download `NaturalScrollToggle.pkg` from
[Releases](https://github.com/juanwilde/natural-scroll-toggle/releases) and
double-click it. It installs the app to `/Applications` (admin password
required, as with any installer), registers it to start at login for your
user, and launches it. Since the pkg is unsigned, macOS may show a warning:
right-click the pkg ▸ **Open**, or allow it in System Settings ▸ Privacy &
Security.

On first launch the app asks for the **Accessibility** permission — approve
it when prompted (System Settings ▸ Privacy & Security ▸ Accessibility), or
toggle once from the menu bar icon and approve from the dialog. Without it,
changes are saved but not applied until apps restart.

### DMG

Download `NaturalScrollToggle.dmg`, open it, and double-click
**Install.command** — same result as the pkg, but without an admin password
(the app goes to `~/Applications`).

### From a release tarball

Download the latest `natural-scroll-toggle-*.tar.gz` from
[Releases](https://github.com/juanwilde/natural-scroll-toggle/releases),
extract it, and run:

```sh
./install.sh
```

### From source

```sh
git clone https://github.com/juanwilde/natural-scroll-toggle.git
cd natural-scroll-toggle
./build.sh    # needs Xcode Command Line Tools
./install.sh
```

Both options install the app to `~/Applications` and register a LaunchAgent
so it starts at login. No administrator rights needed.

## Uninstall

From a repo/tarball checkout:

```sh
./uninstall.sh
```

This removes everything: the app (both `~/Applications` and `/Applications`
locations), the LaunchAgent, preferences, logs, support files, the TCC
Accessibility permission, and leftovers of the old auto-switcher. If the app
was installed with the pkg into `/Applications` and the script cannot remove
it, run `sudo rm -rf /Applications/NaturalScrollToggle.app`.

## Updating

Download the latest release tarball, extract it, and run `./install.sh`
again — it replaces the app and the LaunchAgent in place. Your settings
(automatic/manual mode) are preserved.

After an update, macOS may ask you to re-approve the **Accessibility**
permission if the app's code signature changed (System Settings ▸ Privacy &
Security ▸ Accessibility).

If that Mac still has the old standalone auto-switcher
(`mouse-scroll-autoswitch`, an earlier experiment), remove it first so only
one thing changes the setting:

```sh
launchctl unload ~/Library/LaunchAgents/com.wilde.mouse-scroll-autoswitch.plist
rm ~/Library/LaunchAgents/com.wilde.mouse-scroll-autoswitch.plist
rm -rf ~/Library/"Application Support"/mouse-scroll-autoswitch
```

## Usage

Click the arrows icon in the menu bar:

- **Automático (según ratón)** — checkmark enables/disables automatic mode.
- **Natural scrolling: on/off** — flips the setting now (switches to manual
  mode if automatic was on).

When the app flips the setting, it briefly opens and closes System Settings
in the background — that's how it presses the real switch. **Salir** quits
the app.

## Repository layout

```
Sources/main.swift    the whole app (single file)
build.sh              builds + signs a universal binary into dist/
dist/NaturalScrollToggle.app   prebuilt app bundle
install.sh            installs to ~/Applications + LaunchAgent
uninstall.sh          removes it again
```

## Disclaimer

Not affiliated with Apple. Uses the public Accessibility API to operate
System Settings UI; if Apple changes that UI in a future macOS version, the
direct-write fallback will still work (though possibly not live).

## License

[MIT](LICENSE)
