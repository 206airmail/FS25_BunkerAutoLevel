--
-- BunkerAutoLevelEvent.lua
--
-- Client -> server request to auto-level a bunker silo's fill heap.
--
-- The actual leveling (density-map height mutation) is server-authoritative, so a
-- client that presses the keybind sends this event; the server runs autoLevel()
-- and the resulting height changes replicate back to all clients via the engine's
-- density-map sync. No result needs to be sent back.
--
-- Uses InitEventClass (NOT InitStaticEventClass) — mod-defined events must let the
-- server assign the event id at runtime; the static variant is base-game only and
-- errors at mod load.
--

BunkerAutoLevelEvent = {}
local BunkerAutoLevelEvent_mt = Class(BunkerAutoLevelEvent, Event)

InitEventClass(BunkerAutoLevelEvent, "BunkerAutoLevelEvent")

function BunkerAutoLevelEvent.emptyNew()
    return Event.new(BunkerAutoLevelEvent_mt)
end

--- @param bunkerSilo BunkerSilo the silo to level
function BunkerAutoLevelEvent.new(bunkerSilo)
    local self = BunkerAutoLevelEvent.emptyNew()
    self.bunkerSilo = bunkerSilo
    return self
end

function BunkerAutoLevelEvent:readStream(streamId, connection)
    -- Only the server reads an incoming request from a client.
    if not connection:getIsServer() then
        self.bunkerSilo = NetworkUtil.readNodeObject(streamId)
    end
    self:run(connection)
end

function BunkerAutoLevelEvent:writeStream(streamId, connection)
    -- Only a client writes the request to the server.
    if connection:getIsServer() then
        NetworkUtil.writeNodeObject(streamId, self.bunkerSilo)
    end
end

function BunkerAutoLevelEvent:run(connection)
    -- Runs on the server when a request arrives from a client.
    if not connection:getIsServer() then
        if self.bunkerSilo ~= nil and self.bunkerSilo.autoLevel ~= nil then
            self.bunkerSilo:autoLevel()
        end
    end
end

--- Helper: request a level from wherever the caller is. On a client this sends the
-- event to the server; on the server it runs immediately.
function BunkerAutoLevelEvent.sendRequest(bunkerSilo)
    if bunkerSilo == nil then
        return
    end
    if g_server ~= nil then
        bunkerSilo:autoLevel()
    else
        g_client:getServerConnection():sendEvent(BunkerAutoLevelEvent.new(bunkerSilo))
    end
end
