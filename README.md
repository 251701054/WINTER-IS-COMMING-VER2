# ❄️⛄ WinterIsComing 🌨️✨

> **Brace yourself... your Mac desktop is about to become a winter wonderland!** 🧣☕

Snow drifts down across your screen, rides wild wind gusts, and piles up right on top of your open windows, your Dock, and the bottom of your display! Roll snowballs just by wiggling your mouse, bowl them into each other, carry them around like tiny frozen pets, and stack three together to summon a surprise snowman—all packed into **one single Swift file** with every snowflake drawn in code! 🎨💻

---

## 🎉 What Can This Little Blizzard Do? ❄️

- 🌨️ **Three-Layer Cozy Snowfall**: Far, middle, and near snowflakes drifting down with a natural sway—plus dynamic wind moods
  - (**Gentle Breeze** 🍃, **Moderate Wind** 🌬️, and **Strong Gust** 💨) so it actually feels alive!
- 🏔️ **Real Snow Piles Everywhere**: Watch snow stack up on top of your windows, across your Dock, and along the bottom of your screen—and
  - slump sideways when a pile gets too tall and dramatic! 📐
- 🪟 **Yeet the Snow (*Whoosh!* 🚀)**: Drag or close a window and all the snow sitting on top goes flying! The faster you yeet the window,
  - the farther the snow clumps launch! 💥
- ⚪ **Zero-Click Snowball Rolling**: Just slide your mouse sideways over a snow pile (no clicking required!) and
  - watch a tiny snowball grow into a chonky snow boulder as it gobbles up snow! 🌀
- 🎳 **Snowball Bowling**: Roll one snowball into another to push it along—or shove your friend's snowball right off the edge of a window! *Poof!* 💨
- 🖐️ **Carry & Toss**: Left-click and drag any snowball anywhere on screen. Drop it from up high and watch it *splat* back into fresh powder! ☃️
- 🎩 **Build-a-Snowman Surprise**: Stack **three** snowballs and *ta-da!* ✨ You get a randomized snowman with its own vibe
  - **Classic Frosty** 🎩, **Cozy Winter** 🧶, **Dapper Gentleman** 🤵, **Nordic Explorer** 🧭, or **Playful Scamp** 🧢—complete with expressive faces,
  - colorful scarves/bow ties,
  - and random accessories (glasses 👓, pipe 🪈, earmuffs 🎧, or a twig broom 🧹)!
- 🖥️ **Multi-Display Magic**: Got extra monitors? It spreads the snowfall across *every* connected screen automatically
	- while sharing one cached WindowServer snapshot so your Mac stays chill! 😎
- ⚙️ **Native Settings & Saved Vibes**: Pop open Settings from the **❄︎** menu bar icon (or hit `⌘,`) to pick your snow amount,
	- performance profile, or **Reduce Motion**—saved automatically so your winter setup is waiting next time! 💾
- 🔋 **Battery-Friendly & Accessible**:
  - Pick **Battery Saver** 🪫, **Balanced** ⚖️, or **High Quality** ✨ to tune flake count, FPS, and window polling.
  - Flip on **Reduce Motion** 🐢 to cap the scene at 15 FPS and 80 flakes.
  - Toggle **Launch at Login** 🚀 (`SMAppService`, macOS 13+) so it starts snowing the moment you boot up!
- 🔓 Accessibility Permission (Optional, for Dock Snow 🛳️): Want snow piling on your Dock too?	
	- Head to System Settings → Privacy & Security → Accessibility and toggle on your Terminal (or the app).
 - 
## 🛠️ What You Need Before Summoning Snow 🧰

- 🍎 **macOS 13.0 or newer**
- 🧑‍💻 **Xcode Command Line Tools** (`swiftc`). Don't have it yet? Run this magic spell:
  ```sh
  xcode-select --install


## 🚀 Try It on Any Mac! ❄️

🧰 First time running Swift on Mac? If Terminal says swiftc isn't installed, run this first and try zsh build.sh again:

```xcode-select --install```

Open **Terminal** on your Mac (`⌘ + Space`, type `Terminal`, hit Enter) and paste this in:

```sh
git clone [https://github.com/251701054/WINTER-IS-COMMING-VER2.git](https://github.com/251701054/WINTER-IS-COMMING-VER2.git)
cd WINTER-IS-COMMING-VER2
zsh build.sh
```

## ⌨️ Menu Bar & Secret Shortcuts 🕹️

Click the ❄︎ icon chilling in your menu bar, or use these quick combos:

Shortcut	Winter Magic ✨
⌘⌥P	---   ⏸️ Pause / ▶️ Resume the blizzard
⌘⌥C	---   🧹 Clear all snow & snowballs (fresh slate!)
⌘,	---   ⚙️ Open the Settings window
⌘Q	---   👋 Melt away & Quit

## 🎨 Make It Yours! 🧙‍♂️

Want a mega-blizzard or giant snowballs? Open WinterIsComing.swift and tweak enum Cfg right at the top—change 
targetFlakes, fallSpeed, windowPileMax, groundPileMax, dockPileMax, ballMaxRadius, or maxBalls, then run zsh build.sh again! 🔥
📁 Inside the Snow Globe
📜 WinterIsComing.swift — The entire app! Snow physics, wind gusts, snowman wardrobe, multi-display overlays, Dock tracking, and Settings UI
🔨 build.sh — Compiles, bundles, signs, and launches WinterIsComing.app
✅ verify_changes.sh — Quick sanity check for features, linked frameworks, and build binaries
📄 LICENSE — MIT License
💙 License

MIT — Made with ❄️, ☕, and maximum winter joy! ⛄🎉

## 🧪 Validation Notes ✅

- 🕵️‍♂️ **Source Check (`verify_changes.sh`)**: Passed **30 / 31** checks! Every feature—from randomized snowmen ☃️ (`SnowmanKind`, `SnowmanExpression`, `SnowmanAccessory`) and
- 	- dynamic wind gusts 💨 (`WindRegime`, `stepWind`) to multi-display pause sync 🖥️—is verified in `WinterIsComing.swift`!
- 🔇 **Clean Framework Check**: Zero audio frameworks linked (`AVFoundation`, `AudioToolbox`, `CoreAudio` stay out—pure silent winter vibes ❄️).
- 🍎 **macOS Native Build**: The standalone `WinterIsComing` binary is present and executable; run `zsh build.sh` on macOS to generate `WinterIsComing.app` and
- 	- verify UI behavior, Accessibility Dock tracking, and **Launch at Login** (`SMAppService`)! 🚀

