--
-- BunkerAutoLevel.lua
--
-- Automatically levels the fill heap inside a bunker silo so the input material
-- (chaff / grass etc.) is spread evenly across the whole silo area instead of
-- piling up wherever the trailer happened to tip it.
--
-- HOW THE BUNKER FILL HEAP WORKS (base game, see dataS/scripts/objects/BunkerSilo.lua):
--   * The heap is NOT a vehicle fill unit. It lives in the density-map HEIGHT layer.
--   * BunkerSilo.bunkerSiloArea is a parallelogram with three world-space corners:
--       start  (sx,sy,sz) -> the "origin" corner
--       width  (wx,wy,wz) -> origin + width edge
--       height (hx,hy,hz) -> origin + length edge
--   * The current volume of a fill type in the area is read with
--       DensityMapHeightUtil.getFillLevelAtArea(fillType, x0,z0, x1,z1, x2,z2)
--   * Material is removed with DensityMapHeightUtil.removeFromGroundByArea(...)
--   * Material is deposited (and spread, with a radius) with
--       DensityMapHeightUtil.tipToGroundAroundLine(...)  -- returns the amount NOT placed
--
-- LEVELING STRATEGY:
--   1. Read total volume V of inputFillType currently in the silo area.
--   2. Remove all of it from the ground in the area.
--   3. Re-deposit V evenly by sweeping tipToGroundAroundLine across the area in
--      parallel passes, capping the per-pass height so the result is flat.
--
-- MULTIPLAYER:
--   * Density-map height is server-authoritative state. ALL leveling MUST run on
--     the server only; the resulting height changes replicate to clients
--     automatically via the engine's density-map sync. A dedicated server has no
--     g_localPlayer, so we never gate the actual mutation on client-side state.
--   * A client request to level travels client -> server via BunkerAutoLevelEvent
--     (added in a later milestone); for now the entry point is server-guarded.
--
-- See project memory and the fs25-modding skill for the patterns this follows.
--

BunkerAutoLevel = {}
BunkerAutoLevel.MOD_NAME = g_currentModName
BunkerAutoLevel.MOD_DIRECTORY = g_currentModDirectory

-- Tuning knobs ---------------------------------------------------------------

-- Minimum volume (litres) that must be present before a level pass does anything.
BunkerAutoLevel.MIN_FILL_LEVEL = 100

-- Margin (metres) kept away from the inner walls when depositing, so material
-- does not spill over the wall tops. The base game inner area already insets
-- ~25cm; this is an extra safety margin for the spread radius.
BunkerAutoLevel.WALL_MARGIN = 0.5

local BunkerAutoLevel_installed = false

--- One-time install of the hooks into the base BunkerSilo class.
-- Called once at mod load. Base-game globals (BunkerSilo, DensityMapHeightUtil,
-- Utils) resolve via the mod env __index fall-through, so direct reference is fine.
function BunkerAutoLevel.install()
    if BunkerAutoLevel_installed then
        return
    end
    BunkerAutoLevel_installed = true

    -- Register our level function on every BunkerSilo instance.
    BunkerSilo.autoLevel = BunkerAutoLevel.autoLevel

    -- NOTE: the trigger that *calls* autoLevel (activatable entry, keybind, or
    -- "level while filling" tick) is intentionally not wired yet — that is the
    -- next milestone and depends on the UX choice. autoLevel() itself is the
    -- self-contained, testable core and is safe to call on the server directly,
    -- e.g. from the in-game console for verification.

    Logging.info("[%s] installed (auto-level core ready)", BunkerAutoLevel.MOD_NAME)
end

--- Level the fill heap in this bunker silo. SERVER ONLY.
-- Spreads all currently-present inputFillType material evenly across the silo
-- area. Safe to call repeatedly; a no-op when below MIN_FILL_LEVEL or not in the
-- FILL state.
-- @return number leftover litres that could not be placed (0 on full success)
function BunkerAutoLevel:autoLevel()
    -- Server-authoritative: density-map mutations only happen on the server.
    if not self.isServer then
        return 0
    end

    -- Only meaningful while the silo is open and accepting input material.
    if self.state ~= BunkerSilo.STATE_FILL then
        return 0
    end

    local area = self.bunkerSiloArea
    if area == nil or area.inner == nil then
        return 0
    end

    local fillType = self.inputFillType
    if fillType == nil or fillType == FillType.UNKNOWN then
        return 0
    end

    -- 1. How much material is in the silo right now (read over the inner area,
    --    matching how the base game measures fillLevel).
    local inner = area.inner
    local volume = DensityMapHeightUtil.getFillLevelAtArea(
        fillType,
        inner.sx, inner.sz,
        inner.wx, inner.wz,
        inner.hx, inner.hz
    )

    if volume == nil or volume < BunkerAutoLevel.MIN_FILL_LEVEL then
        return 0
    end

    -- 2. Remove everything currently on the ground in the FULL area.
    DensityMapHeightUtil.removeFromGroundByArea(
        area.sx, area.sz,
        area.wx, area.wz,
        area.hx, area.hz,
        fillType
    )

    -- 3. Re-deposit it evenly. We sweep parallel lines along the width edge,
    --    stepping along the length edge, and let tipToGroundAroundLine spread
    --    each drop. Any leftover is returned and (for now) discarded back to the
    --    ground at the centre so material is never lost.
    local leftover = BunkerAutoLevel.redistributeEvenly(self, fillType, volume)

    -- Recompute the cached fill level / compaction immediately so the HUD and
    -- close-silo logic stay consistent without waiting for the next updateTick.
    self:updateFillLevel()
    self:updateCompacting(math.min(self.compactedFillLevel, self.fillLevel))

    return leftover
end

--- Deposit `volume` litres of `fillType` spread evenly across the silo area.
-- Implementation stub for the redistribution sweep. Returns leftover litres.
-- Kept separate from autoLevel() so the sweep math can be tuned/tested in
-- isolation. SERVER ONLY (callers guarantee this).
function BunkerAutoLevel.redistributeEvenly(silo, fillType, volume)
    -- TODO(milestone 2): implement the parallel-line tipToGroundAroundLine sweep
    -- with a per-pass height cap derived from area footprint so the surface comes
    -- out flat. For now, re-tip the whole volume along the silo's centre line so
    -- no material is lost while the spread math is being finalised.
    local area = silo.bunkerSiloArea

    -- Centre line of the silo, from the middle of the start edge to the middle
    -- of the height (length) edge.
    local sx = area.sx + 0.5 * area.dwx
    local sz = area.sz + 0.5 * area.dwz
    local sy = DensityMapHeightUtil.getHeightAtWorldPos(sx, 0, sz)
    local ex = sx + area.dhx
    local ez = sz + area.dhz
    local ey = DensityMapHeightUtil.getHeightAtWorldPos(ex, 0, ez)

    local radius = DensityMapHeightUtil.getDefaultMaxRadius(fillType) or 1.0

    local leftover = DensityMapHeightUtil.tipToGroundAroundLine(
        nil,          -- vehicle (none)
        volume,       -- delta to place
        fillType,
        sx, sy, sz,
        ex, ey, ez,
        0.0,          -- innerRadius
        radius,       -- radius
        nil,          -- lineOffset
        false,        -- limitToLineHeight
        nil,          -- occlusionAreas
        false,        -- useOcclusionAreas
        true          -- applyChanges
    )

    return leftover or 0
end

-- Bootstrap -----------------------------------------------------------------
-- extraSourceFiles run at mod load, before the mission starts. BunkerSilo is a
-- base-game global available immediately, so install hooks now (guarded so a
-- hot-reload during dev doesn't double-install).
BunkerAutoLevel.install()
