-- DirectionalDashConfig
return {
    DashDuration = 10 / 60,
    DashDistance = 18,
    Cooldown = 0.65,


    FadeOutTime = 0.025,
    InvisibleTime = 0.085,
    FadeInTime = 0.056666,

    AnimationIds = {
        Front = "rbxassetid://126388621007978",
        Back = "rbxassetid://73505692833388",
        Right = "rbxassetid://96397241320967",
        Left = "rbxassetid://133275442931285",
    },
}
-- DirectionalDashServer
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage:WaitForChild("DirectionalDashConfig"))

local remotes = ReplicatedStorage:FindFirstChild("DirectionalDashRemotes")
if not remotes then
    remotes = Instance.new("Folder")
    remotes.Name = "DirectionalDashRemotes"
    remotes.Parent = ReplicatedStorage
end

local dashRequest = remotes:FindFirstChild("DashRequest")
if not dashRequest then
    dashRequest = Instance.new("RemoteEvent")
    dashRequest.Name = "DashRequest"
    dashRequest.Parent = remotes
end

local dashStarted = remotes:FindFirstChild("DashStarted")
if not dashStarted then
    dashStarted = Instance.new("RemoteEvent")
    dashStarted.Name = "DashStarted"
    dashStarted.Parent = remotes
end

local validDirections = {
    Front = true,
    Back = true,
    Left = true,
    Right = true,
}

local activeDashes = {}
local lastDashAt = {}
local serial = 0

local function flattenUnit(vector, fallback)
    local flat = Vector3.new(vector.X, 0, vector.Z)
    if flat.Magnitude < 0.001 then
        return fallback
    end
    return flat.Unit
end

local function getDashVector(root, directionName)
    local forward = flattenUnit(root.CFrame.LookVector, Vector3.new(0, 0, -1))
    local right = flattenUnit(root.CFrame.RightVector, Vector3.new(1, 0, 0))

    if directionName == "Back" then
        return -forward
    elseif directionName == "Left" then
        return -right
    elseif directionName == "Right" then
        return right
    end

    return forward
end

local function lerpNumber(from, to, alpha)
    return from + (to - from) * alpha
end

local function fadeNumberSequence(sequence, alpha)
    local keypoints = table.create(#sequence.Keypoints)
    for index, keypoint in ipairs(sequence.Keypoints) do
        keypoints[index] = NumberSequenceKeypoint.new(
            keypoint.Time,
            lerpNumber(keypoint.Value, 1, alpha),
            keypoint.Envelope
        )
    end
    return NumberSequence.new(keypoints)
end

local function captureVisuals(character)
    local root = character:FindFirstChild("HumanoidRootPart")
    local originals = {}

    for _, instance in ipairs(character:GetDescendants()) do
        if instance:IsA("BasePart") then
            originals[instance] = {
                kind = "number",
                value = instance.Transparency,
            }
        elseif instance:IsA("Decal") or instance:IsA("Texture") then
            originals[instance] = {
                kind = "number",
                value = instance.Transparency,
            }
        elseif instance:IsA("ParticleEmitter")
            or instance:IsA("Trail")
            or instance:IsA("Beam") then
            originals[instance] = {
                kind = "sequence",
                value = instance.Transparency,
            }
        elseif instance:IsA("Highlight") then
            originals[instance] = {
                kind = "highlight",
                fill = instance.FillTransparency,
                outline = instance.OutlineTransparency,
            }
        end
    end

    local function apply(alpha)
        for instance, original in pairs(originals) do
            if instance.Parent then
                if instance == root then
                 
                    instance.Transparency = 1
                elseif original.kind == "number" then
                    instance.Transparency = lerpNumber(original.value, 1, alpha)
                elseif original.kind == "sequence" then
                    instance.Transparency = fadeNumberSequence(original.value, alpha)
                elseif original.kind == "highlight" then
                    instance.FillTransparency = lerpNumber(original.fill, 1, alpha)
                    instance.OutlineTransparency = lerpNumber(original.outline, 1, alpha)
                end
            end
        end
    end

    local function restore()
        for instance, original in pairs(originals) do
            if instance.Parent then
                if instance == root then
                    instance.Transparency = 1
                elseif original.kind == "number" then
                    instance.Transparency = original.value
                elseif original.kind == "sequence" then
                    instance.Transparency = original.value
                elseif original.kind == "highlight" then
                    instance.FillTransparency = original.fill
                    instance.OutlineTransparency = original.outline
                end
            end
        end
    end

    return apply, restore
end

local function beginVisualEffect(character, duration)
    local apply, restore = captureVisuals(character)
    local fadeOut = math.clamp(Config.FadeOutTime, 0, duration)
    local invisible = math.clamp(Config.InvisibleTime, 0, duration - fadeOut)
    local fadeIn = math.clamp(Config.FadeInTime, 0, duration - fadeOut - invisible)
    local startedAt = os.clock()
    local connection
    local stopped = false

    apply(0)

    local function stop()
        if stopped then
            return
        end
        stopped = true
        if connection then
            connection:Disconnect()
            connection = nil
        end
        restore()
    end

    connection = RunService.Heartbeat:Connect(function()
        local elapsed = os.clock() - startedAt

        if elapsed < fadeOut and fadeOut > 0 then
            apply(elapsed / fadeOut)
        elseif elapsed < fadeOut + invisible then
            apply(1)
        elseif elapsed < duration and fadeIn > 0 then
            apply(1 - ((elapsed - fadeOut - invisible) / fadeIn))
        else
            apply(0)
            stop()
        end
    end)

    return stop
end

local function lockHumanoid(humanoid)
    local saved = {
        WalkSpeed = humanoid.WalkSpeed,
        AutoRotate = humanoid.AutoRotate,
        JumpPower = humanoid.JumpPower,
        JumpHeight = humanoid.JumpHeight,
        JumpingEnabled = humanoid:GetStateEnabled(Enum.HumanoidStateType.Jumping),
        ClimbingEnabled = humanoid:GetStateEnabled(Enum.HumanoidStateType.Climbing),
    }

    humanoid.WalkSpeed = 0
    humanoid.AutoRotate = false
    humanoid.JumpPower = 0
    humanoid.JumpHeight = 0
    humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, false)
    humanoid:SetStateEnabled(Enum.HumanoidStateType.Climbing, false)
    humanoid.Jump = false
    humanoid:Move(Vector3.zero, true)

    local restored = false
    return function()
        if restored then
            return
        end
        restored = true
        if not humanoid.Parent then
            return
        end

        humanoid.WalkSpeed = saved.WalkSpeed
        humanoid.AutoRotate = saved.AutoRotate
        humanoid.JumpPower = saved.JumpPower
        humanoid.JumpHeight = saved.JumpHeight
        humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, saved.JumpingEnabled)
        humanoid:SetStateEnabled(Enum.HumanoidStateType.Climbing, saved.ClimbingEnabled)
    end
end

local function finishDash(player, token)
    local state = activeDashes[player]
    if not state or state.token ~= token then
        return
    end

    activeDashes[player] = nil

    if state.movementConnection then
        state.movementConnection:Disconnect()
        state.movementConnection = nil
    end
    if state.diedConnection then
        state.diedConnection:Disconnect()
        state.diedConnection = nil
    end
    if state.characterAncestryConnection then
        state.characterAncestryConnection:Disconnect()
        state.characterAncestryConnection = nil
    end

    if state.velocity and state.velocity.Parent then
        state.velocity:Destroy()
    end
    if state.attachment and state.attachment.Parent then
        state.attachment:Destroy()
    end

    if state.root and state.root.Parent then
        local currentVelocity = state.root.AssemblyLinearVelocity
       
        state.root.AssemblyLinearVelocity = Vector3.new(0, currentVelocity.Y, 0)
    end

    if state.stopVisuals then
        state.stopVisuals()
    end
    if state.restoreHumanoid then
        state.restoreHumanoid()
    end
end

local function startDash(player, directionName)
    if not validDirections[directionName] then
        return
    end

    local now = os.clock()
    local last = lastDashAt[player] or -math.huge
    if now - last < Config.Cooldown then
        return
    end

    local character = player.Character
    if not character then
        return
    end

    local humanoid = character:FindFirstChildOfClass("Humanoid")
    local root = character:FindFirstChild("HumanoidRootPart")
    if not humanoid or not root or humanoid.Health <= 0 then
        return
    end
    if activeDashes[player] then
        return
    end

    lastDashAt[player] = now
    serial += 1
    local token = serial
    local direction = getDashVector(root, directionName)
    local dashStartedAt = os.clock()
    local velocity = Instance.new("LinearVelocity")
    local attachment = Instance.new("Attachment")

    attachment.Name = "DirectionalDashAttachment"
    attachment.Parent = root

    velocity.Name = "DirectionalDashVelocity"
    velocity.Attachment0 = attachment
    velocity.RelativeTo = Enum.ActuatorRelativeTo.World

    velocity.VectorVelocity = Vector3.zero
    velocity.MaxForce = math.huge
    pcall(function()
        velocity.ForceLimitsEnabled = false
    end)
    velocity.Parent = root

    local state = {
        token = token,
        character = character,
        humanoid = humanoid,
        root = root,
        attachment = attachment,
        velocity = velocity,
        restoreHumanoid = lockHumanoid(humanoid),
        stopVisuals = beginVisualEffect(character, Config.DashDuration),
    }
    activeDashes[player] = state

    state.diedConnection = humanoid.Died:Connect(function()
        finishDash(player, token)
    end)
    state.characterAncestryConnection = character.AncestryChanged:Connect(function(_, parent)
        if not parent then
            finishDash(player, token)
        end
    end)

    state.movementConnection = RunService.Heartbeat:Connect(function()
        if activeDashes[player] ~= state then
            return
        end

        local progress = math.clamp(
            (os.clock() - dashStartedAt) / Config.DashDuration,
            0,
            1
        )

        if progress >= 1 then
            finishDash(player, token)
            return
        end

        local smoothStepDerivative = 6 * progress * (1 - progress)
        local speed = (Config.DashDistance / Config.DashDuration) * smoothStepDerivative
        velocity.VectorVelocity = direction * speed
    end)

  
    dashStarted:FireAllClients(player, directionName, Config.DashDuration)

    task.delay(Config.DashDuration, function()
        finishDash(player, token)
    end)
end

dashRequest.OnServerEvent:Connect(function(player, directionName)
    if typeof(directionName) ~= "string" then
        return
    end
    startDash(player, directionName)
end)

local function clearPlayer(player)
    local state = activeDashes[player]
    if state then
        finishDash(player, state.token)
    end
    activeDashes[player] = nil
    lastDashAt[player] = nil
end

Players.PlayerRemoving:Connect(clearPlayer)

Players.PlayerAdded:Connect(function(player)
    player.CharacterRemoving:Connect(function(character)
        local state = activeDashes[player]
        if state and state.character == character then
            finishDash(player, state.token)
        end
    end)
end)

for _, player in ipairs(Players:GetPlayers()) do
    player.CharacterRemoving:Connect(function(character)
        local state = activeDashes[player]
        if state and state.character == character then
            finishDash(player, state.token)
        end
    end)
end
-- DirectionalDashClient
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local ContentProvider = game:GetService("ContentProvider")

local player = Players.LocalPlayer
local Config = require(ReplicatedStorage:WaitForChild("DirectionalDashConfig"))
local remotes = ReplicatedStorage:WaitForChild("DirectionalDashRemotes")
local dashRequest = remotes:WaitForChild("DashRequest")
local dashStarted = remotes:WaitForChild("DashStarted")

local directionByKey = {
    [Enum.KeyCode.W] = "Front",
    [Enum.KeyCode.S] = "Back",
    [Enum.KeyCode.A] = "Left",
    [Enum.KeyCode.D] = "Right",
}

local heldDirections = {}
local pressOrder = {}
local activeCharacter = nil
local localDashActive = false
local localDashEndsAt = 0
local movementLockConnection = nil
local localDashToken = 0
local localDashTrack = nil
local localDashTrackConnection = nil
local animationTracks = {}

local animations = {}
for directionName, animationId in pairs(Config.AnimationIds) do
    local animation = Instance.new("Animation")
    animation.Name = "DirectionalDash_" .. directionName
    animation.AnimationId = animationId
    animations[directionName] = animation
end
ContentProvider:PreloadAsync({ animations.Front, animations.Back, animations.Left, animations.Right })

local function getCharacterParts(character)
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    local root = character and character:FindFirstChild("HumanoidRootPart")
    return humanoid, root
end

local function getHeldDirection()
    local humanoid, root = getCharacterParts(player.Character)
    local candidates = {}

    for directionName, isHeld in pairs(heldDirections) do
        if isHeld then
            candidates[#candidates + 1] = directionName
        end
    end

    if #candidates == 0 then
        return "Front"
    end
    if #candidates == 1 then
        return candidates[1]
    end

   
    local moveDirection = humanoid and humanoid.MoveDirection or Vector3.zero
    if root and moveDirection.Magnitude > 0.05 then
        local forward = Vector3.new(root.CFrame.LookVector.X, 0, root.CFrame.LookVector.Z)
        local right = Vector3.new(root.CFrame.RightVector.X, 0, root.CFrame.RightVector.Z)
        if forward.Magnitude > 0 then
            forward = forward.Unit
        end
        if right.Magnitude > 0 then
            right = right.Unit
        end

        local worldDirection = {
            Front = forward,
            Back = -forward,
            Left = -right,
            Right = right,
        }

        local bestDirection = nil
        local bestDot = -math.huge
        for _, directionName in ipairs(candidates) do
            local dot = moveDirection.Unit:Dot(worldDirection[directionName])
            if dot > bestDot then
                bestDot = dot
                bestDirection = directionName
            end
        end
        if bestDirection then
            return bestDirection
        end
    end

   
    local newestDirection = candidates[1]
    local newestOrder = pressOrder[newestDirection] or 0
    for _, directionName in ipairs(candidates) do
        local order = pressOrder[directionName] or 0
        if order > newestOrder then
            newestDirection = directionName
            newestOrder = order
        end
    end
    return newestDirection
end

local function stopTrack(character)
    local track = animationTracks[character]
    animationTracks[character] = nil
    if track then
        pcall(function()
            track:Stop(0.025)
            track:Destroy()
        end)
    end
end

local function playDashAnimation(character, directionName, duration)
    if not character or not character.Parent then
        return nil
    end

    local humanoid = character:FindFirstChildOfClass("Humanoid")
    if not humanoid then
        return nil
    end

    local animator = humanoid:FindFirstChildOfClass("Animator")
    if not animator then
        animator = Instance.new("Animator")
        animator.Parent = humanoid
    end

    stopTrack(character)

    local animation = animations[directionName]
    if not animation then
        return nil
    end

    local track = animator:LoadAnimation(animation)
    track.Priority = Enum.AnimationPriority.Action4
    track.Looped = false
    track:Play(0.02, 1, 1)

    
    if track.Length > 0.001 then
        track:AdjustSpeed(track.Length / duration)
    end

    animationTracks[character] = track
    task.delay(duration, function()
        if animationTracks[character] == track then
            animationTracks[character] = nil
            pcall(function()
                track:Stop(0.03)
                track:Destroy()
            end)
        end
    end)

    return track
end

local function endLocalDash(expectedToken)
    if expectedToken and expectedToken ~= localDashToken then
        return
    end
    if not localDashActive then
        return
    end

    local track = localDashTrack
    local character = activeCharacter

    localDashActive = false
    localDashToken += 1
    localDashTrack = nil

    if localDashTrackConnection then
        localDashTrackConnection:Disconnect()
        localDashTrackConnection = nil
    end
    if movementLockConnection then
        movementLockConnection:Disconnect()
        movementLockConnection = nil
    end

    if character and animationTracks[character] == track then
        animationTracks[character] = nil
    end
    if track then
        pcall(function()
            track:Stop(0.03)
            track:Destroy()
        end)
    end
end

local function beginLocalDash(character, duration, track)
    if localDashActive then
        endLocalDash()
    end

    localDashToken += 1
    local token = localDashToken
    localDashActive = true
    activeCharacter = character
    localDashEndsAt = os.clock() + duration
    localDashTrack = track

    if track then
        localDashTrackConnection = track.Stopped:Connect(function()
            if localDashActive and localDashToken == token then
                endLocalDash(token)
            end
        end)
    end

    movementLockConnection = RunService.RenderStepped:Connect(function()
        if localDashToken ~= token then
            return
        end
        if os.clock() >= localDashEndsAt or player.Character ~= activeCharacter then
            endLocalDash(token)
            return
        end

        local humanoid = activeCharacter and activeCharacter:FindFirstChildOfClass("Humanoid")
        if not humanoid or humanoid.Health <= 0 then
            endLocalDash(token)
            return
        end

      
        humanoid.Jump = false
        humanoid:Move(Vector3.zero, false)
    end)
end

local function requestDash()
    if localDashActive then
        return
    end
    if player.Character and player.Character.Parent then
        dashRequest:FireServer(getHeldDirection())
    end
end

UserInputService.InputBegan:Connect(function(input, gameProcessed)
    if gameProcessed or input.UserInputType ~= Enum.UserInputType.Keyboard then
        return
    end

    local directionName = directionByKey[input.KeyCode]
    if directionName then
        heldDirections[directionName] = true
        pressOrder[directionName] = os.clock()
    elseif input.KeyCode == Enum.KeyCode.Q then
        requestDash()
    end
end)

UserInputService.InputEnded:Connect(function(input)
    if input.UserInputType ~= Enum.UserInputType.Keyboard then
        return
    end

    local directionName = directionByKey[input.KeyCode]
    if directionName then
        heldDirections[directionName] = nil
    end
end)

dashStarted.OnClientEvent:Connect(function(dashingPlayer, directionName, duration)
    if typeof(dashingPlayer) ~= "Instance" or not dashingPlayer:IsA("Player") then
        return
    end
    if typeof(directionName) ~= "string" or not Config.AnimationIds[directionName] then
        return
    end

    local character = dashingPlayer.Character
    if not character then
        return
    end

    local dashDuration = duration or Config.DashDuration
    local track = playDashAnimation(character, directionName, dashDuration)

    if dashingPlayer == player then
        beginLocalDash(character, dashDuration, track)
    end
end)

player.CharacterAdded:Connect(function(character)
    endLocalDash()
    activeCharacter = character
end)

player.CharacterRemoving:Connect(function(character)
    if activeCharacter == character then
        endLocalDash()
    end
    stopTrack(character)
end)
