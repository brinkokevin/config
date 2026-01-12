# Config

A reactive configuration management package for Roblox built on [Charm](https://github.com/littensy/charm). Provides server-side player config with A/B testing support and client-side config consumption.

## Features

- **Dynamic Key Registration** - Register config keys at runtime via `addKey()`
- **Server/Client Split** - Separate APIs for server (`Config.server.*`) and client (`Config.client.*`)
- **Reactive State** - Built on Charm atoms for reactive config updates
- **A/B Testing Support** - Pluggable eligibility evaluators for experiment targeting
- **Cohort Persistence** - Configurable persistence callbacks for maintaining A/B cohort assignments
- **ConfigService Integration** - Seamless integration with Roblox's ConfigService for remote config
- **Automatic Reconciliation** - Missing nested keys are filled from defaults
- **Studio Mode** - `testValue` overrides apply automatically in Roblox Studio

## Installation

Add to your `wally.toml`:

```toml
[dependencies]
config = "brinkokevin/config@0.0.1"
charm = "littensy/charm@0.11.0-rc.3"
```

## Quick Start

### 1. Register Config Keys (Shared Code)

Create a shared module that registers all your config keys. This should run on both server and client.

```lua
-- src/shared/configKeys.lua
local Config = require("@Packages/config")

Config.addKey("featureEnabled", {
    scope = "player",
    replicated = true,
    defaultValue = false,
    testValue = true,  -- Used in Studio
})

Config.addKey("maxItems", {
    scope = "server",
    replicated = false,
    defaultValue = 100,
})

return Config.getKeys()
```

### 2. Server Setup

```lua
-- src/server/config.server.lua
local Config = require("@Packages/config")

-- Import to trigger key registration
require("@shared/configKeys")

-- Initialize server (starts listening to ConfigService)
Config.server.init()

-- Player lifecycle
game.Players.PlayerAdded:Connect(function(player)
    Config.server.initPlayer(player)
end)

game.Players.PlayerRemoving:Connect(function(player)
    Config.server.cleanupPlayer(player)
end)

-- Initialize existing players
for _, player in game.Players:GetPlayers() do
    Config.server.initPlayer(player)
end
```

### 3. Client Setup

```lua
-- src/client/config.client.lua
local Config = require("@Packages/config")

-- Import to trigger key registration
require("@shared/configKeys")

-- Config is synced via your state replication system (e.g., charmSync)
-- Call Config.client.setConfig(replicatedConfig) when receiving updates
```

## API Reference

### Shared API

#### `Config.addKey(name: string, definition: ConfigKey)`

Register a new config key. Must be called before accessing the key.

```lua
Config.addKey("myFeature", {
    scope = "player",      -- "server" or "player"
    replicated = true,     -- Sync to client?
    defaultValue = false,  -- Default value
    testValue = true,      -- Optional: Studio override
    eligibility = {        -- Optional: A/B test targeting
        kind = "newPlayer",
    },
})
```

#### `Config.getKey(name: string): ConfigKey`

Get a registered key's definition. Throws if key doesn't exist.

#### `Config.getKeys(): { [string]: ConfigKey }`

Get all registered keys.

#### `Config.registerEligibility(kind: string, evaluator: (playerId: string, eligibility: Eligibility) -> boolean?)`

Register an eligibility evaluator for A/B test targeting.

```lua
Config.registerEligibility("newPlayer", function(playerId)
    -- Return true (eligible), false (not eligible), or nil (not ready yet)
    local playerData = getPlayerData(playerId)
    if playerData == nil then
        return nil  -- Data not loaded yet
    end
    return not playerData.onboardingComplete
end)
```

#### `Config.setPersistence(callbacks: PersistenceCallbacks)`

Configure persistence for A/B cohort tracking. Required for experiments to maintain cohort assignment across sessions.

```lua
Config.setPersistence({
    getEligibility = function(playerId: string): { [string]: boolean }?
        return playerData[playerId].configEligibility
    end,
    setEligibility = function(playerId: string, eligibility: { [string]: boolean })
        playerData[playerId].configEligibility = eligibility
    end,
    getEnrolledValues = function(playerId: string): { [string]: any }?
        return playerData[playerId].configEnrolledValues
    end,
    setEnrolledValues = function(playerId: string, values: { [string]: any })
        playerData[playerId].configEnrolledValues = values
    end,
})
```

---

### Server API (`Config.server.*`)

#### `Config.server.init()`

Initialize the server config system. Starts listening to ConfigService for remote config updates. Call once on server startup.

#### `Config.server.initPlayer(player: Player)`

Initialize config for a player. Sets up eligibility evaluation, persistence, and ConfigService listener. Call on `PlayerAdded`.

#### `Config.server.cleanupPlayer(player: Player)`

Cleanup player config state. Call on `PlayerRemoving`.

#### `Config.server.getValue(key: string, player: Player?): any`

Get a config value. Player is required for player-scoped keys.

```lua
-- Server-scoped (no player needed)
local maxItems = Config.server.getValue("maxItems")

-- Player-scoped (player required)
local enabled = Config.server.getValue("featureEnabled", player)
```

#### `Config.server.getBoolean(key: string, player: Player?): boolean`

Type-safe getter for boolean config values.

#### `Config.server.getNumber(key: string, player: Player?): number`

Type-safe getter for number config values.

#### `Config.server.getPlayerAtom(player: Player): Atom<{ [string]: any }>`

Get the Charm atom for a player's config. Use for reactive subscriptions.

```lua
local charm = require("@Packages/charm")

local atom = Config.server.getPlayerAtom(player)
charm.effect(function()
    local config = atom()
    print("Config updated:", config.featureEnabled)
end)
```

#### `Config.server.getPlayerOverrides(player: Player): Atom<{ [string]: any }>`

Get the overrides atom for a player. Useful for admin/testing tools.

#### `Config.server.setPlayerOverride(player: Player, key: string, value: any?)`

Set a config override for a player. Pass `nil` to remove the override.

```lua
-- Override for testing
Config.server.setPlayerOverride(player, "featureEnabled", true)

-- Remove override
Config.server.setPlayerOverride(player, "featureEnabled", nil)
```

#### `Config.server.getReplicatedConfig(player: Player): { [string]: any }`

Get all replicated config values for a player. Useful for initial state sync.

---

### Client API (`Config.client.*`)

#### `Config.client.init(config: { [string]: any })`

Initialize client config with values received from server.

#### `Config.client.update(config: { [string]: any })`

Update client config. Alias for `setConfig`.

#### `Config.client.getConfig(): { [string]: any }?`

Get the current config state. Returns `nil` if not initialized.

#### `Config.client.setConfig(config: { [string]: any }?)`

Set the client config state. Used by state replication systems.

#### `Config.client.isLoaded(key: string?): boolean`

Check if config is loaded. If key is provided, checks if that specific key exists.

```lua
if Config.client.isLoaded() then
    -- Config is ready
end

if Config.client.isLoaded("featureEnabled") then
    -- Specific key is available
end
```

#### `Config.client.getValue(key: string): any`

Get a config value. Returns default if config not loaded.

#### `Config.client.getBoolean(key: string): boolean`

Type-safe getter for boolean config values.

#### `Config.client.getNumber(key: string): number`

Type-safe getter for number config values.

---

## Types

```lua
export type Eligibility = {
    kind: string,
    [string]: any,  -- Additional fields for evaluator
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
```

---

## A/B Testing

The config package supports A/B testing through ConfigService integration with eligibility-based targeting.

### How It Works

1. **Eligibility Evaluation** - When a player joins, their eligibility for each experiment is evaluated using registered evaluators
2. **Cohort Assignment** - Eligible players receive experiment values from ConfigService; ineligible players get control values
3. **Persistence** - Cohort assignments are persisted to maintain consistency across sessions
4. **Experiment End Detection** - When a player's stored value matches the control value, the experiment is considered ended and eligibility is re-evaluated

### Setting Up an A/B Test

1. **Register the eligibility evaluator:**

```lua
Config.registerEligibility("newPlayer", function(playerId)
    local data = getPlayerData(playerId)
    if data == nil then return nil end
    return not data.onboardingComplete
end)
```

2. **Configure persistence:**

```lua
Config.setPersistence({
    getEligibility = function(playerId)
        return getPlayerData(playerId).configEligibility
    end,
    setEligibility = function(playerId, data)
        getPlayerData(playerId).configEligibility = data
        savePlayerData(playerId)
    end,
    getEnrolledValues = function(playerId)
        return getPlayerData(playerId).configEnrolledValues
    end,
    setEnrolledValues = function(playerId, data)
        getPlayerData(playerId).configEnrolledValues = data
        savePlayerData(playerId)
    end,
})
```

3. **Add the config key with eligibility:**

```lua
Config.addKey("newFeatureEnabled", {
    scope = "player",
    replicated = true,
    defaultValue = false,  -- Control value
    eligibility = {
        kind = "newPlayer",
    },
})
```

4. **Configure the experiment in ConfigService** with treatment values for eligible players.

---

## Integration with CharmSync

Here's a complete example of integrating with [charm-sync](https://github.com/littensy/charm-sync) for state replication:

### Server

```lua
-- src/server/charm.server.lua
local Players = game:GetService("Players")
local charmSync = require("@Packages/charmSync")
local Config = require("@Packages/config")

require("@shared/configKeys")
Config.server.init()

local server = charmSync.server

local function onPlayerAdded(player)
    Config.server.initPlayer(player)
    
    -- Add player's config atom to sync
    server.addSignalsToClient(player, {
        [`config_{player.Name}`] = Config.server.getPlayerAtom(player),
    })
end

local function onPlayerRemoving(player)
    server.removeClient(player)
    Config.server.cleanupPlayer(player)
end

Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(onPlayerRemoving)

for _, player in Players:GetPlayers() do
    onPlayerAdded(player)
end
```

### Client

```lua
-- src/client/charm.client.lua
local Players = game:GetService("Players")
local charmSync = require("@Packages/charmSync")
local Config = require("@Packages/config")

require("@shared/configKeys")

local client = charmSync.client
local localPlayer = Players.LocalPlayer

client.addSignals({
    [`config_{localPlayer.Name}`] = Config.client.setConfig,
})
```

---

## React Integration

Use with [react-charm](https://github.com/littensy/react-charm) for reactive UI:

```lua
local React = require("@Packages/react")
local reactCharm = require("@Packages/reactCharm")
local Config = require("@Packages/config")

local function FeatureButton()
    local enabled = reactCharm.useAtomState(function()
        return Config.client.getBoolean("featureEnabled")
    end)
    
    if not enabled then
        return nil
    end
    
    return React.createElement("TextButton", {
        Text = "New Feature!",
    })
end
```

---

## Best Practices

1. **Register keys in shared code** - Ensure keys are registered on both server and client before accessing them

2. **Use type-safe getters** - Prefer `getBoolean()` and `getNumber()` over `getValue()` when the type is known

3. **Handle loading state** - Check `isLoaded()` before accessing config on the client, especially during startup

4. **Test with overrides** - Use `setPlayerOverride()` to test different config values without changing ConfigService

5. **Return `nil` from eligibility evaluators** - When player data isn't loaded yet, return `nil` to defer evaluation

---

## License

MIT
