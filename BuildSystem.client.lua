--[[
This code is written for the application
Only local script is used
I did not want to go into too much detail 
Because I did not use a module script
--]]

--// Services
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Debris = game:GetService("Debris")
local CollectionService = game:GetService("CollectionService")

--// Constants
local GRID_SIZE = 2
local ROTATION_STEP = 45
local MAX_RAYCAST_DISTANCE = 200
local PREVIEW_TRANSPARENCY = 0.5
local OBJECT_LIFETIME = 120
local ROTATION_DELAY = 0.5
local UNDO_DELAY = 0.3
local SURFACE_SNAP_OFFSET = 0.5
local COLLISION_CHECK_RADIUS = .3
local POOL_SIZE = 10

local localPlayer: Player = Players.LocalPlayer
local camera: Camera = workspace.CurrentCamera

local buildablesFolder: Folder? = ReplicatedStorage:FindFirstChild("Buildables")

--// State Variables
local activePreview: Model? = nil
local currentTemplateName: string? = nil
local currentRotation: number = 0
local placedObjectsList: {any} = {}
local isBuildModeEnabled: boolean = false
local availableBuildables: {Model} = {}
local selectedBuildableIndex: number = 1
local lastSurfacePosition: Vector3? = nil
local lastSurfaceNormal: Vector3? = nil

--// Input State Tracking
local keyHoldState: {[string]: boolean} = {
    rotateLeft = false,
    rotateRight = false,
    undoLast = false
}

--// Timing Variables
local lastRotationTime: number = 0
local lastUndoTime: number = 0

--// Object Pool for Performance Optimization
local ObjectPool = {}
ObjectPool.__index = ObjectPool

function ObjectPool.new(maxSize: number)
    local self = setmetatable({}, ObjectPool)
    self.pool = {}
    self.maxSize = maxSize or POOL_SIZE
    self.activeCount = 0
    return self
end

function ObjectPool:acquire(template: Model): Model
    if #self.pool > 0 then
        local obj = table.remove(self.pool)
        obj.Parent = workspace
        self.activeCount = self.activeCount + 1
        return obj
    else
        local newObj = template:Clone()
        self.activeCount = self.activeCount + 1
        return newObj
    end
end

function ObjectPool:release(object: Model)
    if #self.pool < self.maxSize then
        object.Parent = nil
        table.insert(self.pool, object)
        self.activeCount = self.activeCount - 1
    else
        object:Destroy()
        self.activeCount = self.activeCount - 1
    end
end

function ObjectPool:clear()
    for _, obj in ipairs(self.pool) do
        obj:Destroy()
    end
    self.pool = {}
    self.activeCount = 0
end

--// Initialize Object Pool
local buildObjectPool = ObjectPool.new(POOL_SIZE)

--// Placed Object Metatable for Management
local PlacedObject = {}
PlacedObject.__index = PlacedObject

function PlacedObject.new(model: Model, cframe: CFrame, rotationAngle: number)
    local self = setmetatable({}, PlacedObject)
    self.model = model
    self.cframe = cframe
    self.rotation = rotationAngle
    self.timestamp = tick()
    self.isValid = true
    return self
end

function PlacedObject:destroy()
    if self.isValid and self.model and self.model.Parent then
        self.model:Destroy()
        self.isValid = false
    end
end

function PlacedObject:getAge(): number
    return tick() - self.timestamp
end

-- Snaps a value to the nearest grid point
local function snapToGrid(value: number, gridInterval: number): number
    return math.floor((value + gridInterval * 0.5) / gridInterval) * gridInterval
end

local function calculateSurfaceAlignment(position: Vector3, normalVector: Vector3): CFrame
    if not normalVector or normalVector.Magnitude == 0 then
        return CFrame.new(position)
    end

    -- Normalize the surface normal to get the up vector
    local upVector: Vector3 = normalVector.Unit

    -- Calculate right vector using cross product with world x axis
    local rightVector: Vector3 = Vector3.new(1, 0, 0):Cross(upVector)

    -- Handle edge case where normal is parallel to x axis
    if rightVector.Magnitude < 0.001 then
        rightVector = Vector3.new(0, 0, 1):Cross(upVector)
    end

    rightVector = rightVector.Unit

    -- Calculate look vectr
    local lookVector: Vector3 = rightVector:Cross(upVector).Unit

    -- Offset position sligtly above the surface
    local offsetPosition: Vector3 = position + (upVector * SURFACE_SNAP_OFFSET)

    -- Construct CFrame from matrix components
    return CFrame.fromMatrix(offsetPosition, rightVector, upVector)
end

-- Performs collision detecion within a radius
local function checkCollisionInRadius(position: Vector3, radius: number): boolean
    local overlapParams = OverlapParams.new()
    overlapParams.FilterType = Enum.RaycastFilterType.Exclude
    overlapParams.FilterDescendantsInstances = {localPlayer.Character, activePreview}

    local partsInRadius: {BasePart} = workspace:GetPartBoundsInRadius(position, radius, overlapParams)

    for _, part in ipairs(partsInRadius) do
        if CollectionService:HasTag(part, "BuildingPart") then
            return true
        end
    end

    return false
end

-- Casts a ray from camera through mouse position
local function performMouseRaycast(ignoreList: {Instance}): RaycastResult?
    local mousePosition: Vector2 = UserInputService:GetMouseLocation()
    local screenRay: Ray = camera:ScreenPointToRay(mousePosition.X, mousePosition.Y)

    local raycastParams = RaycastParams.new()
    raycastParams.FilterType = Enum.RaycastFilterType.Exclude
    raycastParams.IgnoreWater = true
    raycastParams.FilterDescendantsInstances = ignoreList or {}

    local rayDirection: Vector3 = screenRay.Direction * MAX_RAYCAST_DISTANCE
    return workspace:Raycast(screenRay.Origin, rayDirection, raycastParams)
end

-- Clears the current preview object
local function clearActivePreview()
    if activePreview then
        activePreview:Destroy()
        activePreview = nil
    end
    currentTemplateName = nil
    lastSurfacePosition = nil
    lastSurfaceNormal = nil
end

-- Creates a transparent preview of the selected buildable
local function createBuildPreview(templateModel: Model)
    if not templateModel then return end
    clearActivePreview()

    local previewModel: Model = templateModel:Clone()

    if not previewModel.PrimaryPart then
        for _, descendant in pairs(previewModel:GetDescendants()) do
            if descendant:IsA("BasePart") then
                previewModel.PrimaryPart = descendant
                break
            end
        end
    end

    -- Configure all parts in the preview
    for _, descendant in pairs(previewModel:GetDescendants()) do
        if descendant:IsA("BasePart") then
            descendant.CanCollide = false
            descendant.Anchored = true
            descendant.Transparency = PREVIEW_TRANSPARENCY
            descendant.CastShadow = false
            descendant.Material = Enum.Material.ForceField
        end
    end

    previewModel.Parent = workspace
    activePreview = previewModel
    currentTemplateName = templateModel.Name
end

local function updatePreviewPosition()
    if not isBuildModeEnabled or not activePreview then return end

    local ignoreList: {Instance} = {localPlayer.Character, activePreview}
    local raycastResult: RaycastResult? = performMouseRaycast(ignoreList)
    local targetCFrame: CFrame

    if raycastResult and raycastResult.Instance:IsA("BasePart") then
        -- Mouse is over a part - snap to surface
        lastSurfacePosition = raycastResult.Position
        lastSurfaceNormal = raycastResult.Normal
        targetCFrame = calculateSurfaceAlignment(lastSurfacePosition, lastSurfaceNormal)
    elseif lastSurfacePosition and lastSurfaceNormal then
        targetCFrame = calculateSurfaceAlignment(lastSurfacePosition, lastSurfaceNormal)
    else
        local cameraPosition: Vector3 = camera.CFrame.Position
        local cameraLookVector: Vector3 = camera.CFrame.LookVector
        local targetPosition: Vector3 = cameraPosition + cameraLookVector * MAX_RAYCAST_DISTANCE

        targetCFrame = CFrame.new(
            snapToGrid(targetPosition.X, GRID_SIZE),
            snapToGrid(targetPosition.Y, GRID_SIZE),
            snapToGrid(targetPosition.Z, GRID_SIZE)
        )
    end

    -- Apply rotation to the target CFrame
    local rotatedCFrame: CFrame = targetCFrame * CFrame.Angles(0, math.rad(currentRotation), 0)
    activePreview:PivotTo(rotatedCFrame)
end

local function placeCurrentObject()
    if not activePreview then return end

    local placementCFrame: CFrame = activePreview:GetPivot()

    -- Check for collisions before placing
    if checkCollisionInRadius(placementCFrame.Position, COLLISION_CHECK_RADIUS) then
        warn("collision detected")
        return
    end

    local newObject: Model = activePreview:Clone()
    newObject.Name = "Placed_" .. currentTemplateName

    for _, descendant in pairs(newObject:GetDescendants()) do
        if descendant:IsA("BasePart") then
            descendant.Transparency = 0
            descendant.CanCollide = true
            descendant.Anchored = false
            descendant.Velocity = Vector3.zero
            descendant.AssemblyAngularVelocity = Vector3.zero
            descendant.Material = Enum.Material.Plastic
            CollectionService:AddTag(descendant, "BuildingPart")
        end
    end

    newObject.Parent = workspace
    newObject:PivotTo(placementCFrame)


    local placedObjectData = PlacedObject.new(newObject, placementCFrame, currentRotation)
    table.insert(placedObjectsList, placedObjectData)

    Debris:AddItem(newObject, OBJECT_LIFETIME)

end

-- Removes the most recently placed object
local function undoLastPlacement()
    local objectCount: number = #placedObjectsList
    if objectCount > 0 then
        local lastPlacedObject = placedObjectsList[objectCount]
        lastPlacedObject:destroy()
        table.remove(placedObjectsList, objectCount)
    end
end

-- Toggles building mode 
local function toggleBuildMode()
    isBuildModeEnabled = not isBuildModeEnabled

    if isBuildModeEnabled then
        if availableBuildables[selectedBuildableIndex] then
            createBuildPreview(availableBuildables[selectedBuildableIndex])
        end
    else
        clearActivePreview()
    end
end

-- Cycles through available buildable objects
local function cycleBuildableObject(direction: number)
    if #availableBuildables == 0 then return end

    selectedBuildableIndex = ((selectedBuildableIndex - 1 + direction) % #availableBuildables) + 1

    if isBuildModeEnabled then
        createBuildPreview(availableBuildables[selectedBuildableIndex])
    end
end

-- Load all available buildables from ReplicatedStorage
if buildablesFolder then
    for _, item in pairs(buildablesFolder:GetChildren()) do
        if item:IsA("Model") then
            table.insert(availableBuildables, item)
        end
    end

    table.sort(availableBuildables, function(a, b)
        return a.Name < b.Name
    end)
end


UserInputService.InputBegan:Connect(function(inputObject: InputObject, gameProcessedEvent: boolean)
    if gameProcessedEvent then return end

    if inputObject.UserInputType == Enum.UserInputType.MouseButton1 then
        if isBuildModeEnabled then
            placeCurrentObject()
        end
    elseif inputObject.KeyCode == Enum.KeyCode.R then
        toggleBuildMode()
    elseif inputObject.KeyCode == Enum.KeyCode.Q then
        keyHoldState.rotateLeft = true
    elseif inputObject.KeyCode == Enum.KeyCode.E then
        keyHoldState.rotateRight = true
    elseif inputObject.KeyCode == Enum.KeyCode.Z then
        keyHoldState.undoLast = true
    end
end)

UserInputService.InputEnded:Connect(function(inputObject: InputObject)
    if inputObject.KeyCode == Enum.KeyCode.Q then
        keyHoldState.rotateLeft = false
    elseif inputObject.KeyCode == Enum.KeyCode.E then
        keyHoldState.rotateRight = false
    elseif inputObject.KeyCode == Enum.KeyCode.Z then
        keyHoldState.undoLast = false
    end
end)

UserInputService.InputChanged:Connect(function(inputObject: InputObject, gameProcessedEvent: boolean)
    if gameProcessedEvent or not isBuildModeEnabled then return end

    if inputObject.UserInputType == Enum.UserInputType.MouseWheel then
        local scrollDirection: number = inputObject.Position.Z > 0 and 1 or -1
        cycleBuildableObject(scrollDirection)
    end
end)


RunService.RenderStepped:Connect(function()
    updatePreviewPosition()

    local currentTime: number = tick()

    -- Handle continuous rotation when key is held
    if keyHoldState.rotateLeft and currentTime - lastRotationTime >= ROTATION_DELAY then
        currentRotation = (currentRotation - ROTATION_STEP) % 360
        lastRotationTime = currentTime
    elseif keyHoldState.rotateRight and currentTime - lastRotationTime >= ROTATION_DELAY then
        currentRotation = (currentRotation + ROTATION_STEP) % 360
        lastRotationTime = currentTime
    end

    -- Handle continuous undo when key is held
    if keyHoldState.undoLast and currentTime - lastUndoTime >= UNDO_DELAY then
        undoLastPlacement()
        lastUndoTime = currentTime
    end
end)

--// Cleanup Player

Players.PlayerRemoving:Connect(function(removingPlayer: Player)
    if removingPlayer == localPlayer then
        clearActivePreview()
        buildObjectPool:clear()

        for _, placedObject in ipairs(placedObjectsList) do
            placedObject:destroy()
        end
    end
end)