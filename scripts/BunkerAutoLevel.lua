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

    -- Layered fill: fill the whole footprint to 1m, then 2m, then 3m ... up to the
    -- cap height, stopping when the material runs out. Each layer is a flat fill at
    -- its level; the last (partial) layer is laid starting from the walled end so a
    -- partly-filled silo packs toward the back wall, not the open mouth.
    local placed = BunkerAutoLevel.depositLayered(geo, fillType, radius, volume, edges, true)

    if BunkerAutoLevel.DEBUG then
        Logging.info(
            "[%s] level: vol=%.0fl placed=%.0fl leftover=%.0fl edges(F/B/L/R open)=%s/%s/%s/%s len=%.1f wid=%.1f cap=%.1fm r=%.2f",
            BunkerAutoLevel.MOD_NAME, volume, placed, math.max(0, volume - placed),
            tostring(edges.frontOpen), tostring(edges.backOpen),
            tostring(edges.leftOpen), tostring(edges.rightOpen),
            geo.length, geo.width, geo.capHeight, radius)
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


--- Layered fill: fill the whole footprint to 1m, then 2m, then 3m ... up to the
-- cap height, stopping when the material runs out. Each layer is a flat fill at
-- `floorY + level` using limitToLineHeight=true (fill TO a level) but capped by
-- the remaining volume passed as the delta, so it never creates material. Layers
-- are laid by sweeping deposit lines that run ALONG the length axis, stepped
-- across the width. Within the partial top layer the strips are ordered from the
-- WALLED end first so a partly-filled silo packs toward the back wall.
-- VOLUME-CONSERVING. @return total litres placed.
function BunkerAutoLevel.depositLayered(geo, fillType, radius, volume, edges, apply)
    if volume <= 0 then
        return 0
    end

    -- Footprint band across the width: inset from OPEN long sides so material
    -- slopes there; run to WALLED sides. Strips run the full length, inset from
    -- OPEN ends.
    local margin = BunkerAutoLevel.WALL_OFFSET
    local leftInset = edges.leftOpen and margin or 0.0
    local rightInset = edges.rightOpen and margin or 0.0
    local band = geo.width - leftInset - rightInset
    if band <= 0 then
        leftInset, band = geo.width * 0.5, 0.0
    end

    local startDist = edges.frontOpen and margin or 0.0
    local endDist = math.max(startDist + 0.01, geo.length - (edges.backOpen and margin or 0.0))

    -- Strip layout across the width.
    local numLines = (band > 0) and math.max(1, math.floor(band / BunkerAutoLevel.LINE_SPACING + 0.5)) or 1
    local stepW = (band > 0) and (band / numLines) or 0

    -- Which length-end is walled? Lay each layer's lines from the walled end so a
    -- partial layer fills toward the back wall. We bias by choosing the line's
    -- "start" of the segment at the walled end (the engine fills from there).
    -- Strip ordering across width doesn't matter for a full layer; for the partial
    -- top layer we want material concentrated at the walled END (length axis), and
    -- tipToGroundAroundLine fills along the whole line, so each line already spans
    -- the length. To bias toward the walled end we SHORTEN the line for the partial
    -- layer from the open end inward (handled implicitly by running out of volume).

    local capLevels = math.max(1, math.floor(geo.capHeight + 0.0001))
    local remaining = volume
    local totalPlaced = 0

    for level = 1, capLevels do
        if remaining <= 0 then break end
        local lineY = geo.floorY + level

        for i = 0, numLines - 1 do
            if remaining <= 0 then break end
            local w = (band > 0) and (leftInset + (i + 0.5) * stepW) or leftInset
            local bx = geo.sx + geo.wnx * w
            local bz = geo.sz + geo.wnz * w

            -- Line runs along the length. Order endpoints so the WALLED end is the
            -- segment start (material fills from there outward on a partial layer).
            local sDist, eDist = startDist, endDist
            if edges.frontOpen and not edges.backOpen then
                sDist, eDist = endDist, startDist   -- back walled -> start at back
            end

            local sx = bx + geo.lnx * sDist
            local sz = bz + geo.lnz * sDist
            local ex = bx + geo.lnx * eDist
            local ez = bz + geo.lnz * eDist

            local placed = DensityMapHeightUtil.tipToGroundAroundLine(
                nil,            -- vehicle
                remaining,      -- delta = remaining volume (HARD cap; no creation)
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
