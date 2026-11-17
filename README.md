# Natural Scroll Toggle

A tiny macOS menu bar app that toggles **Natural Scrolling** with one click.

![How it works](https://img.shields.io/badge/macOS-12%2B-blue) ![Arch](https://img.shields.io/badge/arch-arm64%20%7C%20x86__64-lightgrey) ![License](https://img.shields.io/badge/license-MIT-green)

## Why

Natural scrolling feels great on a **trackpad** — content follows your fingers.
But with a **mouse wheel** most people prefer the classic direction (roll the
wheel down → content goes down). If you constantly switch between trackpad and
mouse, you end up fighting the scroll direction every time you plug the mouse
in or out.

This app puts a small icon in the menu bar:

- 🟢 **Green arrows** — Natural scrolling is **on** (trackpad mode)
- 🔴 **Red arrows** — Natural scrolling is **off** (mouse mode)

Click the icon, then the first menu item, and the setting changes everywhere
immediately — the same as toggling it yourself in System Settings, without
digging through panes.

The icon also stays in sync if you change the setting from System Settings,
and it starts automatically at login.

## How it works (and why it's not just a `defaults write`)

Natural scrolling is stored in the global preference key
`com.apple.swipescrolldirection`. On modern macOS, **writing that key directly
does not apply the change to the running system** — new values are only picked
up by processes that read the preference again, so the scroll direction stays
the same until apps relaunch (or the session restarts). That's why so many
"one-liner" solutions for toggling scroll direction feel broken.

This app takes a different approach:

1. When you toggle, it opens the **Trackpad** pane of System Settings in the
   background.
2. It presses the middle tab ("Scroll & Zoom") and then the **Natural
   scrolling** checkbox through the macOS **Accessibility API** (`AXPress` on
   the real UI control).
3. Because it operates the exact same control a human would, the change is
   applied live system-wide by Apple's own code path.
4. If anything fails (no Accessibility permission, unexpected UI, …), it falls
   back to writing the preference directly and restarting `cfprefsd`/`hidd`.

The app is written in Swift, uses only public frameworks (AppKit,
ApplicationServices, CoreFoundation) and has no third-party dependencies.

## Requirements

- macOS 12 (Monterey) or later
- Apple Silicon or Intel
- **Accessibility permission** — macOS asks the first time you toggle (System
  Settings ▸ Privacy & Security ▸ Accessibility). Without it, the app falls
  back to the direct (non-live) mode.

## Install

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

Both options install the app to `~/Applications` and register a LaunchAgent so
it starts at login. No administrator rights needed.

## Uninstall

```sh
./uninstall.sh
```

## Usage

Click the arrows icon in the menu bar and choose the first item
(**Natural scrolling: on/off**). The app briefly opens and closes System
Settings in the background — that's how it flips the real switch. **Salir**
quits the app.

## Repository layout

```
Sources/main.swift    the whole app (single file)
build.sh              builds a universal binary into dist/
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
