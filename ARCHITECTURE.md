# Duomulator architecture

Multi-system emulator for iPhone Duo (foldable, iOS 27.1 SDK; deployment target iOS 26.0 so it also
runs on regular iPhones). Build: `xcodegen generate && xcodebuild -project Duomulator.xcodeproj
-scheme Duomulator -destination 'id=<sim udid>' -derivedDataPath build build`.
Swift 5 language mode. Gate every Duo API with `if #available(iOS 27.1, *)`.

## Layers
| Module  | Files | Owns |
|---------|-------|------|
| Core    | `Vendor/*` (one static lib per libretro core: snes9x, FCEUmm, melonDS, PicoDrive, FinalBurn Neo, PCSX ReARMed, Mupen64Plus-Next; symbols renamed per core via `CoreBuild/`), `Core/` | libretro host (`EmulatorCore`, `CoreAPI` function tables, `HWRender` OpenGL ES for N64) |
| Shared  | `App/Shared/SharedTypes.swift` | `SNESButtons`, `InputHub`, `FrameBuffer`, `AudioRingBuffer`, `Posture`, `GamePaths`. FROZEN — do not change semantics; additive changes only if unavoidable. |
| Video   | `App/Video/` | `GameRenderView` (Metal) |
| Audio   | `App/Audio/` | `AudioOutput` (AVAudioEngine) |
| Input   | `App/Input/` | `TouchControllerView`, `GameControllerManager` |
| Duo     | `App/Duo/` | `PostureMonitor`, `GameViewController`, in-game menu |
| Library | `App/Library/` | `DuomulatorApp`, ROM import/list, settings |

Each stub file's public signatures are the contract between modules. Keep them; you may add
members. Data flow:

```
GameControllerManager ─┐
TouchControllerView ───┼─> InputHub ──(poll)──> EmulatorCore (emu thread, the game's core via libretro)
                       │                          ├─ video_refresh ─> FrameBuffer ─> GameRenderView (CADisplayLink + Metal)
                       │                          └─ audio_batch  ─> AudioRingBuffer ─> AudioOutput (AVAudioSourceNode)
PostureMonitor (UIHingeInteraction + reservedRegions(kind: .division)) ─> GameViewController layout
```

## iPhone Duo APIs (verified from the iOS 27.1 SDK headers)
- `UIHingeInteraction { interaction, update in update.hinge?.status / .angle }`; add with
  `view.addInteraction(_:)`. `UIHinge.Status`: `.unknown .closed .partiallyOpen .fullyOpen`.
  `update.hinge == nil` ⇒ no hinge (not a Duo, or on the outer display).
- `view.reservedRegions(kind: .division)` → `[UIView.ReservedRegion]` with `frame`, `margins`,
  `isActive`, in the view's coordinate space. `.division` = where content should split (the
  fold); `.occlusion` = cameras etc. Re-query on layout.
- `UISceneAccessory.cameraCapture(...)` / `.externalNonInteractive(...)` exist but the outer
  display is NOT available to us for gameplay while open — don't build on it.

## Postures → layout
- `.tent` (partially open, DS style): game above the division, `TouchControllerView(.panel)`
  plus quick actions below it. Only a fold running across the screen counts; half open
  sideways the game screen asks to be turned. DS: top screen above, touch screen below
  flanked by the controls.
- `.flat` (fully open / any non-foldable): game aspect-fit; `TouchControllerView(.overlay)`,
  drawn as outlines. Landscape: game centered, controls over it.
- `.closed` (outer display): like flat, but the quick bar stands vertically in the system's
  side strip at the right edge (Apple's outer-display bar placement), and the controls below
  the game reach across that strip.
- Physical controller connected ⇒ overlay controls hide until the screen is touched; the
  panel below the fold always shows.
- Controls keep clear of the rounded screen corners (`ControllerLayout.keepClear`).

## Persistence
`GamePaths` (Documents/ROMs, Saves/*.srm, States/*.sN). SRAM is flushed on pause, background,
unload, and every ~10 s if changed. Slot 0 = auto-suspend state.
