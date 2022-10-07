local AddonName, SAO = ...

function SAO.AddOverlayOption(self, talentID, auraID, count, talentSubText)
    local className = self.CurrentClass.Intrinsics[1];
    local classFile = self.CurrentClass.Intrinsics[2];

    local applyTextFunc = function(self)
        local enabled = self:IsEnabled();

        -- Class text
        local classColor;
        if (enabled) then
            classColor = select(4,GetClassColor(classFile));
        else
            local dimmedClassColor = CreateColor(0.5*RAID_CLASS_COLORS[classFile].r, 0.5*RAID_CLASS_COLORS[classFile].g, 0.5*RAID_CLASS_COLORS[classFile].b);
            classColor = dimmedClassColor:GenerateHexColor();
        end
        local text = WrapTextInColorCode(className, classColor);

        -- Talent text
        local spellName, _, spellIcon = GetSpellInfo(talentID);
        text = text.." |T"..spellIcon..":0|t "..spellName;
        if (talentSubText) then
            text = text.." ("..talentSubText..")";
        end

        -- Set final text to checkbox
        self.Text:SetText(text);

        if (enabled) then
            self.Text:SetTextColor(1, 1, 1);
        else
            self.Text:SetTextColor(0.5, 0.5, 0.5);
        end
    end

    self:AddOption("alert", auraID, count or 0, applyTextFunc, SpellActivationOverlayOptionsPanelSpellAlertTestButton);
end


function SAO.AddOverlayLink(self, srcOption, dstOption)
    if (not self.OverlayOptionLinks) then
        self.OverlayOptionLinks = { [dstOption] = srcOption };
    else
        self.OverlayOptionLinks[dstOption] = srcOption;
    end
end
