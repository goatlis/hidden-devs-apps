-- DirectionalDashConfig
-- This module keeps all dash values in one shared location so both the client
-- and server use identical timing, distance, visual, and animation settings.
return {
    -- The server uses this value to determine how long the dash movement exists.
    -- Keeping duration in the config allows movement, visuals, and animations
    -- to synchronize without each system having its own hardcoded timing.
    DashDuration = 10 / 60,
    -- The server uses this as the total horizontal distance the dash should cover.
    -- The client never controls this value, keeping the actual movement server-sided.
    DashDistance = 18,
    -- This prevents repeated RemoteEvent requests from creating unwanted dashes.
    -- It is checked on the server because a client-side cooldown can be bypassed.
    Cooldown = 0.65,
    -- These values divide the visual effect into fade-out, invisible, and fade-in phases.
    -- They are separate from movement so the visual effect can be adjusted independently.
    FadeOutTime = 0.025,
    InvisibleTime = 0.085,
    FadeInTime = 0.056666,
    -- Direction names are shared between the input system, server movement system,
    -- and animation system so every part of the dash uses the same direction reference.
    AnimationIds = {
        Front = "rbxassetid://",
        Back = "rbxassetid://",
        Right = "rbxassetid://",
        Left = "rbxassetid://", -- sorry i didnt have any animations
    },
}
-- DirectionalDashServer
-- The server is responsible for validating requests and controlling actual movement.
-- This prevents the client from deciding its own dash distance, cooldown, or direction.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
-- The server and client both require the same module so timing and configuration
-- remain synchronized instead of having separate values that could become inconsistent.
local Config = require(ReplicatedStorage:WaitForChild("DirectionalDashConfig"))
-- Keeping the RemoteEvents inside one folder gives the client a predictable
-- communication interface for sending requests and receiving confirmed dashes.
local remotes = ReplicatedStorage:FindFirstChild("DirectionalDashRemotes")
if not remotes then
    remotes = Instance.new("Folder")
    remotes.Name = "DirectionalDashRemotes"
    remotes.Parent = ReplicatedStorage
end
-- DashRequest is intentionally a request rather than direct movement control.
-- The client tells the server what it wants, and the server decides whether it is valid.
local dashRequest = remotes:FindFirstChild("DashRequest")
if not dashRequest then
    dashRequest = Instance.new("RemoteEvent")
    dashRequest.Name = "DashRequest"
    dashRequest.Parent = remotes
end
-- DashStarted is used after validation so every client can synchronize the
-- visual animation with the movement that the server has already approved.
local dashStarted = remotes:FindFirstChild("DashStarted")
if not dashStarted then
    dashStarted = Instance.new("RemoteEvent")
    dashStarted.Name = "DashStarted"
    dashStarted.Parent = remotes
end
-- This whitelist prevents arbitrary direction strings from reaching the movement logic.
-- It also gives the server a fixed set of directions that the client is allowed to request.
local validDirections = {
    Front = true,
    Back = true,
    Left = true,
    Right = true,
}
-- activeDashes stores the complete state of each player's current dash so that
-- movement, cleanup, death handling, and character removal all reference the same state.
local activeDashes = {}
-- lastDashAt provides server-side cooldown validation independently from the client.
local lastDashAt = {}
-- Each dash receives a unique token so delayed cleanup from an older dash cannot
-- accidentally terminate a newer dash belonging to the same player.
local serial = 0
-- Direction vectors are flattened onto the XZ plane because this dash is intended
-- to move horizontally rather than using the character's vertical facing direction.
local function flattenUnit(vector, fallback)
    local flat = Vector3.new(vector.X, 0, vector.Z)
    if flat.Magnitude < 0.001 then
        return fallback
    end
    return flat.Unit
end
-- The character's current CFrame is used as the reference frame so Front/Back/Left/Right
-- remain relative to where the character is facing rather than fixed world directions.
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
-- Linear interpolation is used here because transparency needs a gradual transition
-- between the character's original value and completely invisible.
local function lerpNumber(from, to, alpha)
    return from + (to - from) * alpha
end
-- Particle, trail, and beam transparency uses NumberSequence rather than a single number.
-- Rebuilding its keypoints allows the same fade interpolation to work on those objects.
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
-- Visual properties are captured before changing anything so the dash effect can
-- restore custom character appearances instead of assuming default transparency values.
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
    -- The same captured values are used during the effect so every visual component
    -- fades relative to its original appearance instead of always starting at zero.
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
    -- Restoration is kept separate from applying the effect so cleanup can always
    -- return the character to the exact visual state it had before the dash.
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
-- This function owns the complete visual timeline so visual timing stays tied
-- to the dash duration without affecting the actual movement controller.
local function beginVisualEffect(character, duration)
    local apply, restore = captureVisuals(character)
    local fadeOut = math.clamp(Config.FadeOutTime, 0, duration)
    local invisible = math.clamp(Config.InvisibleTime, 0, duration - fadeOut)
    local fadeIn = math.clamp(Config.FadeInTime, 0, duration - fadeOut - invisible)
    local startedAt = os.clock()
    local connection
    local stopped = false
    apply(0)
    -- stop() centralizes cleanup so the Heartbeat connection and character visuals
    -- are restored exactly once even if multiple cleanup paths attempt to finish the dash.
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
    -- Heartbeat is used because the visual transition needs continuous frame updates
    -- while remaining synchronized with the server's elapsed dash time.
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
-- The humanoid is temporarily locked because normal walking, jumping, and rotation
-- would otherwise compete with the server-controlled dash movement.
local function lockHumanoid(humanoid)
    -- Saving these properties allows the system to support characters with custom
    -- movement settings instead of forcing default Roblox values after the dash.
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
    -- Returning a restore function lets finishDash handle all humanoid cleanup
    -- from one place regardless of whether the dash ends normally or unexpectedly.
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
-- All dash cleanup is centralized here so movement objects, connections, visuals,
-- and humanoid restrictions cannot remain active after the dash has ended.
local function finishDash(player, token)
    local state = activeDashes[player]
    -- The token check protects newer dashes from cleanup belonging to an older dash.
    if not state or state.token ~= token then
        return
    end
    activeDashes[player] = nil
    -- Connections are disconnected first because leaving them active would allow
    -- old callbacks to continue modifying the character after the dash is finished.
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
    -- These physics objects only exist for the dash, so keeping them afterward
    -- would allow unintended movement or unnecessary instances to accumulate.
    if state.velocity and state.velocity.Parent then
        state.velocity:Destroy()
    end
    if state.attachment and state.attachment.Parent then
        state.attachment:Destroy()
    end
    -- Only horizontal dash momentum is removed; the Y velocity is preserved so
    -- falling or other vertical physics are not artificially interrupted.
    if state.root and state.root.Parent then
        local currentVelocity = state.root.AssemblyLinearVelocity
        state.root.AssemblyLinearVelocity = Vector3.new(0, currentVelocity.Y, 0)
    end
    -- These returned functions restore the two systems that were temporarily changed:
    -- character visibility and normal humanoid movement.
    if state.stopVisuals then
        state.stopVisuals()
    end
    if state.restoreHumanoid then
        state.restoreHumanoid()
    end
end
-- This is the server's main validation point. The client provides intent,
-- while this function decides whether the requested dash can actually happen.
local function startDash(player, directionName)
    if not validDirections[directionName] then
        return
    end
    -- Cooldown validation happens here rather than only on the client because
    -- RemoteEvents can be manually fired by an exploiter.
    local now = os.clock()
    local last = lastDashAt[player] or -math.huge
    if now - last < Config.Cooldown then
        return
    end
    local character = player.Character
    if not character then
        return
    end
    -- These references are required because the dash depends on both humanoid
    -- state and the root part's orientation/physics.
    local humanoid = character:FindFirstChildOfClass("Humanoid")
    local root = character:FindFirstChild("HumanoidRootPart")
    if not humanoid or not root or humanoid.Health <= 0 then
        return
    end
    -- Prevents overlapping dash states from competing over the same character.
    if activeDashes[player] then
        return
    end
    lastDashAt[player] = now
    serial += 1
    -- The token gives this dash a unique identity for delayed cleanup and callbacks.
    local token = serial
    -- Direction is calculated once from the character's orientation so the dash
    -- continues in the requested direction even if the character rotates afterward.
    local direction = getDashVector(root, directionName)
    local dashStartedAt = os.clock()
    -- LinearVelocity is used because it provides controlled physics movement while
    -- allowing the server to continuously change the velocity during the dash.
    local velocity = Instance.new("LinearVelocity")
    local attachment = Instance.new("Attachment")
    attachment.Name = "DirectionalDashAttachment"
    attachment.Parent = root
    -- The attachment provides the physical reference point used by LinearVelocity.
    velocity.Name = "DirectionalDashVelocity"
    velocity.Attachment0 = attachment
    -- World-relative movement ensures the calculated direction is not transformed
    -- again by the attachment or character orientation.
    velocity.RelativeTo = Enum.ActuatorRelativeTo.World
    velocity.VectorVelocity = Vector3.zero
    velocity.MaxForce = math.huge
    -- This keeps the movement unconstrained by the default force limit behavior.
    pcall(function()
        velocity.ForceLimitsEnabled = false
    end)
    velocity.Parent = root
    -- One state table groups every object and cleanup function belonging to this dash.
    -- This makes the dash lifecycle easier to manage from death, removal, or timeout.
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
    -- A death connection prevents a dead character from retaining dash movement.
    state.diedConnection = humanoid.Died:Connect(function()
        finishDash(player, token)
    end)
    -- Character removal needs its own cleanup because the humanoid may not die first.
    state.characterAncestryConnection = character.AncestryChanged:Connect(function(_, parent)
        if not parent then
            finishDash(player, token)
        end
    end)
    -- Heartbeat allows the server to continuously calculate the required velocity
    -- instead of applying one fixed impulse that would not match the configured curve.
    state.movementConnection = RunService.Heartbeat:Connect(function()
        if activeDashes[player] ~= state then
            return
        end
        -- Progress converts elapsed time into a predictable 0-to-1 dash timeline.
        local progress = math.clamp(
            (os.clock() - dashStartedAt) / Config.DashDuration,
            0,
            1
        )
        if progress >= 1 then
            finishDash(player, token)
            return
        end
        -- This derivative creates acceleration at the start and deceleration at
        -- the end, producing a smoother dash than using constant velocity.
        local smoothStepDerivative = 6 * progress * (1 - progress)
        -- Distance / duration establishes the required base speed, while the curve
        -- controls how that speed is distributed across the dash's lifetime.
        local speed = (Config.DashDistance / Config.DashDuration) * smoothStepDerivative
        velocity.VectorVelocity = direction * speed
    end)
    -- Only after the server has accepted the request do clients receive the event.
    -- This keeps animation synchronization tied to an actual server-approved dash.
    dashStarted:FireAllClients(player, directionName, Config.DashDuration)
    -- This provides a secondary cleanup path if the frame-based connection somehow
    -- fails to finish the dash at exactly the configured duration.
    task.delay(Config.DashDuration, function()
        finishDash(player, token)
    end)
end
-- RemoteEvent data is validated before entering the main dash logic so unexpected
-- client data cannot be treated as a valid direction.
dashRequest.OnServerEvent:Connect(function(player, directionName)
    if typeof(directionName) ~= "string" then
        return
    end
    startDash(player, directionName)
end)
-- Player cleanup removes both active state and cooldown data when the player leaves.
local function clearPlayer(player)
    local state = activeDashes[player]
    if state then
        finishDash(player, state.token)
    end
    activeDashes[player] = nil
    lastDashAt[player] = nil
end
Players.PlayerRemoving:Connect(clearPlayer)
-- Characters can be replaced without the player leaving, so their old dash state
-- must also be terminated when CharacterRemoving fires.
Players.PlayerAdded:Connect(function(player)
    player.CharacterRemoving:Connect(function(character)
        local state = activeDashes[player]
        if state and state.character == character then
            finishDash(player, state.token)
        end
    end)
end)
-- Existing players need the same CharacterRemoving connection when this script starts.
for _, player in ipairs(Players:GetPlayers()) do
    player.CharacterRemoving:Connect(function(character)
        local state = activeDashes[player]
        if state and state.character == character then
            finishDash(player, state.token)
        end
    end)
end
-- DirectionalDashClient
-- The client handles keyboard input and presentation while the server remains
-- authoritative over the actual dash movement and validation.
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
-- These mappings translate physical keyboard input into the same direction names
-- used by the server and animation configuration.
local directionByKey = {
    [Enum.KeyCode.W] = "Front",
    [Enum.KeyCode.S] = "Back",
    [Enum.KeyCode.A] = "Left",
    [Enum.KeyCode.D] = "Right",
}
-- These tables allow the input system to remember multiple held directions
-- and determine which input should take priority when necessary.
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
-- Animation objects are created once instead of every dash to avoid repeatedly
-- allocating the same assets during gameplay.
local animations = {}
for directionName, animationId in pairs(Config.AnimationIds) do
    local animation = Instance.new("Animation")
    animation.Name = "DirectionalDash_" .. directionName
    animation.AnimationId = animationId
    animations[directionName] = animation
end
-- Preloading reduces the chance of the first dash having visible animation delay.
ContentProvider:PreloadAsync({
    animations.Front,
    animations.Back,
    animations.Left,
    animations.Right
})
-- The local controller only needs these two character components to manage input
-- locking and reference the character currently performing the dash.
local function getCharacterParts(character)
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    local root = character and character:FindFirstChild("HumanoidRootPart")
    return humanoid, root
end
-- Converts the current keyboard state into one direction that the server can validate.
local function getHeldDirection()
    local humanoid, root = getCharacterParts(player.Character)
    local candidates = {}
    -- Collect every direction currently being held instead of assuming only one key.
    for directionName, isHeld in pairs(heldDirections) do
        if isHeld then
            candidates[#candidates + 1] = directionName
        end
    end
    -- Forward is used as a safe default when the player presses Q without movement input.
    if #candidates == 0 then
        return "Front"
    end
    -- No comparison is required when only one direction is being held.
    if #candidates == 1 then
        return candidates[1]
    end
    -- For combinations such as W+D, the character's actual movement direction is
    -- compared against each possible dash direction to choose the closest match.
    local moveDirection = humanoid and humanoid.MoveDirection or Vector3.zero
    if root and moveDirection.Magnitude > 0.05 then
        local forward = Vector3.new(
            root.CFrame.LookVector.X,
            0,
            root.CFrame.LookVector.Z
        )
        local right = Vector3.new(
            root.CFrame.RightVector.X,
            0,
            root.CFrame.RightVector.Z
        )
        if forward.Magnitude > 0 then
            forward = forward.Unit
        end
        if right.Magnitude > 0 then
            right = right.Unit
        end
        -- These vectors use the same local-to-world relationship as the server,
        -- ensuring the client chooses the same directional meaning that the server uses.
        local worldDirection = {
            Front = forward,
            Back = -forward,
            Left = -right,
            Right = right,
        }
        local bestDirection = nil
        local bestDot = -math.huge
        -- Dot products provide a simple comparison between the player's movement
        -- direction and each possible dash direction.
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
    -- If movement direction cannot resolve the combination, the most recently
    -- pressed key is used because it matches the player's latest input intention.
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
-- Only one dash animation should control a character at a time, so the previous
-- track is stopped before a new direction's animation is loaded.
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
-- The client handles animation presentation because animation playback does not
-- need to be authoritative, while the server remains authoritative over movement.
local function playDashAnimation(character, directionName, duration)
    if not character or not character.Parent then
        return nil
    end
    local humanoid = character:FindFirstChildOfClass("Humanoid")
    if not humanoid then
        return nil
    end
    -- Animator is the Roblox component responsible for creating animation tracks
    -- from Animation objects and is required before LoadAnimation can be used.
    local animator = humanoid:FindFirstChildOfClass("Animator")
    if not animator then
        animator = Instance.new("Animator")
        animator.Parent = humanoid
    end
    stopTrack(character)
    -- The direction name received from the server selects the corresponding animation.
    local animation = animations[directionName]
    if not animation then
        return nil
    end
    local track = animator:LoadAnimation(animation)
    -- Action4 gives the dash animation high priority so normal movement animations
    -- do not visually override the dash while it is active.
    track.Priority = Enum.AnimationPriority.Action4
    track.Looped = false
    track:Play(0.02, 1, 1)
    -- Scaling playback speed makes animations with different original lengths
    -- finish at the same time as the server-controlled dash.
    if track.Length > 0.001 then
        track:AdjustSpeed(track.Length / duration)
    end
    animationTracks[character] = track
    -- Delayed cleanup prevents unused animation tracks from remaining stored forever.
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
-- Ends all local state associated with the current dash.
local function endLocalDash(expectedToken)
    -- An old callback is ignored when its token no longer matches the current dash.
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
    -- Local connections are disconnected so they cannot continue locking the player
    -- after the server has finished the dash.
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
-- This handles the local presentation of a confirmed server dash.
-- It does not move the player; it only prevents input from fighting server movement.
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
    -- If the animation ends unexpectedly, the local dash state is cleaned up as well.
    if track then
        localDashTrackConnection = track.Stopped:Connect(function()
            if localDashActive and localDashToken == token then
                endLocalDash(token)
            end
        end)
    end
    -- RenderStepped is used for local input locking because it runs on the client
    -- every rendered frame and prevents movement input from visually fighting the dash.
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
-- The client sends only the player's intended direction.
-- Actual permission and movement are still decided by the server.
local function requestDash()
    if localDashActive then
        return
    end
    if player.Character and player.Character.Parent then
        dashRequest:FireServer(getHeldDirection())
    end
end
-- Convert keyboard input into held direction state or a dash request.
UserInputService.InputBegan:Connect(function(input, gameProcessed)
    -- Ignoring processed input prevents the dash system from reacting to input
    -- that Roblox has already consumed for another interface.
    if gameProcessed or input.UserInputType ~= Enum.UserInputType.Keyboard then
        return
    end
    local directionName = directionByKey[input.KeyCode]
    if directionName then
        -- Store the key so combinations can be resolved later.
        heldDirections[directionName] = true
        -- The timestamp provides ordering information for simultaneous held keys.
        pressOrder[directionName] = os.clock()
    elseif input.KeyCode == Enum.KeyCode.Q then
        requestDash()
    end
end)
-- Remove the direction from the active input state once the key is released.
UserInputService.InputEnded:Connect(function(input)
    if input.UserInputType ~= Enum.UserInputType.Keyboard then
        return
    end
    local directionName = directionByKey[input.KeyCode]
    if directionName then
        heldDirections[directionName] = nil
    end
end)
-- This event is received only after the server accepts a dash.
-- It synchronizes the visual animation across every client while keeping movement server-sided.
dashStarted.OnClientEvent:Connect(function(dashingPlayer, directionName, duration)
    -- Validate the replicated player reference before using it as a character owner.
    if typeof(dashingPlayer) ~= "Instance" or not dashingPlayer:IsA("Player") then
        return
    end
    -- The direction must exist in the shared animation configuration so clients
    -- cannot attempt to load an undefined animation.
    if typeof(directionName) ~= "string" or not Config.AnimationIds[directionName] then
        return
    end
    local character = dashingPlayer.Character
    if not character then
        return
    end
    -- The server-provided duration is preferred because it represents the dash
    -- that was actually accepted rather than a potentially different local value.
    local dashDuration = duration or Config.DashDuration
    local track = playDashAnimation(character, directionName, dashDuration)
    -- Only the local player needs input locking; other clients only need the animation.
    if dashingPlayer == player then
        beginLocalDash(character, dashDuration, track)
    end
end)
-- A new character invalidates the previous local dash state because the old
-- humanoid and animation objects no longer belong to the active character.
player.CharacterAdded:Connect(function(character)
    endLocalDash()
    activeCharacter = character
end)
-- CharacterRemoving is the final local cleanup path for animations and dash state
-- when Roblox replaces or removes the player's character.
player.CharacterRemoving:Connect(function(character)
    if activeCharacter == character then
        endLocalDash()
    end
    stopTrack(character)
end)
