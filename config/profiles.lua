--[[
    ConsoleExperienceClassic - Profiles Module
    
    Manages multiple configuration profiles per character.
    Each profile stores:
    - Complete config settings
    - Proxied action bindings
    - Action bar contents (slots 1-120)
]]

-- Create the profiles module namespace
ConsoleExperience.profiles = ConsoleExperience.profiles or {}
local Profiles = ConsoleExperience.profiles

-- Constants
Profiles.DEFAULT_PROFILE_NAME = "Default"
Profiles.MAX_ACTION_SLOTS = 120  -- WoW 1.12 has 120 action slots total

-- Check if action bar management via profiles is enabled
-- Returns true if the addon should save/load action bar slot assignments
function Profiles:IsActionBarManaged()
    if not ConsoleExperienceDB or not ConsoleExperienceDB.config then
        return true  -- Default to managed if config not yet loaded
    end
    return ConsoleExperienceDB.config.actionBarManaged ~= false
end

-- ============================================================================
-- Profile Data Access
-- ============================================================================

-- Get current profile name (returns "Default" if not set)
function Profiles:GetCurrentProfileName()
    if not ConsoleExperienceDB or not ConsoleExperienceDB.currentProfile then
        return self.DEFAULT_PROFILE_NAME
    end
    return ConsoleExperienceDB.currentProfile
end

-- Get profile data by name
function Profiles:GetProfile(profileName)
    if not ConsoleExperienceDB or not ConsoleExperienceDB.profiles then
        return nil
    end
    return ConsoleExperienceDB.profiles[profileName]
end

-- Get current profile data
function Profiles:GetCurrentProfile()
    local profileName = self:GetCurrentProfileName()
    return self:GetProfile(profileName)
end

-- List all profile names
function Profiles:ListProfiles()
    if not ConsoleExperienceDB or not ConsoleExperienceDB.profiles then
        return {}
    end
    
    local profiles = {}
    for name, _ in pairs(ConsoleExperienceDB.profiles) do
        table.insert(profiles, name)
    end
    table.sort(profiles)  -- Sort alphabetically
    return profiles
end

-- ============================================================================
-- Action Bar Save/Load
-- ============================================================================

-- Helper: Find spell ID in spellbook by name (base name without rank)
local function FindSpellIDByName(spellName)
    if not spellName then return nil end
    
    -- Remove rank from spell name to get base name
    local baseName = string.gsub(spellName, " %(Rank %d+%)", "")
    
    -- Search spellbook
    local i = 1
    while true do
        local spellNameInBook, spellRank = GetSpellName(i, BOOKTYPE_SPELL)
        if not spellNameInBook then break end
        
        -- Get base name from spellbook
        local baseNameInBook = string.gsub(spellNameInBook, " %(Rank %d+%)", "")
        
        -- Check if names match
        if baseNameInBook == baseName then
            return i  -- Return spell index (ID)
        end
        
        i = i + 1
    end
    
    return nil
end

-- Helper: Find macro ID by name
local function FindMacroIDByName(macroName)
    if not macroName then return nil end
    
    -- Search through macros (1-36 in WoW 1.12)
    for i = 1, 36 do
        local name, texture, body = GetMacroInfo(i)
        if name and name == macroName then
            return i
        end
    end
    
    return nil
end

-- Helper: Scan current WoW action bar slots and return a table of action data
-- This is the core scanning logic used by both SaveActionBars and SnapshotServerBars
local function ScanCurrentActionBars()
    local actionBars = {}
    for slot = 1, Profiles.MAX_ACTION_SLOTS do
        if HasAction(slot) then
            local texture = GetActionTexture(slot)
            
            GameTooltip:SetOwner(UIParent, "ANCHOR_NONE")
            GameTooltip:ClearLines()
            GameTooltip:SetAction(slot)
            
            local actionName = nil
            local numLines = GameTooltip:NumLines() or 0
            if numLines > 0 then
                local firstLine = getglobal("GameTooltipTextLeft1")
                if firstLine and firstLine.GetText then
                    actionName = firstLine:GetText()
                end
            end
            
            GameTooltip:Hide()
            
            if actionName and texture then
                local spellID = FindSpellIDByName(actionName)
                if spellID then
                    actionBars[slot] = {
                        type = "spell",
                        id = spellID,
                        name = actionName,
                        texture = texture,
                    }
                else
                    local macroID = FindMacroIDByName(actionName)
                    if macroID then
                        actionBars[slot] = {
                            type = "macro",
                            id = macroID,
                            name = actionName,
                            texture = texture,
                        }
                    else
                        actionBars[slot] = {
                            type = "unknown",
                            name = actionName,
                            texture = texture,
                        }
                    end
                end
            end
        end
    end
    return actionBars
end

-- Save current action bar state
-- Returns a table mapping slot -> action data
-- Note: We save ALL slots (1-120), including empty ones as nil entries
-- This ensures that when loading, we can clear slots that were previously filled
function Profiles:SaveActionBars()
    local actionBars = {}
    local profile = self:GetCurrentProfile()
    
    -- Start with existing action bars from profile (to preserve slots that might not be in current state)
    if profile and profile.actionBars then
        for slot, data in pairs(profile.actionBars) do
            actionBars[slot] = data
        end
    end
    
    -- Now update with current state using the shared scanning helper
    local current = ScanCurrentActionBars()
    for slot = 1, self.MAX_ACTION_SLOTS do
        if HasAction(slot) then
            if current[slot] then
                actionBars[slot] = current[slot]
            end
            -- If HasAction but scan returned nil (e.g. no name/texture), keep old profile data
        else
            -- Slot is empty - explicitly set to nil to clear it from profile
            actionBars[slot] = nil
        end
    end
    
    return actionBars
end

-- Load action bar state from saved data
function Profiles:LoadActionBars(actionBars)
    -- Suppress auto-save during bar restoration to avoid saving partial state
    self.isRestoringBars = true
    
    -- Always clear ALL action slots first (1-120) to ensure clean state
    -- This ensures that slots that were cleared in the profile are actually cleared
    for slot = 1, self.MAX_ACTION_SLOTS do
        if HasAction(slot) then
            PickupAction(slot)
            ClearCursor()
        end
    end
    
    -- If actionBars is empty or nil, we're done (all slots already cleared)
    if not actionBars or next(actionBars) == nil then
        self.isRestoringBars = false
        
        -- Update action bar display
        if ConsoleExperience.actionbars and ConsoleExperience.actionbars.UpdateAllButtons then
            ConsoleExperience.actionbars:UpdateAllButtons()
        end
        
        CE_Debug("Profiles: All action bars cleared (empty profile)")
        return
    end
    
    -- Small delay to ensure cursor is cleared before placing actions
    local restoreFrame = CreateFrame("Frame")
    local slotsToRestore = {}
    for slot, data in pairs(actionBars) do
        table.insert(slotsToRestore, {slot = slot, data = data})
    end
    
    local currentIndex = 1
    local restoreDelay = 0
    local slotsCount = table.getn(slotsToRestore)
    restoreFrame:SetScript("OnUpdate", function()
        local elapsed = arg1
        restoreDelay = restoreDelay + elapsed
        -- Wait a small amount before starting restoration
        if restoreDelay < 0.1 then
            return
        end
        
        -- Restore one slot per frame to avoid overwhelming the game
        if currentIndex <= slotsCount then
            local item = slotsToRestore[currentIndex]
            local slot = item.slot
            local data = item.data
            
            -- Restore the action based on type
            if data.type == "spell" and data.id then
                -- Restore spell using spell ID
                PickupSpell(data.id, BOOKTYPE_SPELL)
                PlaceAction(slot)
                ClearCursor()
            elseif data.type == "macro" and data.id then
                -- Restore macro using macro ID
                PickupMacro(data.id)
                PlaceAction(slot)
                ClearCursor()
            elseif data.type == "unknown" and data.name then
                -- Try to find and restore by name (spell or macro)
                local spellID = FindSpellIDByName(data.name)
                if spellID then
                    PickupSpell(spellID, BOOKTYPE_SPELL)
                    PlaceAction(slot)
                    ClearCursor()
                else
                    local macroID = FindMacroIDByName(data.name)
                    if macroID then
                        PickupMacro(macroID)
                        PlaceAction(slot)
                        ClearCursor()
                    end
                end
            end
            
            currentIndex = currentIndex + 1
        else
            -- All slots restored, clean up
            restoreFrame:SetScript("OnUpdate", nil)
            restoreFrame:Hide()
            Profiles.isRestoringBars = false
            
            -- Update action bar display
            if ConsoleExperience.actionbars and ConsoleExperience.actionbars.UpdateAllButtons then
                ConsoleExperience.actionbars:UpdateAllButtons()
            end
            
            CE_Debug("Profiles: Action bars restored (" .. slotsCount .. " slots)")
        end
    end)
end

-- ============================================================================
-- Server Bar Snapshot/Restore
-- When actionBarManaged is enabled, the addon snapshots the original server-side
-- action bars on login and restores them on logout. This ensures the addon's
-- device-specific controller mapping does not persist on the server, preserving
-- the original action bar layout for other devices.
-- ============================================================================

-- Snapshot current server-side action bar state (in-memory only, NOT persisted)
-- Called once during initialization, before any profile bars are loaded
function Profiles:SnapshotServerBars()
    if not self:IsActionBarManaged() then
        return
    end
    
    self.serverSnapshot = ScanCurrentActionBars()
    
    local count = self:CountTableKeys(self.serverSnapshot)
    CE_Debug("Profiles: Snapshotted " .. count .. " server action bar slots")
end

-- Restore original server-side action bars from snapshot (synchronous)
-- Called during PLAYER_LOGOUT to undo the addon's action bar modifications
-- Uses synchronous restore (no OnUpdate throttling) since we're in the logout handler
function Profiles:RestoreServerBars()
    if not self:IsActionBarManaged() or not self.serverSnapshot then
        return
    end
    
    -- Suppress auto-save during server bar restoration
    self.isRestoringBars = true
    
    -- Clear all current action slots
    for slot = 1, self.MAX_ACTION_SLOTS do
        if HasAction(slot) then
            PickupAction(slot)
            ClearCursor()
        end
    end
    
    -- Restore from snapshot (synchronous - no throttling needed during logout)
    local restoredCount = 0
    for slot, data in pairs(self.serverSnapshot) do
        if data.type == "spell" and data.id then
            PickupSpell(data.id, BOOKTYPE_SPELL)
            PlaceAction(slot)
            ClearCursor()
            restoredCount = restoredCount + 1
        elseif data.type == "macro" and data.id then
            PickupMacro(data.id)
            PlaceAction(slot)
            ClearCursor()
            restoredCount = restoredCount + 1
        elseif data.type == "unknown" and data.name then
            local spellID = FindSpellIDByName(data.name)
            if spellID then
                PickupSpell(spellID, BOOKTYPE_SPELL)
                PlaceAction(slot)
                ClearCursor()
                restoredCount = restoredCount + 1
            else
                local macroID = FindMacroIDByName(data.name)
                if macroID then
                    PickupMacro(macroID)
                    PlaceAction(slot)
                    ClearCursor()
                    restoredCount = restoredCount + 1
                end
            end
        end
    end
    
    self.isRestoringBars = false
    
    CE_Debug("Profiles: Restored " .. restoredCount .. " server action bar slots from snapshot")
end

-- ============================================================================
-- Profile Management
-- ============================================================================

-- Create a new profile
-- sourceProfile: profile name to copy from (nil = use defaults)
function Profiles:CreateProfile(name, sourceProfile)
    if not name or name == "" then
        return false, "Profile name cannot be empty"
    end
    
    -- Check if profile already exists
    if self:GetProfile(name) then
        return false, "Profile already exists"
    end
    
    -- Initialize profiles table if needed
    if not ConsoleExperienceDB.profiles then
        ConsoleExperienceDB.profiles = {}
    end
    
    local newProfile = {
        config = {},
        proxiedActions = {},
        actionBars = {},
    }
    
    if sourceProfile then
        -- Clone from source profile
        local source = self:GetProfile(sourceProfile)
        if source then
            -- Deep copy config
            for key, value in pairs(source.config or {}) do
                newProfile.config[key] = value
            end
            -- Deep copy proxied actions
            for slot, binding in pairs(source.proxiedActions or {}) do
                newProfile.proxiedActions[slot] = binding
            end
            -- Deep copy action bars
            for slot, action in pairs(source.actionBars or {}) do
                newProfile.actionBars[slot] = {}
                for k, v in pairs(action) do
                    newProfile.actionBars[slot][k] = v
                end
            end
        end
    else
        -- New profile with defaults
        -- Config will be populated with defaults when loaded
        -- Action bars start empty
        -- Set default proxied actions (same as proxied.lua Initialize)
        newProfile.proxiedActions[1] = "JUMP"
        newProfile.proxiedActions[30] = "CE_INTERACT"
        CE_Debug("Profiles: Created new profile with default proxied actions (JUMP on slot 1, CE_INTERACT on slot 30)")
    end
    
    ConsoleExperienceDB.profiles[name] = newProfile
    return true, nil
end

-- Delete a profile
function Profiles:DeleteProfile(name)
    if not name or name == "" then
        return false, "Profile name cannot be empty"
    end
    
    -- Prevent deleting default profile
    if name == self.DEFAULT_PROFILE_NAME then
        return false, "Cannot delete the default profile"
    end
    
    -- Check if profile exists
    if not self:GetProfile(name) then
        return false, "Profile does not exist"
    end
    
    -- If deleting current profile, switch to default first
    if self:GetCurrentProfileName() == name then
        self:SetProfile(self.DEFAULT_PROFILE_NAME)
    end
    
    -- Delete the profile
    ConsoleExperienceDB.profiles[name] = nil
    
    return true, nil
end

-- Switch to a profile
function Profiles:SetProfile(profileName)
    if not profileName or profileName == "" then
        profileName = self.DEFAULT_PROFILE_NAME
    end
    
    -- Check if profile exists
    if not self:GetProfile(profileName) then
        CE_Debug("Profiles: Profile '" .. profileName .. "' does not exist, creating it")
        self:CreateProfile(profileName, nil)
    end
    
    -- Save current state before switching (if we have a current profile)
    local currentProfileName = self:GetCurrentProfileName()
    if currentProfileName and currentProfileName ~= profileName then
        self:SaveCurrentProfile()
    end
    
    -- Set new current profile
    ConsoleExperienceDB.currentProfile = profileName
    
    -- Load the new profile
    self:LoadProfile(profileName)
    
    return true, nil
end

-- Save current profile state (config, proxied actions, action bars)
function Profiles:SaveCurrentProfile()
    local profileName = self:GetCurrentProfileName()
    local profile = self:GetProfile(profileName)
    
    if not profile then
        -- Create profile if it doesn't exist
        self:CreateProfile(profileName, nil)
        profile = self:GetProfile(profileName)
    end
    
    -- Save config (copy from ConsoleExperienceDB.config)
    if ConsoleExperienceDB.config then
        profile.config = {}
        for key, value in pairs(ConsoleExperienceDB.config) do
            profile.config[key] = value
        end
    end
    
    -- Ensure all defaults are in the profile (adds any new defaults that were added)
    if ConsoleExperience.config and ConsoleExperience.config.DEFAULTS then
        for key, defaultValue in pairs(ConsoleExperience.config.DEFAULTS) do
            if profile.config[key] == nil then
                profile.config[key] = defaultValue
                CE_Debug("Profiles: Added missing default '" .. key .. "' = " .. tostring(defaultValue) .. " to profile when saving")
            end
        end
    end
    
    -- Save proxied actions (copy from ConsoleExperienceDB.proxiedActions)
    if ConsoleExperienceDB.proxiedActions then
        profile.proxiedActions = {}
        for slot, binding in pairs(ConsoleExperienceDB.proxiedActions) do
            profile.proxiedActions[slot] = binding
        end
    end
    
    -- Save action bars (only saves slots that have actions)
    -- Empty slots are not saved, which is fine because LoadActionBars clears all slots first
    -- Skip if actionBarManaged is disabled (user wants server-side bars untouched)
    if self:IsActionBarManaged() then
        profile.actionBars = self:SaveActionBars()
        CE_Debug("Profiles: Saved " .. (self:CountTableKeys(profile.actionBars) or 0) .. " action bar slots")
    else
        CE_Debug("Profiles: Skipped action bar save (actionBarManaged is disabled)")
    end
end

-- Load a profile (apply its settings)
function Profiles:LoadProfile(profileName)
    local profile = self:GetProfile(profileName)
    if not profile then
        CE_Debug("Profiles: Profile '" .. profileName .. "' not found")
        return false
    end
    
    -- Initialize config if needed
    if not ConsoleExperienceDB.config then
        ConsoleExperienceDB.config = {}
    end
    
    -- Load config (merge with defaults)
    -- First, reset to defaults (ensures new defaults are added)
    if ConsoleExperience.config and ConsoleExperience.config.DEFAULTS then
        for key, defaultValue in pairs(ConsoleExperience.config.DEFAULTS) do
            ConsoleExperienceDB.config[key] = defaultValue
        end
    end
    
    -- Then apply saved values from profile
    if profile.config then
        for key, value in pairs(profile.config) do
            ConsoleExperienceDB.config[key] = value
        end
    end
    
    -- Ensure any new defaults not in the profile are added
    if ConsoleExperience.config and ConsoleExperience.config.DEFAULTS then
        for key, defaultValue in pairs(ConsoleExperience.config.DEFAULTS) do
            if ConsoleExperienceDB.config[key] == nil then
                ConsoleExperienceDB.config[key] = defaultValue
                CE_Debug("Profiles: Added missing default config '" .. key .. "' = " .. tostring(defaultValue) .. " when loading profile")
            end
        end
    end
    
    -- Load proxied actions
    if not ConsoleExperienceDB.proxiedActions then
        ConsoleExperienceDB.proxiedActions = {}
    else
        -- Clear existing proxied actions
        for slot, _ in pairs(ConsoleExperienceDB.proxiedActions) do
            ConsoleExperienceDB.proxiedActions[slot] = nil
        end
    end
    
    if profile.proxiedActions then
        for slot, binding in pairs(profile.proxiedActions) do
            ConsoleExperienceDB.proxiedActions[slot] = binding
            CE_Debug("Profiles: Loaded proxied action - slot " .. slot .. " -> " .. tostring(binding))
        end
    else
        -- If profile has no proxied actions, check if it's a new profile and should have defaults
        -- (This shouldn't happen if CreateProfile sets defaults, but just in case)
        if not profile.config or next(profile.config) == nil then
            -- Looks like a new profile, set defaults
            ConsoleExperienceDB.proxiedActions[1] = "JUMP"
            ConsoleExperienceDB.proxiedActions[30] = "CE_INTERACT"
            CE_Debug("Profiles: Applied default proxied actions to new profile")
        end
    end
    
    -- Apply config settings immediately
    if ConsoleExperience.config then
        -- Apply debug setting
        if ConsoleExperienceDB.config.debugEnabled ~= nil then
            ConsoleExperience_DEBUG_KEYS = ConsoleExperienceDB.config.debugEnabled
        end
        
        -- Apply crosshair
        if ConsoleExperience.config.UpdateCrosshair then
            ConsoleExperience.config:UpdateCrosshair()
        end
        
        -- Apply action bar layout
        if ConsoleExperience.config.UpdateActionBarLayout then
            ConsoleExperience.config:UpdateActionBarLayout()
        end
        
        -- Apply sidebars (must be called after action bar layout)
        if ConsoleExperience.actionbars and ConsoleExperience.actionbars.UpdateSideBars then
            ConsoleExperience.actionbars:UpdateSideBars()
        end
        
        -- Apply chat layout
        if ConsoleExperience.chat and ConsoleExperience.chat.UpdateChatLayout then
            ConsoleExperience.chat:UpdateChatLayout()
        end
        
        -- Apply XP/Rep bar layout
        if ConsoleExperience.xpbar and ConsoleExperience.xpbar.UpdateAllBars then
            ConsoleExperience.xpbar:UpdateAllBars()
        end
        
        -- Apply castbar layout
        if ConsoleExperience.castbar and ConsoleExperience.castbar.ReloadConfig then
            ConsoleExperience.castbar:ReloadConfig()
        end
        
        -- Update keyboard visibility based on keyboardEnabled setting
        if ConsoleExperience.keyboard then
            local keyboardEnabled = ConsoleExperienceDB.config.keyboardEnabled
            if keyboardEnabled == false and ConsoleExperience.keyboard:IsVisible() then
                -- Hide keyboard if disabled
                ConsoleExperience.keyboard:Hide()
            end
            -- Note: Keyboard will show automatically when chat opens if enabled
        end
        
        -- Update sidebar binding visibility in config UI
        if ConsoleExperience.config.UpdateSidebarBindingVisibility then
            ConsoleExperience.config:UpdateSidebarBindingVisibility()
        end
        
        -- Refresh binding icons in config UI
        if ConsoleExperience.config.RefreshBindingIcons then
            ConsoleExperience.config:RefreshBindingIcons()
        end
        
        -- Refresh proxied action dropdowns in config UI
        if ConsoleExperience.config.RefreshProxiedDropdowns then
            ConsoleExperience.config:RefreshProxiedDropdowns()
        end
        
        -- Update all action bar buttons (to reflect proxied actions, etc.)
        if ConsoleExperience.actionbars and ConsoleExperience.actionbars.UpdateAllButtons then
            ConsoleExperience.actionbars:UpdateAllButtons()
        end
        
        -- Refresh config UI checkboxes if config window is open
        -- We need to refresh all checkboxes to reflect the new profile values
        if ConsoleExperience.config.frame and ConsoleExperience.config.frame:IsVisible() then
            local currentSection = ConsoleExperience.config.currentSection
            if currentSection then
                -- Small delay to ensure config values are set, then refresh checkboxes
                local refreshFrame = CreateFrame("Frame")
                refreshFrame:SetScript("OnUpdate", function()
                    refreshFrame:SetScript("OnUpdate", nil)
                    -- Refresh checkboxes in the current section
                    if ConsoleExperience.config.RefreshCheckboxes then
                        local section = ConsoleExperience.config.contentSections[currentSection]
                        if section then
                            ConsoleExperience.config:RefreshCheckboxes(section)
                        end
                    end
                    -- Also refresh dropdowns and other UI elements by re-showing the section
                    if ConsoleExperience.config.ShowSection then
                        ConsoleExperience.config:ShowSection(currentSection)
                    end
                end)
            end
        end
    end
    
    -- Apply proxied bindings
    if ConsoleExperience.proxied and ConsoleExperience.proxied.ApplyAllBindings then
        ConsoleExperience.proxied:ApplyAllBindings()
    end
    
    -- Load action bars (with delay to ensure everything else is loaded first)
    -- Skip if actionBarManaged is disabled (user wants server-side bars untouched)
    if self:IsActionBarManaged() and profile.actionBars then
        -- Use a small delay before loading action bars
        local loadFrame = CreateFrame("Frame")
        loadFrame:SetScript("OnUpdate", function()
            loadFrame:SetScript("OnUpdate", nil)
            Profiles:LoadActionBars(profile.actionBars)
        end)
    elseif not self:IsActionBarManaged() then
        CE_Debug("Profiles: Skipped action bar load (actionBarManaged is disabled)")
    end
    
    return true
end

-- ============================================================================
-- Migration from Legacy Config
-- ============================================================================

-- Migrate legacy config to profile system
function Profiles:MigrateLegacyConfig()
    -- Check if migration is needed
    if ConsoleExperienceDB.profiles and ConsoleExperienceDB.profiles[self.DEFAULT_PROFILE_NAME] then
        -- Profiles already exist, no migration needed
        return false
    end
    
    CE_Debug("Profiles: Migrating legacy config to profile system...")
    
    -- Initialize profiles table
    if not ConsoleExperienceDB.profiles then
        ConsoleExperienceDB.profiles = {}
    end
    
    -- Create default profile
    local defaultProfile = {
        config = {},
        proxiedActions = {},
        actionBars = {},
    }
    
    -- Migrate config settings
    if ConsoleExperienceDB.config then
        -- Copy all existing config values
        for key, value in pairs(ConsoleExperienceDB.config) do
            defaultProfile.config[key] = value
        end
    else
        -- Initialize with defaults if config doesn't exist
        ConsoleExperienceDB.config = {}
    end
    
    -- Ensure all default values are set in both places (generic migration)
    -- This automatically adds any new default values that weren't in the old config
    if ConsoleExperience.config and ConsoleExperience.config.DEFAULTS then
        for key, defaultValue in pairs(ConsoleExperience.config.DEFAULTS) do
            -- Add to ConsoleExperienceDB.config if missing
            if ConsoleExperienceDB.config[key] == nil then
                ConsoleExperienceDB.config[key] = defaultValue
                CE_Debug("Profiles: Added missing default config '" .. key .. "' = " .. tostring(defaultValue))
            end
            -- Add to defaultProfile.config if missing
            if defaultProfile.config[key] == nil then
                defaultProfile.config[key] = defaultValue
                CE_Debug("Profiles: Added missing default config to profile '" .. key .. "' = " .. tostring(defaultValue))
            end
        end
    end
    
    -- Migrate proxied actions
    if ConsoleExperienceDB.proxiedActions then
        -- Copy all proxied actions
        for slot, binding in pairs(ConsoleExperienceDB.proxiedActions) do
            defaultProfile.proxiedActions[slot] = binding
            CE_Debug("Profiles: Migrated proxied action - slot " .. slot .. " -> " .. tostring(binding))
        end
    else
        -- Initialize if it doesn't exist
        ConsoleExperienceDB.proxiedActions = {}
    end
    
    -- Ensure proxied actions are also preserved in ConsoleExperienceDB.proxiedActions
    -- (they should already be there, but make sure they're not lost)
    if ConsoleExperienceDB.proxiedActions and next(ConsoleExperienceDB.proxiedActions) == nil then
        -- If proxiedActions is empty but we have them in the profile, restore them
        if defaultProfile.proxiedActions and next(defaultProfile.proxiedActions) ~= nil then
            for slot, binding in pairs(defaultProfile.proxiedActions) do
                ConsoleExperienceDB.proxiedActions[slot] = binding
                CE_Debug("Profiles: Restored proxied action to ConsoleExperienceDB - slot " .. slot .. " -> " .. tostring(binding))
            end
        end
    end
    
    -- Save current action bar state
    defaultProfile.actionBars = self:SaveActionBars()
    
    -- Store default profile
    ConsoleExperienceDB.profiles[self.DEFAULT_PROFILE_NAME] = defaultProfile
    
    -- Set as current profile
    ConsoleExperienceDB.currentProfile = self.DEFAULT_PROFILE_NAME
    
    CE_Debug("Profiles: Migration complete. Created default profile with:")
    CE_Debug("  - " .. (self:CountTableKeys(defaultProfile.config) or 0) .. " config settings")
    CE_Debug("  - " .. (self:CountTableKeys(defaultProfile.proxiedActions) or 0) .. " proxied actions")
    CE_Debug("  - " .. (self:CountTableKeys(defaultProfile.actionBars) or 0) .. " action bar slots")
    
    -- Apply proxied bindings after migration (if proxied module is available)
    -- This ensures the bindings are actually set in the game
    if ConsoleExperience.proxied and ConsoleExperience.proxied.ApplyAllBindings then
        -- Small delay to ensure everything is initialized
        local applyFrame = CreateFrame("Frame")
        applyFrame:SetScript("OnUpdate", function()
            applyFrame:SetScript("OnUpdate", nil)
            ConsoleExperience.proxied:ApplyAllBindings()
            CE_Debug("Profiles: Applied proxied bindings after migration")
        end)
    end
    
    return true
end

-- Helper function to count table keys
function Profiles:CountTableKeys(tbl)
    if not tbl then return 0 end
    local count = 0
    for _ in pairs(tbl) do
        count = count + 1
    end
    return count
end

-- ============================================================================
-- Initialization
-- ============================================================================

-- Hook into action bar changes
local function OnActionBarSlotChanged()
    -- Skip auto-save during bar restoration (snapshot restore, profile load)
    if Profiles.isRestoringBars then
        return
    end
    -- Skip auto-save if actionBarManaged is disabled (user wants server-side bars untouched)
    if not ConsoleExperience.profiles:IsActionBarManaged() then
        return
    end
    -- Save current profile immediately when action bars change
    if ConsoleExperience.profiles and ConsoleExperience.profiles.SaveCurrentProfile then
        ConsoleExperience.profiles:SaveCurrentProfile()
        CE_Debug("Profiles: Auto-saved profile after action bar change (slot " .. (arg1 or "unknown") .. ")")
    end
end

function Profiles:Initialize()
    -- Run migration first
    local migrated = self:MigrateLegacyConfig()
    
    -- Ensure current profile is set
    if not ConsoleExperienceDB.currentProfile then
        ConsoleExperienceDB.currentProfile = self.DEFAULT_PROFILE_NAME
    end
    
    -- Ensure default profile exists
    if not self:GetProfile(self.DEFAULT_PROFILE_NAME) then
        self:CreateProfile(self.DEFAULT_PROFILE_NAME, nil)
    end
    
    -- If migration happened, ensure proxied actions are synced
    if migrated then
        local defaultProfile = self:GetProfile(self.DEFAULT_PROFILE_NAME)
        if defaultProfile and defaultProfile.proxiedActions then
            -- Make sure ConsoleExperienceDB.proxiedActions matches the profile
            if not ConsoleExperienceDB.proxiedActions then
                ConsoleExperienceDB.proxiedActions = {}
            end
            -- Sync from profile to ConsoleExperienceDB
            for slot, binding in pairs(defaultProfile.proxiedActions) do
                if not ConsoleExperienceDB.proxiedActions[slot] or ConsoleExperienceDB.proxiedActions[slot] ~= binding then
                    ConsoleExperienceDB.proxiedActions[slot] = binding
                    CE_Debug("Profiles: Synced proxied action from profile - slot " .. slot .. " -> " .. tostring(binding))
                end
            end
        end
    end
    
    -- Snapshot current server-side action bars BEFORE loading profile bars
    -- This captures the original server state so it can be restored on logout
    self:SnapshotServerBars()
    
    -- Load profile action bars (deferred to next frame)
    -- Since we restore original bars on logout, the server bars on login are the
    -- original (non-addon) bars. We must load the profile's bars for the addon to work.
    if self:IsActionBarManaged() then
        local profile = self:GetCurrentProfile()
        if profile and profile.actionBars and next(profile.actionBars) ~= nil then
            local loadFrame = CreateFrame("Frame")
            loadFrame:SetScript("OnUpdate", function()
                loadFrame:SetScript("OnUpdate", nil)
                Profiles:LoadActionBars(profile.actionBars)
            end)
            CE_Debug("Profiles: Queued profile action bar load for next frame")
        end
    end
    
    -- Register for action bar change events to auto-save profile
    if not self.eventFrame then
        self.eventFrame = CreateFrame("Frame")
        self.eventFrame:RegisterEvent("ACTIONBAR_SLOT_CHANGED")
        self.eventFrame:SetScript("OnEvent", function()
            if event == "ACTIONBAR_SLOT_CHANGED" then
                OnActionBarSlotChanged()
            end
        end)
    end
    
    CE_Debug("Profiles: Initialized. Current profile: " .. self:GetCurrentProfileName())
end

-- ============================================================================
-- Slash Commands
-- ============================================================================

SLASH_CEPROFILE1 = "/ceprofile"
SLASH_CEPROFILE2 = "/cep"
SlashCmdList["CEPROFILE"] = function(msg)
    msg = string.gsub(msg, "^%s*(.-)%s*$", "%1")  -- Trim whitespace
    
    if msg == "" or msg == nil then
        -- Show current profile
        local currentProfile = Profiles:GetCurrentProfileName()
        CE_Print("Current profile: " .. currentProfile)
        CE_Print("Usage: /ceprofile <name> or /cep <name>")
        CE_Print("Available profiles:")
        local profiles = Profiles:ListProfiles()
        for _, name in ipairs(profiles) do
            local marker = (name == currentProfile) and " (current)" or ""
            CE_Print("  - " .. name .. marker)
        end
    else
        -- Switch to specified profile
        local profileName = msg
        local profile = Profiles:GetProfile(profileName)
        
        if profile then
            -- Save current profile before switching
            Profiles:SaveCurrentProfile()
            -- Switch to the profile
            Profiles:SetProfile(profileName)
            CE_Print("Switched to profile: " .. profileName)
        else
            CE_Print("Profile '" .. profileName .. "' not found.")
            CE_Print("Available profiles:")
            local profiles = Profiles:ListProfiles()
            for _, name in ipairs(profiles) do
                CE_Print("  - " .. name)
            end
        end
    end
end

CE_Debug("Profiles module loaded")
