local AddonName, SAO = ...
local Module = "effect"

--[[
    List of registered effect objects.
    Each object can have / must have these members:

{
    name = "my_effect", -- Mandatory
    project = SAO.WRATH + SAO.CATA, -- Mandatory
    spellID = 12345, -- Mandatory; usually a buff to track, for counters this is the counter ability
    talent = 49188, -- Talent or rune or nil (for counters that don't rely on other talent)
    counter = false, -- Default is false
    combatOnly = false, -- Default is false
    minor = false, -- Default is false; tells the effect is minor, and should not have any option

    triggers = { -- Default is false for every trigger; at least one trigger must be set
        aura = true, -- The aura with spell ID 'spellID' is gained or lost by the player
        action = false, -- The action with spell ID 'spellID' is usable or not
        talent = false, -- The player spent at least one point in effect's talent, or spent none
        holyPower = false, -- Number of charges of Holy Power (Paladin only, Cataclysm)
    },

    overlays = {{
        project = SAO.WRATH, -- Default is project from effect
        condition = { -- Default is the default value for each trigger defined in 'triggers'
            aura = 0, -- Default is 0. -1 for 'aura missing', 0 for 'any stacks', 1 or more tells the number of stacks
            action = nil, -- Default is true. true for action usable, false for action not usable
            talent = nil, -- Default is true. true for talent picked (at least one point), false for talent not picked
            holyPower = nil, -- Default is 3
        },
        spellID = nil, -- Default is spellID from effect
        texture = "genericarc_05", -- Mandatory
        position = "Top", -- Mandatory
        scale = 1, -- Default is 1
        color = {255, 255, 255}, -- Default is {255, 255, 255}
        pulse = true, -- Default is true
        option = { -- Default is true
            setupStacks = 0, -- Default is number of stacks from overlay
            testStacks = 0, -- Default is nil, which defaults to setupStacks
            subText = "no stacks", -- Default is nil
            variants = nil, -- Default is nil
        },
    }}, -- Although rare, multiple overlays are possible

    buttons = {{
        project = SAO.WRATH, -- Default is project from effect
        condition = {}, -- Default is the default value for each trigger. See above comment of 'overlays.condition'
        spellID = 1111, -- Default is spellID from effect
        useName = true, -- Default is false from Era to Wrath, default is true starting from Cataclysm
        option = { -- Default is true
            talentSubText = "no stacks", -- Default is nil; if option is not set at all, try to guess a good stack count for SAO:NbStacks
            spellSubText = nil, -- Default is nil
            variants = nil, -- Default is nil
        },
    }, { -- Multiple buttons if needed
        project = SAO.CATA,
        spellID = 2222,
        useName = true,
    }},
}

    Creating an object is done by a higher level function, called CreateEffect.
    CreateEffect translates human-readable effects (HREs) into Native Optimized Effects (NOEs).
    Once created, an effect may not be registered immediately, due to lazy init (e.g. requires talent tree which is sent by the server later).
    When an effect is registered, it gets 'promoted' with functions to perform operations like activating or deactivating.
]]
local registeredEffects = {}

-- Same list, but sorted by effect name
-- Unlike registeredEffects which was sorted by time of insertion, this list has a random order
-- When order matters, registeredEffects should be preferred
local registeredEffectsByName = {}

-- List of effects waiting to be added to registeredEffects
-- Cannot add them immediately to registeredEffects because the game is in need of other initialization, such as talent tree
local pendingEffects = {}

-- Flag to know when the player has logged in, detected by PLAYER_LOGIN event
local hasPlayerLoggedIn = false;

local function doesUseName(useNameProp)
    if useNameProp == nil then
        return SAO.IsCata() == false;
    else
        return useNameProp == true;
    end
end

-- Copy option's value, deep-copy if option is a table
local function copyOption(option)
    if type(option) == 'table' then
        local optionCopy = {}; -- Copy table to avoid issues when re-using options between effects
        for k, v in pairs(option) do
            optionCopy[k] = v; -- Copy one depth level only
            -- optionCopy[k] = copyOption(v); -- Use this code for a full deep copy
        end
        return optionCopy;
    else
        return option;
    end
end

-- Merge option1 and option2, with priority to option2
local function mergeOption(option1, option2)
    if option2 == nil then -- nil means "unspecified"
        return copyOption(option1);
    end

    if option2 == false then -- false means "no options, please"
        return false;
    end

    if option2 == true then -- true means "I specify that yes I want an option, but not specifying which params exactly"
        if type(option1) == 'table' then
            return copyOption(option1);
        end
        return true;
    end

    -- At this point, option2 should be a table
    if type(option2) ~= 'table' then
        SAO:Error(Module, "Merging options with invalid values "..tostring(option1).." vs. "..tostring(option2));
        return copyOption(option2);
    end

    if type(option1) ~= 'table' then
        return copyOption(option2);
    end

    -- Merge both tables, with priority to option2
    local combined = {}
    for k, v in pairs(option1) do
        combined[k] = v; -- write option1 first
    end
    for k, v in pairs(option2) do
        combined[k] = v; -- option2 overwrites option1, if sharing same keys
    end
    return combined;
end

local function getValueOrDefault(value, default)
    if value ~= nil then
        return value;
    else
        return default;
    end
end

local ConditionBuilders = {}
local ConditionBuilder = {
    register = function(self, nativeVar, humanReadableVar, defaultValue, hashSetter, description, checker)
        local builder = {
            nativeVar = nativeVar,
            humanReadableVar = humanReadableVar,
            hashSetter = hashSetter,
            defaultValue = defaultValue,
            description = description,
            checker = checker,
        }
        self.__index = nil;
        setmetatable(builder, self);
        self.__index = self;
        ConditionBuilders[nativeVar] = builder;
    end,

    -- Value fetched by CreateEffect to transform a Human Readable Effect into a Native Optimized Effect
    getHumanReadableValue = function(self, config, default)
        local value = config[self.humanReadableVar];
        if value == nil then
            value = default[self.humanReadableVar];
        end
        if type(value) ~= 'nil' and not self.checker(value) then
            SAO:Error(Module, "Building condition with invalid "..self.description.." "..tostring(value));
        end
        return value;
    end,

    -- Value fetched by RegisterNativeEffectNow to use a Native Optimized Effect to create an overlay or button
    getNativeValue = function(self, object) -- Object is either an overlay or button
        local value = object[self.nativeVar];
        if value == nil then
            value = self.defaultValue;
        end
        if type(value) ~= 'nil' and not self.checker(value) then
            SAO:Error(Module, "Using invalid "..self.description.." "..tostring(value));
        end
        return value;
    end,

    -- Update a hash with specified value
    setHashValue = function(self, hash, value)
        hash[self.hashSetter](hash, value);
    end,
}

ConditionBuilder:register(
    "aura", -- Name used by NOE
    "stacks", -- Name used by HRE
    0, -- Default (NOE only)
    "setAuraStacks", -- Setter method for Hash
    "number of stacks",
    function(value) return type(value) == 'number' and value >= -1 and value <= 99 end
);
ConditionBuilder:register(
    "action", -- Name used by NOE
    "actionUsable", -- Name used by HRE
    true, -- Default (NOE only)
    "setActionUsable", -- Setter method for Hash
    "action usable flag",
    function(value) return type(value) == 'boolean' end
);
ConditionBuilder:register(
    "talent", -- Name used by NOE
    "requireTalent", -- Name used by HRE
    true, -- Default (NOE only)
    "setTalented", -- Setter method for Hash
    "talent flag",
    function(value) return type(value) == 'boolean' end
);
ConditionBuilder:register(
    "holyPower", -- Name used by NOE
    "holyPower", -- Name used by HRE
    0, -- Default (NOE only)
    "setHolyPower", -- Setter method for Hash
    "Holy Power value",
    function(value) return type(value) == 'number' and value >= 0 and value <= 3 end
);

local function getCondition(config, default, triggers)
    local condition = {}

    for _, builder in ipairs(ConditionBuilders) do
        if triggers[builder.nativeVar] then
            local value = builder:getHumanReadableValue(config, default);
            condition[builder.nativeVar] = value;
        end
    end

    return condition;
end

local function addOneOverlay(overlays, overlayConfig, project, default, triggers)
    if not default then
        default = {}
    end

    local condition = getCondition(overlayConfig, default, triggers);

    local texture = overlayConfig.texture or default.texture;
    if type(texture) ~= 'string' then
        SAO:Error(Module, "Adding Overlay with invalid texture "..tostring(texture));
    end

    local position = overlayConfig.position or default.position;
    if type(position) ~= 'string' then
        SAO:Error(Module, "Adding Overlay with invalid position "..tostring(position));
    end

    local option = overlayConfig.option;
    if option == nil then option = default.option; end
    if option ~= nil and type(option) ~= 'boolean' and type(option) ~= 'table' then
        SAO:Error(Module, "Adding Overlay with invalid option "..tostring(option));
    end

    local color = overlayConfig.color or default.color;

    local overlay = {
        project = overlayConfig.project or project, -- Note: cannot have a 'default.project'
        condition = condition,
        texture = texture,
        position = position,
        scale = overlayConfig.scale or default.scale,
        color = color and { color[1], color[2], color[3] } or nil,
        pulse = getValueOrDefault(overlayConfig.pulse, default.pulse),
        option = mergeOption(default.option, overlayConfig.option),
    }

    if type(overlay.project) == 'number' and not SAO.IsProject(overlay.project) then
        return;
    end

    table.insert(overlays, overlay);
end

local function addOneButton(buttons, buttonConfig, project, default, triggers)
    if not default then
        default = {}
    end

    local condition;

    if type(buttonConfig) == 'table' then
        local spellID = buttonConfig.spellID or default.spellID;
        if spellID ~= nil and type(spellID) ~= 'number' then
            SAO:Error(Module, "Adding Button with invalid spellID "..tostring(spellID));
        end
        local option = buttonConfig.option;
        if option == nil then option = default.option; end
        if option ~= nil and type(option) ~= 'boolean' and type(option) ~= 'table' then
            SAO:Error(Module, "Adding Button with invalid option "..tostring(option));
        end
        condition = getCondition(buttonConfig, default, triggers);
    else
        condition = getCondition({}, default, triggers);
    end

    local button = {
        condition = condition,
    };

    if type(buttonConfig) == 'number' then
        button.project = project; -- Note: cannot have a 'default.project'
        button.spellID = buttonConfig;
        button.useName = default.useName;
        button.stacks = default.stacks;
        button.option = copyOption(default.option);
    elseif type(buttonConfig) == 'table' then
        button.project = buttonConfig.project or project; -- Note: cannot have a 'default.project'
        button.spellID = buttonConfig.spellID or default.spellID;
        button.useName = getValueOrDefault(buttonConfig.useName, default.useName);
        button.stacks = buttonConfig.stacks or default.stacks;
        button.option = mergeOption(default.option, buttonConfig.option);
    else
        SAO:Error(Module, "Adding Button with invalid value "..tostring(buttonConfig));
    end

    if type(button.project) == 'number' and not SAO.IsProject(button.project) then
        return;
    end

    table.insert(buttons, button);
end

local function importTalent(effect, props)
    if type(props.talent) == 'number' then
        effect.talent = props.talent;
    elseif type(props.talent) == 'table' then
        for project, talent in pairs(props.talent) do
            if SAO.IsProject(project) then
                effect.talent = talent;
                break;
            end
        end
    else
        effect.talent = effect.spellID;
    end

    if type(props.requireTalent) == 'boolean' then
        effect.triggers.talent = props.requireTalent;
    elseif type(props.requireTalent) == 'table' then
        for project, requireTalent in pairs(props.requireTalent) do
            if SAO.IsProject(project) then
                effect.triggers.talent = requireTalent;
                break;
            end
        end
    else
        effect.triggers.talent = false;
    end
end

local function importOverlays(effect, props)
    effect.overlays = {}
    if props.overlay then
        addOneOverlay(effect.overlays, props.overlay, nil, nil, effect.triggers);
    end
    local default = props.overlays and props.overlays.default or nil;
    for key, overlayConfig in pairs(props.overlays or {}) do
        if key ~= "default" then
            if type(key) == 'number' and key >= SAO.ERA then
                if type(overlayConfig) == 'table' and overlayConfig[1] then
                    for _, subOverlayConfig in ipairs(overlayConfig) do
                        addOneOverlay(effect.overlays, subOverlayConfig, key, overlayConfig.default or default, effect.triggers);
                    end
                else
                    addOneOverlay(effect.overlays, overlayConfig, key, default, effect.triggers);
                end
            else
                addOneOverlay(effect.overlays, overlayConfig, nil, default, effect.triggers);
            end
        end
    end
end

local function importButtons(effect, props)
    effect.buttons = {}
    if props.button then
        addOneButton(effect.buttons, props.button, nil, nil, effect.triggers);
    end
    local default = props.buttons and props.buttons.default or nil;
    for key, buttonConfig in pairs(props.buttons or {}) do
        if key ~= "default" then
            if type(key) == 'number' and key >= SAO.ERA then
                if type(buttonConfig) == 'table' and buttonConfig[1] then
                    for _, subButtonConfig in ipairs(buttonConfig) do
                        addOneButton(effect.buttons, subButtonConfig, key, buttonConfig.default or default, effect.triggers);
                    end
                else
                    addOneButton(effect.buttons, buttonConfig, key, default, effect.triggers);
                end
            else
                addOneButton(effect.buttons, buttonConfig, nil, default, effect.triggers);
            end
        end
    end
end

local function createCounter(effect, props)
    effect.counter = true;

    if type(props) == 'table' then
        effect.combatOnly = props.combatOnly;
        effect.buttons = {{
            useName = doesUseName(props.useName),
        }}
    else
        effect.buttons = {{
            useName = doesUseName(),
        }}
    end

    return effect;
end

local function createAura(effect, props)
    if type(props) == 'table' then
        effect.combatOnly = props.combatOnly;
    else
        SAO:Error(Module, "Creating an aura for "..tostring(effect.name).." requires a 'props' table");
    end

    effect.triggers.aura = true;

    importTalent(effect, props);

    importOverlays(effect, props);

    importButtons(effect, props);

    return effect;
end

local function createCounterWithOverlay(effect, props)
    if type(props) ~= 'table' or (not props.overlay and not props.overlays) then
        SAO:Error(Module, "Creating a counter with overlay for "..tostring(effect.name).." requires a 'props' table that contains either 'overlay' or 'overlays' or both");
    end

    createCounter(effect, props);

    importTalent(effect, props);

    importOverlays(effect, props);

    return effect;
end

local function getHash(condition, triggers)
    local hash = SAO.Hash:new();

    for trigger, enabled in pairs(triggers) do
        if enabled then
            local builder = ConditionBuilders[trigger];
            local value = builder:getNativeValue(condition);
            builder:setHashValue(hash, value);
        end
    end

    return hash;
end

local function checkNativeEffect(effect)
    if type(effect) ~= 'table' then
        SAO:Error(Module, "Registering invalid effect "..tostring(effect));
        return false;
    end
    if type(effect.name) ~= 'string' or effect.name == '' then
        SAO:Error(Module, "Registering effect with invalid name "..tostring(effect.name));
        return false;
    end
    if type(effect.project) ~= 'number' or bit.band(effect.project, SAO.ALL_PROJECTS) == 0 then
        SAO:Error(Module, "Registering effect "..effect.name.." with invalid project flags "..tostring(effect.project));
        return false;
    end
    if type(effect.spellID) ~= 'number' or effect.spellID <= 0 then
        SAO:Error(Module, "Registering effect "..effect.name.." with invalid spellID "..tostring(effect.spellID));
        return false;
    end
    if effect.talent and type(effect.talent) ~= 'number' then
        SAO:Error(Module, "Registering effect "..effect.name.." with invalid talent "..tostring(effect.talent));
        return false;
    end
    if effect.minor ~= nil and type(effect.minor) ~= 'boolean' then
        SAO:Error(Module, "Registering effect "..effect.name.." with invalid minor flag "..tostring(effect.minor));
        return nil;
    end
    if effect.counter ~= true and type(effect.overlays) ~= "table" then
        SAO:Error(Module, "Registering effect "..effect.name.." with no overlays and not as counter");
        return false;
    end
    if effect.counter == true and (type(effect.buttons) ~= "table" or #effect.buttons == 0) then
        SAO:Error(Module, "Registering effect "..effect.name.." with no buttons despite being a counter");
        return false;
    end
    if type(effect.triggers) ~= 'table' then
        SAO:Error(Module, "Registering effect "..effect.name.." with invalid trigger list");
        return false;
    end
    if effect.overlays and type(effect.overlays) ~= 'table' then
        SAO:Error(Module, "Registering effect "..effect.name.." with invalid overlay list");
        return false;
    end
    if effect.buttons and type(effect.buttons) ~= 'table' then
        SAO:Error(Module, "Registering effect "..effect.name.." with invalid button list");
        return false;
    end

    local nbTriggers = 0;
    for name, enabled in pairs(effect.triggers) do
        if not tContains(SAO.TriggerNames, name) then
            SAO:Error(Module, "Registering effect "..effect.name.." with unknown trigger "..tostring(name));
            return false;
        end
        if type(enabled) ~= 'boolean' then
            SAO:Error(Module, "Registering effect "..effect.name.." for trigger "..tostring(name).." with invalid value "..tostring(enabled));
            return false;
        end
        if enabled then
            nbTriggers = nbTriggers + 1;
        end
    end
    if nbTriggers == 0 then
        SAO:Error(Module, "Registering effect "..effect.name.." without any trigger enabled in the list of triggers");
        return false;
    end

    local hasStacksZero, hasStacksNonZero, hasStacksNegative = false, false, false;
    for i, overlay in ipairs(effect.overlays or {}) do
        if overlay.project and type(overlay.project) ~= 'number' then
            SAO:Error(Module, "Registering effect "..effect.name.." for overlay "..i.." with invalid project flags "..tostring(overlay.project));
            return false;
        end
        if overlay.spellID and type(overlay.spellID) ~= 'number' then
            SAO:Error(Module, "Registering effect "..effect.name.." for overlay "..i.." with invalid spellID "..tostring(overlay.spellID));
            return false;
        end
        if type(overlay.stacks) ~= 'nil' and (type(overlay.stacks) ~= 'number' or overlay.stacks < -1 or overlay.stacks > 99) then
            SAO:Error(Module, "Registering effect "..effect.name.." for overlay "..i.." with invalid number of stacks "..tostring(overlay.stacks));
            return false;
        end
        local stacks = overlay.stacks or 0;
        if stacks == 0 then
            if hasStacksNonZero or hasStacksNegative then
                SAO:Error(Module, "Registering effect "..effect.name.." with mixed stacks of "..(hasStacksNonZero and "zero and non-zero" or "positive and negative"));
                return false;
            end
            hasStacksZero = true;
        elseif stacks == -1 then
            if hasStacksZero or hasStacksNonZero then
                SAO:Error(Module, "Registering effect "..effect.name.." with mixed stacks of positive and negative");
                return false;
            end
            hasStacksNegative = true;
        else
            if hasStacksZero or hasStacksNegative then
                SAO:Error(Module, "Registering effect "..effect.name.." with mixed stacks of "..(hasStacksZero and "zero and non-zero" or "positive and negative"));
                return false;
            end
            hasStacksNonZero = true;
        end
        if type(overlay.texture) ~= 'string' then
            SAO:Error(Module, "Registering effect "..effect.name.." for overlay "..i.." with invalid texture name "..tostring(overlay.texture));
            return false;
        end
        if SAO.TexName[overlay.texture] == nil then
            SAO:Error(Module, "Registering effect "..effect.name.." for overlay "..i.." with unknown texture name "..tostring(overlay.texture));
            return false;
        end
        if type(overlay.position) ~= 'string' then -- @todo check the position is one of the allowed values
            SAO:Error(Module, "Registering effect "..effect.name.." for overlay "..i.." with invalid position "..tostring(overlay.position));
            return false;
        end
        if overlay.scale and (type(overlay.scale) ~= 'number' or overlay.scale <= 0) then
            SAO:Error(Module, "Registering effect "..effect.name.." for overlay "..i.." with invalid scale factor "..tostring(overlay.scale));
            return false;
        end
        if overlay.color and (type(overlay.color) ~= 'table' or type(overlay.color[1]) ~= 'number' or type(overlay.color[2]) ~= 'number' or type(overlay.color[3]) ~= 'number') then
            SAO:Error(Module, "Registering effect "..effect.name.." for overlay "..i.." with invalid color");
            return false;
        end
    end

    for i, button in ipairs(effect.buttons or {}) do
        if button.project and type(button.project) ~= 'number' then
            SAO:Error(Module, "Registering effect "..effect.name.." for button "..i.." with invalid project flags "..tostring(button.project));
            return false;
        end
        if button.spellID and type(button.spellID) ~= 'number' then
            SAO:Error(Module, "Registering effect "..effect.name.." for button "..i.." with invalid spellID "..tostring(button.spellID));
            return false;
        end
    end

    if effect.triggers.talent and not effect.talent then
        SAO:Error(Module, "Registering effect "..effect.name.." with talent requirement, but no talent is pointed out in the talent tree");
        return false;
    end

    return true;
end

local function RegisterNativeEffectNow(self, effect)
    local bucket, created = self.BucketManager:getOrCreateBucket(effect.name, effect.spellID);
    if not created then
        self:Warn(Module, "Overwriting bucket "..bucket.description);
    end

    for name, enabled in pairs(effect.triggers) do
        if enabled then
            bucket.trigger:require(SAO.TriggerFlags[name]);
        end
    end

    for _, overlay in ipairs(effect.overlays or {}) do
        if not overlay.project or self.IsProject(overlay.project) then
            local stacks = overlay.condition.stacks or 0;
            local spellID = overlay.spellID or effect.spellID;
            local texture = overlay.texture;
            local position = overlay.position;
            local scale = overlay.scale or 1;
            local r, g, b = 255, 255, 255;
            if overlay.color then r, g, b = overlay.color[1], overlay.color[2], overlay.color[3] end
            local autoPulse = overlay.pulse ~= false;
            local combatOnly = overlay.combatOnly == true or effect.combatOnly == true;

            local hash = getHash(overlay.condition, effect.triggers);

            local overlayPod = {
                stacks = stacks, -- @todo replace with real hash
                spellID = spellID,
                texture = SAO.TexName[texture], -- Map from TexName
                position = position,
                scale = scale,
                r = r, g = g, b = b,
                autoPulse = autoPulse,
                combatOnly = combatOnly,
            }

            self.BucketManager:addEffectOverlay(bucket, hash, overlayPod, combatOnly);
        end
    end

    for _, button in ipairs(effect.buttons or {}) do
        if not button.project or self.IsProject(button.project) then
            local spellID = button.spellID or effect.spellID;
            local useName = doesUseName(button.useName);
            local combatOnly = effect.combatOnly == true;
            local spellToAdd;
            if useName then
                local spellName = GetSpellInfo(spellID);
                if not spellName then
                    self:Warn(Module, "Registering effect "..effect.name.." for button with unknown spellID "..tostring(spellID));
                    spellToAdd = spellID;
                end
                spellToAdd = spellName;
            else
                spellToAdd = spellID;
            end

            local hash = getHash(button.condition, effect.triggers);

            self.BucketManager:addEffectButton(bucket, hash, spellToAdd, combatOnly);
        end
    end

    if effect.talent and effect.triggers.talent then
        local talentName = GetSpellInfo(effect.talent);
        local _, _, tab, index = self:GetTalentByName(talentName);
        if type(tab) == 'number' and type(index) == 'number' then
            bucket.talentTabIndex = { tab, index };
        else
            self:Error(Module, "Effect "..tostring(effect.name).." requires talent "..effect.talent..(talentName and "("..talentName..")" or "")..", but it cannot be found in the talent tree");
        end
    end

    if effect.counter == true then
        self:RegisterCounter(effect.name);
    end

    table.insert(registeredEffects, effect);
    if registeredEffectsByName[effect.name] then
        self:Warn(Module, "Registering multiple effects with same name "..tostring(effect.name));
    end
    registeredEffectsByName[effect.name] = effect;
end

function SAO:RegisterNativeEffect(effect)
    if not checkNativeEffect(effect) then
        return;
    end

    if not self.IsProject(effect.project) then
        return;
    end

    if hasPlayerLoggedIn then
        RegisterNativeEffectNow(self, effect);
    else
        table.insert(pendingEffects, effect);
    end
end

function SAO:RegisterPendingEffectsAfterPlayerLoggedIn()
    if hasPlayerLoggedIn then
        self:Debug(Module, "Received PLAYER_LOGIN twice in the same session");
    end
    hasPlayerLoggedIn = true;

    for _, effect in ipairs(pendingEffects) do
        RegisterNativeEffectNow(self, effect);
    end
    pendingEffects = {};
end

function SAO:AddEffectOptions()
    for _, effect in ipairs(registeredEffects) do
        local talent = effect.talent;
        local skipOptions = effect.minor == true;

        local uniqueOverlayStack = { latest = nil, unique = true };
        for _, overlay in ipairs((not skipOptions) and effect.overlays or {}) do
            if overlay.option ~= false and (not overlay.project or self.IsProject(overlay.project)) then
                local buff = overlay.spellID or effect.spellID;
                if type(overlay.option) == 'table' then
                    local setupStacks = type(overlay.option.setupStacks) == 'number' and overlay.option.setupStacks or overlay.stacks;
                    local testStacks = type(overlay.option.testStacks) == 'number' and overlay.option.testStacks or setupStacks;
                    local subText = overlay.option.subText;
                    local variants = overlay.option.variants;
                    self:AddOverlayOption(talent, buff, setupStacks, subText, variants, testStacks);
                else
                    local setupStacks = overlay.stacks;
                    self:AddOverlayOption(talent, buff, setupStacks);
                end

                -- Bonus: detect if all overlays are based on a unique stack count; it will help write sub-text for glowing option
                local stacks = overlay.stacks or 0;
                if uniqueOverlayStack.latest and uniqueOverlayStack.latest ~= stacks and uniqueOverlayStack.unique then
                    uniqueOverlayStack.unique = false;
                end
                uniqueOverlayStack.latest = stacks;
            end
        end

        for _, button in ipairs((not skipOptions) and effect.buttons or {}) do
            if button.option ~= false and (not button.project or self.IsProject(button.project)) then
                local buff = effect.spellID;
                local spellID = button.spellID or effect.spellID;
                if type(button.option) == 'table' then
                    local talentSubText = button.option.talentSubText;
                    local spellSubText = button.option.spellSubText;
                    local variants = button.option.variants;
                    self:AddGlowingOption(talent, buff, spellID, talentSubText, spellSubText, variants);
                else
                    local stacks = button.stacks or (uniqueOverlayStack.unique and uniqueOverlayStack.latest) or nil;
                    local talentSubText = stacks and stacks > 0 and self:NbStacks(stacks) or nil;
                    self:AddGlowingOption(talent, buff, spellID, talentSubText);
                end
            end
        end
    end
end

--[[
    Create an effect based on a specific class.
    @param name Effect name, must be unique
    @param project Project flags where the effect is used e.g. SAO.WRATH+SAO.CATA
    @param class Class name e.g., "counter"
    @param props (optional) Properties to initialize the effect
    @param register (optional) Register the effect automatically after creation; default is true
]]
function SAO:CreateEffect(name, project, spellID, class, props, register)
    if type(name) ~= 'string' or name == '' then
        self:Error(Module, "Creating effect with invalid name "..tostring(name));
        return nil;
    end
    if type(project) ~= 'number' or bit.band(project, SAO.ALL_PROJECTS) == 0 then
        self:Error(Module, "Creating effect "..name.." with invalid project flags "..tostring(project));
        return nil;
    end
    if (type(spellID) ~= 'number' and type(spellID) ~= 'table') or (type(spellID) == 'number' and spellID <= 0) then
        self:Error(Module, "Creating effect "..name.." with invalid spellID "..tostring(spellID));
        return nil;
    end
    if type(class) ~= 'string' then
        self:Error(Module, "Creating effect "..name.." with invalid class "..tostring(spellID));
        return nil;
    end
    if props and type(props) ~= 'table' then
        self:Error(Module, "Creating effect "..name.." with invalid props "..tostring(props));
        return nil;
    end
    if props and props.minor ~= nil and type(props.minor) ~= 'boolean' then
        self:Error(Module, "Creating effect "..name.." with invalid minor flag "..tostring(props.minor));
        return nil;
    end

    if not self.IsProject(project) then
        return;
    end

    if type(spellID) == 'table' then
        for spellProject, projectedSpellID in pairs(spellID) do
            if type(spellProject) ~= 'number' or spellProject < SAO.ERA or type(projectedSpellID) ~= 'number' or projectedSpellID <= 0 then
                self:Error(Module, "Creating effect "..name.." with invalid spellProject "..tostring(spellProject).." or spellID "..tostring(projectedSpellID).." or both");
                return nil;
            end
            if self.IsProject(spellProject) then
                spellID = projectedSpellID;
                break;
            end
        end
    end

    local effect = {
        name = name,
        project = project,
        spellID = spellID,
        minor = type(props) == 'table' and props.minor,
        triggers = {},
    }

    if strlower(class) == "counter" then
        createCounter(effect, props);
    elseif strlower(class) == "aura" then
        createAura(effect, props);
    elseif strlower(class) == "counter_with_overlay" then
        createCounterWithOverlay(effect, props);
    else
        self:Error(Module, "Creating effect "..name.." with unknown class "..tostring(class));
        return nil;
    end

    if register == nil or register == true then
        self:RegisterNativeEffect(effect);
    end

    return effect;
end

--[[
    Create multiple, linked effects.
    Parameters are almost identical to CreateEffect, the main difference is that there are multiple spellIDs instead of one.
    The last spellID is the 'master' while all others are linked to it.
    Options are set to false for all overlays/buttons, except the last one.
    The minor flag, if set, will be ignored because overriden to disable all options.
]]
function SAO:CreateLinkedEffects(name, project, spellIDs, class, props, register)
    if not self.IsProject(project) then
        return nil;
    end

    local wasMinor;
    local minorProps;
    if type(props) == 'table' then
        wasMinor = props.minor;
        minorProps = props;
        if type(wasMinor) == 'boolean' then
            self:Error(Module, "Effect link group "..tostring(name).." uses a minor flag; it will be overriden");
        end
    else
        minorProps = {};
    end

    -- Start by creating the last effect, because it is the most important one
    -- If it fails, don't even bother creating the rest
    local lastSpell = spellIDs[#spellIDs];
    minorProps.minor = false; -- Last spell is *not* minor
    local lastEffect = self:CreateEffect(name.."_link_max", project, lastSpell, class, minorProps, false);
    if not lastEffect then
        self:Error(Module, "Failed to create main effect for an effect link group of "..tostring(name));
        minorProps.minor = wasMinor;
        return nil;
    end
    minorProps.minor = true; -- All other spells will be minor

    local hasOverlay = type(props) == 'table' and (props.overlay or props.overlays);
    local hasButton = type(props) == 'table' and (props.button or props.buttons);

    local effects = {};

    for i, spell in ipairs(spellIDs) do
        if spell ~= lastSpell then
            if hasOverlay then
                self:AddOverlayLink(lastSpell, spell);
            end
            if hasButton then
                self:AddGlowingLink(lastSpell, spell);
            end

            local effect = self:CreateEffect(name.."_link_"..i, project, spell, class, minorProps, false);
            if effect then
                table.insert(effects, effect);
            end
        end
    end

    table.insert(effects, lastEffect);

    if register == nil or register == true then
        for _, effect in ipairs(effects) do
            self:RegisterNativeEffect(effect);
        end
    end

    minorProps.minor = wasMinor;
    return effects;
end
