# Duomulator architecture

SNES emulator for iPhone Duo (foldable, iOS 27.1 SDK; deployment target iOS 26.0 so it also
runs on regular iPhones). Build: `xcodegen generate && xcodebuild -project Duomulator.xcodeproj
-scheme Duomulator -destination 'id=<sim udid>' -derivedDataPath build build`.
Swift 5 language mode. Gate every Duo API with `if #available(iOS 27.1, *)`.

## Layers
| Module  | Files | Owns |
|---------|-------|------|
| Core    | `Vendor/snes9x` (static lib `SNESCore`, built via libretro API), `Core/` | libretro host |
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
TouchControllerView ───┼─> InputHub ──(poll)──> EmulatorCore (emu thread, snes9x via libretro)
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
  plus quick actions below it.
- `.flat` (fully open / any non-foldable): game aspect-fit; `TouchControllerView(.overlay)`.
  Landscape: game centered, controls in the side gutters.
- `.closed` (outer display): regular phone layout, same as flat on a normal iPhone.
- Physical controller connected ⇒ hide touch controls, game uses the whole area.

## Persistence
`GamePaths` (Documents/ROMs, Saves/*.srm, States/*.sN). SRAM is flushed on pause, background,
unload, and every ~10 s if changed. Slot 0 = auto-suspend state.
