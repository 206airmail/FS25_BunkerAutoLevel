# FS25_BunkerAutoLevel

A Farming Simulator 25 mod that **automatically levels the fill heap inside bunker
silos** — spreading the input material (chaff, grass, etc.) evenly across the whole
silo so you don't have to drive a leveling blade back and forth.

## Status

Early scaffold (`v0.1.0.0`). The auto-level **core** (`BunkerSilo:autoLevel()`) is
implemented and server-authoritative; the redistribution sweep and the player-facing
trigger (activatable / keybind) are the next milestones.

## How it works

The bunker fill heap is stored in the Giants Engine **density-map height layer**, not
as a vehicle fill unit. Leveling reads the total volume of the silo's input fill type
over its area, removes it, then re-deposits it evenly using
`DensityMapHeightUtil.tipToGroundAroundLine`.

All mutations run **on the server only**; the resulting height changes replicate to
clients automatically via the engine's density-map sync, so the mod is multiplayer-safe
(including dedicated servers, which have no local player).

## Building a distributable zip

Run `zipThisMod.bat` from the mod root (requires 7-Zip). It produces
`FS25_BunkerAutoLevel.zip` ready to drop into your FS25 `mods` folder.

## Compatibility

- FS25 `descVersion` 109 (patch 1.19+)
- Multiplayer: supported (server-authoritative)
- Self-contained — no dependency on any other mod
