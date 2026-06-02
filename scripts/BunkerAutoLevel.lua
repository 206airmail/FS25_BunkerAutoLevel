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

-- Fallback max heap height (metres) if a silo has no interaction trigger node to
-- read the height from.
BunkerAutoLevel.DEFAULT_MAX_HEIGHT = 3.0

-- Litres per cubic metre, for metering per-line deposit shares (FS25 fill volumes
-- are litres; 1 m^3 = 1000 l).
BunkerAutoLevel.LITERS_PER_M3 = 1000.0

-- If the material can't cover the whole floor to ~this depth (metres), deposit a
-- single centred pile instead of a thin partial layer.
BunkerAutoLevel.MIN_LAYER_DEPTH = 1.0

-- Set true to print volume/edge/placement diagnostics to the log on each level.
BunkerAutoLevel.DEBUG = true

-- How far (metres) past an edge the probe box centre sits when looking for a wall.
BunkerAutoLevel.WALL_PROBE_DISTANCE = 1.0

-- Half-thickness (metres) of the overlap box ALONG the outward normal.
BunkerAutoLevel.WALL_PROBE_HALF = 0.6

-- Half-span (metres) of the probe box ALONG the edge. SMALL on purpose: probing
-- only the centre of an edge avoids catching the perpendicular side walls at the
-- corners (which produced false "walled" on all four edges).
BunkerAutoLevel.WALL_PROBE_SPAN_HALF = 2.0

-- Vertical half-extent (metres) of the probe box. Tall enough to overlap a wall.
BunkerAutoLevel.WALL_PROBE_VHALF = 1.5

-- Collision mask for the wall probe: static buildings/objects (bunker walls
-- register as BUILDING; some custom silos use STATIC_OBJECT too).
BunkerAutoLevel.WALL_PROBE_MASK = CollisionFlag.BUILDING + CollisionFlag.STATIC_OBJECT

-- Scratch target for the overlap-box callback (avoids per-call allocation).
BunkerAutoLevel.probeResult = { hit = false, node = nil }

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

    -- Footprint area (m^2) and the volume needed to cover it to MIN_LAYER_DEPTH.
    -- If we have less than that, a thin layer over the whole floor looks wrong —
    -- a centred pile is what you'd actually get, so deposit that instead.
    local footprint = geo.length * geo.width
    local coverVolume = footprint * BunkerAutoLevel.MIN_LAYER_DEPTH * BunkerAutoLevel.LITERS_PER_M3

    local mode, placed
    if volume < coverVolume then
        mode = "pile"
        placed = BunkerAutoLevel.depositCenteredPile(geo, fillType, radius, volume, true)
    else
        mode = "layer"
        placed = BunkerAutoLevel.depositLayered(geo, fillType, radius, volume, edges, true)
    end

    if BunkerAutoLevel.DEBUG then
        Logging.info(
            "[%s] level: vol=%.0fl placed=%.0fl leftover=%.0fl mode=%s coverVol=%.0fl edges(F/B/L/R open)=%s/%s/%s/%s len=%.1f wid=%.1f cap=%.1fm r=%.2f",
            BunkerAutoLevel.MOD_NAME, volume, placed, math.max(0, volume - placed),
            mode, coverVolume,
            tostring(edges.frontOpen), tostring(edges.backOpen),
            tostring(edges.leftOpen), tostring(edges.rightOpen),
            geo.length, geo.width, geo.capHeight, radius)
    end

    return math.max(0, volume - placed)
end

--- Deposit `volume` as a single centred pile (used when there isn't enough to
-- cover the whole floor). Tips the whole amount at the silo centre and lets the
-- engine slope it out at the natural angle of repose. VOLUME-CONSERVING.
function BunkerAutoLevel.depositCenteredPile(geo, fillType, radius, volume, apply)
    if volume <= 0 then
        return 0
    end

    -- Centre of the silo area.
    local cx = geo.sx + 0.5 * geo.dhx + 0.5 * geo.dwx
    local cz = geo.sz + 0.5 * geo.dhz + 0.5 * geo.dwz

    -- Short cross line at the centre so the heap isn't a single sharp spike.
    local half = math.min(2.0, geo.width * 0.5 - 0.1, geo.length * 0.5 - 0.1)
    half = math.max(0.0, half)
    local sx = cx - geo.wnx * half
    local sz = cz - geo.wnz * half
    local ex = cx + geo.wnx * half
    local ez = cz + geo.wnz * half

    -- Deposit in chunks, re-reading the ground so it slumps outward into a pile.
    local chunks = 8
    local perChunk = volume / chunks
    local totalPlaced = 0
    for _ = 1, chunks do
        local sy = DensityMapHeightUtil.getHeightAtWorldPos(sx, 0, sz)
        local ey = DensityMapHeightUtil.getHeightAtWorldPos(ex, 0, ez)
        local placed = DensityMapHeightUtil.tipToGroundAroundLine(
            nil, perChunk, fillType,
            sx, sy, sz, ex, ey, ez,
            0.0, radius, nil,
            false,          -- limitToLineHeight=false: place the amount, natural slope
            nil, false, apply)
        totalPlaced = totalPlaced + (placed or 0)
    end
    return totalPlaced
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

    -- Floor Y: the area nodes sit at the silo floor (y=0 locally). Use the start
    -- node's world Y as the floor reference.
    local floorY = area.sy

    -- Max heap height = the interaction trigger node's height above the floor.
    -- The trigger is placed at the top of the usable silo volume (e.g. y=7 on the
    -- stock medium silo). Fall back to a sane default if no trigger is present.
    local capHeight = BunkerAutoLevel.DEFAULT_MAX_HEIGHT
    local capSource = "default"
    if silo.interactionTriggerNode ~= nil then
        local _, ty, _ = getWorldTranslation(silo.interactionTriggerNode)
        local h = ty - floorY
        if h > 0.5 then
            capHeight = h
            capSource = "trigger"
        end
        if BunkerAutoLevel.DEBUG then
            Logging.info("[%s]  cap: triggerNode=%s triggerWorldY=%.2f floorY=%.2f h=%.2f -> %s",
                BunkerAutoLevel.MOD_NAME, tostring(silo.interactionTriggerNode), ty, floorY, h, capSource)
        end
    elseif BunkerAutoLevel.DEBUG then
        Logging.info("[%s]  cap: no interactionTriggerNode -> default %.1fm",
            BunkerAutoLevel.MOD_NAME, capHeight)
    end

    return {
        area = area,
        sx = area.sx, sz = area.sz,
        floorY = floorY,
        capHeight = capHeight,
        dhx = area.dhx, dhz = area.dhz,
        dwx = area.dwx, dwz = area.dwz,
        length = length, width = width,
        lnx = lnx, lnz = lnz,   -- unit dir along length (toward back)
        wnx = wnx, wnz = wnz,   -- unit dir across width (toward right wall)
    }
end

--- Overlap-box callback: record the FIRST hit node and stop traversal.
function BunkerAutoLevel.probeCallback(transformId)
    BunkerAutoLevel.probeResult.hit = true
    BunkerAutoLevel.probeResult.node = transformId
    return false
end

--- True if the given edge has a static wall just beyond it.
-- @param which "front"/"back" (short ends, along length) or "left"/"right" (long
--        sides, along width).
-- Probes a SMALL box centred on the edge MIDPOINT, just outside the edge. Keeping
-- the box small along the edge avoids catching the perpendicular side walls at the
-- corners (which falsely reported every edge as walled). A real wall spanning the
-- end is caught at the midpoint; a wall-less open end / flat pad finds nothing.
function BunkerAutoLevel.probeEdgeIsWalled(geo, which)
    -- ecx/ecz = edge midpoint; onx/onz = OUTWARD unit normal of the edge.
    local ecx, ecz, onx, onz
    if which == "front" then
        ecx = geo.sx + 0.5 * geo.dwx
        ecz = geo.sz + 0.5 * geo.dwz
        onx, onz = -geo.lnx, -geo.lnz
    elseif which == "back" then
        ecx = geo.sx + geo.dhx + 0.5 * geo.dwx
        ecz = geo.sz + geo.dhz + 0.5 * geo.dwz
        onx, onz = geo.lnx, geo.lnz
    elseif which == "left" then
        ecx = geo.sx + 0.5 * geo.dhx
        ecz = geo.sz + 0.5 * geo.dhz
        onx, onz = -geo.wnx, -geo.wnz
    else -- "right"
        ecx = geo.sx + geo.dwx + 0.5 * geo.dhx
        ecz = geo.sz + geo.dwz + 0.5 * geo.dhz
        onx, onz = geo.wnx, geo.wnz
    end

    local d = BunkerAutoLevel.WALL_PROBE_DISTANCE
    local px = ecx + onx * d
    local pz = ecz + onz * d
    local py = DensityMapHeightUtil.getHeightAtWorldPos(px, 0, pz) + BunkerAutoLevel.WALL_PROBE_VHALF

    -- Box local Z aligned to the outward normal. Half-extents:
    --   X (along edge) = WALL_PROBE_SPAN_HALF (small), Y = VHALF, Z (outward) = HALF.
    local rotY = MathUtil.getYRotationFromDirection(onx, onz)
    BunkerAutoLevel.probeResult.hit = false
    BunkerAutoLevel.probeResult.node = nil
    overlapBox(
        px, py, pz,
        0, rotY, 0,
        BunkerAutoLevel.WALL_PROBE_SPAN_HALF, BunkerAutoLevel.WALL_PROBE_VHALF, BunkerAutoLevel.WALL_PROBE_HALF,
        "probeCallback", BunkerAutoLevel,
        BunkerAutoLevel.WALL_PROBE_MASK,
        true, true, true
    )

    if BunkerAutoLevel.DEBUG then
        local nodeName = "-"
        if BunkerAutoLevel.probeResult.node ~= nil and getName ~= nil then
            nodeName = getName(BunkerAutoLevel.probeResult.node) or tostring(BunkerAutoLevel.probeResult.node)
        end
        Logging.info("[%s]  probe %-5s: walled=%s hit=%s @(%.1f,%.1f,%.1f)",
            BunkerAutoLevel.MOD_NAME, which, tostring(BunkerAutoLevel.probeResult.hit), nodeName, px, py, pz)
    end

    return BunkerAutoLevel.probeResult.hit
end


--- Layered fill: fill the footprint to 1m, then 2m ... up to the cap, stopping
-- when material runs out. VOLUME-CONSERVING (limitToLineHeight + per-line metering).
--
-- Geometry: deposit lines run PERPENDICULAR to the fill direction (i.e. across the
-- silo, wall-to-wall on the closed axis), and are STEPPED along the fill direction
-- starting from the deepest WALLED end toward the OPEN end. Each line is metered to
-- ~its strip's share of the current 1m layer (capped by remaining) so no single
-- line hogs the whole volume — that was why everything piled against one wall.
-- @return total litres placed.
function BunkerAutoLevel.depositLayered(geo, fillType, radius, volume, edges, apply)
    if volume <= 0 then
        return 0
    end

    local margin = BunkerAutoLevel.WALL_OFFSET

    -- Decide the FILL axis = the axis that has an open end (material slopes toward
    -- the opening). Prefer the length axis; fall back to width; else (fully closed
    -- or fully open) fill along the length from one end.
    -- crossDir = unit vector the deposit LINE runs along (perpendicular to fill).
    -- fillDir  = unit vector we STEP along (toward the open end).
    local fillNx, fillNz, crossNx, crossNz, fillLen, crossLen
    local crossLowInset, crossHighInset   -- insets at the two ends of the cross line
    local fillStart, fillEnd              -- step range along fill axis

    local function pickAxisAlongLength()
        fillNx, fillNz = geo.lnx, geo.lnz
        crossNx, crossNz = geo.wnx, geo.wnz
        fillLen, crossLen = geo.length, geo.width
        crossLowInset = edges.leftOpen and margin or 0.0
        crossHighInset = edges.rightOpen and margin or 0.0
        -- step from the WALLED end toward the OPEN end
        if edges.frontOpen and not edges.backOpen then
            fillStart, fillEnd = geo.length - margin, margin           -- open front: start at back
        else
            fillStart, fillEnd = (edges.backOpen and 0.0 or 0.0) + margin*0, math.max(0.01, geo.length - (edges.backOpen and margin or 0.0))
            fillStart = 0.0
        end
    end
    local function pickAxisAlongWidth()
        fillNx, fillNz = geo.wnx, geo.wnz
        crossNx, crossNz = geo.lnx, geo.lnz
        fillLen, crossLen = geo.width, geo.length
        crossLowInset = edges.frontOpen and margin or 0.0
        crossHighInset = edges.backOpen and margin or 0.0
        if edges.leftOpen and not edges.rightOpen then
            fillStart, fillEnd = geo.width - margin, margin
        else
            fillStart, fillEnd = 0.0, math.max(0.01, geo.width - (edges.rightOpen and margin or 0.0))
        end
    end

    -- Choose fill axis: the one with exactly one open end is ideal (clear slope dir).
    local lengthHasOpen = edges.frontOpen or edges.backOpen
    local widthHasOpen = edges.leftOpen or edges.rightOpen
    if lengthHasOpen and not widthHasOpen then
        pickAxisAlongLength()
    elseif widthHasOpen and not lengthHasOpen then
        pickAxisAlongWidth()
    elseif lengthHasOpen then
        -- both axes have an open edge (e.g. straight silo open both ends, or a
        -- corner): fill along the longer axis for a tidier result.
        if geo.length >= geo.width then pickAxisAlongLength() else pickAxisAlongWidth() end
    else
        -- fully closed (or fully open box): just fill along length from offset 0.
        pickAxisAlongLength()
    end

    -- Cross-line endpoints (constant per step): from crossLowInset to crossLen-high.
    local cLow = crossLowInset
    local cHigh = math.max(cLow + 0.01, crossLen - crossHighInset)
    local crossSpan = cHigh - cLow

    -- Step layout along the fill axis.
    local fillSpan = math.abs(fillEnd - fillStart)
    local fillSign = (fillEnd >= fillStart) and 1 or -1
    local numSteps = math.max(1, math.floor(fillSpan / BunkerAutoLevel.LINE_SPACING + 0.5))
    local stepLen = fillSpan / numSteps

    -- Per-line litres to raise one strip (stepLen x crossSpan) by 1m of layer.
    local stripFootprint = stepLen * crossSpan
    local perLineFull = stripFootprint * BunkerAutoLevel.LITERS_PER_M3

    local capLevels = math.max(1, math.floor(geo.capHeight + 0.0001))
    local remaining = volume
    local totalPlaced = 0

    for level = 1, capLevels do
        if remaining <= 0 then break end
        local lineY = geo.floorY + level

        for s = 0, numSteps - 1 do
            if remaining <= 0 then break end
            local f = fillStart + fillSign * (s + 0.5) * stepLen

            -- Base point on the fill axis, then the cross line across the silo.
            local px = geo.sx + fillNx * f
            local pz = geo.sz + fillNz * f
            local sx = px + crossNx * cLow
            local sz = pz + crossNz * cLow
            local ex = px + crossNx * cHigh
            local ez = pz + crossNz * cHigh

            -- Meter this line to ~one strip's worth (plus a little headroom) so the
            -- layer spreads across all steps instead of dumping at the first.
            local delta = math.min(remaining, perLineFull * 1.25)

            local placed = DensityMapHeightUtil.tipToGroundAroundLine(
                nil,            -- vehicle
                delta,
                fillType,
                sx, lineY, sz,
                ex, lineY, ez,
                0.0,            -- innerRadius
                radius,         -- radius
                nil,            -- lineOffset
                true,           -- limitToLineHeight=true: fill UP TO lineY (this layer)
                nil,            -- occlusionAreas
                false,          -- useOcclusionAreas
                apply           -- applyChanges
            )
            placed = placed or 0
            remaining = remaining - placed
            totalPlaced = totalPlaced + placed
        end
    end

    return totalPlaced
end

-- Bootstrap -----------------------------------------------------------------
-- extraSourceFiles run at mod load, before the mission starts. BunkerSilo is a
-- base-game global available immediately, so install hooks now (guarded so a
-- hot-reload during dev doesn't double-install).
BunkerAutoLevel.install()
