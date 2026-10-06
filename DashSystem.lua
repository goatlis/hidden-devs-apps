--// SERVICES
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")
local Workspace = game:GetService("Workspace")

--// PLAYER REFERENCES
local Player = Players.LocalPlayer
local Camera = Workspace.CurrentCamera

--// CONFIGURATION
local CONFIG = {
	Dash = {
		Distance = 22,
		Duration = 0.18,
		Cooldown = 0.65,
		StaminaCost = 25,
		MaxStamina = 100,
		StaminaRecovery = 20,
		Acceleration = 4,
	},
	Movement = {
		MinimumDirection = 0.05,
		WallPadding = 1.5,
	},
	Camera = {
		DefaultFOV = 70,
		DashFOV = 82,
		TweenTime = 0.08,
	},
	Visuals = {
		Transparency = 0.65,
		AfterimageLifetime = 0.12,
	},
	Keys = {
		Dash = Enum.KeyCode.Q,
		Forward = Enum.KeyCode.W,
		Backward = Enum.KeyCode.S,
		Left = Enum.KeyCode.A,
		Right = Enum.KeyCode.D,
	},
}

--// DIRECTION TABLE
local DIRECTIONS = {
	Forward = Vector3.new(0, 0, -1),
	Backward = Vector3.new(0, 0, 1),
	Left = Vector3.new(-1, 0, 0),
	Right = Vector3.new(1, 0, 0),
}

--// INPUT STATE
local InputState = {
	[CONFIG.Keys.Forward] = false,
	[CONFIG.Keys.Backward] = false,
	[CONFIG.Keys.Left] = false,
	[CONFIG.Keys.Right] = false,
}

--// CONTROLLER METATABLE
-- A metatable keeps the dash state and its behavior together instead of
-- spreading state across unrelated global functions.
local Controller = {}
Controller.__index = Controller

function Controller.new(player)
	local self = setmetatable({}, Controller)

	self.Player = player
	self.Character = nil
	self.Humanoid = nil
	self.Root = nil
	self.Animator = nil

	self.IsDashing = false
	self.LastDash = -math.huge
	self.Stamina = CONFIG.Dash.MaxStamina

	self.DashVelocity = nil
	self.DashAttachment = nil
	self.DashConnection = nil
	self.DeathConnection = nil
	self.CharacterConnection = nil

	self.AnimationTracks = {}
	self.VisualParts = {}

	self.UI = nil
	self.StaminaBar = nil
	self.StatusLabel = nil

	self.CameraTween = nil

	return self
end

--// CHARACTER SETUP
function Controller:SetCharacter(character)
	self:StopDash()
	self:DisconnectCharacter()

	self.Character = character
	self.Humanoid = character:WaitForChild("Humanoid")
	self.Root = character:WaitForChild("HumanoidRootPart")
	self.Animator = self.Humanoid:FindFirstChildOfClass("Animator")

	if not self.Animator then
		self.Animator = Instance.new("Animator")
		self.Animator.Parent = self.Humanoid
	end

	self.Stamina = CONFIG.Dash.MaxStamina
	self:CreateAnimations()
	self:CreateDeathConnection()
	self:UpdateUI()
end

--// CHARACTER CLEANUP
function Controller:DisconnectCharacter()
	if self.DeathConnection then
		self.DeathConnection:Disconnect()
		self.DeathConnection = nil
	end
end

--// DEATH HANDLING
function Controller:CreateDeathConnection()
	self.DeathConnection = self.Humanoid.Died:Connect(function()
		self:StopDash()
		self:ClearVisuals()
	end)
end

--// ANIMATION CREATION
function Controller:CreateAnimations()
	self.AnimationTracks = {}

	local animations = {
		Forward = "rbxassetid://",
		Backward = "rbxassetid://",
		Left = "rbxassetid://",
		Right = "rbxassetid://", -- sorry didnt make any animations 
	}

	for name, id in pairs(animations) do
		local animation = Instance.new("Animation")
		animation.Name = "Dash_" .. name
		animation.AnimationId = id

		local success, track = pcall(function()
			return self.Animator:LoadAnimation(animation)
		end)

		if success and track then
			track.Priority = Enum.AnimationPriority.Action4
			track.Looped = false
			self.AnimationTracks[name] = track
		end

		animation:Destroy()
	end
end

--// INPUT DIRECTION
function Controller:GetInputDirection()
	local x = 0
	local z = 0

	if InputState[CONFIG.Keys.Left] then
		x -= 1
	end

	if InputState[CONFIG.Keys.Right] then
		x += 1
	end

	if InputState[CONFIG.Keys.Forward] then
		z -= 1
	end

	if InputState[CONFIG.Keys.Backward] then
		z += 1
	end

	local input = Vector3.new(x, 0, z)

	if input.Magnitude < CONFIG.Movement.MinimumDirection then
		return Vector3.new(0, 0, -1)
	end

	return input.Unit
end

--// CAMERA RELATIVE DIRECTION
function Controller:GetWorldDirection()
	local localDirection = self:GetInputDirection()

	local cameraCFrame = Camera.CFrame

	local forward = Vector3.new(
		cameraCFrame.LookVector.X,
		0,
		cameraCFrame.LookVector.Z
	)

	local right = Vector3.new(
		cameraCFrame.RightVector.X,
		0,
		cameraCFrame.RightVector.Z
	)

	if forward.Magnitude <= 0 then
		forward = Vector3.new(0, 0, -1)
	else
		forward = forward.Unit
	end

	if right.Magnitude <= 0 then
		right = Vector3.new(1, 0, 0)
	else
		right = right.Unit
	end

	local worldDirection =
		right * localDirection.X
		+ forward * -localDirection.Z

	if worldDirection.Magnitude <= 0 then
		return forward
	end

	return worldDirection.Unit
end

--// DIRECTION NAME
function Controller:GetDirectionName(direction)
	local root = self.Root

	if not root then
		return "Forward"
	end

	local forward = Vector3.new(
		root.CFrame.LookVector.X,
		0,
		root.CFrame.LookVector.Z
	).Unit

	local right = Vector3.new(
		root.CFrame.RightVector.X,
		0,
		root.CFrame.RightVector.Z
	).Unit

	local values = {
		Forward = direction:Dot(forward),
		Backward = direction:Dot(-forward),
		Right = direction:Dot(right),
		Left = direction:Dot(-right),
	}

	local selected = "Forward"
	local highest = -math.huge

	for name, value in pairs(values) do
		if value > highest then
			highest = value
			selected = name
		end
	end

	return selected
end

--// RAYCAST PARAMETERS
function Controller:GetRaycastParams()
	local params = RaycastParams.new()

	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = {self.Character}
	params.IgnoreWater = true

	return params
end

--// OBSTACLE CHECK
function Controller:GetSafeDistance(direction)
	if not self.Root then
		return 0
	end

	local origin = self.Root.Position
	local castDistance = CONFIG.Dash.Distance

	local result = Workspace:Raycast(
		origin,
		direction * castDistance,
		self:GetRaycastParams()
	)

	if not result then
		return castDistance
	end

	local distance = (result.Position - origin).Magnitude
	local safeDistance = math.max(
		distance - CONFIG.Movement.WallPadding,
		0
	)

	return safeDistance
end

--// STAMINA CHECK
function Controller:CanDash()
	if not self.Character then
		return false
	end

	if not self.Humanoid then
		return false
	end

	if self.Humanoid.Health <= 0 then
		return false
	end

	if self.IsDashing then
		return false
	end

	if os.clock() - self.LastDash < CONFIG.Dash.Cooldown then
		return false
	end

	if self.Stamina < CONFIG.Dash.StaminaCost then
		return false
	end

	return true
end

--// ANIMATION
function Controller:PlayAnimation(directionName)
	local track = self.AnimationTracks[directionName]

	if not track then
		return
	end

	for _, otherTrack in pairs(self.AnimationTracks) do
		if otherTrack ~= track and otherTrack.IsPlaying then
			otherTrack:Stop(0.04)
		end
	end

	track:Play(0.04, 1, 1)

	if track.Length > 0 then
		track:AdjustSpeed(track.Length / CONFIG.Dash.Duration)
	end
end

--// CAMERA EFFECT
function Controller:SetCameraDashEffect(enabled)
	local targetFOV = enabled
		and CONFIG.Camera.DashFOV
		or CONFIG.Camera.DefaultFOV

	if self.CameraTween then
		self.CameraTween:Cancel()
	end

	self.CameraTween = TweenService:Create(
		Camera,
		TweenInfo.new(
			CONFIG.Camera.TweenTime,
			Enum.EasingStyle.Quad,
			Enum.EasingDirection.Out
		),
		{
			FieldOfView = targetFOV,
		}
	)

	self.CameraTween:Play()
end

--// AFTERIMAGE CREATION
function Controller:CreateAfterimage()
	if not self.Character then
		return
	end

	local folder = Workspace:FindFirstChild("DashAfterimages")

	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "DashAfterimages"
		folder.Parent = Workspace
	end

	for _, original in ipairs(self.Character:GetChildren()) do
		if original:IsA("BasePart")
			and original.Name ~= "HumanoidRootPart" then

			local clone = original:Clone()

			for _, descendant in ipairs(clone:GetDescendants()) do
				if descendant:IsA("Script")
					or descendant:IsA("LocalScript")
					or descendant:IsA("ModuleScript") then
					descendant:Destroy()
				end
			end

			clone.Anchored = true
			clone.CanCollide = false
			clone.CanTouch = false
			clone.CanQuery = false
			clone.Transparency = CONFIG.Visuals.Transparency
			clone.Parent = folder

			Debris:AddItem(
				clone,
				CONFIG.Visuals.AfterimageLifetime
			)

			local tween = TweenService:Create(
				clone,
				TweenInfo.new(
					CONFIG.Visuals.AfterimageLifetime,
					Enum.EasingStyle.Linear
				),
				{
					Transparency = 1,
				}
			)

			tween:Play()
		end
	end
end

--// VELOCITY CREATION
function Controller:CreateDashPhysics()
	self.DashAttachment = Instance.new("Attachment")
	self.DashAttachment.Name = "DashAttachment"
	self.DashAttachment.Parent = self.Root

	self.DashVelocity = Instance.new("LinearVelocity")
	self.DashVelocity.Name = "DashVelocity"
	self.DashVelocity.Attachment0 = self.DashAttachment
	self.DashVelocity.RelativeTo = Enum.ActuatorRelativeTo.World
	self.DashVelocity.MaxForce = math.huge
	self.DashVelocity.VectorVelocity = Vector3.zero

	pcall(function()
		self.DashVelocity.ForceLimitsEnabled = false
	end)

	self.DashVelocity.Parent = self.Root
end

--// PHYSICS CLEANUP
function Controller:DestroyDashPhysics()
	if self.DashVelocity then
		self.DashVelocity:Destroy()
		self.DashVelocity = nil
	end

	if self.DashAttachment then
		self.DashAttachment:Destroy()
		self.DashAttachment = nil
	end
end

--// MOVEMENT LOCK
function Controller:LockHumanoid()
	if not self.Humanoid then
		return
	end

	self.Humanoid.AutoRotate = false
	self.Humanoid.WalkSpeed = 0
	self.Humanoid.Jump = false
end

--// MOVEMENT RESTORE
function Controller:RestoreHumanoid()
	if not self.Humanoid then
		return
	end

	self.Humanoid.AutoRotate = true
	self.Humanoid.WalkSpeed = 16
	self.Humanoid.Jump = false
end

--// DASH START
function Controller:Dash()
	if not self:CanDash() then
		return
	end

	local direction = self:GetWorldDirection()
	local directionName = self:GetDirectionName(direction)
	local safeDistance = self:GetSafeDistance(direction)

	if safeDistance <= 0 then
		return
	end

	self.IsDashing = true
	self.LastDash = os.clock()
	self.Stamina -= CONFIG.Dash.StaminaCost

	self:LockHumanoid()
	self:CreateDashPhysics()
	self:PlayAnimation(directionName)
	self:SetCameraDashEffect(true)
	self:CreateAfterimage()

	local startTime = os.clock()
	local duration = CONFIG.Dash.Duration

	self.DashConnection = RunService.RenderStepped:Connect(function()
		if not self.IsDashing then
			return
		end

		if not self.Root or not self.Root.Parent then
			self:StopDash()
			return
		end

		local elapsed = os.clock() - startTime
		local progress = math.clamp(
			elapsed / duration,
			0,
			1
		)

		if progress >= 1 then
			self:StopDash()
			return
		end

		local acceleration =
			math.sin(progress * math.pi)

		local speed =
			(safeDistance / duration)
			* acceleration
			* CONFIG.Dash.Acceleration

		local currentVelocity =
			direction * speed

		if self.DashVelocity then
			self.DashVelocity.VectorVelocity =
				currentVelocity
		end

		if progress > 0.35
			and progress < 0.75
			and math.random() < 0.15 then
			self:CreateAfterimage()
		end

		self.Humanoid.Jump = false
	end)
end

--// DASH STOP
function Controller:StopDash()
	if not self.IsDashing and not self.DashConnection then
		return
	end

	self.IsDashing = false

	if self.DashConnection then
		self.DashConnection:Disconnect()
		self.DashConnection = nil
	end

	self:DestroyDashPhysics()
	self:RestoreHumanoid()
	self:SetCameraDashEffect(false)
end

--// STAMINA UPDATE
function Controller:RecoverStamina(deltaTime)
	if self.IsDashing then
		return
	end

	self.Stamina = math.min(
		CONFIG.Dash.MaxStamina,
		self.Stamina
			+ CONFIG.Dash.StaminaRecovery
			* deltaTime
	)
end

--// UI CREATION
function Controller:CreateUI()
	local gui = Instance.new("ScreenGui")
	gui.Name = "DashDemoUI"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.Parent = Player:WaitForChild("PlayerGui")

	local frame = Instance.new("Frame")
	frame.Name = "Container"
	frame.Size = UDim2.fromOffset(280, 90)
	frame.Position = UDim2.new(
		0,
		20,
		1,
		-110
	)
	frame.BackgroundTransparency = 0.15
	frame.Parent = gui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = frame

	local status = Instance.new("TextLabel")
	status.Name = "Status"
	status.Size = UDim2.new(1, -20, 0, 30)
	status.Position = UDim2.fromOffset(10, 8)
	status.BackgroundTransparency = 1
	status.Text = "DASH READY | Q"
	status.TextSize = 18
	status.Font = Enum.Font.GothamBold
	status.TextXAlignment = Enum.TextXAlignment.Left
	status.Parent = frame

	local barBackground = Instance.new("Frame")
	barBackground.Name = "StaminaBackground"
	barBackground.Size = UDim2.new(1, -20, 0, 16)
	barBackground.Position = UDim2.fromOffset(10, 50)
	barBackground.BackgroundTransparency = 0.25
	barBackground.Parent = frame

	local barCorner = Instance.new("UICorner")
	barCorner.CornerRadius = UDim.new(1, 0)
	barCorner.Parent = barBackground

	local bar = Instance.new("Frame")
	bar.Name = "Stamina"
	bar.Size = UDim2.fromScale(1, 1)
	bar.BackgroundTransparency = 0
	bar.Parent = barBackground

	local barFillCorner = Instance.new("UICorner")
	barFillCorner.CornerRadius = UDim.new(1, 0)
	barFillCorner.Parent = bar

	self.UI = gui
	self.StatusLabel = status
	self.StaminaBar = bar
end

--// UI UPDATE
function Controller:UpdateUI()
	if not self.StatusLabel or not self.StaminaBar then
		return
	end

	local percentage =
		self.Stamina / CONFIG.Dash.MaxStamina

	self.StaminaBar.Size =
		UDim2.fromScale(
			math.clamp(percentage, 0, 1),
			1
		)

	if self.IsDashing then
		self.StatusLabel.Text = "DASHING"
	elseif percentage < 1 then
		self.StatusLabel.Text =
			"DASH COOLDOWN / STAMINA"
	else
		self.StatusLabel.Text =
			"DASH READY | Q"
	end
end

--// VISUAL CLEANUP
function Controller:ClearVisuals()
	for _, object in ipairs(self.VisualParts) do
		if object and object.Parent then
			object:Destroy()
		end
	end

	table.clear(self.VisualParts)
end

--// UPDATE LOOP
function Controller:Update(deltaTime)
	self:RecoverStamina(deltaTime)

	if self.LastDash ~= -math.huge then
		if os.clock() - self.LastDash >= CONFIG.Dash.Cooldown
			and self.Stamina >= CONFIG.Dash.StaminaCost then

			self:UpdateUI()
		end
	end

	self:UpdateUI()
end

--// CONTROLLER INITIALIZATION
local DashController = Controller.new(Player)

DashController:CreateUI()

--// INITIAL CHARACTER
if Player.Character then
	DashController:SetCharacter(Player.Character)
end

--// CHARACTER RESPAWN
Player.CharacterAdded:Connect(function(character)
	DashController:SetCharacter(character)
end)

--// KEYBOARD INPUT
UserInputService.InputBegan:Connect(function(input, processed)
	if processed then
		return
	end

	if input.UserInputType ~= Enum.UserInputType.Keyboard then
		return
	end

	if InputState[input.KeyCode] ~= nil then
		InputState[input.KeyCode] = true
		return
	end

	if input.KeyCode == CONFIG.Keys.Dash then
		DashController:Dash()
	end
end)

--// KEYBOARD RELEASE
UserInputService.InputEnded:Connect(function(input)
	if input.UserInputType ~= Enum.UserInputType.Keyboard then
		return
	end

	if InputState[input.KeyCode] ~= nil then
		InputState[input.KeyCode] = false
	end
end)

--// FRAME UPDATE
RunService.RenderStepped:Connect(function(deltaTime)
	DashController:Update(deltaTime)
end)

--// CAMERA RECOVERY
Camera.FieldOfView = CONFIG.Camera.DefaultFOV
