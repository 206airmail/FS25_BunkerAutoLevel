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

-- How far (metres) past a short end to probe for a static wall when deciding
-- whether that end is open (slope a drivable ramp) or walled (pack flat).
BunkerAutoLevel.WALL_PROBE_DISTANCE = 1.0

-- Half-thickness (metres) of the overlap box used for the wall probe.
BunkerAutoLevel.WALL_PROBE_HALF = 0.5

-- Collision mask for the wall probe: static buildings/objects (bunker walls
-- register as BUILDING; some custom silos use STATIC_OBJECT too).
BunkerAutoLevel.WALL_PROBE_MASK = CollisionFlag.BUILDING + CollisionFlag.STATIC_OBJECT

-- Convergence settings for solving the flat-top height (volume is consumed by
-- the open-end ramps, so flat height is found by a short bisection).
BunkerAutoLevel.HEIGHT_SOLVE_ITERATIONS = 8

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

    -- Bisect the flat-top height so total deposited volume ≈ requested volume.
    -- Open edges consume volume as ~40° ramps, reducing the flat-top footprint.
    local targetHeight = BunkerAutoLevel.solveFlatHeight(geo, volume, edges)

    -- Deposit the sweep at the solved height.
    local placed = BunkerAutoLevel.depositSweep(geo, fillType, radius, targetHeight, edges, true)

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

--- Ramp run-out (metres) for a given flat-top height at the natural repose angle.
function BunkerAutoLevel.rampRun(height)
    return height / math.tan(math.rad(40))
end

--- Estimate the deposited volume for a candidate flat-top height.
-- The flat top shrinks on each axis by one ramp run-out per OPEN edge on that
-- axis; the ramps themselves add roughly half-prism volume back. This is only an
-- estimate to choose a height — the engine does the real placement.
-- @param edges table { frontOpen, backOpen, leftOpen, rightOpen } booleans.
function BunkerAutoLevel.estimateVolume(geo, height, edges)
    if height <= 0 then
        return 0
    end
    local run = BunkerAutoLevel.rampRun(height)

    -- Flat-top footprint after pulling in from each open edge.
    local lengthInset = (edges.frontOpen and run or 0) + (edges.backOpen and run or 0)
    local widthInset = (edges.leftOpen and run or 0) + (edges.rightOpen and run or 0)
    local flatLen = math.max(0, geo.length - lengthInset)
    local flatWid = math.max(0, geo.width - widthInset)

    -- Flat slab + a triangular ramp prism along each open edge (half-prism each).
    local slab = flatLen * flatWid * height
    local openOnLength = (edges.frontOpen and 1 or 0) + (edges.backOpen and 1 or 0)
    local openOnWidth = (edges.leftOpen and 1 or 0) + (edges.rightOpen and 1 or 0)
    local lengthRamps = openOnLength * (flatWid * run * height * 0.5)
    local widthRamps = openOnWidth * (flatLen * run * height * 0.5)

    local cubicM = slab + lengthRamps + widthRamps
    return cubicM * 1000 -- litres (1 m^3 = 1000 l)
end

--- Bisect the flat-top height so estimated volume matches the requested volume.
function BunkerAutoLevel.solveFlatHeight(geo, volume, edges)
    local lo, hi = 0.0, 50.0 -- 50m is far above any real silo wall height
    for _ = 1, BunkerAutoLevel.HEIGHT_SOLVE_ITERATIONS do
        local mid = (lo + hi) * 0.5
        if BunkerAutoLevel.estimateVolume(geo, mid, edges) < volume then
            lo = mid
        else
            hi = mid
        end
    end
    return (lo + hi) * 0.5
end

--- Sweep deposit lines along the length axis, stepped across the width, capping
-- each to `height`. Lines are pulled in from any OPEN edge by the ramp run-out so
-- the engine's angle of repose forms a drivable ramp there; at WALLED edges they
-- run to the very edge so material packs flat against the wall.
-- @param edges table { frontOpen, backOpen, leftOpen, rightOpen } booleans.
-- @param apply when false, only sums the would-be placement (dry run).
-- @return total litres placed.
function BunkerAutoLevel.depositSweep(geo, fillType, radius, height, edges, apply)
    if height <= 0 then
        return 0
    end

    local run = BunkerAutoLevel.rampRun(height)

    -- Inset along the length axis (front/back) for the line endpoints.
    local startDist = edges.frontOpen and run or 0.0
    local endDist = math.max(startDist, geo.length - (edges.backOpen and run or 0.0))
    local lineLen = math.max(0.01, endDist - startDist)

    -- Inset across the width (left/right) for which strips we lay lines in.
    local leftInset = edges.leftOpen and run or 0.0
    local rightInset = edges.rightOpen and run or 0.0
    local flatWid = math.max(0.0, geo.width - leftInset - rightInset)
    if flatWid <= 0 then
        -- Silo narrower than two ramp run-outs: lay a single centre line so the
        -- material still goes somewhere sensible rather than nothing.
        leftInset = geo.width * 0.5
        flatWid = 0.0
    end

    local numLines = math.max(1, math.floor((flatWid > 0 and flatWid or 0.01) / BunkerAutoLevel.LINE_SPACING + 0.5))
    local stepW = (flatWid > 0 and flatWid or 0) / numLines

    local totalPlaced = 0
    -- Generous per-line delta so the engine fills up to the cap and returns the
    -- remainder; the limitToLineHeight cap is what actually flattens the top.
    local perLineDelta = ((flatWid > 0 and flatWid or geo.width) * lineLen * height * 1000) / numLines * 2.0

    for i = 0, numLines - 1 do
        -- Strip centre across the width, starting after the left inset.
        local w = leftInset + (i + 0.5) * stepW
        local bx = geo.sx + geo.wnx * w
        local bz = geo.sz + geo.wnz * w

        local sx = bx + geo.lnx * startDist
        local sz = bz + geo.lnz * startDist
        local ex = bx + geo.lnx * endDist
        local ez = bz + geo.lnz * endDist

        -- Cap height: terrain base + target flat height at both endpoints.
        local baseY = DensityMapHeightUtil.getHeightAtWorldPos(bx, 0, bz)
        local capY = baseY + height
        local sy, ey = capY, capY

        local placed = DensityMapHeightUtil.tipToGroundAroundLine(
            nil,            -- vehicle
            perLineDelta,   -- delta to place
            fillType,
            sx, sy, sz,
            ex, ey, ez,
            0.0,            -- innerRadius
            radius,         -- radius
            nil,            -- lineOffset
            true,           -- limitToLineHeight -> caps surface at the line y (flat top)
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
