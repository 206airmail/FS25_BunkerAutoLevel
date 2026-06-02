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

-- Spacing (metres) between adjacent deposit lines swept across the silo width.
-- Smaller = flatter top but more passes (slower). ~1m merges cleanly with the
-- default tip radius.
BunkerAutoLevel.LINE_SPACING = 1.0

-- How far (metres) the initial tip point sits IN FROM a walled end / corner, so
-- the heap also slopes gently down to that wall instead of packing dead flat.
BunkerAutoLevel.WALL_OFFSET = 1.0

-- Half-length (metres) of the short anchor line the volume is tipped along.
BunkerAutoLevel.ANCHOR_LINE_HALF = 2.0

-- Number of chunks the volume is deposited in at the anchor (re-reading the
-- ground between chunks so the heap slumps outward instead of spiking).
BunkerAutoLevel.DEPOSIT_CHUNKS = 6

-- Set true to print volume/edge/placement diagnostics to the log on each level.
BunkerAutoLevel.DEBUG = true

-- How far (metres) past a short end to probe for a static wall when deciding
-- whether that end is open (slope a drivable ramp) or walled (pack flat).
BunkerAutoLevel.WALL_PROBE_DISTANCE = 1.0

-- Half-thickness (metres) of the overlap box used for the wall probe.
BunkerAutoLevel.WALL_PROBE_HALF = 0.5

-- Collision mask for the wall probe: static buildings/objects (bunker walls
-- register as BUILDING; some custom silos use STATIC_OBJECT too).
BunkerAutoLevel.WALL_PROBE_MASK = CollisionFlag.BUILDING + CollisionFlag.STATIC_OBJECT

-- Scratch target for the overlap-box callback (avoids per-call allocation).
BunkerAutoLevel.probeResult = { hit = false }

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

    -- The keybind is registered/unregistered as the LOCAL player enters/leaves a
    -- bunker, reusing the base game's existing interaction trigger (the same one
    -- that drives the compaction HUD and the "cover silo" prompt). The trigger
    -- callback's return value is unused by the engine, so an appended hook is safe.
    BunkerSilo.interactionTriggerCallback =
        Utils.appendedFunction(BunkerSilo.interactionTriggerCallback, BunkerAutoLevel.onInteractionTrigger)

    -- Clean up our action event if a silo we were attached to is deleted while the
    -- player is still in range (e.g. sold from under them).
    BunkerSilo.delete = Utils.prependedFunction(BunkerSilo.delete, BunkerAutoLevel.onBunkerDelete)

    -- Keep the keybind's visibility in sync with the silo's live state (so it
    -- appears the moment the heap has material, while the player stands inside).
    -- The base update already runs every frame while in range; we only do work for
    -- the currently-active silo.
    BunkerSilo.update = Utils.appendedFunction(BunkerSilo.update, BunkerAutoLevel.onBunkerUpdate)

    Logging.info("[%s] installed (auto-level core + keybind ready)", BunkerAutoLevel.MOD_NAME)
end

-- Keybind registration -------------------------------------------------------
-- We track at most one "active" silo at a time (the one whose trigger the local
-- player most recently entered). Registration is purely client-side input state;
-- the actual level request goes to the server via BunkerAutoLevelEvent.

BunkerAutoLevel.activeSilo = nil
BunkerAutoLevel.actionEventId = nil

--- Appended to BunkerSilo:interactionTriggerCallback. Registers our keybind when
-- the LOCAL player enters this silo's interaction trigger, and removes it on exit.
-- Signature mirrors the base callback: (self, triggerId, otherId, onEnter, onLeave, ...)
function BunkerAutoLevel:onInteractionTrigger(_, otherId, onEnter, onLeave, _, _)
    local localPlayer = g_localPlayer
    if localPlayer == nil then
        return -- dedicated server has no local player; nothing to bind
    end

    -- Only react to the local player's own body entering/leaving (vehicles drive
    -- the base game's per-vehicle path; the keybind is a player-context action).
    if otherId ~= localPlayer.rootNode then
        return
    end

    if onEnter then
        BunkerAutoLevel.setActiveSilo(self)
    elseif onLeave then
        if BunkerAutoLevel.activeSilo == self then
            BunkerAutoLevel.setActiveSilo(nil)
        end
    end
end

--- Prepended to BunkerSilo:delete. Drops our binding if the active silo is gone.
function BunkerAutoLevel:onBunkerDelete()
    if BunkerAutoLevel.activeSilo == self then
        BunkerAutoLevel.setActiveSilo(nil)
    end
end

--- Appended to BunkerSilo:update. Refreshes keybind visibility for the active silo
-- so it tracks live fill state without the player having to re-enter the trigger.
function BunkerAutoLevel:onBunkerUpdate(_)
    if BunkerAutoLevel.activeSilo == self then
        BunkerAutoLevel.updateActionVisibility()
    end
end

--- Set (or clear) the silo the keybind currently targets, registering/removing
-- the action event accordingly.
function BunkerAutoLevel.setActiveSilo(silo)
    BunkerAutoLevel.activeSilo = silo

    if silo == nil then
        if BunkerAutoLevel.actionEventId ~= nil then
            g_inputBinding:removeActionEvent(BunkerAutoLevel.actionEventId)
            BunkerAutoLevel.actionEventId = nil
        end
        return
    end

    if BunkerAutoLevel.actionEventId == nil then
        local _, eventId = g_inputBinding:registerActionEvent(
            InputAction.BUNKERAUTOLEVEL_LEVEL,
            BunkerAutoLevel,
            BunkerAutoLevel.onLevelAction,
            false,  -- triggerUp
            true,   -- triggerDown
            false,  -- triggerAlways
            true    -- startActive
        )
        BunkerAutoLevel.actionEventId = eventId
        g_inputBinding:setActionEventText(eventId, g_i18n:getText("input_BUNKERAUTOLEVEL_LEVEL"))
        g_inputBinding:setActionEventTextPriority(eventId, GS_PRIO_NORMAL)
    end

    BunkerAutoLevel.updateActionVisibility()
end

--- Show the keybind only when leveling is meaningful: silo in FILL state with
-- material present. Call whenever the relevant state may have changed.
function BunkerAutoLevel.updateActionVisibility()
    if BunkerAutoLevel.actionEventId == nil then
        return
    end
    local silo = BunkerAutoLevel.activeSilo
    local visible = silo ~= nil
        and silo.state == BunkerSilo.STATE_FILL
        and (silo.fillLevel or 0) > 0
    g_inputBinding:setActionEventActive(BunkerAutoLevel.actionEventId, visible)
end

--- Keypress handler: request a level of the active silo (client -> server).
function BunkerAutoLevel:onLevelAction(_, _)
    local silo = BunkerAutoLevel.activeSilo
    if silo == nil then
        return
    end
    if silo.state ~= BunkerSilo.STATE_FILL or (silo.fillLevel or 0) <= 0 then
        return
    end
    BunkerAutoLevelEvent.sendRequest(silo)
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
-- Profile goal:
--   * FLAT against every wall — the two long side walls (always present) and any
--     short end that a wall probe finds closed (corner / 3-sided silos).
--   * SLOPED down (natural angle of repose) at any OPEN short end, so a compactor
--     can still drive up onto the heap.
-- Method: sweep deposit lines that run ALONG the length (dh) axis, stepped across
-- the width (dw). Each line is capped to a target flat height (limitToLineHeight).
-- Lines run to the very edge at walled ends (flat to the wall) but stop short at
-- open ends, letting the engine's angle of repose form the drivable ramp.
-- SERVER ONLY (callers guarantee this). Returns leftover litres (0 on success).
function BunkerAutoLevel.redistributeEvenly(silo, fillType, volume)
    local geo = BunkerAutoLevel.computeGeometry(silo)
    if geo == nil then
        return volume
    end

    -- Detect which of the four edges are open vs. walled. The base BunkerSilo
    -- only models the two long side walls, and some silos (flat field pads) have
    -- NO walls at all, so we probe all four edges for static collision rather than
    -- assuming. An open edge gets a drivable angle-of-repose ramp; a walled edge
    -- packs flat against the wall.
    local edges = {
        frontOpen = not BunkerAutoLevel.probeEdgeIsWalled(geo, "front"),
        backOpen  = not BunkerAutoLevel.probeEdgeIsWalled(geo, "back"),
        leftOpen  = not BunkerAutoLevel.probeEdgeIsWalled(geo, "left"),
        rightOpen = not BunkerAutoLevel.probeEdgeIsWalled(geo, "right"),
    }

    local radius = DensityMapHeightUtil.getDefaultMaxRadius(fillType) or 1.0

    -- Anchor-and-slope model: dump the whole volume at a single anchor point
    -- determined by the walls (centre when fully open; against the walled end/
    -- corner otherwise) and let the engine slope it out at the angle of repose.
    local placed = BunkerAutoLevel.depositAtAnchor(geo, fillType, radius, volume, edges, true)

    if BunkerAutoLevel.DEBUG then
        Logging.info(
            "[%s] level: vol=%.0fl placed=%.0fl leftover=%.0fl edges(F/B/L/R open)=%s/%s/%s/%s len=%.1f wid=%.1f r=%.2f",
            BunkerAutoLevel.MOD_NAME, volume, placed, math.max(0, volume - placed),
            tostring(edges.frontOpen), tostring(edges.backOpen),
            tostring(edges.leftOpen), tostring(edges.rightOpen),
            geo.length, geo.width, radius)
    end

    return math.max(0, volume - placed)
end

--- Precompute world-space geometry for the silo area (vectors, unit dirs, length).
-- Returns nil if the area is degenerate.
function BunkerAutoLevel.computeGeometry(silo)
    local area = silo.bunkerSiloArea
    if area == nil then
        return nil
    end

    local length = MathUtil.vector2Length(area.dhx, area.dhz) -- along dh (open-end axis)
    local width = MathUtil.vector2Length(area.dwx, area.dwz)  -- wall-to-wall gap
    if length < 0.5 or width < 0.5 then
        return nil
    end

    -- Unit vector along the length (front->back) and across the width.
    local lnx, lnz = area.dhx / length, area.dhz / length
    local wnx, wnz = area.dwx / width, area.dwz / width

    return {
        area = area,
        sx = area.sx, sz = area.sz,
        dhx = area.dhx, dhz = area.dhz,
        dwx = area.dwx, dwz = area.dwz,
        length = length, width = width,
        lnx = lnx, lnz = lnz,   -- unit dir along length (toward back)
        wnx = wnx, wnz = wnz,   -- unit dir across width (toward right wall)
    }
end

--- Overlap-box callback: flag a hit and stop traversal.
function BunkerAutoLevel.probeCallback(_)
    BunkerAutoLevel.probeResult.hit = true
    return false
end

--- True if the given edge has a static wall just beyond it.
-- @param which "front"/"back" (the short ends, along the length axis) or
--        "left"/"right" (the long sides, along the width axis).
-- Probes an overlap box centred just OUTSIDE that edge, spanning the edge's
-- length, thin in the outward direction. Long-side probes naturally hit the
-- silo's own wallLeft/wallRight collision when present, and find nothing on a
-- wall-less flat pad — exactly the discrimination we want.
function BunkerAutoLevel.probeEdgeIsWalled(geo, which)
    -- ecx/ecz = centre of the edge; onx/onz = OUTWARD unit normal of the edge;
    -- span = full length of the edge (box half-extent along the edge direction).
    local ecx, ecz, onx, onz, span
    if which == "front" then
        ecx = geo.sx + 0.5 * geo.dwx
        ecz = geo.sz + 0.5 * geo.dwz
        onx, onz = -geo.lnx, -geo.lnz
        span = geo.width
    elseif which == "back" then
        ecx = geo.sx + geo.dhx + 0.5 * geo.dwx
        ecz = geo.sz + geo.dhz + 0.5 * geo.dwz
        onx, onz = geo.lnx, geo.lnz
        span = geo.width
    elseif which == "left" then
        ecx = geo.sx + 0.5 * geo.dhx
        ecz = geo.sz + 0.5 * geo.dhz
        onx, onz = -geo.wnx, -geo.wnz
        span = geo.length
    else -- "right"
        ecx = geo.sx + geo.dwx + 0.5 * geo.dhx
        ecz = geo.sz + geo.dwz + 0.5 * geo.dhz
        onx, onz = geo.wnx, geo.wnz
        span = geo.length
    end

    local d = BunkerAutoLevel.WALL_PROBE_DISTANCE
    local px = ecx + onx * (d * 0.5)
    local pz = ecz + onz * (d * 0.5)
    local py = DensityMapHeightUtil.getHeightAtWorldPos(px, 0, pz) + 1.0

    -- Box local Z aligned to the outward normal: half-extents are
    -- (along-edge = span/2, vertical = 1.0, outward = WALL_PROBE_HALF).
    local rotY = MathUtil.getYRotationFromDirection(onx, onz)
    BunkerAutoLevel.probeResult.hit = false
    overlapBox(
        px, py, pz,
        0, rotY, 0,
        span * 0.5, 1.0, BunkerAutoLevel.WALL_PROBE_HALF,
        "probeCallback", BunkerAutoLevel,
        BunkerAutoLevel.WALL_PROBE_MASK,
        true, true, true
    )
    return BunkerAutoLevel.probeResult.hit
end

--- Compute the anchor distance along an axis given which ends are open/walled.
-- @param len axis length; @param openLow open at offset 0; @param openHigh open at len.
-- Returns the anchor offset along the axis:
--   both open  -> centre (material slopes both ways)
--   one walled -> WALL_OFFSET in from that wall (so the heap also slopes gently
--                 down to the wall, not packed dead flat against it)
--   both walled-> centre
function BunkerAutoLevel.anchorOnAxis(len, openLow, openHigh)
    local off = BunkerAutoLevel.WALL_OFFSET
    if openLow == openHigh then
        return len * 0.5            -- both open or both walled -> centre
    elseif not openLow then
        return math.min(off, len * 0.5)        -- walled at low end -> 1m in from offset 0
    else
        return math.max(len - off, len * 0.5)  -- walled at high end -> 1m in from len
    end
end

--- Deposit the whole `volume` at a single anchor and let the engine slope it out
-- at the natural angle of repose. The anchor is chosen from the walls:
--   * fully open / straight  -> centre of the silo (heap slopes out all ways)
--   * 3-sided [ (one end walled) -> centred across width, near the walled end
--   * L / corner -> in the corner
-- The deposit is done as a SHORT line centred on the anchor (a point-ish source);
-- a large delta naturally forms a cone/ridge that runs downhill toward the open
-- side(s). VOLUME-CONSERVING: places `volume` litres (delta), returns what the
-- engine accepted.
--
-- For big volumes we deposit in several chunks at the same anchor, re-reading the
-- ground between chunks so each chunk slumps outward before the next lands — this
-- spreads the heap toward the open end instead of spiking straight up.
-- @param apply when false, performs a dry-run sum (no ground change).
-- @return total litres placed.
function BunkerAutoLevel.depositAtAnchor(geo, fillType, radius, volume, edges, apply)
    if volume <= 0 then
        return 0
    end

    -- Anchor offsets along each axis (1m in from any walled end/corner; centre when
    -- that axis is open at both ends).
    local along = BunkerAutoLevel.anchorOnAxis(geo.length, edges.frontOpen, edges.backOpen)
    local across = BunkerAutoLevel.anchorOnAxis(geo.width, edges.leftOpen, edges.rightOpen)

    -- Anchor world position.
    local ax = geo.sx + geo.lnx * along + geo.wnx * across
    local az = geo.sz + geo.lnz * along + geo.wnz * across

    -- Short anchor line, oriented across the width, clamped to stay inside the
    -- silo. A small span (not a point) avoids an unnaturally sharp spike.
    local half = math.min(BunkerAutoLevel.ANCHOR_LINE_HALF, geo.width * 0.5 - 0.1)
    half = math.max(0.0, half)
    local sx = ax - geo.wnx * half
    local sz = az - geo.wnz * half
    local ex = ax + geo.wnx * half
    local ez = az + geo.wnz * half

    local chunks = math.max(1, BunkerAutoLevel.DEPOSIT_CHUNKS)
    local perChunk = volume / chunks
    local totalPlaced = 0

    for _ = 1, chunks do
        -- Re-read ground each chunk so the heap builds on what's already slumped.
        local sy = DensityMapHeightUtil.getHeightAtWorldPos(sx, 0, sz)
        local ey = DensityMapHeightUtil.getHeightAtWorldPos(ex, 0, ez)

        local placed = DensityMapHeightUtil.tipToGroundAroundLine(
            nil,            -- vehicle
            perChunk,       -- delta to place (litres) -- volume-driven
            fillType,
            sx, sy, sz,
            ex, ey, ez,
            0.0,            -- innerRadius
            radius,         -- radius
            nil,            -- lineOffset
            false,          -- limitToLineHeight = false: place the AMOUNT, not to a level
            nil,            -- occlusionAreas
            false,          -- useOcclusionAreas
            apply           -- applyChanges
        )
        totalPlaced = totalPlaced + (placed or 0)
    end

    return totalPlaced
end

-- Bootstrap -----------------------------------------------------------------
-- extraSourceFiles run at mod load, before the mission starts. BunkerSilo is a
-- base-game global available immediately, so install hooks now (guarded so a
-- hot-reload during dev doesn't double-install).
BunkerAutoLevel.install()
