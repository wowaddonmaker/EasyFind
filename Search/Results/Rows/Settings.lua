local _, ns = ...

local Results = ns.Results
local Rows = ns.ResultRows

local function ReadSettingVariable(variable)
    if Settings and Settings.GetSetting then
        local sok, settObj = pcall(Settings.GetSetting, variable)
        if sok and settObj and settObj.GetValue then
            local vok, value = pcall(settObj.GetValue, settObj)
            if vok then return value end
        end
    end
    if GetCVar then
        local ok, value = pcall(GetCVar, variable)
        if ok then return value end
    end
end

local function WriteSettingVariable(variable, value)
    -- Prefer the per-setting object: GetSetting returns nil for variables
    -- the Settings panel doesn't know about, so a successful SetValue here
    -- means the write actually went somewhere. Settings.SetValue (static)
    -- is a silent no-op for unregistered variables, so we skip it.
    if Settings and Settings.GetSetting then
        local sok, settObj = pcall(Settings.GetSetting, variable)
        if sok and settObj and settObj.SetValue then
            -- Coerce to the setting's declared variable type before
            -- writing. Type mismatches (e.g. passing "1" to a number
            -- setting) make Setting:SetValue silently no-op, which
            -- looks like a flicker on our row: pcall succeeds but
            -- the underlying value never changes.
            local writeValue = value
            if settObj.GetVariableType then
                local tok, vtype = pcall(settObj.GetVariableType, settObj)
                if tok and type(vtype) == "string" then
                    if vtype == "number" then
                        writeValue = tonumber(value) or value
                    elseif vtype == "string" then
                        writeValue = tostring(value)
                    elseif vtype == "boolean" then
                        if type(value) == "boolean" then
                            writeValue = value
                        elseif value == "1" or value == 1 or value == "true" then
                            writeValue = true
                        elseif value == "0" or value == 0 or value == "false" then
                            writeValue = false
                        end
                    end
                end
            end
            if pcall(settObj.SetValue, settObj, writeValue) then
                -- Settings flagged with CommitFlag.Apply stage to
                -- pendingValue (graphics, resolution, etc.) and need
                -- the user to commit. Tell BlizzOptionsSearch so the
                -- floating Apply/Revert bar can surface the change.
                if ns.BlizzOptionsSearch and ns.BlizzOptionsSearch.NotePendingApply then
                    ns.BlizzOptionsSearch:NotePendingApply(variable)
                end
                -- Verify: SetValue can succeed on the call but reject
                -- the value internally. Read back to confirm it took.
                if settObj.GetValue then
                    local rok, raw = pcall(settObj.GetValue, settObj)
                    if rok and (raw == writeValue or tostring(raw) == tostring(writeValue)) then
                        return true
                    end
                else
                    return true
                end
            end
        end
    end
    -- CVar fallback for raw CVars not registered with the Settings panel.
    -- Booleans need explicit "1"/"0": tostring(true) gives "true", which
    -- a CVar slot would store literally and break the next read.
    if SetCVar then
        local cvarVal
        if type(value) == "boolean" then
            cvarVal = value and "1" or "0"
        else
            cvarVal = tostring(value)
        end
        if pcall(SetCVar, variable, cvarVal) then return true end
    end
    return false
end

function Rows:ReadSettingVariable(variable)
    return ReadSettingVariable(variable)
end

function Rows:WriteSettingVariable(variable, value)
    return WriteSettingVariable(variable, value)
end

local function ActivateSettingResult(data, openMenuHeld)
    if not data or not data.settingVariable then return false end
    local stype = data.settingType
    if (stype == "checkbox" or stype == "checkboxSlider") and not openMenuHeld then
        -- Plain click toggles inline. Alt+click falls through to open
        -- the in-game Settings panel for the same variable. For
        -- checkboxSlider, the cb variable lives at data.settingVariable
        -- so the existing toggle path Just Works.
        Results:ToggleSettingCheckbox(data)
        return true
    end
    -- Slider / keybind / dropdown / unknown: let the caller fall through
    -- to the normal SelectResult path. SelectResult clears the search
    -- bar and dismisses results before dispatching to HandleStep, which
    -- gives navigation clicks the same behavior as every other row.
    return false
end

function Rows:ActivateSettingResult(data, openMenuHeld)
    return ActivateSettingResult(data, openMenuHeld)
end
