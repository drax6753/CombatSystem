-- Connected Discord-GitHub
-- Discord: drax6753 | Roblox: j8w7r

--!strict

--// Services
local Players = game:GetService("Players") -- Manages all players in the game.
local ReplicatedStorage = game:GetService("ReplicatedStorage") -- Contains data accessible from both server and client.
local ServerScriptService = game:GetService("ServerScriptService") -- Runs server scripts and contains data accessible from only the server.
local RunService = game:GetService("RunService") -- Provides runtime events such as Heartbeat.

--// Dependencies
local sharedServices = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Services") -- Contains services shared between the client and server.
local NetworkService = require(sharedServices:WaitForChild("NetworkService")) -- Handles communication between the client and server.
local AnimationService = require(sharedServices:WaitForChild("AnimationService")) -- Plays and stops character animations.
local FXService = require(sharedServices:WaitForChild("FXService")) -- Plays visual and sound effects.

local serverServices = ServerScriptService:WaitForChild("Server"):WaitForChild("Services") -- Contains server-only services.
local StateService = require(serverServices:WaitForChild("StateService")) -- Manages entity states (Idle, Punching, Blocking, etc...).
local StaminaService = require(serverServices:WaitForChild("StaminaService")) -- Manages entity stamina values and stamina-related events.

--// CombatService //--
local CombatService = {}
type CombatService = typeof(CombatService)

--// Variables
local stuns = {} -- Stores when each entity's stun should end.
local stages = {} -- Tracks each entity's current punch combo stage and last punch time.
local cooldowns: {[Model]: {[string]: number}} = {} -- Stores cooldown end times for each action per entity.

--// Settings
-- Punch
local PUNCH_COOLDOWN = 0.5
local PUNCH_DURATION = 0.3
local HITBOX_SIZE = Vector3.new(8, 5, 8)
local STUN_DURATION = 0.75
local STUN_SPEED = 0
local NORMAL_SPEED = 16
local PUNCH_DAMAGE = 5
local PUNCH_STAGES = 3
local PUNCH_STAGE_DURATION = 1
local PUNCH_STAGE_COOLDOWN = 1.5
local KNOCKBACK_SPEED = 75
local KNOCKBACK_FORCE = 1000000
local KNOCKBACK_DURATION = 0.3

-- Dash
local DASH_FORCE = 100000
local DASH_STAMINA_COST = 25
local DASH_COOLDOWN = 5
local DASH_DURATION = 0.2
local DASH_SPEED = 100

-- Block
local BLOCK_STAMINA_COST = 20

--// Helpers
-- Sets an entity cooldown for a specific action to a specific duration.
local function setCooldown(entity: Model, action: string, duration: number)
	if not entity then return end

	local entityCooldowns = cooldowns[entity] -- Get the cooldowns of the entity.
	if not entityCooldowns then
		entityCooldowns = {}
		cooldowns[entity] = entityCooldowns

		entity.Destroying:Once(function()
			cooldowns[entity] = nil -- Removes the table of the entity when its destroyed to avoid memory leaks.
		end)
	end

	entityCooldowns[action] = os.clock() + duration -- Store the time where the cooldown ends to check for it using "isOnCooldown" function.
end

-- Check whether an entity is on cooldown.
local function isOnCooldown(entity: Model, action: string): boolean
	if not entity then 
		warn("No entity")
		return false
	end

	local entityCooldowns = cooldowns[entity] -- Required for checking the entity cooldowns
	if not entityCooldowns then return false end -- It doesn't have any cooldowns so its not on cooldown

	local endsAt = entityCooldowns[action] -- Get the time where the cooldown ends.
	if not endsAt then return false end

	-- We check if the current time is more or equals the cooldown ends at time means that the cooldown ended.
	if os.clock() >= endsAt then
		entityCooldowns[action] = nil -- Remove the saved time where the cooldown ends at .
		return false
	end

	return true -- Returns true when none of the conditions above are true, means that the entity IS on cooldown.
end

-- Applies linearvelocity to a part, will use it for dash and knockback.
local function applyVelocity(part: Part, force: number, speed: number?, direction: Vector3?, duration: number)
	local att0 = Instance.new("Attachment", part) -- Create an attachment and parent it to the part that we will apply velocity for (Necessary for linearvelocity).
	local lv = Instance.new("LinearVelocity") -- Creates linear velocity but we dont parent it now yet, we parent it after we finish setting up for smoother feeling. "Doesn't really matter that much".

	lv.Attachment0 = att0 -- Set the lv attachment0 to the attachemt we created earlier.
	lv.MaxForce = force -- Set the maxforce of the velocity to the custom force given in the function (Force is the "strength" of the velocity, for example, setting it to high will cause a fling when the part impacts with a wall).

	-- Make sure that speed and direction exists before setting vectorvelocity.
	if speed and direction then
		lv.VectorVelocity = speed * direction
	end

	lv.Parent = part -- Parent after configuration so the force isn't applied until setup is complete.

	task.delay(duration, function()
		lv:Destroy()
		att0:Destroy()
	end) -- Destroy the instance and the attachment after the duration runs out.

	return lv -- return the the instance so we can change its properties if we wanted.
end

-- Checks if a specific action is allowed for an entity.
-- We will use it for checking if the entity is allowed to punch or dash.
local function canAction(entity, actionName)
	-- Check what's the requested action.
	if actionName == "Punch" then
		-- Get entity state, and check if its not idle
		if StateService:GetState(entity) ~= "Idle"
		-- or check if the entity is on cooldown.
		or isOnCooldown(entity, "Punch") then
		-- We used "or" so that if any of the checks were true it will run.
		
			return false -- Punch action is not allowed for the entity.
		end
	elseif actionName == "Dash" then -- Check for dash action.
		if StateService:GetState(entity) ~= "Idle" -- If the entity state is not idle
			or StaminaService:GetStamina(entity) < DASH_STAMINA_COST -- Or the entity doesn't have enough stamina to dash
			or isOnCooldown(entity, "Dash") then -- Or the entity is on cooldown for dash action.
			return false -- Dash action is not allowed for that entity.
		end
	end

	-- If none of checks above ran then the entity is allowed to perform the action.
	return true
end

-- Punch --
-- Returns a hitbox surrounding the entity made by "workspace:GetPartBoundsInBox"
-- it detects everything inside a workspace box for a single frame and returns them in a table.
local function getHitbox(entity, root)
	local cframe = root.CFrame -- Required for creating the hitbox.
	local params = OverlapParams.new() 
	params.FilterType = Enum.RaycastFilterType.Exclude -- Set the filter type to exclude (excludes the given instances when using "FilterDescendantsInstances").
	params.FilterDescendantsInstances = {entity} -- Filter the entity for the function to ignore it.

	return workspace:GetPartBoundsInBox(cframe, HITBOX_SIZE, params) -- Run the function and return it, returns the detected parts in a table so we can loop in it and check each part using for loop.
end

-- Determines whether the enemy is facing the attacker.
-- The dot product compares the enemy's forward direction with the
-- direction from the enemy to the attacker. A higher value means
-- the enemy is looking more directly at the attacker.
local function enemyIsFacingMe(root: Part, enemyRoot: Part)
	local enemyRootLook = enemyRoot.CFrame.LookVector -- The direction that the enemyRoot is facing.
	local toRoot = (root.Position - enemyRoot.Position).Unit -- Direction from the enemy to the attacker.

	local dot = enemyRootLook:Dot(toRoot)

	-- Values closer to 1 indicate the enemy is facing the attacker.
	-- A threshold of 0.5 allows some tolerance instead of requiring perfect alignment.
	return dot > 0.5
end

local function getPunchStage(entity): number
	local now =  os.clock() -- We store the current time.
	local data = stages[entity] -- The data where we store and check stage and lastPunchTime

	-- If the entity has no data stored then initialize and store new data for it.
	if not data then
		data = {
			stage = 1,
			lastTime = 0
		}
		stages[entity] = data
	end

	if now - data.lastTime < PUNCH_STAGE_DURATION then -- We compare the elapsed time with the punch stage duration if its less then our punch stage will increase.
		if data.stage < PUNCH_STAGES then -- We check the stage and make sure it doesn't increase past max stages.
			data.stage += 1
		else
			data.stage = 1 -- If the stage is past max stages then reset it.
		end
	else -- If the elapsed time is more than the stage increase duration then also reset stage for the entity.
		data.stage = 1
	end

	data.lastTime = now -- We update and set the last hit time to now so next time we get the elapsed time.
	return data.stage -- We return punch stage that we calculated after the function ran.
end

-- Lunges both the attacker and the entity that got punched to the attacker's facing direction.
local function lungeForward(root, enemyRoot)
	local direction = root.CFrame.LookVector -- Attacker's root direction for using it in applyVelocity().
	
	applyVelocity(root,100000, 10, direction, 0.2)
	applyVelocity(enemyRoot, 100000,10, direction, 0.2)
end

-- Stuns the enemyEntity, and its speed to 0 and its state to stunned.
local function stun(enemyEntity, enemyHum)
	StateService:SetState(enemyEntity, "Stunned") -- Sets state to stunned, to prevent any action until stun ends.
	enemyHum.WalkSpeed = STUN_SPEED -- Set its speed to 0.
	stuns[enemyEntity] = os.clock() + STUN_DURATION -- Saves the time where the stun is supposed to end at, if we stun 2 times in a row the duration will increase to make sure only the last stun ends.

	-- Run a function after stun duration time.
	task.delay(STUN_DURATION, function()
		-- Check if we passed the time when the stun is supposed to end for that entity.
		if os.clock() >= stuns[enemyEntity] then
			-- Make sure that the enemy entity is stunned before setting it back to idle.
			if StateService:GetState(enemyEntity) == "Stunned" then
				StateService:SetState(enemyEntity, "Idle")
			end

			enemyHum.WalkSpeed = NORMAL_SPEED -- Set enemy speed to normal speed.
			stuns[enemyEntity] = nil -- Clear the table to avoid memory leaks.
		end
	end)
end

-- Applies knockback to enemyEntity, will use it when punch stage 3 lands.
local function applyKnockback(enemyEntity, enemyRoot, root)
	local look = root.CFrame.LookVector -- We need the root look of the entity that is punching so we can set the knockback direction to it.
	local direction = Vector3.new(look.X, 0.5, look.Z).Unit -- Set the knockback direction to root look, while setting Y axis to 0.5 (upward forward).
	-- Unit makes sure and sets the vector3 to a number between (0, 1).
	-- If it was (10, 5, 10) it will be (1, 0.5, 1)

	applyVelocity(enemyRoot, KNOCKBACK_FORCE, KNOCKBACK_SPEED, direction, KNOCKBACK_DURATION)
end

-- Runs the punch logic when the punch lands
local function resolvePunch(entity, hum, root, enemyEntity, enemyHum, enemyRoot, punchStage)
	-- We get the enemyEntity state and check if its knocked, if it is then we can't punch it.
	if StateService:GetState(enemyEntity) == "Knocked" then
		return
	end

	-- Blocking check logic for the enemyEntity.
	-- We check if it's state is blocking.
	if StateService:GetState(enemyEntity) == "Blocking" then
		local enemyStamina = StaminaService:GetStamina(enemyEntity) -- Get enemyEntity stamina, we'll use it for checking that it has enough stamina to block the punch.
		if enemyIsFacingMe(root, enemyRoot)
			-- Checks if it has enough stamina to block the hit.
			and enemyStamina >= BLOCK_STAMINA_COST then
			StaminaService:SetStamina(enemyEntity, enemyStamina - BLOCK_STAMINA_COST) -- Subtract the cost of the block from its stamina.
			FXService:PlaySFX("Block", enemyRoot) -- Plays blocking sound effect on its root.
			return -- Cancels the attacker's punch.
		end
	end

	-- This logic will run if none of the checks above ran
	enemyHum:TakeDamage(PUNCH_DAMAGE) -- Damage the enemy.
	FXService:PlaySFX("Hit", enemyRoot) -- Play hit sfx on the enemyRoot.
	FXService:PlayVFX("Hit", enemyRoot.Position, enemyRoot) -- Play hit vfx on the enemyroot.

	-- Stage one will stun and play stage animation.
	if punchStage == 1 then
		stun(enemyEntity, enemyHum)
		AnimationService:Play("Hurt1", enemyEntity)

		-- Same thing
	elseif punchStage == 2 then
		stun(enemyEntity, enemyHum)
		AnimationService:Play("Hurt2", enemyEntity)

		-- On stage 3
	elseif punchStage == 3 then
		applyKnockback(enemyEntity, enemyRoot, root) -- Apply knockback to enemyEntity.
		StateService:SetState(enemyEntity, "Knocked") -- Set its state to knocked, so it can't get punched while knocked.
		AnimationService:Play("SentFlying", enemyEntity) -- Play sent flying animation.

		task.delay(0.5, function()
			AnimationService:Stop("SentFlying", enemyEntity) -- Stop the animation.
			-- Check if its state is knocked.
			if StateService:GetState(enemyEntity) == "Knocked" then
				StateService:SetState(enemyEntity, "Idle") -- Set it back to idle.
			end
		end)
	end
end

--// Public Methods
-- Initializes.
function CombatService.Init(self: CombatService)
	-- Listens for punch requests coming from client.
	NetworkService:OnServerEvent("PunchRequest", function(player)
		local char = player.Character -- We get the player character to use it for the entity in the punch method.
		-- Only run if character exists.
		if char then
			self:Punch(char) -- Call the method and pass char as entity.
		end
	end)

	-- Listens for dash requests coming from client.
	NetworkService:OnServerEvent("DashRequest", function(player)
		local char = player.Character
		if char then
			self:Dash(char)
		end
	end)

	-- Listens for toggling block request coming from client.
	NetworkService:OnServerEvent("ToggleBlockRequest", function(player, blockState)
		local char = player.Character
		if char then
			self:ToggleBlock(char, blockState)
		end
	end)

	-- Listens for stamina change for an entity to turn of his toggle off its block if it doesn't have enough stamina.
	StaminaService.StaminaChanged:Connect(function(entity, newStamina)
		-- Compare the newStamina with the block cost if its less, then toggle off block for that entity.
		if newStamina < BLOCK_STAMINA_COST then
			self:ToggleBlock(entity, false) -- Toggle off blocking.
		end
	end)
end

-- The actual punch logic.
-- Runs for each entity.
-- Uses getHitbox() which uses workspace:GetPartBoundsInBox() to detect enemies.
function CombatService.Punch(self: CombatService, entity: Model)
	local hum = entity:FindFirstChild("Humanoid") :: Humanoid? -- We get the humanoid for punch logic
	local root = entity:FindFirstChild("HumanoidRootPart") :: Part? -- We get the root for punch logic

	if not (hum and root) then return end -- Nil safety
	if not canAction(entity, "Punch") then return end -- Make sure that the entity can punch

	setCooldown(entity, "Punch", PUNCH_COOLDOWN) -- Gives entity cooldown so it can't spam punches
	StateService:SetState(entity, "Punching") -- Set state to punching so players can't do specific actions until the punch duration ends
	task.delay(PUNCH_DURATION, function() -- Doesn't yield the script
		StateService:SetState(entity, "Idle") -- Reset state to idle after punch duration time ends
	end)
	
	FXService:PlaySFX("Punch", root) -- Always plays a punch sfx on the attacker's root (its a punch swing sfx, different from punch hit sfx)

	local punchStage = getPunchStage(entity) -- Get punch stage to use it for playing animations and knockbacks
	local hits = getHitbox(entity, root) -- Get everything detected inside the hitbox
	-- Use for loop to loop in the hits and apply punch logic if we detected a target
	for _, hit in hits do
		local enemyEntity = hit:FindFirstAncestorOfClass("Model") -- Tries to find the model ancestor of the hit
		if not enemyEntity then continue end -- If it didn't find it then continue to the other detected hit, because we only detect models

		local enemyHum = enemyEntity:FindFirstChild("Humanoid") :: Humanoid? -- Tries to get the humanoid of the model
		local enemyRoot = enemyEntity:FindFirstChild("HumanoidRootPart") :: Part? -- Tries to get the humanoidrootpart of the model
		if not (enemyHum and enemyRoot) then continue end -- If both of them doesn't exist then continue to the other hit part

		-- This logic will run if the punch landed
		lungeForward(root, enemyRoot)
		resolvePunch(entity, hum, root, enemyEntity, enemyHum, enemyRoot, punchStage) -- Contains the punch logic and checks

		break -- Break the loop after logic ran, to avoid duplicated hits
	end

	if punchStage == 3 then
		setCooldown(entity, "Punch", PUNCH_STAGE_COOLDOWN) -- Set the cooldown for the entity that punched to the longer cooldown (only when his punch stages become 3).
	end
end

-- Applies linear velocity using "applyVelocity" function to the entity to make it dash forward, and keeps updating the direction until the dash duration ends.
function CombatService.Dash(self: CombatService, entity: Model)
	local hum = entity:FindFirstChild("Humanoid") :: Humanoid? -- Get the entity humanoid.
	local root = entity:FindFirstChild("HumanoidRootPart") :: Part? -- Get the entity humanoid root part.
	if not (hum and root) then return end -- If the humanoid and the root together are dont exist then exit the function.
	if not canAction(entity, "Dash") then return end -- If the entity is not allowed to perform the dash action then exit the function.

	local stamina = StaminaService:GetStamina(entity) -- Get the entity stamina.
	local staminaAfterSubtract = stamina - DASH_STAMINA_COST -- New stamina value after subtracting dash cost from it.
	StaminaService:SetStamina(entity, staminaAfterSubtract) -- Set the entity stamina to stamina after decrease.
	StateService:SetState(entity, "Dashing") -- Set the entity state to dashing.
	FXService:PlaySFX("Dash", root) -- Plays the dash sound effect and parent it to the entity root.

	local lv = applyVelocity(-- We get linear velocity by calling the applyvelocity function.
		root,
		DASH_FORCE,
		nil, -- Speed is nil "So we can change it later"
		nil, -- Duration is nil "So we can change it later"
		DASH_DURATION
	) 

	local endsAt = os.clock() + DASH_DURATION -- Get the time where the dash will end at using os.clock().
	-- os.clock(): Measures the time of how long the program has been actively working, it returns the time in seconds.

	local conn: RBXScriptConnection -- Make an empty connection variable and type it "We will store the actual connection in it".

	-- Server "Heartbeat" event fires every "server" frame after the server finishes physics simulation.
	-- Make a heartbeat connection and store it in "conn" (so we can disconnect it later).
	conn = RunService.Heartbeat:Connect(function()
		-- Check every server frame if current time passed the time where the dash is supposed to end.
		if os.clock() >= endsAt then
			conn:Disconnect() -- Disconnect the connection.
			StateService:SetState(entity, "Idle") -- Set the entity state to idle after the dash ends.
			setCooldown(entity, "Dash", DASH_COOLDOWN) -- Start the entity dash action cooldown.
			return -- Exit the function
		end

		-- The logic under will run if the check above didn't run yet.

		local moveDir = hum.MoveDirection -- Get the humanoid move direction, returns a vector3.

		-- Update dash direction every frame.
		-- If the entity is moving, dash follows MoveDirection.
		-- Otherwise, dash continues toward the entity root facing direction.
		-- This only matters if the entity is a player character and using shiftlock.
		local direction = (moveDir.Magnitude > 0 and moveDir.Unit) or root.CFrame.LookVector

		-- Sets the velocity speed to the dash speed, and gets X and Z direction in unit while ignoring Y direction and sets the direction to it.
		lv.VectorVelocity = DASH_SPEED * Vector3.new(direction.X, 0, direction.Z).Unit
	end)
end

function CombatService.ToggleBlock(self: CombatService, entity: Model, blockState: boolean)
	local state = StateService:GetState(entity) -- Get the entity state, will exist 100%.
	local stamina = StaminaService:GetStamina(entity) -- Get the entity stamina, will exist 100%.
	local player = Players:GetPlayerFromCharacter(entity) -- Try to get the player, might only work if the entity was a player character, or it will return nil.

	-- If that entity wants to block and its state is "Idle" and it has enough stamina to block.
	if blockState and state == "Idle"
		and stamina >= BLOCK_STAMINA_COST then
		StateService:SetState(entity, "Blocking") -- Set the entity state to blocking.

		-- If theres no player that means its an entity with no player.
		if not player then
			AnimationService:Play("Block", entity) -- Plays blocking animation from the server because the entity doesn't have a client.
		end

		-- If the entity wants to turn off blocking and its state is actually blocking.
	elseif not blockState and state == "Blocking" then
		StateService:SetState(entity, "Idle") -- Set entity state to idle.

		if not player then
			AnimationService:Stop("Block", entity) -- Stops the entity block animation if its not a player character, like an npc model.
		end
	end
end

return CombatService
