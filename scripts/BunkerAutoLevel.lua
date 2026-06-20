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

-- How far (metres) the anchor (tip point) sits IN FROM a walled end / corner, so
-- the heap also slopes gently down to that wall instead of packing dead flat.
BunkerAutoLevel.WALL_OFFSET = 1.0

-- Deposit grid cell size (metres). Footprint is swept as a grid of cells this big;
-- each cell is capped at its local allowed (crown) height. Smaller = smoother
-- profile (shallower inter-cell ridges), more tip calls.
BunkerAutoLevel.GRID_STEP = 1.0

-- Litres offered per cell tip call (engine caps to the cell's allowed height).
BunkerAutoLevel.CHUNK_LITERS = 5000.0

-- Each height band is swept repeatedly (repose limits how much stacks per sweep)
-- until a full sweep places < BAND_STALL_FRACTION of the volume, or this cap.
BunkerAutoLevel.MAX_BAND_SWEEPS = 12
BunkerAutoLevel.BAND_STALL_FRACTION = 0.002

-- Post-deposit smoothing (blends the inter-cell ridges/valleys into one surface).
-- The whole level op runs in ~10ms, so we can afford heavy smoothing on this
-- one-shot action.
BunkerAutoLevel.SMOOTH_STEP = 1.0     -- grid step (m) of the smoothing sweep
BunkerAutoLevel.SMOOTH_RADIUS = 9.0   -- smoothing kernel radius (m) — wide enough to flatten ridges
BunkerAutoLevel.SMOOTH_AMOUNT = 1.0   -- 0..1 blend strength per pass
BunkerAutoLevel.SMOOTH_PASSES = 15    -- number of smoothing sweeps

-- Fallback max heap height (metres) if a silo's trigger/wall height can't be read.
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

    -- Detect which of the four edges are open vs. walled.
    -- LONG SIDES (left/right): the base BunkerSilo stores wallLeft/wallRight from
    -- the silo XML, so we read them directly (reliable) instead of probing — the
    -- collision probe missed thin/offset side walls. A side is walled if its wall
    -- node exists AND is visible (extendable silos hide a wall where they join).
    -- SHORT ENDS (front/back): end walls are NOT in the data (corner / 3-sided
    -- silos build them as plain collision), so those we still detect by probing.
    local leftWalled, rightWalled = BunkerAutoLevel.detectSideWalls(silo, geo)
    local edges = {
        frontOpen = not BunkerAutoLevel.probeEdgeIsWalled(geo, "front"),
        backOpen  = not BunkerAutoLevel.probeEdgeIsWalled(geo, "back"),
        leftOpen  = not leftWalled,
        rightOpen = not rightWalled,
    }

    local radius = DensityMapHeightUtil.getDefaultMaxRadius(fillType) or 1.0

    -- Two-height 45° crown deposit: mound from the anchor, capped per-point at the
    -- allowed-height profile (flush to wall tops at walled edges, 45° crown above
    -- walls toward centre up to the trigger top, 45° ramp to floor at open ends).
    local placed = BunkerAutoLevel.depositFromAnchor(geo, fillType, radius, volume, edges, true)

    if BunkerAutoLevel.DEBUG then
        Logging.info(
            "[%s] level: vol=%.0fl placed=%.0fl leftover=%.0fl edges(F/B/L/R open)=%s/%s/%s/%s len=%.1f wid=%.1f wall=%.1fm top=%.1fm r=%.2f",
            BunkerAutoLevel.MOD_NAME, volume, placed, math.max(0, volume - placed),
            tostring(edges.frontOpen), tostring(edges.backOpen),
            tostring(edges.leftOpen), tostring(edges.rightOpen),
            geo.length, geo.width, geo.wallHeight, geo.triggerTop, radius)
    end

    return math.max(0, volume - placed)
end

--- Anchor offset along an axis: 1m in from a walled end, centre when open (or both
-- walled). openLow = open at offset 0, openHigh = open at axis length.
function BunkerAutoLevel.anchorOnAxis(len, openLow, openHigh)
    local off = BunkerAutoLevel.WALL_OFFSET
    if openLow == openHigh then
        return len * 0.5                         -- both open / both walled -> centre
    elseif not openLow then
        return math.min(off, len * 0.5)          -- walled at low end -> 1m in
    else
        return math.max(len - off, len * 0.5)    -- walled at high end -> 1m in
    end
end

--- Allowed heap height (metres above floor) at a point given by its along/across
-- offsets inside the silo area. Each edge contributes (edgeHeight + distanceToEdge)
-- at a 45° slope (tan45 = 1); the allowed height is the MIN over all four edges,
-- clamped to the trigger-top ceiling. Walled edge height = wallHeight; OPEN edge (or
-- wall-less side) = 0, which yields a 45° ramp down to the floor at the opening.
-- @param along distance from the front (offset 0) along the length axis.
-- @param across distance from the left (offset 0) along the width axis.
function BunkerAutoLevel.allowedHeight(geo, edges, along, across)
    local wh = geo.wallHeight
    local hFront = edges.frontOpen and 0.0 or wh
    local hBack  = edges.backOpen  and 0.0 or wh
    local hLeft  = edges.leftOpen  and 0.0 or wh
    local hRight = edges.rightOpen and 0.0 or wh

    local dFront = along
    local dBack  = geo.length - along
    local dLeft  = across
    local dRight = geo.width - across

    local a = math.min(hFront + dFront, hBack + dBack, hLeft + dLeft, hRight + dRight)
    return math.min(a, geo.triggerTop)
end

--- Unified deposit with the two-height 45° crown profile. Sweeps a grid of short
-- cross-lines over the footprint; each cell is capped at its local allowedHeight
-- (flush to wall tops at walled edges, 45° crown above the walls toward the centre,
-- 45° ramp to the floor at open ends). Fills bottom-up in 1m layers so a partial
-- amount makes a centred mound and a full amount makes the crowned shape.
-- VOLUME-CONSERVING. @return total litres placed.
function BunkerAutoLevel.depositFromAnchor(geo, fillType, radius, volume, edges, apply)
    if volume <= 0 then
        return 0
    end

    -- Grid of deposit cells across the footprint (centres at half-steps).
    local step = BunkerAutoLevel.GRID_STEP
    local nA = math.max(1, math.floor(geo.length / step + 0.5))   -- along length
    local nC = math.max(1, math.floor(geo.width / step + 0.5))    -- across width
    local stepA = geo.length / nA
    local stepC = geo.width / nC
    local halfC = stepC * 0.5   -- each cell deposits a short cross-line of this half-len

    -- Anchor (1m off walled ends / corner, centred on open axes) — material mounds
    -- here first, so a partial amount makes a centred pile near the anchor.
    local anchorAlong = BunkerAutoLevel.anchorOnAxis(geo.length, edges.frontOpen, edges.backOpen)
    local anchorAcross = BunkerAutoLevel.anchorOnAxis(geo.width, edges.leftOpen, edges.rightOpen)

    -- Precompute each cell's centre offsets, allowed cap height, and distance to the
    -- anchor. Fill CLOSEST-to-anchor cells first so material mounds at the anchor and
    -- spreads outward; each cell is still capped at its own allowed (crown) height.
    local cells = {}
    for ia = 0, nA - 1 do
        local along = (ia + 0.5) * stepA
        for ic = 0, nC - 1 do
            local across = (ic + 0.5) * stepC
            local capH = BunkerAutoLevel.allowedHeight(geo, edges, along, across)
            if capH > 0.05 then
                local da = along - anchorAlong
                local dc = across - anchorAcross
                cells[#cells + 1] = { along = along, across = across, capH = capH,
                                      dist = da * da + dc * dc }
            end
        end
    end
    -- Nearest-to-anchor first.
    table.sort(cells, function(p, q) return p.dist < q.dist end)

    local remaining = volume
    local totalPlaced = 0

    -- BOTTOM-UP fill in 1m bands so the heap height matches the volume (e.g. 50 m³
    -- in a big silo = a ~1m mound, NOT a tall spike). Within each band, fill cells
    -- nearest the anchor first so a partial amount makes a centred mound; the band
    -- height is clipped per-cell by the crown cap (c.capH). Inter-cell steps are
    -- blended by the smoothing pass afterwards.
    -- Raising a cell to its target in one pass is repose-limited: if neighbours are
    -- still low the engine refuses to stack and returns the unplaced amount. So each
    -- band is SWEPT REPEATEDLY until it stops accepting (a sweep places ~nothing),
    -- then we move up a level. Otherwise large volumes leave a big leftover.
    local maxLevels = math.max(1, math.ceil(geo.triggerTop + 0.0001))
    for level = 1, maxLevels do
        if remaining <= 0 then break end
        local bandTop = level

        for _ = 1, BunkerAutoLevel.MAX_BAND_SWEEPS do
            if remaining <= 0 then break end
            local sweepPlaced = 0
            for _, c in ipairs(cells) do
                if remaining <= 0 then break end
                if c.capH > (level - 1) + 0.01 then    -- cell still rising in this band
                    local cellCapY = geo.floorY + math.min(bandTop, c.capH)
                    local cx = geo.sx + geo.lnx * c.along + geo.wnx * c.across
                    local cz = geo.sz + geo.lnz * c.along + geo.wnz * c.across
                    local sx = cx - geo.wnx * halfC
                    local sz = cz - geo.wnz * halfC
                    local ex = cx + geo.wnx * halfC
                    local ez = cz + geo.wnz * halfC

                    local chunk = math.min(remaining, BunkerAutoLevel.CHUNK_LITERS)
                    local placed = DensityMapHeightUtil.tipToGroundAroundLine(
                        nil, chunk, fillType,
                        sx, cellCapY, sz, ex, cellCapY, ez,
                        0.0, radius, nil,
                        true,            -- limitToLineHeight: cap at this band/crown Y
                        nil, false, apply)
                    placed = placed or 0
                    remaining = remaining - placed
                    totalPlaced = totalPlaced + placed
                    sweepPlaced = sweepPlaced + placed
                end
            end
            -- Band is full once a whole sweep barely placed anything.
            if sweepPlaced < volume * BunkerAutoLevel.BAND_STALL_FRACTION then
                break
            end
        end
    end

    -- Smoothing pass: the grid of capped cell-tips leaves ridges/valleys between
    -- cells. Sweep the footprint and smooth the height field to blend them into a
    -- continuous surface. (Only fill types with allowsSmoothing, e.g. CHAFF, smooth;
    -- SILAGE does not — but the silo input type is the chaff-like input fill.)
    if apply then
        BunkerAutoLevel.smoothFootprint(geo, edges)
    end

    return totalPlaced
end

--- Smooth the deposited heap to remove the inter-cell ridges/valleys. Sweeps a grid
-- over the footprint calling smoothDensityMapHeightAtWorldPos at each point. Runs a
-- few passes for a cleaner surface.
function BunkerAutoLevel.smoothFootprint(geo, edges)
    if smoothDensityMapHeightAtWorldPos == nil then
        return
    end
    local updater = g_densityMapHeightManager:getTerrainDetailHeightUpdater()
    if updater == nil then
        return
    end
    local tireId = g_currentMission.tireTrackSystem.tireTrackSystemId

    local step = BunkerAutoLevel.SMOOTH_STEP
    local nA = math.max(1, math.floor(geo.length / step + 0.5))
    local nC = math.max(1, math.floor(geo.width / step + 0.5))
    local stepA = geo.length / nA
    local stepC = geo.width / nC
    local smoothRadius = BunkerAutoLevel.SMOOTH_RADIUS
    local smoothAmount = BunkerAutoLevel.SMOOTH_AMOUNT

    local nSmoothed, nNilType, nNoSmooth = 0, 0, 0
    for _ = 1, BunkerAutoLevel.SMOOTH_PASSES do
        for ia = 0, nA - 1 do
            local along = (ia + 0.5) * stepA
            for ic = 0, nC - 1 do
                local across = (ic + 0.5) * stepC
                local x = geo.sx + geo.lnx * along + geo.wnx * across
                local z = geo.sz + geo.lnz * along + geo.wnz * across
                local y = DensityMapHeightUtil.getHeightAtWorldPos(x, 0, z)
                local ht = DensityMapHeightUtil.getHeightTypeDescAtWorldPos(x, y, z, smoothRadius)
                if ht == nil then
                    nNilType = nNilType + 1
                elseif not ht.allowsSmoothing then
                    nNoSmooth = nNoSmooth + 1
                else
                    smoothDensityMapHeightAtWorldPos(
                        updater,
                        x, y - ht.collisionBaseOffset, z,
                        smoothAmount, ht.index,
                        0, smoothRadius, smoothRadius + 1.2,
                        tireId)
                    nSmoothed = nSmoothed + 1
                end
            end
        end
    end

    if BunkerAutoLevel.DEBUG then
        Logging.info("[%s]  smooth: ran=%d nilType=%d noSmooth=%d (grid %dx%d, %d passes)",
            BunkerAutoLevel.MOD_NAME, nSmoothed, nNilType, nNoSmooth, nA, nC, BunkerAutoLevel.SMOOTH_PASSES)
    end
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

    -- TRIGGER-TOP height (centre ceiling) = top of the interaction trigger box
    -- above the floor, via its world AABB (NOT the bounding sphere — a wide box's
    -- sphere radius is dominated by its width and grossly overestimates height).
    local triggerTop = BunkerAutoLevel.DEFAULT_MAX_HEIGHT
    local tNode = silo.interactionTriggerNode
    if tNode ~= nil and getRigidBodyAABB ~= nil then
        local _, _, _, maxY = getRigidBodyAABB(tNode)
        if maxY ~= nil then
            local h = maxY - floorY
            if h > 0.5 then triggerTop = h end
        end
    end

    -- WALL height (edge cap for walled sides) = top of a wall collision above the
    -- floor. The base silo only has wallLeft/wallRight; use the taller of the two.
    local wallHeight = 0.0
    local function wallTop(w)
        if w == nil then return nil end
        local node = w.collision or w.node
        if node == nil or getRigidBodyAABB == nil then return nil end
        local _, _, _, maxY = getRigidBodyAABB(node)
        if maxY == nil then return nil end
        return maxY - floorY
    end
    local wl, wr = wallTop(silo.wallLeft), wallTop(silo.wallRight)
    if wl ~= nil and wl > wallHeight then wallHeight = wl end
    if wr ~= nil and wr > wallHeight then wallHeight = wr end
    if wallHeight <= 0.5 then
        -- No readable wall collision; assume walls match the trigger-implied height.
        wallHeight = math.min(triggerTop, BunkerAutoLevel.DEFAULT_MAX_HEIGHT)
    end

    if BunkerAutoLevel.DEBUG then
        Logging.info("[%s]  heights: floorY=%.2f wallHeight=%.2fm triggerTop=%.2fm",
            BunkerAutoLevel.MOD_NAME, floorY, wallHeight, triggerTop)
    end

    return {
        area = area,
        sx = area.sx, sz = area.sz,
        floorY = floorY,
        wallHeight = wallHeight,   -- edge cap at WALLED edges
        triggerTop = triggerTop,   -- absolute ceiling at the centre
        capHeight = triggerTop,    -- legacy field (some code reads capHeight)
        dhx = area.dhx, dhz = area.dhz,
        dwx = area.dwx, dwz = area.dwz,
        length = length, width = width,
        lnx = lnx, lnz = lnz,   -- unit dir along length (toward back)
        wnx = wnx, wnz = wnz,   -- unit dir across width (toward right wall)
    }
end

--- Detect the long side walls from the silo's own data (reliable), mapping each
-- wall node to the low (across=0) or high (across=width) side by projecting its
-- world position onto the width axis. A side is walled if a wall node sits on it
-- AND is visible (extendable silos hide a wall where two silos join).
-- @return leftWalled (low/across=0 side), rightWalled (high/across=width side)
function BunkerAutoLevel.detectSideWalls(silo, geo)
    local lowWalled, highWalled = false, false

    local function classify(w)
        if w == nil or w.node == nil then return end
        local visible = (w.visible ~= false)   -- treat nil as visible
        local wx, _, wz = getWorldTranslation(w.node)
        -- across offset of this wall along the width axis from the area start.
        local across = (wx - geo.sx) * geo.wnx + (wz - geo.sz) * geo.wnz
        if across < geo.width * 0.5 then
            lowWalled = lowWalled or visible
        else
            highWalled = highWalled or visible
        end
    end

    classify(silo.wallLeft)
    classify(silo.wallRight)

    if BunkerAutoLevel.DEBUG then
        Logging.info("[%s]  sideWalls: low(left)=%s high(right)=%s",
            BunkerAutoLevel.MOD_NAME, tostring(lowWalled), tostring(highWalled))
    end

    return lowWalled, highWalled
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
        local node = BunkerAutoLevel.probeResult.node
        local nodeName = "-"
        if type(node) == "number" and getName ~= nil then
            nodeName = getName(node) or tostring(node)   -- getName needs an int node id
        elseif node ~= nil then
            nodeName = tostring(node)                     -- some hits report a table; don't call getName
        end
        Logging.info("[%s]  probe %-5s: walled=%s hit=%s @(%.1f,%.1f,%.1f)",
            BunkerAutoLevel.MOD_NAME, which, tostring(BunkerAutoLevel.probeResult.hit), nodeName, px, py, pz)
    end

    return BunkerAutoLevel.probeResult.hit
end



-- Bootstrap -----------------------------------------------------------------
-- extraSourceFiles run at mod load, before the mission starts. BunkerSilo is a
-- base-game global available immediately, so install hooks now (guarded so a
-- hot-reload during dev doesn't double-install).
BunkerAutoLevel.install()
