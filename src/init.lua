--[[
	Reusable Config Package
	=======================
	
	A self-contained config management system with:
	- Dynamic key registration via addKey()
	- Server-side player config with A/B testing support
	- Client-side config consumption
	- Pluggable eligibility evaluators and persistence
	
	SETUP:
	```lua
	local Config = require("config")
	
	-- Register keys (shared code, runs on both server and client)
	Config.addKey("featureEnabled", {
		scope = "player",
		replicated = true,
		defaultValue = false,
		testValue = true,  -- Optional: used in Studio
		eligibility = { kind = "newPlayer" },  -- Optional: A/B targeting
	})
	```
	
	SERVER USAGE:
	```lua
	-- Initialize (call once on server startup)
	Config.server.init()
	
	-- Player lifecycle (call on PlayerAdded/PlayerRemoving)
	Config.server.initPlayer(player)
	Config.server.cleanupPlayer(player)
	
	-- Read values
	local value = Config.server.getValue("featureEnabled", player)
	local enabled = Config.server.getBoolean("featureEnabled", player)
	
	-- Reactivity
	local atom = Config.server.getPlayerAtom(player)
	
	-- Overrides (for testing/admin)
	Config.server.setPlayerOverride(player, "featureEnabled", true)
	```
	
	CLIENT USAGE:
	```lua
	-- Initialize with config received from server
	Config.client.init(replicatedConfig)
	
	-- Update when server sends new config
	Config.client.update(newConfig)
	
	-- Read values
	local value = Config.client.getValue("featureEnabled")
	local enabled = Config.client.getBoolean("featureEnabled")
	
	-- Reactivity (returns charm signal getter)
	local getConfig = Config.client.getConfig()
	```
	
	A/B TESTING SETUP:
	```lua
	-- Register eligibility evaluators
	Config.registerEligibility("newPlayer", function(playerId)
		return isNewPlayer(playerId)  -- true/false/nil (nil = not ready)
	end)
	
	-- Configure persistence for cohort tracking
	Config.setPersistence({
		getEligibility = function(playerId) return stored[playerId].eligibility end,
		setEligibility = function(playerId, data) stored[playerId].eligibility = data end,
		getEnrolledValues = function(playerId) return stored[playerId].enrolled end,
		setEnrolledValues = function(playerId, data) stored[playerId].enrolled = data end,
	})
	```
]]

local ConfigService = game:GetService("ConfigService")
local RunService = game:GetService("RunService")

-- NOTE: Adjust this require path to match your project's charm package location
local charm = require("./charm")

--------------------------------------------------------------------------------
-- Types
--------------------------------------------------------------------------------

export type Eligibility = {
	kind: string,
	[string]: any,
}

export type ConfigKey = {
	scope: "server" | "player",
	replicated: boolean,
	defaultValue: any,
	testValue: any?,
	eligibility: Eligibility?,
}

export type PersistenceCallbacks = {
	getEligibility: (playerId: string) -> { [string]: boolean }?,
	setEligibility: (playerId: string, eligibility: { [string]: boolean }) -> (),
	getEnrolledValues: (playerId: string) -> { [string]: any }?,
	setEnrolledValues: (playerId: string, values: { [string]: any }) -> (),
}

type EligibilityEvaluator = (playerId: string) -> boolean?

--------------------------------------------------------------------------------
-- Utility Functions (inline for self-containment)
--------------------------------------------------------------------------------

local function equals(a: any, b: any): boolean
	if a == b then
		return true
	end

	if type(a) ~= "table" or type(b) ~= "table" then
		return false
	end

	for key, value in pairs(a) do
		if not equals(value, b[key]) then
			return false
		end
	end

	for key, value in pairs(b) do
		if not equals(value, a[key]) then
			return false
		end
	end

	return true
end

local function set<K, V>(dictionary: { [K]: V }, key: K, value: V): { [K]: V }
	local result = table.clone(dictionary)
	result[key] = value
	return result
end

local function _setIn<S, T>(state: S, path: { string }, value: T): S
	local function recursiveSet(currentState: any, index: number): any
		if index > #path then
			return value
		end

		local key = path[index]
		local nextState = if currentState[key] ~= nil then currentState[key] else {}
		return set(currentState, key, recursiveSet(nextState, index + 1))
	end

	return recursiveSet(state, 1) :: S
end

local function when(condition: () -> any, callback: () -> ()): () -> ()
	local toggled = charm.computed(function(wasToggled: boolean?)
		return wasToggled or (not not condition()) or false
	end)

	return charm.effect(function()
		if toggled() then
			return charm.peek(callback)
		end
		return
	end)
end

-- Recursively merge config value with defaults, filling in missing keys
local function reconcileWithDefaults(value: any, defaultValue: any): any
	if type(defaultValue) ~= "table" or type(value) ~= "table" then
		return value
	end

	local result = table.clone(value)
	for key, defaultVal in defaultValue do
		if result[key] == nil then
			result[key] = defaultVal
		elseif type(defaultVal) == "table" then
			result[key] = reconcileWithDefaults(result[key], defaultVal)
		end
	end
	return result
end

--------------------------------------------------------------------------------
-- Shared State
--------------------------------------------------------------------------------

local isStudio = RunService:IsStudio()
local configKeys: { [string]: ConfigKey } = {}
local eligibilityEvaluators: { [string]: EligibilityEvaluator } = {}
local persistence: PersistenceCallbacks? = nil

--------------------------------------------------------------------------------
-- Shared API
--------------------------------------------------------------------------------

local function addKey(name: string, definition: ConfigKey)
	if configKeys[name] then
		error(`Config key "{name}" is already registered`)
	end
	configKeys[name] = definition
end

local function getKey(name: string): ConfigKey
	local key = configKeys[name]
	if not key then
		error(`Invalid config key: {name}`)
	end
	return key
end

local function getKeys(): { [string]: ConfigKey }
	return configKeys
end

local function registerEligibility(kind: string, evaluator: EligibilityEvaluator)
	eligibilityEvaluators[kind] = evaluator
end

local function setPersistence(callbacks: PersistenceCallbacks)
	persistence = callbacks
end

local function evaluateEligibility(eligibility: Eligibility, playerId: string): boolean?
	local evaluator = eligibilityEvaluators[eligibility.kind]
	if not evaluator then
		error(`Unknown eligibility kind: {eligibility.kind}`)
	end
	return evaluator(playerId)
end

--------------------------------------------------------------------------------
-- Server API
--------------------------------------------------------------------------------

type Atom<T> = ((T | (T) -> T) -> T) & (() -> T)

local serverAtom: Atom<{ [string]: any }>
local playerAtoms: { [string]: Atom<{ [string]: any }> } = {}
local playerOverrides: { [string]: Atom<{ [string]: any }> } = {}
local playerCleanups: { [string]: () -> () } = {}

local function getServerDefaults(): { [string]: any }
	local defaults = {}
	for key, def in configKeys do
		defaults[key] = def.defaultValue
	end
	return defaults
end

local function updateServerAtom(serverConfig: ConfigSnapshot)
	local values = {}
	for key, def in configKeys do
		local rawValue = serverConfig:GetValue(key)
		if rawValue == nil then
			rawValue = def.defaultValue
		end
		values[key] = rawValue
	end
	serverAtom(values)
end

local function getServerValue(key: string): any
	return serverAtom()[key]
end

local function serverInit()
	serverAtom = charm.atom(getServerDefaults())

	task.spawn(function()
		local serverConfig = ConfigService:GetConfigAsync()
		updateServerAtom(serverConfig)
		serverConfig.UpdateAvailable:Connect(function()
			serverConfig:Refresh()
			updateServerAtom(serverConfig)
		end)
	end)

	-- Set test values in Studio
	if isStudio then
		for key, def in configKeys do
			if def.testValue ~= nil then
				ConfigService:SetTestingValue(key, def.testValue)
			end
		end
	end
end

local function serverGetPlayerAtom(player: Player): Atom<{ [string]: any }>
	local atom = playerAtoms[player.Name]
	if atom then
		return atom
	end

	local playerConfigAtom = charm.atom(getServerDefaults())
	playerAtoms[player.Name] = playerConfigAtom
	return playerConfigAtom
end

local function serverGetPlayerOverrides(player: Player): Atom<{ [string]: any }>
	local overrides = playerOverrides[player.Name]
	if overrides then
		return overrides
	end

	local playerOverridesAtom = charm.atom({})
	playerOverrides[player.Name] = playerOverridesAtom
	return playerOverridesAtom
end

local function serverInitPlayer(player: Player)
	local playerConfigAtom = serverGetPlayerAtom(player)
	local overrides = serverGetPlayerOverrides(player)
	local playerConfig = ConfigService:GetConfigForPlayerAsync(player)

	-- Eligibility computed atom - only evaluates once when persistence data is ready
	-- Uses persistent storage to maintain A/B cohort assignment across sessions
	local eligibilityAtom = charm.computed(function(lastEligible): { [string]: boolean }?
		if lastEligible then
			return lastEligible
		end

		if not persistence then
			-- No persistence configured, all keys are eligible
			local eligible: { [string]: boolean } = {}
			for key, def in configKeys do
				if def.scope == "player" then
					eligible[key] = def.eligibility == nil or evaluateEligibility(def.eligibility, player.Name) == true
				end
			end
			return eligible
		end

		local eligible: { [string]: boolean } = {}
		local storedEligibility = persistence.getEligibility(player.Name)
		if storedEligibility == nil then
			return nil
		end

		local storedEnrolledValues = persistence.getEnrolledValues(player.Name)
		if storedEnrolledValues == nil then
			return nil
		end

		for key, def in configKeys do
			if def.scope == "player" then
				if def.eligibility == nil then
					eligible[key] = true
				else
					local wasEnrolled = storedEligibility[key]
					local storedValue = storedEnrolledValues[key]

					if wasEnrolled and storedValue ~= nil then
						-- Was enrolled, check if still in experiment by comparing with control
						local controlValue = getServerValue(key)
						if not equals(storedValue, controlValue) then
							-- Stored value differs from control → still in treatment → stay enrolled
							eligible[key] = true
						else
							-- Stored value matches control → experiment ended or was in control
							-- Re-evaluate eligibility to potentially enroll in new experiment
							local isEligible = evaluateEligibility(def.eligibility, player.Name)
							if isEligible == nil then
								return nil
							end
							eligible[key] = isEligible
						end
					else
						-- Not enrolled or no stored value, evaluate eligibility fresh
						local isEligible = evaluateEligibility(def.eligibility, player.Name)
						if isEligible == nil then
							return nil
						end
						eligible[key] = isEligible
					end
				end
			end
		end

		return eligible
	end)

	-- Persist eligibility when computed
	local persistEligibilityCleanup = when(eligibilityAtom, function()
		if persistence then
			local eligible = eligibilityAtom()
			if eligible then
				persistence.setEligibility(player.Name, eligible)
			end
		end
	end)

	local function updateValues()
		local eligible = eligibilityAtom()
		local newValues = {}
		local newEnrolledValues: { [string]: any } = {}
		local overrideValues = overrides()
		local storedEnrolledValues = if persistence
			then charm.peek(function()
				return persistence.getEnrolledValues(player.Name)
			end)
			else nil

		for key, def in configKeys do
			local value = nil

			if overrideValues[key] ~= nil then
				value = reconcileWithDefaults(overrideValues[key], def.defaultValue)
			elseif isStudio and def.testValue ~= nil then
				value = reconcileWithDefaults(def.testValue, def.defaultValue)
			else
				local controlValue = getServerValue(key)
				if controlValue == nil then
					controlValue = def.defaultValue
				else
					controlValue = reconcileWithDefaults(controlValue, def.defaultValue)
				end

				if eligible and eligible[key] then
					local configValue = playerConfig:GetValue(key)
					if configValue ~= nil then
						value = reconcileWithDefaults(configValue, def.defaultValue)
						-- Store raw value (before reconcile) for future comparison
						newEnrolledValues[key] = configValue
					else
						value = controlValue
					end
				else
					value = controlValue
				end
			end

			newValues[key] = value
		end

		-- Persist enrolled values for future session comparison
		if persistence and storedEnrolledValues ~= nil and not equals(storedEnrolledValues, newEnrolledValues) then
			task.defer(function()
				if persistence then
					persistence.setEnrolledValues(player.Name, newEnrolledValues)
				end
			end)
		end

		playerConfigAtom(newValues)
	end

	local cleanup = charm.effect(updateValues)
	local connection = playerConfig.UpdateAvailable:Connect(function()
		playerConfig:Refresh()
		charm.trigger(eligibilityAtom)
	end)

	playerCleanups[player.Name] = function()
		connection:Disconnect()
		persistEligibilityCleanup()
		cleanup()
		playerAtoms[player.Name] = nil
		playerOverrides[player.Name] = nil
		playerCleanups[player.Name] = nil
	end
end

local function serverCleanupPlayer(player: Player)
	local cleanup = playerCleanups[player.Name]
	if cleanup then
		cleanup()
	end
end

local function serverGetValue(key: string, player: Player?): any
	local keyConfig = getKey(key)

	local configData: { [string]: any }?
	if keyConfig.scope == "server" then
		configData = serverAtom()
	else
		assert(player, "Player is required for player-scoped config")
		local atom = playerAtoms[player.Name]
		if atom then
			configData = atom()
		end
	end

	if configData then
		local value = configData[key]
		if value ~= nil then
			return value
		end
	end
	return keyConfig.defaultValue
end

local function serverSetPlayerOverride(player: Player, key: string, value: any?)
	local keyConfig = getKey(key)
	if keyConfig.scope ~= "player" then
		error(`Cannot override server-scoped config key: {key}`)
	end

	local overridesAtom = playerOverrides[player.Name]
	if not overridesAtom then
		error(`Player overrides not initialized for player: {player.Name}`)
	end

	overridesAtom(function(state)
		return set(state, key, value)
	end)
end

local function serverGetReplicatedConfig(player: Player): { [string]: any }
	local atom = playerAtoms[player.Name]
	if not atom then
		return {}
	end

	local config = atom()
	local replicated = {}
	for key, def in configKeys do
		if def.replicated then
			replicated[key] = config[key]
		end
	end
	return replicated
end

--------------------------------------------------------------------------------
-- Client API
--------------------------------------------------------------------------------

local clientGetConfig, clientSetConfig = charm.signal(nil :: { [string]: any }?)

local function clientInit(config: { [string]: any })
	clientSetConfig(config)
end

local function clientUpdate(config: { [string]: any })
	clientSetConfig(config)
end

local function clientIsLoaded(key: string?): boolean
	local config = clientGetConfig()
	if config == nil then
		return false
	end
	if key then
		return config[key] ~= nil
	end
	return true
end

local function clientGetValue(key: string): any
	local config = clientGetConfig()
	if config then
		local value = config[key]
		if value ~= nil then
			return value
		end
	end
	local keyConfig = configKeys[key]
	if keyConfig then
		return keyConfig.defaultValue
	end
	return nil
end

--------------------------------------------------------------------------------
-- Module Export
--------------------------------------------------------------------------------

return {
	-- Shared API
	addKey = addKey,
	getKey = getKey,
	getKeys = getKeys,
	registerEligibility = registerEligibility,
	setPersistence = setPersistence,

	-- Server API
	server = {
		init = serverInit,
		initPlayer = serverInitPlayer,
		cleanupPlayer = serverCleanupPlayer,
		getValue = serverGetValue,
		getBoolean = function(key: string, player: Player?): boolean
			return serverGetValue(key, player)
		end,
		getNumber = function(key: string, player: Player?): number
			return serverGetValue(key, player)
		end,
		getPlayerAtom = serverGetPlayerAtom,
		getPlayerOverrides = serverGetPlayerOverrides,
		setPlayerOverride = serverSetPlayerOverride,
		getReplicatedConfig = serverGetReplicatedConfig,
	},

	-- Client API
	client = {
		init = clientInit,
		update = clientUpdate,
		isLoaded = clientIsLoaded,
		getConfig = clientGetConfig,
		setConfig = clientSetConfig,
		getValue = clientGetValue,
		getBoolean = function(key: string): boolean
			return clientGetValue(key)
		end,
		getNumber = function(key: string): number
			return clientGetValue(key)
		end,
	},
}
