local perSurface = {}

local MOD = "modular-underground-storage"
local TILE = "modular-underground-storage-tile"
local TILE_STACK = { name = TILE }

-- This code uses positions as table keys.
-- Because Lua compares tables by their reference only that means positions have to be encoded as numbers.
-- Factorio runs scripts in Lua 5.2 which means numbers are float64.
-- A float holds up to 52 significant bits so use half of them for the y coordinate.
-- Lua 5.2 has no bit shift operations so we have fall back to multiplication.
local Y_SHIFT = 2^26
local Y_SHIFT_HALF = Y_SHIFT / 2

-- naming rule: things named "pos" work with encoded positions, those named "position" work with structured positions

local function toPos(x, y)
    assert(x > -Y_SHIFT_HALF and x < Y_SHIFT_HALF, "x position cannot be encoded")
    assert(y > -Y_SHIFT_HALF and y < Y_SHIFT_HALF, "y position cannot be encoded")

    -- decoding using division breaks down when encoding produces a negative number
    local px = x < 0 and x + Y_SHIFT or x
    local py = y < 0 and y + Y_SHIFT or y
    return py * Y_SHIFT + px
end

local function toCoords(pos)
    local y = math.floor(pos / Y_SHIFT)
    local x = pos - y * Y_SHIFT
    if y > Y_SHIFT_HALF then y = y - Y_SHIFT end
    if x > Y_SHIFT_HALF then x = x - Y_SHIFT end
    return x, y
end

local function encodePos(position)
    return toPos(position.x, position.y)
end

local function decodePos(pos)
    local x, y = toCoords(pos)
    return { x = x, y = y }
end

local function toPosition(x, y)
    return { x = x, y = y }
end

local function posToString(posOrPosition)
    local x, y
    if posOrPosition == nil then
        return "nil"
    end
    if (type(posOrPosition) == "number") then
        x, y = toCoords(posOrPosition)
    else
        x = posOrPosition.x
        y = posOrPosition.y
    end
    return "(" .. x .. "," .. y .. ")"
end

function player_print(msg)
    for _, p in pairs(game.players) do
        if (msg) then p.print(msg) end
    end
end

local function perSurfaceData(surface, createIfNecessary)
    local surfaceData = perSurface[surface.index]
    if not surfaceData then
        player_print("tracking new surface ".. surface.index)        
        surfaceData = {
            next_id = 1,
            patches = {},
            lookup = {}, 
        }
        if createIfNecessary then 
            perSurface[surface.index] = surfaceData
            player_print("persisting data for surface ".. surface.index)
        end
    end
    return surfaceData
end

local Storage = {}
local Patch = {}

Storage.init =  function()
    if not global.perSurface then
        global.perSurface = {}
    end
    perSurface = global.perSurface
end

local N  = defines.direction.north
local E  = defines.direction.east
local S  = defines.direction.south
local W  = defines.direction.west
local NW = defines.direction.northwest
local NE = defines.direction.northeast
local SW = defines.direction.southwest
local SE = defines.direction.southeast

local DIR = defines.direction

local DIR_CARDINAL = {}
DIR_CARDINAL[N] = { 0,-1}
DIR_CARDINAL[E] = { 1, 0}
DIR_CARDINAL[S] = { 0, 1}
DIR_CARDINAL[W] = {-1, 0}

local DIR_ORDINAL = {}
DIR_ORDINAL[NE] = { 1,-1}
DIR_ORDINAL[SE] = { 1, 1}
DIR_ORDINAL[SW] = {-1, 1}
DIR_ORDINAL[NW] = {-1,-1}

local function iterAdjacentStorageTiles(surface, centerPos, directions)
    local px, py = toCoords(centerPos)
    local iter, iterState, iterVar = pairs(directions)

    return function()
        while true do
            local dir, offsets = iter(iterState, iterVar)
            if dir == nil then return nil end
            iterVar = dir

            local x = px + offsets[1]
            local y = py + offsets[2]
            if surface.get_tile(x,y).name == TILE then 
                return dir, toPos(x,y)
            end
        end
    end
end

local function mapAdjacentStorageTiles(surface, centerPos, directions)
    local px, py = toCoords(centerPos)
    local result = {}

    for dir, offsets in pairs(directions) do
        local x, y = px + offsets[1], py + offsets[2]
        if surface.get_tile(x,y).name == TILE then
            result[dir] = toPos(x,y)
        end
    end

    return result
end

local function mightBeSplit(surface, pos)
    local disconnected = 0
    local cardinals = mapAdjacentStorageTiles(surface, pos, DIR_CARDINAL)
    local ordinals = mapAdjacentStorageTiles(surface, pos, DIR_ORDINAL)

    if cardinals[N] and not ((ordinals[NW] and cardinals[W]) or (ordinals[NE] and cardinals[E])) then disconnected = disconnected + 1 end
    if cardinals[E] and not ((ordinals[NE] and cardinals[N]) or (ordinals[SE] and cardinals[S])) then disconnected = disconnected + 1 end
    if cardinals[W] and not ((ordinals[NW] and cardinals[N]) or (ordinals[SW] and cardinals[S])) then disconnected = disconnected + 1 end
    if cardinals[S] and not ((ordinals[SW] and cardinals[W]) or (ordinals[SE] and cardinals[E])) then disconnected = disconnected + 1 end

    return disconnected > 1
end

Storage.newTile = function(surface, pos)
    player_print("new tile at " .. posToString(pos))

    local surfaceData = perSurfaceData(surface, true)

    local lastPatch = nil
    for direction, adjacentPos in iterAdjacentStorageTiles(surface, pos, DIR_CARDINAL) do
        local patch = surfaceData.lookup[adjacentPos]
        if patch then 
            if not lastPatch then
                Storage.addToPatch(surfaceData, patch, adjacentPos)
                lastPatch = patch
            elseif lastPatch.id ~= patch.id then
                lastPatch = Storage.mergePatches(surfaceData, patch, lastPatch)
            end
        else
            player_print("loose tile at " .. posToString(adjacentPos))
            if lastPatch then
                Storage.addToPatch(surfaceData, lastPatch, adjacentPos)
            else
                lastPatch = Storage.newPatch(surfaceData, adjacentPos)
            end
        end
    end

    if lastPatch then
        Storage.addToPatch(surfaceData, lastPatch, pos)
    else
        Storage.newPatch(surfaceData, pos)
    end
end

Patch.create = function()
    return {
        tiles = {}, -- pos -> true
        tileCount = 0,
        items = {}, -- item.name -> count
        inputs = {},
        outputs = {},
    }
end

Storage.newPatch = function(surfaceData, pos)
    local newPatch = Patch.create()
    newPatch.id = surfaceData.next_id
    newPatch.tiles[pos] = true
    newPatch.tileCount = 1
    surfaceData.next_id = surfaceData.next_id + 1
    surfaceData.patches[newPatch.id] = newPatch
    surfaceData.lookup[pos] = newPatch

    player_print("new patch " .. newPatch.id)

    return newPatch
end

Storage.addToPatch = function(surfaceData, patch, pos)
    if not patch.tiles[pos] then
        patch.tiles[pos] = true
        patch.tileCount = patch.tileCount + 1
        player_print("added ".. posToString(pos) .. " to patch " .. patch.id)
    end
    surfaceData.lookup[pos] = patch
end

Storage.removeFromPatch = function(surfaceData, patch, pos)
    if patch.tiles[pos] then
        patch.tiles[pos] = nil
        patch.tileCount = patch.tileCount - 1
        surfaceData.lookup[pos] = nil
        player_print("removed ".. posToString(pos) .. " from patch " .. patch.id)
    end
end

Storage.mergePatches = function(surfaceData, patch1, patch2)
    local from, into
    if #patch1.tiles < #patch2.tiles then
        from = patch1
        into = patch2
    else
        from = patch2
        into = patch1
    end

    for pos, _ in pairs(from.tiles) do
        Storage.addToPatch(surfaceData, into, pos)
    end

    for name, count in pairs(from.items) do
        into.items[name] = (into.items[name] or 0) + count
    end

    for pos, entity in pairs(from.inputs) do
        into.inputs[pos] = entity
    end
    for pos, entity in pairs(from.outputs) do
        into.outputs[pos] = entity
    end

    surfaceData.patches[from.id] = nil
    player_print("merged patch " .. from.id .. " into patch " .. into.id)

    return into
end

Storage.removeTile = function(surface, pos)
    local surfaceData = perSurfaceData(surface, false)
    if not surfaceData then return end
    
    local patch = surfaceData.lookup[pos]
    if not patch then return end

    -- Removing the last tile while there are stored items would destroy those items
    if patch.tileCount == 1 and next(patch.items) then 
        return false
    end

    Storage.removeFromPatch(surfaceData, patch, pos)

    if not next(patch.tiles) then
        surfaceData.patches[patch.id] = nil
        -- perSurface.lookup cannot have references when tiles is empty
        player_print("dissolved patch " .. patch.id)

    elseif mightBeSplit(surface, pos) then
        Storage.splitIfNecessary(surfaceData, patch)
    end

    return true
end

local function floodFill(sourcePatch, fill, x, y)
    for dir, offsets in pairs(DIR_CARDINAL) do
        local dx, dy = x + offsets[1], y + offsets[2]
        local dpos = toPos(dx, dy)
        if sourcePatch.tiles[dpos] and not fill.tiles[dpos] then
            fill.tiles[dpos] = true
            fill.tileCount = fill.tileCount + 1
            floodFill(sourcePatch, fill, dx, dy)
        end
    end
end

Storage.splitIfNecessary = function(surfaceData, patch)
    local splits = {}
    local maxTileCount = -1
    local largestPatch = nil

    for i = 1,4 do
        local pos = next(patch.tiles)
        local newPatch = Patch.create()
        newPatch.tiles[pos] = true
        newPatch.tileCount = 1

        local x, y = toCoords(pos)
        floodFill(patch, newPatch, x, y)

        -- remaining tiles in patch are contigous
        if newPatch.tileCount == patch.tileCount then break end

        newPatch.id = surfaceData.next_id
        surfaceData.patches[newPatch.id] = newPatch
        surfaceData.next_id = surfaceData.next_id + 1

        for pos, _ in pairs(newPatch.tiles) do
            patch.tiles[pos] = nil
            patch.tileCount = patch.tileCount - 1
            surfaceData.lookup[pos] = newPatch
        end

        table.insert(splits, newPatch)

        if newPatch.tileCount > maxTileCount then
            largestPatch = newPatch
            maxTileCount = newPatch.tileCount
        end
    end

    if largestPatch and maxTileCount > patch.tileCount then
        largestPatch.items = patch.items
        patch.items = {}
    end

    if #splits > 0 then
        player_print("split " .. #splits .. " patches from patch " .. patch.id)
    end

    -- TODO handle inputs and outputs
end

function player_or_robot(event)
    local actor, surface
    if event.robot then
        actor = event.robot
        surface = actor.surface
    else
        actor = game.players[event.player_index]
        surface = game.surfaces[event.surface_index]
    end

    return actor, surface
end

function marked(event)
    local entity = event.entity

    if "deconstructible-tile-proxy" == entity.type then
        local surface = entity.surface
        if surface.get_tile(entity.position).name == TILE and not Storage.isTileRemovable(surface, encodePos(entity.position)) then
            entity.cancel_deconstruction("player")
        end
    end
end

function tile_mined(event)
    local actor, surface = player_or_robot(event)

    for _, minedTile in pairs(event.tiles) do
        if minedTile.old_tile.name == TILE and not Storage.removeTile(surface, encodePos(minedTile.position)) then
            actor.remove_item(TILE_STACK)
            surface.set_tiles({{ name = TILE, position = minedTile.position}})
        end
    end
end

function tile_built(event) 
    local actor, surface = player_or_robot(event)

    if event.item.place_as_tile_result.result.name == TILE then
        for _, replacedTile in pairs(event.tiles) do
            Storage.newTile(surface, encodePos(replacedTile.position))
        end
    end
end

script.on_init(Storage.init)
script.on_load(Storage.init)

script.on_event(defines.events.on_marked_for_deconstruction, marked)

script.on_event(defines.events.on_robot_mined_tile, tile_mined)
script.on_event(defines.events.on_player_mined_tile, tile_mined)
script.on_event(defines.events.on_surface_deleted, function() data[event.surface_index] = nil end)

script.on_event(defines.events.on_robot_built_tile, tile_built)
script.on_event(defines.events.on_player_built_tile, tile_built)

local texts = {}

function hide(paramTable)
    for _, text in ipairs(texts) do
        text.active = true
    end
    texts = {}
end

function show(paramTable)
    if #texts > 0 then hide() end

    local surface = game.players[paramTable.player_index].surface
    local perSurface = perSurfaceData(surface, false)
    if not perSurface then return end

    for _, patch in pairs(perSurface.patches) do
        local patchId = tostring(patch.id)
        for tilePos, _ in pairs(patch.tiles) do
            local x, y = toCoords(tilePos)
            local text = surface.create_entity({name="flying-text", position=toPosition(x + 0.3, y + 0.3), text=patchId})
            table.insert(texts, text)
            text.active = false
        end
    end
end

function dump(paramTable) 
    local surface = game.players[paramTable.player_index].surface
    local surfaceData = perSurfaceData(surface, false)
    if not surfaceData then return end

    for _, patch in pairs(surfaceData.patches) do
        player_print("#" .. patch.id .. ": " .. patch.tileCount)
    end
end

commands.add_command("mus",
"Overlay storage tiles with the patch id they belong to. Also overlays underground belts that are connected to a patch.",
function(paramTable)
    local cmd = paramTable.parameter
    if cmd == "show" then show(paramTable)
    elseif cmd == "hide" then hide(paramTable)
    elseif cmd == "dump" then dump(paramTable)
    else
        player_print("unknown subcommand " .. cmd)
    end
end)
