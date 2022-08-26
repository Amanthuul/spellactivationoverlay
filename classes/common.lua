local AddonName, SAO = ...

-- List of classes
-- Each class defines its own stuff in their <classname>.lua
SAO.Class = {}

--[[
    Lists of auras that must be tracked
    These lists should be setup at start, based on the player class

    The name should be unique
    For stackable buffs, the stack count should be appended e.g., maelstrom_weapon_4

    Spell IDs may not be unique, especially for stackable buffs
    Because of that, RegisteredAurasBySpellID is a multimap instead of a map
]]
SAO.RegisteredAurasByName = {}
SAO.RegisteredAurasBySpellID = {}

-- List of currently active overlays
-- key = spellID, value = aura config
-- This list will change each time an overlay is triggered or un-triggered
SAO.ActiveOverlays = {}

-- Utility function to register a new aura
-- Arguments simply need to copy Retail's SPELL_ACTIVATION_OVERLAY_SHOW event arguments
function SAO.RegisterAura(self, name, stacks, spellID, texture, positions, scale, r, g, b, autoPulse, glowIDs)
    local aura = { name, stacks, spellID, self.TexName[texture], positions, scale, r, g, b, autoPulse, glowIDs }

    -- Register aura in the spell list, sorted by spell ID and by stack count
    self.RegisteredAurasByName[name] = aura;
    if self.RegisteredAurasBySpellID[spellID] then
        if self.RegisteredAurasBySpellID[spellID][stacks] then
            table.insert(self.RegisteredAurasBySpellID[spellID][stacks], aura)
        else
            self.RegisteredAurasBySpellID[spellID][stacks] = { aura };
        end
    else
        self.RegisteredAurasBySpellID[spellID] = { [stacks] = { aura } }
    end

    -- Apply aura immediately, if found
    local exists, _, count = select(3, self:FindPlayerAuraByID(spellID));
    if (exists and (stacks == 0 or stacks == count)) then
        self:ActivateOverlay(count, select(3,unpack(aura)));
    end
end

-- Utility aura function, one of the many that Blizzard could've done better years ago...
function SAO.FindPlayerAuraByID(self, id)
    local i = 1
    local name, icon, count, dispelType, duration, expirationTime,
        source, isStealable, nameplateShowPersonal, spellId,
        canApplyAura, isBossDebuff, castByPlayer = UnitBuff("player", i);
    while name do
        if (spellId == id) then
            return name, icon, count, dispelType, duration, expirationTime,
                source, isStealable, nameplateShowPersonal, spellId,
                canApplyAura, isBossDebuff, castByPlayer;
        end
        i = i+1
        name, icon, count, dispelType, duration, expirationTime,
            source, isStealable, nameplateShowPersonal, spellId,
            canApplyAura, isBossDebuff, castByPlayer = UnitBuff("player", i);
    end
end

--[[
    Utility function to know how many talent points the player has spent on a specific talent

    If the talent is found, returns:
    - the number of points spent for this talent
    - the total number of points possible for this talent
    - the tabulation in which the talent was found
    - the index in which the talent was found
    Tabulation and index can be re-used in GetTalentInfo to avoid re-parsing all talents

    Returns nil if no talent is found with this name e.g., in the wrong expansion
]]
function SAO.GetTalentByName(self, talentName)
    for tab = 1, GetNumTalentTabs() do
        for index = 1, GetNumTalents(tab) do
            local name, iconTexture, tier, column, rank, maxRank, isExceptional, available = GetTalentInfo(tab, index);
            if (name == talentName) then
                return rank, maxRank, tab, index;
            end
        end
    end
end

-- Check if overlay is active
function SAO.GetActiveOverlay(self, spellID)
    return self.ActiveOverlays[spellID] ~= nil;
end

-- Add or refresh an overlay
function SAO.ActivateOverlay(self, stacks, spellID, texture, positions, scale, r, g, b, autoPulse, forcePulsePlay)
    self.ActiveOverlays[spellID] = stacks;
    self.ShowAllOverlays(self.Frame, spellID, texture, positions, scale, r, g, b, autoPulse, forcePulsePlay);
end

-- Remove an overlay
function SAO.DeactivateOverlay(self, spellID)
    self.ActiveOverlays[spellID] = nil;
    self.HideOverlays(self.Frame, spellID);
end

-- Events starting with SPELL_AURA e.g., SPELL_AURA_APPLIED
-- This should be invoked only if the buff is done on the player i.e., UnitGUID("player") == destGUID
function SAO.SPELL_AURA(self, ...)
    local timestamp, event, _, sourceGUID, sourceName, sourceFlags, sourceRaidFlags, destGUID, destName, destFlags, destRaidFlags = CombatLogGetCurrentEventInfo();
    local spellID, spellName, spellSchool, auraType, amount = select(12, CombatLogGetCurrentEventInfo());
    local auraApplied = event:sub(0,18) == "SPELL_AURA_APPLIED";
    local auraRemoved = event:sub(0,18) == "SPELL_AURA_REMOVED";

    local auras = self.RegisteredAurasBySpellID[spellID];
    if auras and (auraApplied or auraRemoved) then
        local count = 0;
        if (not auras[0]) then
            -- If there is no aura with stacks == 0, this must mean that this aura is stackable
            -- To handle stackable auras, we must find the aura (ugh!) to get its number of stacks
            -- In an ideal world, we'd use the 'amount' which, unfortunately, is unreliable
            count = select(3, self:FindPlayerAuraByID(spellID));
        end

        local currentlyActiveOverlay = self:GetActiveOverlay(spellID);
        if (
            -- Aura not visible yet
            (not currentlyActiveOverlay)
        and
            -- Aura is there, either because it was added or upgraded or downgraded but still visible
            (auraApplied or (auraRemoved and count and count > 0))
        and
            -- The number of stacks is supported
            (auras[count])
        ) then
            -- Activate aura
            for _, aura in ipairs(auras[count]) do
                self:ActivateOverlay(count, select(3,unpack(aura)));
                self:AddGlow(spellID, select(11,unpack(aura)));
            end
        elseif (
            -- Aura is already visible but its number of stack changed
            (currentlyActiveOverlay and currentlyActiveOverlay ~= count)
        and
            -- The new stack count allows it to be visible
            (count and count > 0)
        and
            -- The number of stacks is supported
            (auras[count])
        ) then
            -- Deactivate old aura and activate the new one
            self:DeactivateOverlay(spellID);
            self:RemoveGlow(spellID);
            for _, aura in ipairs(auras[count]) do
                local texture, positions, scale, r, g, b, autoPulse = select(4,unpack(aura));
                local forcePulsePlay = autoPulse;
                self:ActivateOverlay(count, spellID, texture, positions, scale, r, g, b, autoPulse, forcePulsePlay);
                self:AddGlow(spellID, select(11,unpack(aura)));
            end
        elseif (
            -- Aura is already visible and its number of stacks changed
            (currentlyActiveOverlay and currentlyActiveOverlay ~= count)
        and
            ((count and count > 0) or auraRemoved)
            -- If condition end up here, it means the previous 'if' was false
            -- Which means either there is no stacks, or the number of stacks is not supported
        ) then
            -- Aura just disappeared or is not supported for this number of stacks
            self:DeactivateOverlay(spellID);
            self:RemoveGlow(spellID);
        end
    end
end

-- The (in)famous CLEU event
function SAO.COMBAT_LOG_EVENT_UNFILTERED(self, ...)
    local _, event, _, _, _, _, _, destGUID = CombatLogGetCurrentEventInfo();

    if ( (event:sub(0,11) == "SPELL_AURA_") and (destGUID == UnitGUID("player")) ) then
        self:SPELL_AURA(...);
    end
end

-- Event receiver
function SAO.OnEvent(self, event, ...)
    if self[event] then
        self[event](self, ...);
    end
    if (self.CurrentClass and self.CurrentClass[event]) then
        self.CurrentClass[event](self, ...);
    end
end
