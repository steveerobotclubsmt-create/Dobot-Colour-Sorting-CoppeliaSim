sim = require('sim')

local vel = 30
local accel = 45
local jerk = 80

local GREEN_SWING = 110
local RED_SWING = -110

local SIDE_OFFSET = 34 -- each side is +/-34 deg from centre

local BASE_DIP_J2 = 40
local BASE_DIP_J3 = 30

local HEIGHT_STEP_PER_BLOCK = 10 -- clearance grows per stacked
-- block on the same side
local MIN_DIP = 8 -- never dip below this

-- ================================================================
-- STATE --
-- ================================================================
local greenRightCount = 0
local greenLeftCount = 0
local redRightCount = 0
local redLeftCount = 0

local greenTotalCount = 0 -- used only to decide which side is next
local redTotalCount = 0

local greenFull = false -- true once green container hits 6 (informational)
local redFull = false -- true once red container hits 6 (informational)

local systemStopped = false -- once true, arm stops picking BOTH colours

local STOP_DELAY = 15 -- seconds to wait after systemStopped before halting the sim
local systemStoppedAt = nil -- sim time at which systemStopped became true
local simHalted = false -- guards against calling sim.stopSimulation() more than once
local lastPrintedCountdown = nil -- last whole second printed during the countdown

-- ================================================================
-- INIT
-- ================================================================
function sysCall_init()
    print('[Dobot] Script loaded: global stop-at-6 version (either container triggers full stop)')

    dobotHandle = sim.getObject('/Dobot')
    gripperHandle = sim.getObject('/Dobot/suctionCup_link2')

    motorHandles = {}
    for i = 1, 4 do
        motorHandles[i] = sim.getObject('/Dobot/motor' .. i)
    end

    local function r(d)
        return d * math.pi / 180
    end
    local function rv(t)
        return { r(t[1]), r(t[2]), r(t[3]), r(t[4]) }
    end

    maxVel = rv({ vel, vel, vel, vel })
    maxAccel = rv({ accel, accel, accel, accel })
    maxJerk = rv({ jerk, jerk, jerk, jerk })

    homePose = rv({ 0, 0, 0, 0 })
    pickUpPose1 = rv({ -20, 0, 0, 0 })
    pickUpPose2 = rv({ -20, 50, 47, 0 })

    sim.setStringProperty(dobotHandle, 'customData.objectDetected', 'none')
    sim.setStringProperty(dobotHandle, 'customData.detectedColourName', 'none')

    lastPrintedStatus = 'none'
    corout = coroutine.create(coroutineMain)
end

-- ================================================================
-- MOVE HELPERS
-- ================================================================
function deg(d)
    return d * math.pi / 180
end

function moveToConfig(targetConf, enableGripper)
    sim.moveToConfig({
        joints = motorHandles,
        targetPos = targetConf,
        maxVel = maxVel,
        maxAccel = maxAccel,
        maxJerk = maxJerk,
    })
    sim.writeCustomStringData(gripperHandle, 'activity', enableGripper and 'on' or 'off')
end

function pickUpBlock()
    moveToConfig(pickUpPose1, false)
    moveToConfig(pickUpPose2, true)
    sim.wait(0.2)
    moveToConfig(pickUpPose1, true)
end

-- ================================================================
-- Computes drop pose for a given side ('right' or 'left') and how
-- many blocks are already stacked on THAT side.
-- ================================================================
function computeDropPose(baseSwing, side, sideCount)
    local sideOffset = (side == 'right') and SIDE_OFFSET or -SIDE_OFFSET
    local swingAdj = baseSwing + sideOffset

    local reduction = sideCount * HEIGHT_STEP_PER_BLOCK
    local dipJ2 = math.max(MIN_DIP, BASE_DIP_J2 - reduction)
    local dipJ3 = math.max(MIN_DIP, BASE_DIP_J3 - reduction)

    local safePose = { deg(swingAdj), deg(0), deg(0), 0 }
    local dropPose = { deg(swingAdj), deg(dipJ2), deg(dipJ3), 0 }

    return safePose, dropPose
end

-- ================================================================
-- DROP sequence
-- ================================================================
function dropBlock(baseSwing, side, sideCount)
    local safePose, dropPose = computeDropPose(baseSwing, side, sideCount)

    moveToConfig(safePose, true)
    moveToConfig(dropPose, true)

    sim.wait(0.2)
    sim.writeCustomStringData(gripperHandle, 'activity', 'off')
    sim.wait(0.4)

    moveToConfig(safePose, false)
    moveToConfig(homePose, false)
end

function printDetection(colourName, destinationName, side, sideCount, swingAdj, totalInContainer)
    print(
        string.format(
            '[Dobot] Detected %s block -> %s (%s side, stack #%d, swing=%.1f deg, container total=%d/6)',
            colourName,
            destinationName,
            side,
            sideCount + 1,
            swingAdj,
            totalInContainer
        )
    )
end

function checkStopCondition(containerName, rightCount, leftCount)
    local total = rightCount + leftCount
    if total >= 6 then
        print(
            string.format(
                '[Dobot] %s stack fulfilled (%d/6) -- stopping ALL picking (both colours)',
                containerName,
                total
            )
        )
        return true
    end
    return false
end

-- ================================================================
-- MAIN COROUTINE
-- ================================================================
function coroutineMain()
    while true do
        local status = sim.getStringProperty(dobotHandle, 'customData.objectDetected') or 'none'

        local colourName = sim.getStringProperty(dobotHandle, 'customData.detectedColourName') or 'unknown'

        -- Once the system has stopped picking, count down STOP_DELAY
        -- seconds of sim time, printing progress each second, then
        -- halt the simulation entirely.
        if systemStopped and not simHalted then
            local elapsed = sim.getSimulationTime() - systemStoppedAt
            local remaining = math.max(0, STOP_DELAY - elapsed)
            local remainingWhole = math.ceil(remaining)

            if remainingWhole ~= lastPrintedCountdown and elapsed < STOP_DELAY then
                print(string.format('[Dobot] Stopping simulation in %d s...', remainingWhole))
                lastPrintedCountdown = remainingWhole
            end

            if elapsed >= STOP_DELAY then
                print(
                    string.format(
                        '[Dobot] Final counts -- Green: right=%d, left=%d, total=%d/6 | Red: right=%d, left=%d, total=%d/6',
                        greenRightCount,
                        greenLeftCount,
                        greenRightCount + greenLeftCount,
                        redRightCount,
                        redLeftCount,
                        redRightCount + redLeftCount
                    )
                )
                print(string.format('[Dobot] %.0f seconds elapsed since stop -- halting simulation', STOP_DELAY))
                simHalted = true
                sim.stopSimulation()
            end
        end

        if status == 'green' and not systemStopped then
            local side = (greenTotalCount % 2 == 0) and 'right' or 'left'
            local sideCount = (side == 'right') and greenRightCount or greenLeftCount

            pickUpBlock()
            dropBlock(GREEN_SWING, side, sideCount)

            if status ~= lastPrintedStatus then
                local swingAdj = GREEN_SWING + ((side == 'right') and SIDE_OFFSET or -SIDE_OFFSET)
                printDetection(
                    colourName,
                    'GreenContainer',
                    side,
                    sideCount,
                    swingAdj,
                    greenRightCount + greenLeftCount + 1
                )
                lastPrintedStatus = status
            end

            if side == 'right' then
                greenRightCount = greenRightCount + 1
            else
                greenLeftCount = greenLeftCount + 1
            end
            greenTotalCount = greenTotalCount + 1

            sim.setStringProperty(dobotHandle, 'customData.objectDetected', 'none')
            lastPrintedStatus = 'none'

            if checkStopCondition('Green', greenRightCount, greenLeftCount) then
                greenFull = true
                systemStopped = true
                systemStoppedAt = sim.getSimulationTime()
            end
        elseif status == 'red' and not systemStopped then
            local side = (redTotalCount % 2 == 0) and 'right' or 'left'
            local sideCount = (side == 'right') and redRightCount or redLeftCount

            pickUpBlock()
            dropBlock(RED_SWING, side, sideCount)

            if status ~= lastPrintedStatus then
                local swingAdj = RED_SWING + ((side == 'right') and SIDE_OFFSET or -SIDE_OFFSET)
                printDetection(colourName, 'RedContainer', side, sideCount, swingAdj, redRightCount + redLeftCount + 1)
                lastPrintedStatus = status
            end

            if side == 'right' then
                redRightCount = redRightCount + 1
            else
                redLeftCount = redLeftCount + 1
            end
            redTotalCount = redTotalCount + 1

            sim.setStringProperty(dobotHandle, 'customData.objectDetected', 'none')
            lastPrintedStatus = 'none'

            if checkStopCondition('Red', redRightCount, redLeftCount) then
                redFull = true
                systemStopped = true
                systemStoppedAt = sim.getSimulationTime()
            end
        elseif systemStopped and (status == 'green' or status == 'red') then
            sim.setStringProperty(dobotHandle, 'customData.objectDetected', 'none')
            sim.wait(0.1)
        else
            sim.wait(0.1)
        end
    end
end

-- ================================================================
function sysCall_actuation()
    if coroutine.status(corout) ~= 'dead' then
        local ok, errorMsg = coroutine.resume(corout)
        if errorMsg then
            error(debug.traceback(corout, errorMsg), 2)
        end
    else
        corout = coroutine.create(coroutineMain)
    end
end
