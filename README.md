# Filmstrip

**A scrolling window manager for macOS.** Every window sits side by side on one endless horizontal strip. Opening a window never squeezes the others: the strip just gets longer, and you scroll. A minimap at the bottom of the screen shows the whole strip at a glance.

Inspired by [niri](https://github.com/YaLTeR/niri) and [PaperWM](https://github.com/paperwm/PaperWM) on Linux. Native Swift, free and open source.

```
            what you see on screen
         ┌─────────────────────────┐
  ┌────┐ │ ┌─────────┐ ┌─────────┐ │ ┌────┐
  │    │ │ │         │ │         │ │ │    │
  │ ◀  │ │ │ Safari  │ │Terminal │ │ │  ▶ │   ← scroll with ⌃⌥ + wheel / trackpad
  │    │ │ │         │ │         │ │ │    │
  └────┘ │ └─────────┘ └─────────┘ │ └────┘
         │      [▢ ▢ ▣ ▢ ▢]        │   ← minimap: the whole strip, click to jump
         └─────────────────────────┘
```

> **Status:** early development (v0.1). It works day to day, but expect rough edges. Bug reports are very welcome.

## Features

- **The strip:** new windows open right next to the one you are using; nothing overlaps, nothing gets lost behind another window.
- **Scroll to move around:** hold ⌃⌥ (Control-Option) and use the mouse wheel or the trackpad. When you stop, the window nearest the middle gets focus.
- **Minimap:** click a tile to jump to that window, drag tiles to reorder windows, scroll over it to move the strip. Three sizes; always visible, only while navigating, or off.
- **Full height, always:** windows reach from the menu bar to the minimap (or to the Dock, with the minimap floating on top). Their top and bottom edges are locked, so they cannot be resized out of shape.
- **Resize width by hand:** drag a window's left or right edge and the neighbours on that side slide along live.
- **Keyboard control:** move focus, move windows, cycle widths, full width, centre, stack windows in one column.
- **Smart about apps:** dialogs, panels and fixed-size windows float. Apps that will not shrink below a minimum size (WhatsApp, Spotify…) get a wider column instead of overlapping their neighbours.
- **One strip per Space.**
- **Safe:** pausing or quitting puts every window back on screen. Only the Accessibility permission is needed: no kernel extensions, no SIP changes, no network access, no telemetry.

## Requirements

- macOS 13 Ventura or later
- To build it: Xcode or the Xcode Command Line Tools (Swift 5.9 or later)

Developed and tested on Apple silicon. Intel Macs should work but are untested.

## Installation

There are no ready-made downloads yet, so Filmstrip is built from source. It takes about a minute.

**1. Install the Xcode Command Line Tools** (skip if you already have Xcode):

```sh
xcode-select --install
```

**2. Get the code and build the app:**

```sh
git clone https://github.com/berkoca/filmstrip.git
cd filmstrip
scripts/build-app.sh
```

This creates `build/Filmstrip.app`. You can move it to your Applications folder:

```sh
mv build/Filmstrip.app /Applications/
```

**3. Start Filmstrip:**

```sh
open /Applications/Filmstrip.app
```

Filmstrip lives in the menu bar (a small three-column icon); it has no Dock icon.

**4. Allow Accessibility access.** On first launch Filmstrip asks for it. macOS only lets an app move other apps' windows through Accessibility.

1. Open **System Settings → Privacy & Security → Accessibility**.
2. Turn on **Filmstrip**. If it is not in the list, press **+** and choose `Filmstrip.app`.
3. Filmstrip starts by itself a moment later.

**5. Recommended macOS settings:**

- **System Settings → Desktop & Dock → "Displays have separate Spaces"**: on.
- Quit other window managers and window snapping apps (Rectangle, Magnet, AeroSpace, yabai…): two apps moving the same windows will fight.

### Start at login

System Settings → General → Login Items → **+** → choose `Filmstrip.app`.

## Using Filmstrip

Hold **⌃⌥ (Control-Option)** with each key:

| Keys | Action |
| --- | --- |
| ⌃⌥ ← → or H L | Focus the window on the left / right |
| ⌃⌥ ↑ ↓ or K J | Focus up / down inside a stack |
| ⌃⌥⇧ ← → | Move the window left / right |
| ⌃⌥⇧ ↑ ↓ | Move the window up / down inside a stack |
| ⌃⌥⌘ ← → | First / last window |
| ⌃⌥ 1 … 9 | Jump to window 1–9 |
| ⌃⌥ + scroll | Scroll the strip |
| ⌃⌥ R | Cycle width: ⅓, ½, ⅔ of the screen |
| ⌃⌥ F | Full width on / off |
| ⌃⌥ C | Centre the window |
| ⌃⌥ = / - | Wider / narrower |
| ⌃⌥ ] / [ | Stack the window into the column on the left / right |
| ⌃⌥⇧ ] / [ | Pop it out of the stack to the right / left |
| ⌃⌥ T | Float the window (take it off the strip) / put it back |
| ⌃⌥ M | Show / hide the minimap |
| ⌃⌥ Q | Pause / resume Filmstrip |

With the mouse:

- **Minimap:** click a tile to go to that window, drag a tile to reorder, scroll over the minimap to move the strip.
- **Window edges:** drag the left or right edge to change the width. A window dragged around by its title bar slides back into the strip when you let go.

### Settings

Everything is in the menu bar menu:

| Setting | Choices |
| --- | --- |
| Minimap | Always · While navigating · Off; Small · Medium · Large; windows stop above it or reach the Dock |
| Centre Focused Window | Never · When it doesn't fit · Always |
| Gaps | 0 to 24 points between windows |
| Invert Scroll Direction | On / off |
| Re-arrange Windows | Puts every window back in its place and picks up any Filmstrip missed |
| Pause | Gives all windows back to you, for example for a presentation (⌃⌥Q) |

## Troubleshooting

**Shortcuts or tiling do nothing.** Check that Filmstrip is on in **Privacy & Security → Accessibility**. If you built Filmstrip again or moved the app, macOS may have dropped the permission: remove Filmstrip from the list with **−**, add it again with **+**.

**A window is stuck at the edge of the screen.** Choose **Re-arrange Windows** in the menu, or pause and resume Filmstrip (⌃⌥Q twice). Quitting Filmstrip from its menu also brings every window back.

**With two displays, windows jump to the other display.** macOS moves windows that sit too far off screen. Arrange your displays above or below each other instead of side by side (System Settings → Displays → Arrange).

**An app does not get tiled.** Dialogs, panels and windows that cannot be resized float on purpose. If a normal window is left out, please open an issue with the app's name.

## Uninstall

Quit Filmstrip from its menu, delete `Filmstrip.app`, and remove it from **Privacy & Security → Accessibility**. Its settings are stored in `~/Library/Preferences/io.github.berkoca.Filmstrip.plist`.

## Known limitations

- Only the display with the menu bar is managed; windows on other displays are left alone.
- macOS does not let a window sit fully off screen, so windows scrolled out of view keep a 1-point sliver at the screen edge.
- Three- and four-finger trackpad swipes are not supported yet; use ⌃⌥ + scroll.

## How it works

Filmstrip is a small menu bar app written in Swift, in three modules:

| Module | What it does |
| --- | --- |
| `FilmstripCore` | The strip model, layout and minimap maths. Pure Swift with no macOS APIs, covered by unit tests. |
| `FilmstripPlatform` | Talks to macOS: finds, watches and moves windows through the Accessibility API, reads shortcuts and scrolling through an event tap, knows about displays and Spaces. |
| `FilmstripApp` | The menu bar app: the controller, animations, the minimap and the edge guards. |

Data flows one way: macOS events and shortcuts become commands, commands change the model, the layout turns the model into window frames, and the animator moves the windows.

## Contributing

Issues and pull requests are welcome. To work on Filmstrip:

```sh
swift build          # build
swift test           # run the core tests
scripts/build-app.sh # build Filmstrip.app
```

macOS ties the Accessibility permission to the app's code signature, and the default ad-hoc signature changes with every build, so the permission is lost after each rebuild. Run this once to sign your builds with a stable local certificate instead:

```sh
scripts/setup-signing.sh
```

## Acknowledgements

- [niri](https://github.com/YaLTeR/niri) and [PaperWM](https://github.com/paperwm/PaperWM), which made scrolling window management popular.
- [yabai](https://github.com/koekeishiya/yabai), [AeroSpace](https://github.com/nikitabobko/AeroSpace) and [Paneru](https://github.com/karinushka/paneru), whose work shows how far macOS window management can go.

## License

[MIT](LICENSE)
