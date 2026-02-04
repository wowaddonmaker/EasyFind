local ADDON_NAME, ns = ...

FindIt = {}
ns.FindIt = FindIt

local eventFrame = CreateFrame("Frame")
FindIt.db = {}

local function OnInitialize()
    if not FindItDB then
        FindItDB = {
            visible = true,
            mapIconScale = 1.0,
            uiSearchScale = 1.0,
            mapSearchScale = 1.0,
            uiSearchPosition = nil,  -- {point, relPoint, x, y}
            mapSearchPosition = nil, -- {x offset from map edge}
            directOpen = false,      -- If true, open panels directly instead of step-by-step
        }
    end
    -- Ensure new settings exist for existing users
    if FindItDB.mapIconScale == nil then FindItDB.mapIconScale = 1.0 end
    if FindItDB.uiSearchScale == nil then FindItDB.uiSearchScale = 1.0 end
    if FindItDB.mapSearchScale == nil then FindItDB.mapSearchScale = 1.0 end
    if FindItDB.directOpen == nil then FindItDB.directOpen = false end
    
    FindIt.db = FindItDB
    
    SLASH_FINDIT1 = "/find"
    SLASH_FINDIT2 = "/findit"
    SlashCmdList["FINDIT"] = function(msg)
        msg = msg and msg:lower():trim() or ""
        if msg == "o" or msg == "options" or msg == "config" or msg == "settings" then
            FindIt:OpenOptions()
        else
            FindIt:ToggleSearchUI()
        end
    end
    
    -- Debug command to find frame under cursor
    SLASH_FINDITDEBUG1 = "/finddebug"
    SlashCmdList["FINDITDEBUG"] = function(msg)
        local frames = GetMouseFoci and GetMouseFoci() or { GetMouseFocus and GetMouseFocus() }
        local frame = frames and frames[1]
        if frame then
            local name = frame:GetName()
            local parent = frame:GetParent()
            local parentName = parent and parent:GetName() or "nil"
            local grandparent = parent and parent:GetParent()
            local grandparentName = grandparent and grandparent:GetName() or "nil"
            
            print("|cFF00FF00FindIt Debug:|r")
            print("  Frame: " .. (name or "unnamed"))
            print("  Parent: " .. parentName)
            print("  Grandparent: " .. grandparentName)
            
            -- Try to build full path
            local path = {}
            local current = frame
            while current do
                local n = current:GetName()
                if n then
                    table.insert(path, 1, n)
                end
                current = current:GetParent()
            end
            if #path > 0 then
                print("  Full path: " .. table.concat(path, " > "))
            end
        else
            print("|cFF00FF00FindIt Debug:|r No frame under cursor")
        end
    end
    
    -- Debug command for map search
    SLASH_FINDITMAPSCAN1 = "/findmapscan"
    SlashCmdList["FINDITMAPSCAN"] = function(msg)
        if not WorldMapFrame:IsShown() then
            print("|cFFFF0000FindIt:|r Open the World Map first.")
            return
        end
        if ns.MapSearch then
            local pois = ns.MapSearch:ScanMapPOIs()
            local static = ns.MapSearch:GetStaticLocations()
            print("|cFF00FF00FindIt Map Scan:|r")
            print("  Dynamic POIs found: " .. #pois)
            for i, poi in ipairs(pois) do
                if i <= 10 then
                    print("    - " .. (poi.name or "unnamed") .. " [" .. (poi.category or "?") .. "]")
                end
            end
            if #pois > 10 then print("    ... and " .. (#pois - 10) .. " more") end
            print("  Static locations: " .. #static)
            for i, loc in ipairs(static) do
                if i <= 10 then
                    print("    - " .. (loc.name or "unnamed"))
                end
            end
            if #static > 10 then print("    ... and " .. (#static - 10) .. " more") end
        end
    end
    
    FindIt:Print("FindIt loaded! Use /find to toggle UI search.")
end

local function OnPlayerLogin()
    C_Timer.After(0.5, function()
        if ns.UI then ns.UI:Initialize() end
        if ns.Highlight then ns.Highlight:Initialize() end
        if ns.MapSearch then ns.MapSearch:Initialize() end
    end)
end

eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
        OnInitialize()
    elseif event == "PLAYER_LOGIN" then
        OnPlayerLogin()
    end
end)

function FindIt:ToggleSearchUI()
    if ns.UI then ns.UI:Toggle() end
end

function FindIt:OpenOptions()
    if ns.Options then ns.Options:Toggle() end
end

function FindIt:StartGuide(guideData)
    if ns.Highlight then
        ns.Highlight:StartGuide(guideData)
    end
end

function FindIt:Print(msg)
    print("|cFF00FF00FindIt:|r " .. msg)
end
