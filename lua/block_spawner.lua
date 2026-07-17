sim = require('sim')

-- ================================================================
-- BLOCK SPAWNER
-- Attach this as a script to a Dummy object placed at the START
-- (left end) of your conveyor belt, e.g. name it '/BlockSpawner'.
-- ================================================================

function sysCall_init()
    spawnerHandle = sim.getObject('.')

    spawnInterval = 3.0
    blockSize = { 0.04, 0.08, 0.035 }
    spawnHeight = 0.03
    clearRadius = 0.06

    colourPalette = {
        { name = 'red', rgb = { 0.8, 0.05, 0.05 }, weight = 3 },
        { name = 'green', rgb = { 0.05, 0.8, 0.05 }, weight = 3 },
        { name = 'yellow', rgb = { 0.9, 0.85, 0.05 }, weight = 1 },
        { name = 'blue', rgb = { 0.05, 0.05, 0.8 }, weight = 1 },
        { name = 'orange', rgb = { 0.9, 0.45, 0.05 }, weight = 1 },
        { name = 'purple', rgb = { 0.6, 0.05, 0.7 }, weight = 1 },
    }

    weightedList = {}
    for _, c in ipairs(colourPalette) do
        for i = 1, c.weight do
            table.insert(weightedList, c)
        end
    end

    spawnPos = sim.getObjectPosition(spawnerHandle, -1)
    conveyorBelt = sim.getObjectHandle('/efficientConveyor')

    spawnedHandles = {}
    timeSinceLastSpawn = 0
    blockCounter = 0

    math.randomseed(os.time())
end

function isConveyorMoving()
    if conveyorBelt == -1 or conveyorBelt == nil then
        return true
    end
    local ok, data = pcall(sim.readCustomTableData, conveyorBelt, '__ctrl__')
    if ok and data and data.vel then
        return data.vel > 0
    end
    return true
end

function isSpawnAreaClear()
    for i = #spawnedHandles, 1, -1 do
        local h = spawnedHandles[i]
        if sim.isHandle(h) then
            local pos = sim.getObjectPosition(h, -1)
            local dx = pos[1] - spawnPos[1]
            local dy = pos[2] - spawnPos[2]
            local dz = pos[3] - spawnPos[3]
            local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
            if dist < clearRadius then
                return false
            end
        else
            table.remove(spawnedHandles, i)
        end
    end
    return true
end

function spawnBlock()
    local chosen = weightedList[math.random(#weightedList)]

    blockCounter = blockCounter + 1
    local name = 'SpawnedBlock_' .. blockCounter

    local handle = sim.createPrimitiveShape(sim.primitiveshape_cuboid, blockSize, 0)

    -- FIX: force no parent (createPrimitiveShape otherwise parents
    -- to whatever object is currently selected in the hierarchy)
    sim.setObjectParent(handle, -1, true)

    sim.setObjectAlias(handle, name)
    sim.setObjectPosition(handle, -1, { spawnPos[1], spawnPos[2], spawnPos[3] + spawnHeight })
    sim.setShapeColor(handle, nil, sim.colorcomponent_ambient_diffuse, chosen.rgb)

    sim.setObjectInt32Param(handle, sim.shapeintparam_static, 0)
    sim.setObjectInt32Param(handle, sim.shapeintparam_respondable, 1)
    sim.setShapeMass(handle, 0.02)

    table.insert(spawnedHandles, handle)

    print(string.format('[Spawner] Created %s block (%s)', chosen.name, name))
end

function sysCall_actuation()
    if not isConveyorMoving() then
        return
    end

    local dt = sim.getSimulationTimeStep()
    timeSinceLastSpawn = timeSinceLastSpawn + dt

    if timeSinceLastSpawn >= spawnInterval then
        if isSpawnAreaClear() then
            spawnBlock()
            timeSinceLastSpawn = 0
        end
    end
end
