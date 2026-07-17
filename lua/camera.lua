sim = require('sim')
simVision = require('simVision')

function sysCall_init()
    pointsHaveColor = true -- Enable color detection
    builtInCalculation = true -- Use built-in depth calculation
    sensor = sim.getObject('.')

    -- Conveyor Belt Handle
    conveyorBelt = sim.getObjectHandle('/efficientConveyor')

    if conveyorBelt == -1 then
        print('Error: Conveyor belt handle not found. Check the name in the scene.')
    end

    conveyorVelocity = 0.05
    sim.writeCustomTableData(conveyorBelt, '__ctrl__', { vel = conveyorVelocity })

    local t = sim.drawing_points
    if pointsHaveColor then
        t = t | sim.drawing_itemcolors
    end
    pointContainer = sim.addDrawingObject(t, 2, 0, -1, 0, { 1, 0, 0 })
    resX = sim.getObjectInt32Param(sensor, sim.visionintparam_resolution_x) or 128
    resY = sim.getObjectInt32Param(sensor, sim.visionintparam_resolution_y) or 128

    dobotHandle = sim.getObject('/Dobot')
    scriptHandle = sim.getScript(1, dobotHandle)

    lastPrintedColour = 'none'
end

function printColourDetection(colourName)
    local msg = string.format('[Camera] Detected %s block -> ignored, continuing to TrashBin', colourName)
    print(msg)
end

function classifyColour(r, g, b)
    if g > 0.5 and r < 0.3 and b < 0.3 then
        return 'green'
    elseif r > 0.5 and g < 0.3 and b < 0.3 then
        return 'red'
    elseif r > 0.5 and g > 0.5 and b < 0.3 then
        return 'yellow'
    elseif b > 0.5 and r < 0.3 and g < 0.3 then
        return 'blue'
    elseif r > 0.5 and g > 0.3 and g < 0.6 and b < 0.3 then
        return 'orange'
    elseif r > 0.5 and b > 0.5 and g < 0.3 then
        return 'purple'
    end
    return nil -- unrecognized colour combination
end

function sysCall_vision(inData)
    local retVal = {}
    local detectedColour = nil -- specific colour name, e.g. 'red', 'yellow'

    if builtInCalculation then
        simVision.sensorImgToWorkImg(inData.handle)
        simVision.workImgToBuffer1(inData.handle)
        simVision.sensorDepthMapToWorkImg(inData.handle)

        if resX > 0 and resY > 0 then
            local _, pts, cols = simVision.coordinatesFromWorkImg(
                inData.handle | sim.handleflag_abscoords,
                { math.max(1, resX), math.max(1, resY) },
                false,
                pointsHaveColor
            )

            pts = sim.unpackFloatTable(pts)
            if pointsHaveColor then
                cols = sim.unpackUInt8Table(cols)
            end

            local cnt = (#pts - 2) / 4
            sim.addDrawingObjectItem(pointContainer, nil)
            for i = 0, cnt - 1 do
                local ind = 2 + i * 4
                local coord = { pts[ind + 1], pts[ind + 2], pts[ind + 3] }

                if pointsHaveColor then
                    local r = cols[3 * i + 1] / 255
                    local g = cols[3 * i + 2] / 255
                    local b = cols[3 * i + 3] / 255

                    coord[4] = r
                    coord[5] = g
                    coord[6] = b

                    local colourName = classifyColour(r, g, b)
                    if colourName then
                        detectedColour = colourName
                        break
                    end
                end

                sim.addDrawingObjectItem(pointContainer, coord)
            end

            local isPickable = (detectedColour == 'green' or detectedColour == 'red')

            if detectedColour then
                -- Always report what colour was seen, for logging
                sim.setStringProperty(dobotHandle, 'customData.detectedColourName', detectedColour)

                if not isPickable and detectedColour ~= lastPrintedColour then
                    printColourDetection(detectedColour)
                    lastPrintedColour = detectedColour
                elseif isPickable then
                    -- Still update the tracker so we don't re-print
                    -- this colour as "ignored" later if logic changes
                    lastPrintedColour = detectedColour
                end
            end

            if isPickable then
                if conveyorVelocity ~= 0 then
                    conveyorVelocity = 0.0
                    sim.writeCustomTableData(conveyorBelt, '__ctrl__', { vel = conveyorVelocity })
                end
                sim.setStringProperty(dobotHandle, 'customData.objectDetected', detectedColour)
            else
                -- Not red/green (either nothing detected, or an
                -- "other" colour) -> conveyor keeps running, arm
                -- stays idle, block continues to the TrashBin.
                if conveyorVelocity == 0.0 then
                    conveyorVelocity = 0.05
                    sim.writeCustomTableData(conveyorBelt, '__ctrl__', { vel = conveyorVelocity })
                end
                sim.setStringProperty(dobotHandle, 'customData.objectDetected', 'none')

                if not detectedColour then
                    sim.setStringProperty(dobotHandle, 'customData.detectedColourName', 'none')
                    lastPrintedColour = 'none'
                end
            end
        else
            print('Error: Invalid sensor resolution.')
        end
    end

    return retVal
end

function sysCall_sensing()
    if not builtInCalculation then
        local m = sim.getObjectMatrix(sensor, sim.handle_world)
        sim.addDrawingObjectItem(pointContainer, nil)
        local depthMap = sim.getVisionSensorDepth(sensor, 1)
        depthMap = sim.unpackFloatTable(depthMap)

        local cols
        if pointsHaveColor then
            cols = sim.getVisionSensorImg(sensor)
            cols = sim.unpackUInt8Table(cols)
        end

        for y = 0, resY - 1 do
            for x = 0, resX - 1 do
                local ind = y * resY + x + 1
                local d = depthMap[ind]
                local coord = { 0, 0, d }
                coord[1] = d * math.tan(xAngle * 0.5) * (0.5 - (x / (resX - 1))) / 0.5
                coord[2] = d * math.tan(yAngle * 0.5) * ((y / (resY - 1)) - 0.5) / 0.5
                coord = sim.multiplyVector(m, coord)

                if pointsHaveColor then
                    coord[4] = cols[3 * (ind - 1) + 1]
                    coord[5] = cols[3 * (ind - 1) + 2]
                    coord[6] = cols[3 * (ind - 1) + 3]
                end

                sim.addDrawingObjectItem(pointContainer, coord)
            end
        end
    end
end
