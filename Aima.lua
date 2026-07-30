--[[
    Aim.lua
    Aimlock script — Settings + Aimlock + extended features.
]]

-- ============================================================
--  SERVICES
-- ============================================================
local Rayfield         = loadstring(game:HttpGet("https://sirius.menu/rayfield"))()
local Players          = game:GetService("Players")
local RunService       = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService     = game:GetService("TweenService")
local Camera           = workspace.CurrentCamera

local LocalPlayer = Players.LocalPlayer
local function getCharParts()
    local char = LocalPlayer.Character
    if not char then return nil, nil, nil, nil end
    local hrp  = char:FindFirstChild("HumanoidRootPart")
    local hum  = char:FindFirstChildWhichIsA("Humanoid")
    local anim = hum and hum:FindFirstChildWhichIsA("Animator")
    return char, hrp, hum, anim
end

-- ============================================================
--  DEFAULTS / SETTINGS
-- ============================================================
local D = {
    -- ── Aimlock core ──────────────────────────────────────
    aimlockEnabled            = false,
    aimlockFOV                = 200,
    aimlockRange              = 1000,
    aimlockTeamCheck          = true,
    aimlockFriendCheck        = true,
    aimlockWallCheck          = true,
    aimlockShowFOV            = true,
    aimlockPart               = "Head",
    aimlockCrosshairPos       = UDim2.new(0.5, 0, 0.5, 0),
    aimlockCrosshairOpacity   = 0,          -- 0 = fully visible, 1 = invisible
    aimlockKey                = Enum.KeyCode.P,
    aimlockStickyLock         = true,
    aimlockSmartAI            = true,
    aimlockPredictStrength    = 1.0,
    aimlockSmoothing          = 0.55,
    aimlockMaxDegPerFrame     = 0,
    aimlockReacquireDelay     = 0.6,
    aimlockCursorMode         = true,
    aimlockHoldToAim          = false,
    aimlockPartChain          = { "Head", "UpperTorso", "Torso", "HumanoidRootPart" },
    aimlockHumanize           = 0,
    aimlockPredictAccel       = false,
    aimlockMissChance         = 0,
    aimlockFOVColorR          = 255,
    aimlockFOVColorG          = 60,
    aimlockFOVColorB          = 60,
    -- ── Lists ─────────────────────────────────────────────
    targetLockEnabled         = false,
    targetLockList            = {},         -- [lowercase name] = true  (priority targets)
    ignoreList                = {},         -- [lowercase name] = true  (never targeted)
    -- ── Switch Targets ────────────────────────────────────
    switchTargetsEnabled      = false,
    -- ── NPC & Players Mode ────────────────────────────────
    npcPlayerModeEnabled      = false,
    npcPlayerMode             = "player",   -- "player" | "npc" | "zombie" | "humanoid"
    -- ── Images ────────────────────────────────────────────
    aimlockOffImg             = "rbxassetid://124959989742325",
    aimlockOnImg              = "rbxassetid://119279898696244",
    -- ── Button layout ─────────────────────────────────────
    btnSize                   = UDim2.new(0, 72, 0, 72),
    aimlockBtnPos             = UDim2.new(0.34, 0, 0.80, 0),
    switchLeftBtnPos          = UDim2.new(0.18, 0, 0.65, 0),
    switchRightBtnPos         = UDim2.new(0.26, 0, 0.65, 0),
    modeBtnPlayerPos          = UDim2.new(0.42, 0, 0.80, 0),
    modeBtnNpcPos             = UDim2.new(0.50, 0, 0.80, 0),
    modeBtnZombiePos          = UDim2.new(0.58, 0, 0.80, 0),
    modeBtnHumanoidPos        = UDim2.new(0.66, 0, 0.80, 0),
}
local S = {}
for k, v in pairs(D) do S[k] = v end
-- Deep-copy list tables so D defaults stay pristine
S.targetLockList = {}
S.ignoreList     = {}
S.aimlockPartChain = { "Head", "UpperTorso", "Torso", "HumanoidRootPart" }

-- ============================================================
--  AIMLOCK STATE
-- ============================================================
local Aimlock = {
    target       = nil,
    targetLostAt = 0,
    crosshairGui = nil,
    crosshairImg = nil,
    fovCircle    = nil,
    fovStroke    = nil,
    statusLabel  = nil,
    friendCache  = {},
    _holdActive  = false,
}

-- ── List helpers ──────────────────────────────────────────────
local function isOnLockList(entity)
    if not entity then return false end
    return S.targetLockList[string.lower(entity.Name)] == true
end

local function isOnIgnoreList(entity)
    if not entity then return false end
    return S.ignoreList[string.lower(entity.Name)] == true
end

local function isFriend(plr)
    if not plr or plr == LocalPlayer then return false end
    local cached = Aimlock.friendCache[plr.UserId]
    if cached ~= nil then return cached end
    local ok, res = pcall(function() return LocalPlayer:IsFriendsWith(plr.UserId) end)
    if ok then Aimlock.friendCache[plr.UserId] = res; return res end
    return false
end
Players.PlayerRemoving:Connect(function(p) Aimlock.friendCache[p.UserId] = nil end)

-- ── Entity helpers (work for both Player and NPC Model) ───────
local function getEntityModel(entity)
    if entity:IsA("Player") then return entity.Character end
    return entity
end

local function getEntityAimPart(entity)
    local model = getEntityModel(entity)
    if not model then return nil end
    if S.aimlockPart and S.aimlockPart ~= "" then
        local p = model:FindFirstChild(S.aimlockPart)
        if p and p:IsA("BasePart") then return p end
    end
    for _, name in ipairs(S.aimlockPartChain or { "Head", "HumanoidRootPart" }) do
        local p = model:FindFirstChild(name)
        if p and p:IsA("BasePart") then return p end
    end
    if model:IsA("Model") and model.PrimaryPart then return model.PrimaryPart end
    return model:FindFirstChildWhichIsA("BasePart")
end

local function isEntityAlive(entity)
    local model = getEntityModel(entity)
    if not model then return false end
    local hum = model:FindFirstChildWhichIsA("Humanoid")
    return hum ~= nil and hum.Health > 0
end

-- ── Geometry helpers ──────────────────────────────────────────
local function wallBlocked(fromPos, toPart)
    if not S.aimlockWallCheck then return false end
    local rp = RaycastParams.new()
    rp.FilterType = Enum.RaycastFilterType.Exclude
    local exclude = { LocalPlayer.Character }
    if toPart and toPart.Parent then table.insert(exclude, toPart.Parent) end
    rp.FilterDescendantsInstances = exclude
    rp.IgnoreWater = true
    local dir = toPart.Position - fromPos
    local hit = workspace:Raycast(fromPos, dir, rp)
    return hit ~= nil
end

local function crosshairScreenPos()
    local vp  = Camera.ViewportSize
    local pos = S.aimlockCrosshairPos or UDim2.new(0.5, 0, 0.5, 0)
    return Vector2.new(
        pos.X.Scale * vp.X + pos.X.Offset,
        pos.Y.Scale * vp.Y + pos.Y.Offset)
end

-- ── Velocity prediction ───────────────────────────────────────
local _velCache = {}
Players.PlayerRemoving:Connect(function(p) _velCache[p] = nil end)

local function predictedAimPoint(entity, hrp)
    local part = getEntityAimPart(entity)
    if not part then return nil end
    if not S.aimlockSmartAI then return part.Position, part end
    local v   = part.AssemblyLinearVelocity
    local now = tick()
    local accel = Vector3.zero
    local cache = _velCache[entity]
    if cache then
        local dt = math.max(now - cache.t, 1e-3)
        accel = (v - cache.v) / dt
        if accel.Magnitude > 500 then accel = accel.Unit * 500 end
    end
    _velCache[entity] = { v = v, t = now }
    if v.Magnitude < 0.5 and accel.Magnitude < 0.5 then return part.Position, part end
    local dist  = (part.Position - (hrp and hrp.Position or Camera.CFrame.Position)).Magnitude
    local leadT = math.clamp(dist / 1000, 0, 1.5) * (S.aimlockPredictStrength or 1)
    local lead  = v * leadT
    if S.aimlockPredictAccel then
        lead = lead + accel * (0.5 * leadT * leadT)
    end
    return part.Position + lead, part
end

-- ── Team helper (players only) ────────────────────────────────
local function p_team_eq(plr)
    return plr.Team and LocalPlayer.Team and plr.Team == LocalPlayer.Team
end

-- ── Validity checks ───────────────────────────────────────────
local function isValidPlayerTarget(plr, requireInFOV, cross)
    if not plr or plr == LocalPlayer then return false end
    if isOnIgnoreList(plr) then return false end
    if not isEntityAlive(plr) then return false end
    local part = getEntityAimPart(plr); if not part then return false end
    local _, hrp = getCharParts(); if not hrp then return false end
    if (part.Position - hrp.Position).Magnitude > S.aimlockRange then return false end
    if wallBlocked(hrp.Position, part) then return false end
    local listed = isOnLockList(plr)
    if not listed then
        if S.aimlockTeamCheck and p_team_eq(plr) then return false end
        if S.aimlockFriendCheck and isFriend(plr) then return false end
    end
    if requireInFOV and cross then
        local sp, on = Camera:WorldToViewportPoint(part.Position)
        if not on or sp.Z <= 0 then return false end
        local dx, dy = sp.X - cross.X, sp.Y - cross.Y
        if (dx * dx + dy * dy) > (S.aimlockFOV * S.aimlockFOV) then return false end
    end
    return true
end

local function isValidNPCTarget(model, requireInFOV, cross)
    if not model then return false end
    if isOnIgnoreList(model) then return false end
    if not isEntityAlive(model) then return false end
    local part = getEntityAimPart(model); if not part then return false end
    local _, hrp = getCharParts(); if not hrp then return false end
    if (part.Position - hrp.Position).Magnitude > S.aimlockRange then return false end
    if wallBlocked(hrp.Position, part) then return false end
    if requireInFOV and cross then
        local sp, on = Camera:WorldToViewportPoint(part.Position)
        if not on or sp.Z <= 0 then return false end
        local dx, dy = sp.X - cross.X, sp.Y - cross.Y
        if (dx * dx + dy * dy) > (S.aimlockFOV * S.aimlockFOV) then return false end
    end
    return true
end

local function isEntityValid(entity, requireInFOV, cross)
    if entity:IsA("Player") then
        return isValidPlayerTarget(entity, requireInFOV, cross)
    else
        return isValidNPCTarget(entity, requireInFOV, cross)
    end
end

-- ── NPC scan ──────────────────────────────────────────────────
local function getNPCTargets()
    local playerChars = {}
    for _, p in ipairs(Players:GetPlayers()) do
        if p.Character then playerChars[p.Character] = true end
    end
    local npcs = {}
    local mode = S.npcPlayerMode
    for _, obj in ipairs(workspace:GetDescendants()) do
        if obj:IsA("Model") and not playerChars[obj] then
            local hum = obj:FindFirstChildWhichIsA("Humanoid")
            if hum and hum.Health > 0 then
                local include = false
                if mode == "npc" or mode == "humanoid" then
                    include = true
                elseif mode == "zombie" then
                    local n = string.lower(obj.Name)
                    include = (n:find("zombie") ~= nil)
                        or (n:find("undead") ~= nil)
                        or (n:find("ghoul") ~= nil)
                end
                if include then table.insert(npcs, obj) end
            end
        end
    end
    return npcs
end

-- ── Candidate list builder (respects mode) ───────────────────
local function getCandidates()
    local mode = S.npcPlayerMode
    local list = {}
    if mode == "player" or mode == "humanoid" then
        for _, p in ipairs(Players:GetPlayers()) do
            table.insert(list, p)
        end
    end
    if mode == "npc" or mode == "zombie" or mode == "humanoid" then
        for _, npc in ipairs(getNPCTargets()) do
            table.insert(list, npc)
        end
    end
    return list
end

-- ── Acquire best target from FOV ─────────────────────────────
local function acquireTarget()
    local _, hrp = getCharParts(); if not hrp then return nil end
    local cross = crosshairScreenPos()
    local bestListed, bestListedDist = nil, math.huge
    local bestAny,    bestAnyDist    = nil, math.huge
    for _, entity in ipairs(getCandidates()) do
        if isEntityValid(entity, true, cross) then
            local part = getEntityAimPart(entity)
            if part then
                local sp = Camera:WorldToViewportPoint(part.Position)
                local dx, dy = sp.X - cross.X, sp.Y - cross.Y
                local d2 = dx * dx + dy * dy
                if isOnLockList(entity) then
                    if d2 < bestListedDist then bestListedDist, bestListed = d2, entity end
                else
                    if d2 < bestAnyDist then bestAnyDist, bestAny = d2, entity end
                end
            end
        end
    end
    return bestListed or bestAny
end

-- ── Switch-targets helpers ────────────────────────────────────
local function buildSwitchList()
    local _, hrp = getCharParts(); if not hrp then return {} end
    local cross = crosshairScreenPos()
    local items = {}
    for _, entity in ipairs(getCandidates()) do
        if isEntityValid(entity, false, cross) then
            local part = getEntityAimPart(entity)
            if part then
                local dist = (part.Position - hrp.Position).Magnitude
                table.insert(items, { entity = entity, dist = dist })
            end
        end
    end
    table.sort(items, function(a, b) return a.dist < b.dist end)
    local result = {}
    for _, v in ipairs(items) do table.insert(result, v.entity) end
    return result
end

local function switchTarget(dir)
    -- dir: 1 = next (right), -1 = previous (left)
    local list = buildSwitchList()
    if #list == 0 then return end
    local curIdx = 0
    for i, e in ipairs(list) do
        if e == Aimlock.target then curIdx = i; break end
    end
    local newIdx = curIdx + dir
    if newIdx < 1 then newIdx = #list end
    if newIdx > #list then newIdx = 1 end
    Aimlock.target = list[newIdx]
    Aimlock.targetLostAt = 0
end

-- ============================================================
--  CROSSHAIR GUI
-- ============================================================
local function makeCrosshairGui()
    if Aimlock.crosshairGui then return end
    local sg = Instance.new("ScreenGui")
    sg.Name           = "AimlockCrosshairGui"
    sg.ResetOnSpawn   = false
    sg.IgnoreGuiInset = true
    sg.Parent         = LocalPlayer:WaitForChild("PlayerGui")

    -- FOV ring
    local ring = Instance.new("Frame")
    ring.Name              = "FOVRing"
    ring.AnchorPoint       = Vector2.new(0.5, 0.5)
    ring.Position          = S.aimlockCrosshairPos
    ring.Size              = UDim2.new(0, S.aimlockFOV * 2, 0, S.aimlockFOV * 2)
    ring.BackgroundTransparency = 1
    ring.BorderSizePixel   = 0
    ring.Visible           = S.aimlockShowFOV == true
    ring.Parent            = sg
    local rc = Instance.new("UICorner"); rc.CornerRadius = UDim.new(0.5, 0); rc.Parent = ring
    local rs = Instance.new("UIStroke")
    rs.Thickness   = 2
    rs.Color       = Color3.fromRGB(S.aimlockFOVColorR, S.aimlockFOVColorG, S.aimlockFOVColorB)
    rs.Transparency= 0.15
    rs.Parent      = ring
    Aimlock.fovCircle = ring
    Aimlock.fovStroke = rs

    -- Crosshair dot
    local dot = Instance.new("Frame")
    dot.Name               = "CrosshairDot"
    dot.Size               = UDim2.new(0, 14, 0, 14)
    dot.AnchorPoint        = Vector2.new(0.5, 0.5)
    dot.Position           = S.aimlockCrosshairPos
    dot.BackgroundColor3   = Color3.fromRGB(255, 40, 40)
    dot.BackgroundTransparency = S.aimlockCrosshairOpacity or 0
    dot.BorderSizePixel    = 0
    dot.Parent             = sg
    local dc = Instance.new("UICorner"); dc.CornerRadius = UDim.new(0.5, 0); dc.Parent = dot
    local ds = Instance.new("UIStroke")
    ds.Thickness    = 2
    ds.Color        = Color3.fromRGB(255, 255, 255)
    ds.Transparency = 0.2
    ds.Parent       = dot

    -- Status label
    local lbl = Instance.new("TextLabel")
    lbl.AnchorPoint        = Vector2.new(0.5, 0)
    lbl.Position           = UDim2.new(S.aimlockCrosshairPos.X.Scale, 0,
                                       S.aimlockCrosshairPos.Y.Scale, 28)
    lbl.Size               = UDim2.new(0, 220, 0, 18)
    lbl.BackgroundTransparency = 1
    lbl.Font               = Enum.Font.GothamBold
    lbl.TextScaled         = true
    lbl.TextColor3         = Color3.fromRGB(255, 80, 80)
    lbl.TextStrokeTransparency = 0.4
    lbl.Text               = ""
    lbl.Parent             = sg

    Aimlock.crosshairGui = sg
    Aimlock.crosshairImg = dot
    Aimlock.statusLabel  = lbl
end

local function destroyCrosshairGui()
    if Aimlock.crosshairGui then
        pcall(function() Aimlock.crosshairGui:Destroy() end)
        Aimlock.crosshairGui = nil
        Aimlock.crosshairImg = nil
        Aimlock.fovCircle    = nil
        Aimlock.fovStroke    = nil
        Aimlock.statusLabel  = nil
    end
end

local function setAimlock(on)
    S.aimlockEnabled = on
    if on then
        makeCrosshairGui()
    else
        destroyCrosshairGui()
        Aimlock.target = nil
        Aimlock.targetLostAt = 0
    end
    if _G.__FlyScript_UpdateAimlockBtn then pcall(_G.__FlyScript_UpdateAimlockBtn) end
end
_G.__FlyScript_SetAimlock = setAimlock

-- ============================================================
--  RENDER LOOP
-- ============================================================
RunService:BindToRenderStep("FlyAimlock", Enum.RenderPriority.Camera.Value + 2, function()
    if not S.aimlockEnabled then return end
    if S.aimlockHoldToAim and not Aimlock._holdActive then
        if Aimlock.statusLabel then Aimlock.statusLabel.Text = "" end
        return
    end

    -- Sync GUI
    if Aimlock.crosshairImg then
        Aimlock.crosshairImg.Position = S.aimlockCrosshairPos
        Aimlock.crosshairImg.BackgroundTransparency = S.aimlockCrosshairOpacity or 0
    end
    if Aimlock.fovCircle then
        Aimlock.fovCircle.Visible  = S.aimlockShowFOV == true
        Aimlock.fovCircle.Position = S.aimlockCrosshairPos
        Aimlock.fovCircle.Size     = UDim2.new(0, S.aimlockFOV * 2, 0, S.aimlockFOV * 2)
        if Aimlock.fovStroke then
            Aimlock.fovStroke.Color = Color3.fromRGB(
                S.aimlockFOVColorR, S.aimlockFOVColorG, S.aimlockFOVColorB)
        end
    end
    if Aimlock.statusLabel then
        Aimlock.statusLabel.Position = UDim2.new(
            S.aimlockCrosshairPos.X.Scale, 0, S.aimlockCrosshairPos.Y.Scale, 28)
    end

    -- Miss chance
    local missPct = math.clamp(S.aimlockMissChance or 0, 0, 90)
    if missPct > 0 and math.random(1, 100) <= missPct then return end

    local _, hrp = getCharParts()
    if not hrp then return end
    local cross = crosshairScreenPos()

    -- Humanizer jitter
    local humPx = math.max(0, S.aimlockHumanize or 0)
    if humPx > 0 then
        cross = Vector2.new(
            cross.X + (math.random() - 0.5) * 2 * humPx,
            cross.Y + (math.random() - 0.5) * 2 * humPx)
    end

    -- ── Target acquisition ────────────────────────────────
    if S.switchTargetsEnabled then
        -- Switch mode: only auto-advance on death
        if Aimlock.target and not isEntityAlive(Aimlock.target) then
            local list = buildSwitchList()
            Aimlock.target = #list > 0 and list[1] or nil
        end
        if not Aimlock.target then
            local list = buildSwitchList()
            Aimlock.target = #list > 0 and list[1] or nil
        end
    else
        -- Normal sticky lock
        local cur = Aimlock.target
        local keep = false
        if cur and S.aimlockStickyLock then
            if isEntityValid(cur, false, cross) then
                keep = true
                Aimlock.targetLostAt = 0
            else
                if Aimlock.targetLostAt == 0 then Aimlock.targetLostAt = tick() end
                if (tick() - Aimlock.targetLostAt) < (S.aimlockReacquireDelay or 0.6)
                and cur and cur.Parent and isEntityAlive(cur) then
                    keep = true
                else
                    Aimlock.target = nil
                    Aimlock.targetLostAt = 0
                end
            end
        end
        if not keep or not Aimlock.target then
            Aimlock.target = acquireTarget()
            Aimlock.targetLostAt = 0
        end
    end

    local t = Aimlock.target
    if not t then
        if Aimlock.statusLabel then Aimlock.statusLabel.Text = "" end
        return
    end

    local aimPos = predictedAimPoint(t, hrp)
    if not aimPos then
        if Aimlock.statusLabel then Aimlock.statusLabel.Text = "" end
        return
    end

    -- Camera aim
    local camPos   = Camera.CFrame.Position
    local lookCF   = CFrame.lookAt(camPos, aimPos)
    local vp       = Camera.ViewportSize
    local fovY     = math.rad(Camera.FieldOfView)
    local focal    = (vp.Y * 0.5) / math.tan(fovY * 0.5)
    local pxOffX   = cross.X - vp.X * 0.5
    local pxOffY   = cross.Y - vp.Y * 0.5
    local yawOff   = math.atan(pxOffX / focal)
    local pitchOff = math.atan(pxOffY / focal)
    local targetCF = lookCF * CFrame.Angles(pitchOff, yawOff, 0)
    local smooth   = math.clamp(S.aimlockSmoothing or 1, 0.05, 1)
    local newCF    = Camera.CFrame:Lerp(targetCF, smooth)
    local maxDeg   = S.aimlockMaxDegPerFrame or 0
    if maxDeg > 0 then
        local dot    = math.clamp(Camera.CFrame.LookVector:Dot(newCF.LookVector), -1, 1)
        local angDeg = math.deg(math.acos(dot))
        if angDeg > maxDeg then newCF = Camera.CFrame:Lerp(newCF, maxDeg / angDeg) end
    end
    Camera.CFrame = newCF

    if Aimlock.statusLabel then
        local tag = isOnLockList(t) and " [LIST]" or ""
        Aimlock.statusLabel.Text = "Locked: " .. t.Name .. tag
    end
end)

-- ============================================================
--  KEYBINDS
-- ============================================================
UserInputService.InputBegan:Connect(function(input, gpe)
    if gpe then return end
    local k = input.KeyCode
    if k == S.aimlockKey then
        if S.aimlockHoldToAim then
            Aimlock._holdActive = true
            if not S.aimlockEnabled then setAimlock(true) end
        else
            setAimlock(not S.aimlockEnabled)
        end
    end
end)
UserInputService.InputEnded:Connect(function(input, gp)
    if gp then return end
    if S.aimlockHoldToAim and input.KeyCode == S.aimlockKey then
        Aimlock._holdActive = false
    end
end)

-- ============================================================
--  SCREEN GUI
-- ============================================================
local SG = Instance.new("ScreenGui")
SG.Name            = "AimlockUI"
SG.ResetOnSpawn    = false
SG.ZIndexBehavior  = Enum.ZIndexBehavior.Sibling
SG.IgnoreGuiInset  = true
SG.DisplayOrder    = 10
SG.Parent          = LocalPlayer.PlayerGui

local editActive   = false
local allButtons   = {}
local buttonRegistry = {}   -- { obj, sKey } pairs for layout save/reset

local DRAG_THRESH = 12

local function makeButton(name, initPos, initSize, labelText, bgColor, callback)
    local frame = Instance.new("Frame")
    frame.Name                  = name
    frame.Size                  = initSize
    frame.Position              = initPos
    frame.BackgroundColor3      = bgColor
    frame.BackgroundTransparency = 0.2
    frame.BorderSizePixel       = 0
    frame.Active                = true
    frame.Parent                = SG
    do local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0.5, 0); c.Parent = frame end

    local icon = Instance.new("ImageLabel")
    icon.Size               = UDim2.new(1, 0, 1, 0)
    icon.BackgroundTransparency = 1
    icon.Image              = ""
    icon.ScaleType          = Enum.ScaleType.Fit
    icon.Parent             = frame

    local lbl = Instance.new("TextLabel")
    lbl.Name                = "Lbl"
    lbl.Size                = UDim2.new(1, 0, 1, 0)
    lbl.BackgroundTransparency = 1
    lbl.Text                = labelText
    lbl.TextScaled          = true
    lbl.Font                = Enum.Font.GothamBold
    lbl.TextColor3          = Color3.fromRGB(255, 255, 255)
    lbl.TextStrokeTransparency = 0.4
    lbl.ZIndex              = 2
    lbl.Parent              = frame

    local btn = Instance.new("TextButton")
    btn.Size                = UDim2.new(1, 0, 1, 0)
    btn.BackgroundTransparency = 1
    btn.Text                = ""
    btn.ZIndex              = 5
    btn.Parent              = frame

    local activeTouches    = {}
    local currentDragTouch = nil
    local pinchStartDist   = nil
    local pinchStartSize   = nil

    local function getTouchList()
        local list = {}
        for inp in pairs(activeTouches) do table.insert(list, inp) end
        return list
    end

    btn.InputBegan:Connect(function(input)
        if input.UserInputType ~= Enum.UserInputType.Touch
        and input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
        activeTouches[input] = {
            startPos      = input.Position,
            startFramePos = frame.Position,
            dragging      = false,
        }
        local list = getTouchList()
        if #list == 2 then
            pinchStartDist = (list[1].Position - list[2].Position).Magnitude
            pinchStartSize = frame.Size
        end
    end)

    btn.InputChanged:Connect(function(input)
        local info = activeTouches[input]; if not info then return end
        local list = getTouchList()
        if #list == 2 and pinchStartDist and pinchStartDist > 0 and editActive then
            local newDist = (list[1].Position - list[2].Position).Magnitude
            local scale   = newDist / pinchStartDist
            local px      = math.clamp((pinchStartSize.X.Offset > 0 and pinchStartSize.X.Offset or 72) * scale, 48, 128)
            frame.Size    = UDim2.new(0, px, 0, px)
            return
        end
        local delta = input.Position - info.startPos
        if not info.dragging and delta.Magnitude >= DRAG_THRESH and editActive then
            info.dragging    = true
            currentDragTouch = input
        end
        if info.dragging and currentDragTouch == input and editActive then
            frame.Position = UDim2.new(
                info.startFramePos.X.Scale,
                info.startFramePos.X.Offset + delta.X,
                info.startFramePos.Y.Scale,
                info.startFramePos.Y.Offset + delta.Y)
        end
    end)

    btn.InputEnded:Connect(function(input)
        local info = activeTouches[input]; if not info then return end
        if not info.dragging then callback() end
        activeTouches[input] = nil
        if currentDragTouch == input then currentDragTouch = nil end
        local list = getTouchList()
        if #list < 2 then pinchStartDist = nil; pinchStartSize = nil end
    end)

    btn.MouseButton1Click:Connect(function()
        if not next(activeTouches) then callback() end
    end)

    local obj = { frame = frame, lbl = lbl, icon = icon }
    table.insert(allButtons, obj)
    return obj
end

-- ── Aimlock button ────────────────────────────────────────────
local aimlockBtnObj = makeButton("AimlockBtn", S.aimlockBtnPos, S.btnSize, "AIM",
    Color3.fromRGB(40, 20, 20),
    function()
        if S.aimlockHoldToAim then return end
        if _G.__FlyScript_SetAimlock then _G.__FlyScript_SetAimlock(not S.aimlockEnabled) end
    end)
table.insert(buttonRegistry, { obj = aimlockBtnObj, sKey = "aimlockBtnPos" })
do
    local function isHoldInput(i)
        return i.UserInputType == Enum.UserInputType.Touch
            or i.UserInputType == Enum.UserInputType.MouseButton1
    end
    aimlockBtnObj.frame.InputBegan:Connect(function(i)
        if not S.aimlockHoldToAim then return end
        if not isHoldInput(i) then return end
        Aimlock._holdActive = true
        if not S.aimlockEnabled and _G.__FlyScript_SetAimlock then _G.__FlyScript_SetAimlock(true) end
    end)
    aimlockBtnObj.frame.InputEnded:Connect(function(i)
        if not S.aimlockHoldToAim then return end
        if not isHoldInput(i) then return end
        Aimlock._holdActive = false
    end)
end

-- ── Switch-target buttons ─────────────────────────────────────
local switchLeftBtnObj = makeButton("SwitchLeft", S.switchLeftBtnPos, S.btnSize, "◄",
    Color3.fromRGB(20, 60, 130),
    function() if S.switchTargetsEnabled then switchTarget(-1) end end)
table.insert(buttonRegistry, { obj = switchLeftBtnObj, sKey = "switchLeftBtnPos" })

local switchRightBtnObj = makeButton("SwitchRight", S.switchRightBtnPos, S.btnSize, "►",
    Color3.fromRGB(20, 60, 130),
    function() if S.switchTargetsEnabled then switchTarget(1) end end)
table.insert(buttonRegistry, { obj = switchRightBtnObj, sKey = "switchRightBtnPos" })

-- ── NPC / Player mode buttons ─────────────────────────────────
local modeColors = {
    active   = Color3.fromRGB(40, 200, 80),
    inactive = Color3.fromRGB(160, 30, 30),
}

local modeBtnObjs = {}

local function refreshModeButtons()
    for mode, obj in pairs(modeBtnObjs) do
        local isActive = S.npcPlayerMode == mode
        obj.frame.BackgroundColor3 = isActive and modeColors.active or modeColors.inactive
    end
end

local modeList = { "player", "npc", "zombie", "humanoid" }
local modePosKeys = {
    player   = "modeBtnPlayerPos",
    npc      = "modeBtnNpcPos",
    zombie   = "modeBtnZombiePos",
    humanoid = "modeBtnHumanoidPos",
}
local modeLabels = { player = "PLR", npc = "NPC", zombie = "ZMB", humanoid = "HUM" }

for _, mode in ipairs(modeList) do
    local m = mode  -- upvalue capture
    local obj = makeButton("ModeBtn_" .. m, S[modePosKeys[m]], S.btnSize, modeLabels[m],
        Color3.fromRGB(160, 30, 30),
        function()
            if not S.npcPlayerModeEnabled then return end
            S.npcPlayerMode = m
            refreshModeButtons()
        end)
    modeBtnObjs[m]  = obj
    obj.frame.Visible = false
    table.insert(buttonRegistry, { obj = obj, sKey = modePosKeys[m] })
end

-- ── Button visibility loop ────────────────────────────────────
RunService.Heartbeat:Connect(function()
    -- Switch-target buttons
    switchLeftBtnObj.frame.Visible  = S.switchTargetsEnabled
    switchRightBtnObj.frame.Visible = S.switchTargetsEnabled
    -- Mode buttons
    for _, mode in ipairs(modeList) do
        modeBtnObjs[mode].frame.Visible = S.npcPlayerModeEnabled
    end
    -- Aimlock button icon tint (handled by _G hook, but keep visible always)
    aimlockBtnObj.frame.Visible = true
end)

-- ── Aimlock button icon update hook ───────────────────────────
_G.__FlyScript_UpdateAimlockBtn = function()
    if not aimlockBtnObj then return end
    if S.aimlockEnabled then
        aimlockBtnObj.icon.Image            = S.aimlockOnImg or ""
        aimlockBtnObj.frame.BackgroundColor3 = Color3.fromRGB(40, 200, 80)
    else
        aimlockBtnObj.icon.Image            = S.aimlockOffImg or ""
        aimlockBtnObj.frame.BackgroundColor3 = Color3.fromRGB(40, 20, 20)
    end
end

-- ── Edit-layout mode ──────────────────────────────────────────
local function enterEditMode()
    if editActive then return end
    editActive = true

    local overlay = Instance.new("Frame")
    overlay.Size               = UDim2.new(1, 0, 1, 0)
    overlay.BackgroundTransparency = 1
    overlay.ZIndex             = 20
    overlay.Parent             = SG

    local hint = Instance.new("TextLabel")
    hint.Size               = UDim2.new(0.72, 0, 0.06, 0)
    hint.Position           = UDim2.new(0.14, 0, 0.04, 0)
    hint.BackgroundColor3   = Color3.new(0, 0, 0)
    hint.BackgroundTransparency = 0.4
    hint.TextColor3         = Color3.new(1, 1, 1)
    hint.Text               = "Drag to move  •  Pinch to resize"
    hint.TextScaled         = true
    hint.Font               = Enum.Font.GothamSemibold
    hint.ZIndex             = 21
    hint.Parent             = overlay
    do local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0.25, 0); c.Parent = hint end

    local function makeCtrlBtn(label, xPos, bg, cb)
        local b = Instance.new("TextButton")
        b.Size             = UDim2.new(0.22, 0, 0.055, 0)
        b.Position         = UDim2.new(xPos, 0, 0.91, 0)
        b.BackgroundColor3 = bg
        b.TextColor3       = Color3.new(1, 1, 1)
        b.Text             = label
        b.TextScaled       = true
        b.Font             = Enum.Font.GothamBold
        b.ZIndex           = 21
        b.Parent           = overlay
        do local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0.3, 0); c.Parent = b end
        b.MouseButton1Click:Connect(cb)
        b.TouchTap:Connect(cb)
    end

    makeCtrlBtn("Save", 0.08, Color3.fromRGB(30, 160, 60), function()
        -- Save current positions to S
        for _, entry in ipairs(buttonRegistry) do
            S[entry.sKey] = entry.obj.frame.Position
        end
        overlay:Destroy()
        editActive = false
    end)

    makeCtrlBtn("Reset", 0.39, Color3.fromRGB(160, 120, 10), function()
        -- Reset to D defaults
        for _, entry in ipairs(buttonRegistry) do
            entry.obj.frame.Position = D[entry.sKey]
            S[entry.sKey]            = D[entry.sKey]
        end
        overlay:Destroy()
        editActive = false
    end)

    makeCtrlBtn("Cancel", 0.70, Color3.fromRGB(175, 30, 30), function()
        overlay:Destroy()
        editActive = false
    end)
end

-- ============================================================
--  PLAYER PICKER MODAL
-- ============================================================
local function openPlayerPicker(listMode)
    -- listMode: "lock" = targetLockList, "ignore" = ignoreList
    local list  = listMode == "lock" and S.targetLockList or S.ignoreList
    local title = listMode == "lock"
        and "Lock List  —  tap to add / remove"
        or  "Ignore List  —  tap to add / remove"

    -- Destroy any existing picker
    local existing = LocalPlayer.PlayerGui:FindFirstChild("PlayerPickerGui")
    if existing then existing:Destroy() end

    local gui = Instance.new("ScreenGui")
    gui.Name          = "PlayerPickerGui"
    gui.ResetOnSpawn  = false
    gui.IgnoreGuiInset = true
    gui.DisplayOrder  = 200
    gui.Parent        = LocalPlayer.PlayerGui

    -- Dim background
    local dim = Instance.new("Frame")
    dim.Size                 = UDim2.new(1, 0, 1, 0)
    dim.BackgroundColor3     = Color3.fromRGB(0, 0, 0)
    dim.BackgroundTransparency = 0.5
    dim.BorderSizePixel      = 0
    dim.Parent               = gui
    local dimBtn = Instance.new("TextButton")
    dimBtn.Size              = UDim2.new(1, 0, 1, 0)
    dimBtn.BackgroundTransparency = 1
    dimBtn.Text              = ""
    dimBtn.Parent            = dim
    dimBtn.MouseButton1Click:Connect(function() gui:Destroy() end)
    dimBtn.TouchTap:Connect(function() gui:Destroy() end)

    -- Panel
    local panel = Instance.new("Frame")
    panel.Size               = UDim2.new(0, 320, 0, 440)
    panel.Position           = UDim2.new(0.5, -160, 0.5, -220)
    panel.BackgroundColor3   = Color3.fromRGB(18, 18, 24)
    panel.BorderSizePixel    = 0
    panel.ZIndex             = 5
    panel.Parent             = gui
    do local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, 14); c.Parent = panel end
    do local s = Instance.new("UIStroke"); s.Color = Color3.fromRGB(70, 70, 90); s.Thickness = 1.5; s.Parent = panel end

    -- Title bar
    local titleLbl = Instance.new("TextLabel")
    titleLbl.Size              = UDim2.new(1, -16, 0, 46)
    titleLbl.Position          = UDim2.new(0, 8, 0, 0)
    titleLbl.BackgroundTransparency = 1
    titleLbl.Text              = title
    titleLbl.Font              = Enum.Font.GothamBold
    titleLbl.TextSize          = 13
    titleLbl.TextColor3        = Color3.fromRGB(255, 255, 255)
    titleLbl.ZIndex            = 6
    titleLbl.Parent            = panel

    -- Scroll
    local scroll = Instance.new("ScrollingFrame")
    scroll.Size              = UDim2.new(1, -16, 1, -96)
    scroll.Position          = UDim2.new(0, 8, 0, 50)
    scroll.BackgroundTransparency = 1
    scroll.BorderSizePixel   = 0
    scroll.ScrollBarThickness = 4
    scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
    scroll.CanvasSize        = UDim2.new(0, 0, 0, 0)
    scroll.ZIndex            = 6
    scroll.Parent            = panel
    local layout = Instance.new("UIListLayout")
    layout.Padding      = UDim.new(0, 4)
    layout.SortOrder    = Enum.SortOrder.LayoutOrder
    layout.Parent       = scroll

    local rows = {}

    local function refreshRows()
        for _, row in ipairs(rows) do
            local inList = list[string.lower(row.pName)] == true
            row.indicator.BackgroundColor3 = inList
                and Color3.fromRGB(40, 200, 80)
                or  Color3.fromRGB(160, 30, 30)
            row.checkLbl.Text = inList and "✓" or "✗"
        end
    end

    local playerList = Players:GetPlayers()
    for i, p in ipairs(playerList) do
        if p ~= LocalPlayer then
            local rowFrame = Instance.new("Frame")
            rowFrame.Size            = UDim2.new(1, 0, 0, 46)
            rowFrame.BackgroundColor3 = Color3.fromRGB(28, 28, 36)
            rowFrame.BorderSizePixel = 0
            rowFrame.LayoutOrder     = i
            rowFrame.ZIndex          = 7
            rowFrame.Parent          = scroll
            do local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, 8); c.Parent = rowFrame end

            local indicator = Instance.new("Frame")
            indicator.Size            = UDim2.new(0, 20, 0, 20)
            indicator.Position        = UDim2.new(0, 10, 0.5, -10)
            indicator.BorderSizePixel = 0
            indicator.ZIndex          = 8
            indicator.Parent          = rowFrame
            do local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0.5, 0); c.Parent = indicator end

            local checkLbl = Instance.new("TextLabel")
            checkLbl.Size              = UDim2.new(1, 0, 1, 0)
            checkLbl.BackgroundTransparency = 1
            checkLbl.TextColor3        = Color3.fromRGB(255, 255, 255)
            checkLbl.TextSize          = 12
            checkLbl.Font              = Enum.Font.GothamBold
            checkLbl.Text              = "✗"
            checkLbl.ZIndex            = 9
            checkLbl.Parent            = indicator

            local nameLbl = Instance.new("TextLabel")
            nameLbl.Size              = UDim2.new(1, -46, 1, 0)
            nameLbl.Position          = UDim2.new(0, 40, 0, 0)
            nameLbl.BackgroundTransparency = 1
            nameLbl.Text              = p.Name
            nameLbl.TextColor3        = Color3.fromRGB(215, 215, 215)
            nameLbl.Font              = Enum.Font.Gotham
            nameLbl.TextSize          = 14
            nameLbl.TextXAlignment    = Enum.TextXAlignment.Left
            nameLbl.ZIndex            = 8
            nameLbl.Parent            = rowFrame

            -- Tap to toggle
            local rowBtn = Instance.new("TextButton")
            rowBtn.Size              = UDim2.new(1, 0, 1, 0)
            rowBtn.BackgroundTransparency = 1
            rowBtn.Text              = ""
            rowBtn.ZIndex            = 10
            rowBtn.Parent            = rowFrame

            local pName = p.Name
            table.insert(rows, { pName = pName, indicator = indicator, checkLbl = checkLbl })

            local function toggle()
                local key = string.lower(pName)
                if list[key] then list[key] = nil else list[key] = true end
                refreshRows()
            end
            rowBtn.MouseButton1Click:Connect(toggle)
            rowBtn.TouchTap:Connect(toggle)
        end
    end

    -- Empty state
    if #rows == 0 then
        local emptyLbl = Instance.new("TextLabel")
        emptyLbl.Size              = UDim2.new(1, 0, 0, 60)
        emptyLbl.BackgroundTransparency = 1
        emptyLbl.Text              = "No other players in server."
        emptyLbl.TextColor3        = Color3.fromRGB(140, 140, 140)
        emptyLbl.Font              = Enum.Font.Gotham
        emptyLbl.TextSize          = 13
        emptyLbl.ZIndex            = 7
        emptyLbl.Parent            = scroll
    end

    refreshRows()

    -- Done button
    local doneBtn = Instance.new("TextButton")
    doneBtn.Size             = UDim2.new(0.55, 0, 0, 38)
    doneBtn.Position         = UDim2.new(0.225, 0, 1, -50)
    doneBtn.BackgroundColor3 = Color3.fromRGB(35, 120, 220)
    doneBtn.TextColor3       = Color3.fromRGB(255, 255, 255)
    doneBtn.Text             = "Done"
    doneBtn.Font             = Enum.Font.GothamBold
    doneBtn.TextSize         = 14
    doneBtn.ZIndex           = 6
    doneBtn.Parent           = panel
    do local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, 8); c.Parent = doneBtn end
    doneBtn.MouseButton1Click:Connect(function() gui:Destroy() end)
    doneBtn.TouchTap:Connect(function() gui:Destroy() end)
end

-- ============================================================
--  RAYFIELD UI
-- ============================================================
local Window = Rayfield:CreateWindow({
    Name                   = "Aimlock",
    Icon                   = 0,
    LoadingTitle           = "Aimlock",
    LoadingSubtitle        = "by your script",
    Theme                  = "Default",
    DisableRayfieldPrompts = false,
    DisableBuildWarnings   = false,
    KeySystem              = false,
    ConfigurationSaving    = {
        Enabled    = true,
        FolderName = "AimlockScript",
        FileName   = "Config",
    },
    Discord     = { Enabled = false },
    MenuKeybind = "RightControl",
})

-- ── MAIN ─────────────────────────────────────────────────────
local TMain = Window:CreateTab("Main", 4483362458)
TMain:CreateToggle({
    Name         = "Enable Aimlock",
    CurrentValue = S.aimlockEnabled,
    Flag         = "AimlockEnabled",
    Callback     = function(v) setAimlock(v) end,
})

-- ── TARGETING ────────────────────────────────────────────────
local TTarg = Window:CreateTab("Targeting", 4483362458)

TTarg:CreateSection("FOV & Range")
TTarg:CreateSlider({ Name = "FOV Radius (px)", Range = {10,800}, Increment = 5, Suffix = "px",
    CurrentValue = S.aimlockFOV, Flag = "AimlockFOV", Callback = function(v) S.aimlockFOV = v end })
TTarg:CreateSlider({ Name = "Max Range (studs)", Range = {50,5000}, Increment = 50, Suffix = " st",
    CurrentValue = S.aimlockRange, Flag = "AimlockRange", Callback = function(v) S.aimlockRange = v end })

TTarg:CreateSection("Checks")
TTarg:CreateToggle({ Name = "Team Check", CurrentValue = S.aimlockTeamCheck, Flag = "AimlockTeamCheck",
    Callback = function(v) S.aimlockTeamCheck = v end })
TTarg:CreateToggle({ Name = "Friend Check", CurrentValue = S.aimlockFriendCheck, Flag = "AimlockFriendCheck",
    Callback = function(v) S.aimlockFriendCheck = v end })
TTarg:CreateToggle({ Name = "Wall Check", CurrentValue = S.aimlockWallCheck, Flag = "AimlockWallCheck",
    Callback = function(v) S.aimlockWallCheck = v end })

TTarg:CreateSection("Target Part")
TTarg:CreateInput({ Name = "Aim Part  (e.g. Head, UpperTorso)", PlaceholderText = S.aimlockPart,
    RemoveTextAfterFocusLost = false, Flag = "AimlockPart",
    Callback = function(v) if v and v ~= "" then S.aimlockPart = v end end })

-- ── BEHAVIOUR ────────────────────────────────────────────────
local TBehav = Window:CreateTab("Behaviour", 4483362458)

TBehav:CreateSection("Lock Mode")
TBehav:CreateToggle({ Name = "Sticky Lock", CurrentValue = S.aimlockStickyLock, Flag = "AimlockStickyLock",
    Callback = function(v) S.aimlockStickyLock = v end })
TBehav:CreateToggle({ Name = "Hold-to-Aim", CurrentValue = S.aimlockHoldToAim, Flag = "AimlockHoldToAim",
    Callback = function(v) S.aimlockHoldToAim = v end })
TBehav:CreateToggle({ Name = "Cursor Mode", CurrentValue = S.aimlockCursorMode, Flag = "AimlockCursorMode",
    Callback = function(v) S.aimlockCursorMode = v end })
TBehav:CreateSlider({ Name = "Reacquire Delay (sec)", Range = {0,3}, Increment = 1, Suffix = "s",
    CurrentValue = S.aimlockReacquireDelay, Flag = "AimlockReacquireDelay",
    Callback = function(v) S.aimlockReacquireDelay = v end })

TBehav:CreateSection("Smoothing & Speed")
TBehav:CreateSlider({ Name = "Smoothing  (1=snap  20=slow glide)", Range = {1,20}, Increment = 1,
    CurrentValue = math.floor(S.aimlockSmoothing * 20 + 0.5), Flag = "AimlockSmoothing",
    Callback = function(v) S.aimlockSmoothing = v / 20 end })
TBehav:CreateSlider({ Name = "Max Deg Per Frame  (0 = no limit)", Range = {0,45}, Increment = 1, Suffix = "°",
    CurrentValue = S.aimlockMaxDegPerFrame, Flag = "AimlockMaxDeg",
    Callback = function(v) S.aimlockMaxDegPerFrame = v end })
TBehav:CreateSlider({ Name = "Humanizer  (pixel jitter, 0 = off)", Range = {0,40}, Increment = 1, Suffix = "px",
    CurrentValue = S.aimlockHumanize, Flag = "AimlockHumanize",
    Callback = function(v) S.aimlockHumanize = v end })
TBehav:CreateSlider({ Name = "Miss Chance", Range = {0,40}, Increment = 1, Suffix = "%",
    CurrentValue = S.aimlockMissChance, Flag = "AimlockMissChance",
    Callback = function(v) S.aimlockMissChance = v end })

TBehav:CreateSection("Switch Targets  (◄ ► on-screen buttons)")
TBehav:CreateToggle({ Name = "Enable Switch Targets", CurrentValue = S.switchTargetsEnabled,
    Flag = "SwitchTargets",
    Callback = function(v)
        S.switchTargetsEnabled = v
        if v then
            -- grab first target on enable
            local list = buildSwitchList()
            if #list > 0 then Aimlock.target = list[1] end
        end
    end })

TBehav:CreateSection("NPC & Players Mode  (PLR / NPC / ZMB / HUM buttons)")
TBehav:CreateToggle({ Name = "Enable NPC & Players Mode", CurrentValue = S.npcPlayerModeEnabled,
    Flag = "NPCPlayerMode",
    Callback = function(v)
        S.npcPlayerModeEnabled = v
        refreshModeButtons()
    end })

-- ── PREDICTION ───────────────────────────────────────────────
local TPred = Window:CreateTab("Prediction", 4483362458)

TPred:CreateSection("Smart AI Lead")
TPred:CreateToggle({ Name = "Smart AI", CurrentValue = S.aimlockSmartAI, Flag = "AimlockSmartAI",
    Callback = function(v) S.aimlockSmartAI = v end })
TPred:CreateSlider({ Name = "Predict Strength  (0=none  10=full)", Range = {0,10}, Increment = 1,
    CurrentValue = math.floor(S.aimlockPredictStrength * 10 + 0.5), Flag = "AimlockPredictStr",
    Callback = function(v) S.aimlockPredictStrength = v / 10 end })
TPred:CreateToggle({ Name = "Acceleration Prediction  (noisy)", CurrentValue = S.aimlockPredictAccel,
    Flag = "AimlockPredictAccel", Callback = function(v) S.aimlockPredictAccel = v end })

-- ── VISUALS ───────────────────────────────────────────────────
local TVis = Window:CreateTab("Visuals", 4483362458)

TVis:CreateSection("FOV Ring")
TVis:CreateToggle({ Name = "Show FOV Ring", CurrentValue = S.aimlockShowFOV, Flag = "AimlockShowFOV",
    Callback = function(v)
        S.aimlockShowFOV = v
        if Aimlock.fovCircle then Aimlock.fovCircle.Visible = v end
    end })
TVis:CreateSlider({ Name = "Ring Color — Red", Range = {0,255}, Increment = 5,
    CurrentValue = S.aimlockFOVColorR, Flag = "AimlockFOVR",
    Callback = function(v)
        S.aimlockFOVColorR = v
        if Aimlock.fovStroke then
            Aimlock.fovStroke.Color = Color3.fromRGB(S.aimlockFOVColorR, S.aimlockFOVColorG, S.aimlockFOVColorB)
        end
    end })
TVis:CreateSlider({ Name = "Ring Color — Green", Range = {0,255}, Increment = 5,
    CurrentValue = S.aimlockFOVColorG, Flag = "AimlockFOVG",
    Callback = function(v)
        S.aimlockFOVColorG = v
        if Aimlock.fovStroke then
            Aimlock.fovStroke.Color = Color3.fromRGB(S.aimlockFOVColorR, S.aimlockFOVColorG, S.aimlockFOVColorB)
        end
    end })
TVis:CreateSlider({ Name = "Ring Color — Blue", Range = {0,255}, Increment = 5,
    CurrentValue = S.aimlockFOVColorB, Flag = "AimlockFOVB",
    Callback = function(v)
        S.aimlockFOVColorB = v
        if Aimlock.fovStroke then
            Aimlock.fovStroke.Color = Color3.fromRGB(S.aimlockFOVColorR, S.aimlockFOVColorG, S.aimlockFOVColorB)
        end
    end })

TVis:CreateSection("Crosshair")
TVis:CreateInput({
    Name                    = "Crosshair X  (0.0 – 1.0, default 0.5)",
    PlaceholderText         = "0.5",
    RemoveTextAfterFocusLost = false,
    Flag                    = "CrosshairX",
    Callback                = function(v)
        local n = tonumber(v)
        if n then
            n = math.clamp(n, 0, 1)
            S.aimlockCrosshairPos = UDim2.new(n, 0, S.aimlockCrosshairPos.Y.Scale, 0)
        end
    end,
})
TVis:CreateInput({
    Name                    = "Crosshair Y  (0.0 – 1.0, default 0.5)",
    PlaceholderText         = "0.5",
    RemoveTextAfterFocusLost = false,
    Flag                    = "CrosshairY",
    Callback                = function(v)
        local n = tonumber(v)
        if n then
            n = math.clamp(n, 0, 1)
            S.aimlockCrosshairPos = UDim2.new(S.aimlockCrosshairPos.X.Scale, 0, n, 0)
        end
    end,
})
TVis:CreateSlider({
    Name         = "Crosshair Opacity  (0 = solid, 100 = invisible)",
    Range        = { 0, 100 },
    Increment    = 5,
    Suffix       = "%",
    CurrentValue = math.floor((S.aimlockCrosshairOpacity or 0) * 100),
    Flag         = "CrosshairOpacity",
    Callback     = function(v)
        S.aimlockCrosshairOpacity = v / 100
        if Aimlock.crosshairImg then
            Aimlock.crosshairImg.BackgroundTransparency = S.aimlockCrosshairOpacity
        end
    end,
})

-- ── LOCK LIST ────────────────────────────────────────────────
local TLL = Window:CreateTab("Lock List", 4483362458)

TLL:CreateSection("Priority Targets  (bypass friend check)")
TLL:CreateToggle({ Name = "Enable Lock List", CurrentValue = S.targetLockEnabled,
    Flag = "TargetLockEnabled", Callback = function(v) S.targetLockEnabled = v end })
TLL:CreateButton({ Name = "Open Lock List Picker  ›", Callback = function()
    openPlayerPicker("lock")
end })

TLL:CreateSection("Ignore List  (never targeted)")
TLL:CreateButton({ Name = "Open Ignore List Picker  ›", Callback = function()
    openPlayerPicker("ignore")
end })

-- ── SETTINGS ─────────────────────────────────────────────────
local TSet = Window:CreateTab("Settings", 4483362458)

TSet:CreateSection("Button Layout")
TSet:CreateButton({ Name = "Edit Layout  (drag buttons to reposition)", Callback = function()
    enterEditMode()
end })
TSet:CreateButton({ Name = "Reset Layout to Default", Callback = function()
    for _, entry in ipairs(buttonRegistry) do
        entry.obj.frame.Position = D[entry.sKey]
        S[entry.sKey]            = D[entry.sKey]
    end
end })
