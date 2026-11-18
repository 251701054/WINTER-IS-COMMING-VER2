#           ❄︎ WinterIsComing ❄︎

Let it snow on your Mac! ☃️

Snow falls on your desktop and piles up on your windows and Dock. Roll it into snowballs and build a little snowman. It's all one Swift file, and every flake is drawn in code.

<!-- ![demo](docs/demo.gif) -->

## What it can do ✨

- 🌨️ **Cozy snowfall**: three layers of flakes (near, middle and far) drifting in a gentle wind
- 🏔️ **Snow piles up** on top of your windows, along the Dock and at the bottom of the screen
- 🪟 **Drag a window and *whoosh*!** The snow flies off. The faster you drag, the farther it goes
- ⚪ **Roll snowballs** just by moving your mouse sideways over the snow (no clicking!). They grow as they roll
- 🎳 **Snowballs push each other** along, and one that's pushed off the edge falls down
- 🖐️ **Hold a snowball** with the left mouse button and carry it anywhere
- ⛄ **Stack three snowballs** and they turn into a snowman with a carrot nose and a red scarf
- 💥 **A falling snowball goes *poof*** into a soft heap of snow, ready to be rolled again

## Try it 🚀

```sh
git clone https://github.com/<your-username>/WINTER_IS_COMING_VER2.git
cd WINTER_IS_COMING_VER2
zsh build.sh
```

Use the ❄︎ in the menu bar to pause, pick light, medium or heavy snow, choose a manual performance profile, clear the snow, or quit.

## Phase 1 upgrade: multi-display + performance control

- Creates one transparent snow overlay and SpriteKit scene for each connected display.
- Detects display connection, removal and resolution/layout changes and reconciles overlays.
- Shares a cached WindowServer window snapshot across displays instead of querying once per display.
- Converts global window and mouse coordinates into each display's local scene coordinates.
- Adds manual **Battery Saver**, **Balanced** and **High Quality** profiles.
- Profiles adjust the total particle budget, SpriteKit frame rate and window-position polling interval.
- Divides the particle budget across connected displays and trims existing flakes when a lower profile is selected.
- Keeps Dock tracking on the primary display only.
- Preserves the existing snowfall, snow accumulation, window-drag release, snowball and snowman mechanics.

The profile names are relative settings, not guarantees of a specific CPU or battery percentage. Measure on the target Mac and adjust the budgets if necessary.

## Planned follow-on phases

1. Settings window, persistent preferences, optional Launch at Login, keyboard shortcuts and accessibility controls.
2. Additional weather modes, wind, frost, freezing rain and melting.
3. Interactive snowman customization and mini-games. Animals are intentionally excluded from this build.
4. Aurora, seasonal events, accumulation history, frozen window edges and optional ambience (off by default).

- No `swiftc`? Run `xcode-select --install` first.
- Want snow on the Dock too? Turn on **Terminal** in System Settings → Privacy & Security → Accessibility.

## Make it yours 🎨

Every setting lives at the top of `WinterIsComing.swift` (`enum Cfg`): how many flakes fall, how fast they fall, how tall the piles get, how big a snowball can grow… Change a number and run `zsh build.sh` again.

## License

[MIT](LICENSE) · Made with 💙 and a little help from Claude

## Phase 2 upgrade: settings + saved preferences

- Adds a native macOS Settings window, accessible from the menu-bar menu with `Settings…` or `⌘,`.
- Saves the selected manual performance profile, snow amount and Reduce Motion preference using `UserDefaults`.
- Restores those preferences on the next launch.
- Adds a Reduce Motion accessibility option. When enabled, it caps the scene at 15 FPS and limits the active flake budget to 80.
- Adds keyboard menu shortcuts: `⌘⌥P` pause/resume, `⌘⌥C` clear snow and `⌘,` open settings.
- Adds optional Launch at Login using `SMAppService` (macOS 13+).
- Changes the build script to create and launch `WinterIsComing.app`; the app bundle is required for reliable Launch at Login registration.
- Ambient sound remains off and animals remain excluded, as requested.

### Build Phase 2 on macOS

```sh
zsh build.sh
```

The script builds `WinterIsComing.app` and opens it. To use Launch at Login, keep the app in a stable location (for example, `/Applications`) and enable it in Settings. macOS may also show it under System Settings → General → Login Items.

The keyboard shortcuts are menu key equivalents. They are not registered as system-wide hotkeys when another application is active.

## Validation notes

The Swift source passes compiler parser validation. This development environment is Linux and does not include the macOS Cocoa, SpriteKit or ServiceManagement SDKs, so native compilation, UI behavior, Login Item registration and runtime resource measurements must be verified on macOS.
