--[[
    Aim.lua
    Aimlock script — Settings + Aimlock + NPC ESP.
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
    aimlockCrosshairShape     = "dot",      -- "dot" | "cross"
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
    targetLockList            = {},
    ignoreList                = {},
    -- ── Switch Targets ────────────────────────────────────
    switchTargetsEnabled      = false,
    -- ── Target Mode ───────────────────────────────────────
    targetPlayers             = true,
    targetNPCs                = false,
    -- ── NPC ESP (Drawing-based box) ───────────────────────
    espEnabled                = false,
    espDistance               = 500,        -- studs
    espBoxThickness           = 2,          -- pixels
    espBoxColorR              = 255,
    espBoxColorG              = 50,
    espBoxColorB              = 50,
    espNameTag                = true,       -- show name above box
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
}
local S = {}
for k, v in pairs(D) do S[k] = v end
S.targetLockList  = {}
S.ignoreList      = {}
S.aimlockPartChain = { "Head", "UpperTorso", "Torso", "HumanoidRootPart" }

-- ============================================================
--  NPC CACHE  (background-rebuilt every 0.5 s — never blocks rendering)
-- ============================================================
--  npcCache[model] = true  for every living non-player Humanoid model.
--  A task.spawn loop rebuilds the table in a separate coroutine every 0.5 s
--  so workspace:GetDescendants() never runs on the render thread.
--  Walking up the parent chain (not just obj.Parent) catches NPCs whose
--  Humanoid is nested more than one level inside their model.
-- ============================================================
local npcCache = {}      -- [Model] = true

local function rebuildNPCCache()
    local playerChars = {}
    for _, p in ipairs(Players:GetPlayers()) do
        if p.Character then playerChars[p.Character] = true end
    end
    local fresh = {}
    for _, obj in ipairs(workspace:GetDescendants()) do
        if obj:IsA("Humanoid") and obj.Health > 0 then
            -- Walk up to find the nearest Model ancestor (handles nested rigs)
            local model = obj.Parent
            while model and not model:IsA("Model") do
                model = model.Parent
            end
            if model and model ~= workspace and not playerChars[model] then
                fresh[model] = true
            end
        end
    end
    npcCache = fresh
end

rebuildNPCCache()   -- initial synchronous build at load time

-- Subsequent rebuilds run in a background coroutine every 0.5 s
task.spawn(function()
    while true do
        task.wait(0.5)
        rebuildNPCCache()
    end
end)

-- ============================================================
--  AIMLOCK STATE
-- ============================================================
local Aimlock = {
    target          = nil,
    targetLostAt    = 0,
    crosshairGui    = nil,
    crosshairDot    = nil,
    crosshairCrossH = nil,
    crosshairCrossV = nil,
    fovCircle       = nil,
    fovStroke       = nil,
    statusLabel     = nil,
    friendCache     = {},
    _holdActive     = false,
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

-- ── Entity helpers ────────────────────────────────────────────
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

-- ── Team helper ───────────────────────────────────────────────
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

-- ── Candidate list builder ─────────────────────────────────────
--  Reads from the event-driven npcCache — no GetDescendants() call.
--  Applies a squared-distance pre-filter on NPCs so only in-range
--  models ever reach the full validity check.
-- ──────────────────────────────────────────────────────────────
local function getCandidates()
    local list = {}
    if S.targetPlayers then
        for _, p in ipairs(Players:GetPlayers()) do
            table.insert(list, p)
        end
    end
    if S.targetNPCs then
        local _, hrp = getCharParts()
        if hrp then
            -- Pre-compute squared range once (avoids repeated multiplication)
            local range2 = S.aimlockRange * S.aimlockRange
            local hx, hy, hz = hrp.Position.X, hrp.Position.Y, hrp.Position.Z
            for model in pairs(npcCache) do
                -- Quick squared-distance check (no sqrt — cheapest possible filter)
                local root = model.PrimaryPart
                    or model:FindFirstChild("HumanoidRootPart")
                    or model:FindFirstChildWhichIsA("BasePart")
                if root then
                    local dx = root.Position.X - hx
                    local dy = root.Position.Y - hy
                    local dz = root.Position.Z - hz
                    if (dx*dx + dy*dy + dz*dz) <= range2 then
                        table.insert(list, model)
                    end
                end
            end
        else
            -- No HRP yet — include everything and let validity check handle it
            for model in pairs(npcCache) do
                table.insert(list, model)
            end
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
--  In-FOV targets (sorted by screen dist) come before out-FOV (sorted by world dist).
local function buildSwitchList()
    local _, hrp = getCharParts(); if not hrp then return {} end
    local cross = crosshairScreenPos()
    local fovR2  = S.aimlockFOV * S.aimlockFOV
    local inFov  = {}
    local outFov = {}
    for _, entity in ipairs(getCandidates()) do
        if isEntityValid(entity, false, cross) then
            local part = getEntityAimPart(entity)
            if part then
                local sp, onScreen = Camera:WorldToViewportPoint(part.Position)
                if onScreen and sp.Z > 0 then
                    local dx, dy = sp.X - cross.X, sp.Y - cross.Y
                    local screenD2 = dx * dx + dy * dy
                    if screenD2 <= fovR2 then
                        table.insert(inFov,  { entity = entity, dist = screenD2 })
                    else
                        table.insert(outFov, { entity = entity,
                            dist = (part.Position - hrp.Position).Magnitude })
                    end
                else
                    table.insert(outFov, { entity = entity,
                        dist = (part.Position - hrp.Position).Magnitude })
                end
            end
        end
    end
    table.sort(inFov,  function(a, b) return a.dist < b.dist end)
    table.sort(outFov, function(a, b) return a.dist < b.dist end)
    local result = {}
    for _, v in ipairs(inFov)  do table.insert(result, v.entity) end
    for _, v in ipairs(outFov) do table.insert(result, v.entity) end
    return result
end

local function switchTarget(dir)
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
--  BOX ESP  (Drawing API — zero GPU overhead vs Highlight)
-- ============================================================
--  espBoxes[model] = { sq = Drawing<Square>, lbl = Drawing<Text> }
--  Drawing objects are created once per NPC, reused every frame.
--  updateESPBoxes() is called from BindToRenderStep — no 0.5 s lag spikes.
--  clearAllESPBoxes() immediately hides & removes all drawings (instant off).
-- ============================================================
local espBoxes = {}

local function removeESPBox(model)
    local e = espBoxes[model]
    if not e then return end
    if e.sq  then pcall(function() e.sq:Remove()  end) end
    if e.lbl then pcall(function() e.lbl:Remove() end) end
    espBoxes[model] = nil
end

local function clearAllESPBoxes()
    for model in pairs(espBoxes) do
        removeESPBox(model)
    end
end

-- Called every frame from BindToRenderStep — pure 2D math, no Instance ops
local function updateESPBoxes()
    if not S.espEnabled then
        -- ESP off: hide everything and bail out immediately
        for _, e in pairs(espBoxes) do
            if e.sq  then e.sq.Visible  = false end
            if e.lbl then e.lbl.Visible = false end
        end
        return
    end

    local _, hrp = getCharParts()
    if not hrp then return end

    local range2  = S.espDistance * S.espDistance
    local hPos    = hrp.Position
    local boxCol  = Color3.fromRGB(S.espBoxColorR, S.espBoxColorG, S.espBoxColorB)
    local seenInCache = {}

    for model in pairs(npcCache) do
        seenInCache[model] = true

        -- Guard: model might have been destroyed between cache rebuilds
        if not model.Parent then
            removeESPBox(model)
        else
            local root = model.PrimaryPart
                or model:FindFirstChild("HumanoidRootPart")
                or model:FindFirstChildWhichIsA("BasePart")

            local hum = model:FindFirstChildWhichIsA("Humanoid")
            local alive = hum and hum.Health > 0

            if root and alive then
                local rPos = root.Position
                local dx, dy, dz = rPos.X - hPos.X, rPos.Y - hPos.Y, rPos.Z - hPos.Z
                local inRange = (dx*dx + dy*dy + dz*dz) <= range2

                if inRange then
                    -- Lazily create Drawing objects (no alloc cost every frame)
                    if not espBoxes[model] then
                        local sq  = Drawing.new("Square")
                        sq.Filled      = false
                        sq.Color       = boxCol
                        sq.Thickness   = S.espBoxThickness
                        sq.Transparency = 1
                        sq.Visible     = false

                        local lbl = Drawing.new("Text")
                        lbl.Text        = model.Name
                        lbl.Size        = 13
                        lbl.Center      = true
                        lbl.Outline     = true
                        lbl.Color       = boxCol
                        lbl.Transparency = 1
                        lbl.Visible     = false

                        espBoxes[model] = { sq = sq, lbl = lbl }
                    end

                    local e = espBoxes[model]

                    -- Project top (head) and bottom (feet) to screen
                    local headSP = Camera:WorldToViewportPoint(rPos + Vector3.new(0,  2.5, 0))
                    local feetSP = Camera:WorldToViewportPoint(rPos - Vector3.new(0,  3.0, 0))

                    if headSP.Z > 0 then   -- in front of camera
                        local topY  = math.min(headSP.Y, feetSP.Y)
                        local botY  = math.max(headSP.Y, feetSP.Y)
                        local boxH  = math.max(botY - topY, 4)
                        local boxW  = boxH * 0.45
                        local leftX = headSP.X - boxW * 0.5

                        e.sq.Size      = Vector2.new(boxW, boxH)
                        e.sq.Position  = Vector2.new(leftX, topY)
                        e.sq.Color     = boxCol
                        e.sq.Thickness = S.espBoxThickness
                        e.sq.Visible   = true

                        if e.lbl then
                            e.lbl.Position    = Vector2.new(headSP.X, topY - 15)
                            e.lbl.Color       = boxCol
                            e.lbl.Text        = model.Name
                            e.lbl.Visible     = S.espNameTag == true
                        end
                    else
                        e.sq.Visible = false
                        if e.lbl then e.lbl.Visible = false end
                    end
                else
                    -- Out of range — hide (keep object, skip Remove to avoid GC churn)
                    local e = espBoxes[model]
                    if e then
                        e.sq.Visible = false
                        if e.lbl then e.lbl.Visible = false end
                    end
                end
            else
                -- Dead or no root — hide
                local e = espBoxes[model]
                if e then
                    e.sq.Visible = false
                    if e.lbl then e.lbl.Visible = false end
                end
            end
        end
    end

    -- Remove Drawing objects for models that left the cache since last frame
    for model in pairs(espBoxes) do
        if not seenInCache[model] then
            removeESPBox(model)
        end
    end
end

-- ============================================================
--  CROSSHAIR GUI
-- ============================================================
local function syncCrosshairShape()
    local isCross = S.aimlockCrosshairShape == "cross"
    if Aimlock.crosshairDot    then Aimlock.crosshairDot.Visible    = not isCross end
    if Aimlock.crosshairCrossH then Aimlock.crosshairCrossH.Visible = isCross     end
    if Aimlock.crosshairCrossV then Aimlock.crosshairCrossV.Visible = isCross     end
end

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
    ds.Thickness = 2; ds.Color = Color3.fromRGB(255,255,255); ds.Transparency = 0.2; ds.Parent = dot
    Aimlock.crosshairDot = dot

    -- Crosshair cross — horizontal bar
    local crossH = Instance.new("Frame")
    crossH.Name               = "CrosshairCrossH"
    crossH.Size               = UDim2.new(0, 22, 0, 4)
    crossH.AnchorPoint        = Vector2.new(0.5, 0.5)
    crossH.Position           = S.aimlockCrosshairPos
    crossH.BackgroundColor3   = Color3.fromRGB(255, 40, 40)
    crossH.BackgroundTransparency = S.aimlockCrosshairOpacity or 0
    crossH.BorderSizePixel    = 0
    crossH.Parent             = sg
    local chS = Instance.new("UIStroke")
    chS.Thickness = 1.5; chS.Color = Color3.fromRGB(255,255,255); chS.Transparency = 0.25; chS.Parent = crossH
    Aimlock.crosshairCrossH = crossH

    -- Crosshair cross — vertical bar
    local crossV = Instance.new("Frame")
    crossV.Name               = "CrosshairCrossV"
    crossV.Size               = UDim2.new(0, 4, 0, 22)
    crossV.AnchorPoint        = Vector2.new(0.5, 0.5)
    crossV.Position           = S.aimlockCrosshairPos
    crossV.BackgroundColor3   = Color3.fromRGB(255, 40, 40)
    crossV.BackgroundTransparency = S.aimlockCrosshairOpacity or 0
    crossV.BorderSizePixel    = 0
    crossV.Parent             = sg
    local cvS = Instance.new("UIStroke")
    cvS.Thickness = 1.5; cvS.Color = Color3.fromRGB(255,255,255); cvS.Transparency = 0.25; cvS.Parent = crossV
    Aimlock.crosshairCrossV = crossV

    syncCrosshairShape()

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
    Aimlock.statusLabel  = lbl
end

local function destroyCrosshairGui()
    if Aimlock.crosshairGui then
        pcall(function() Aimlock.crosshairGui:Destroy() end)
        Aimlock.crosshairGui    = nil
        Aimlock.crosshairDot    = nil
        Aimlock.crosshairCrossH = nil
        Aimlock.crosshairCrossV = nil
        Aimlock.fovCircle       = nil
        Aimlock.fovStroke       = nil
        Aimlock.statusLabel     = nil
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
--  RENDER LOOP  (camera + crosshair sync)
-- ============================================================
RunService:BindToRenderStep("FlyAimlock", Enum.RenderPriority.Camera.Value + 2, function()
    -- Box ESP runs every frame regardless of aimlock state
    updateESPBoxes()

    if not S.aimlockEnabled then return end
    if S.aimlockHoldToAim and not Aimlock._holdActive then
        if Aimlock.statusLabel then Aimlock.statusLabel.Text = "" end
        return
    end

    -- Sync crosshair position & opacity
    local opacity = S.aimlockCrosshairOpacity or 0
    local pos     = S.aimlockCrosshairPos
    if Aimlock.crosshairDot then
        Aimlock.crosshairDot.Position           = pos
        Aimlock.crosshairDot.BackgroundTransparency = opacity
    end
    if Aimlock.crosshairCrossH then
        Aimlock.crosshairCrossH.Position           = pos
        Aimlock.crosshairCrossH.BackgroundTransparency = opacity
    end
    if Aimlock.crosshairCrossV then
        Aimlock.crosshairCrossV.Position           = pos
        Aimlock.crosshairCrossV.BackgroundTransparency = opacity
    end
    syncCrosshairShape()

    -- Sync FOV ring
    if Aimlock.fovCircle then
        Aimlock.fovCircle.Visible  = S.aimlockShowFOV == true
        Aimlock.fovCircle.Position = pos
        Aimlock.fovCircle.Size     = UDim2.new(0, S.aimlockFOV * 2, 0, S.aimlockFOV * 2)
        if Aimlock.fovStroke then
            Aimlock.fovStroke.Color = Color3.fromRGB(
                S.aimlockFOVColorR, S.aimlockFOVColorG, S.aimlockFOVColorB)
        end
    end
    if Aimlock.statusLabel then
        Aimlock.statusLabel.Position = UDim2.new(pos.X.Scale, 0, pos.Y.Scale, 28)
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

    -- Target acquisition
    if S.switchTargetsEnabled then
        if Aimlock.target and not isEntityAlive(Aimlock.target) then
            local list = buildSwitchList()
            Aimlock.target = #list > 0 and list[1] or nil
        end
        if not Aimlock.target then
            local list = buildSwitchList()
            Aimlock.target = #list > 0 and list[1] or nil
        end
    else
        local cur  = Aimlock.target
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
        local dotV   = math.clamp(Camera.CFrame.LookVector:Dot(newCF.LookVector), -1, 1)
        local angDeg = math.deg(math.acos(dotV))
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

local editActive     = false
local allButtons     = {}
local buttonRegistry = {}
local DRAG_THRESH    = 12

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
    icon.Size = UDim2.new(1,0,1,0); icon.BackgroundTransparency = 1
    icon.Image = ""; icon.ScaleType = Enum.ScaleType.Fit; icon.Parent = frame

    local lbl = Instance.new("TextLabel")
    lbl.Name = "Lbl"; lbl.Size = UDim2.new(1,0,1,0)
    lbl.BackgroundTransparency = 1; lbl.Text = labelText
    lbl.TextScaled = true; lbl.Font = Enum.Font.GothamBold
    lbl.TextColor3 = Color3.fromRGB(255,255,255)
    lbl.TextStrokeTransparency = 0.4; lbl.ZIndex = 2; lbl.Parent = frame

    local btn = Instance.new("TextButton")
    btn.Size = UDim2.new(1,0,1,0); btn.BackgroundTransparency = 1
    btn.Text = ""; btn.ZIndex = 5; btn.Parent = frame

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
        activeTouches[input] = { startPos = input.Position,
            startFramePos = frame.Position, dragging = false }
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
            local px = math.clamp(
                (pinchStartSize.X.Offset > 0 and pinchStartSize.X.Offset or 72) * scale, 48, 128)
            frame.Size = UDim2.new(0, px, 0, px)
            return
        end
        local delta = input.Position - info.startPos
        if not info.dragging and delta.Magnitude >= DRAG_THRESH and editActive then
            info.dragging = true; currentDragTouch = input
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
        if not S.aimlockEnabled and _G.__FlyScript_SetAimlock then
            _G.__FlyScript_SetAimlock(true) end
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

-- ── Target mode buttons (PLR / NPC) ───────────────────────────
local modeColors = { active = Color3.fromRGB(40,200,80), inactive = Color3.fromRGB(160,30,30) }
local modeBtnObjs = {}

local function refreshModeButtons()
    if modeBtnObjs["player"] then
        modeBtnObjs["player"].frame.BackgroundColor3 =
            S.targetPlayers and modeColors.active or modeColors.inactive
    end
    if modeBtnObjs["npc"] then
        modeBtnObjs["npc"].frame.BackgroundColor3 =
            S.targetNPCs and modeColors.active or modeColors.inactive
    end
end

local plrBtnObj = makeButton("ModeBtn_player", S.modeBtnPlayerPos, S.btnSize, "PLR",
    modeColors.active, function()
        S.targetPlayers = not S.targetPlayers; refreshModeButtons()
    end)
modeBtnObjs["player"] = plrBtnObj
plrBtnObj.frame.Visible = false
table.insert(buttonRegistry, { obj = plrBtnObj, sKey = "modeBtnPlayerPos" })

local npcBtnObj = makeButton("ModeBtn_npc", S.modeBtnNpcPos, S.btnSize, "NPC",
    modeColors.inactive, function()
        S.targetNPCs = not S.targetNPCs; refreshModeButtons()
    end)
modeBtnObjs["npc"] = npcBtnObj
npcBtnObj.frame.Visible = false
table.insert(buttonRegistry, { obj = npcBtnObj, sKey = "modeBtnNpcPos" })

refreshModeButtons()

-- ── Combined Heartbeat (button visibility only) ──────────────
RunService.Heartbeat:Connect(function()
    switchLeftBtnObj.frame.Visible  = S.switchTargetsEnabled
    switchRightBtnObj.frame.Visible = S.switchTargetsEnabled
    plrBtnObj.frame.Visible         = S._showModeBtns == true
    npcBtnObj.frame.Visible         = S._showModeBtns == true
    aimlockBtnObj.frame.Visible     = true
end)

-- ── Aimlock button icon hook ───────────────────────────────────
_G.__FlyScript_UpdateAimlockBtn = function()
    if not aimlockBtnObj then return end
    if S.aimlockEnabled then
        aimlockBtnObj.icon.Image             = S.aimlockOnImg or ""
        aimlockBtnObj.frame.BackgroundColor3 = Color3.fromRGB(40, 200, 80)
    else
        aimlockBtnObj.icon.Image             = S.aimlockOffImg or ""
        aimlockBtnObj.frame.BackgroundColor3 = Color3.fromRGB(40, 20, 20)
    end
end

-- ── Edit-layout mode ──────────────────────────────────────────
local function enterEditMode()
    if editActive then return end
    editActive = true

    local overlay = Instance.new("Frame")
    overlay.Size = UDim2.new(1,0,1,0); overlay.BackgroundTransparency = 1
    overlay.ZIndex = 20; overlay.Parent = SG

    local hint = Instance.new("TextLabel")
    hint.Size = UDim2.new(0.72,0,0.06,0); hint.Position = UDim2.new(0.14,0,0.04,0)
    hint.BackgroundColor3 = Color3.new(0,0,0); hint.BackgroundTransparency = 0.4
    hint.TextColor3 = Color3.new(1,1,1); hint.Text = "Drag to move  •  Pinch to resize"
    hint.TextScaled = true; hint.Font = Enum.Font.GothamSemibold
    hint.ZIndex = 21; hint.Parent = overlay
    do local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0.25,0); c.Parent = hint end

    local function makeCtrlBtn(label, xPos, bg, cb)
        local b = Instance.new("TextButton")
        b.Size = UDim2.new(0.22,0,0.055,0); b.Position = UDim2.new(xPos,0,0.91,0)
        b.BackgroundColor3 = bg; b.TextColor3 = Color3.new(1,1,1)
        b.Text = label; b.TextScaled = true; b.Font = Enum.Font.GothamBold
        b.ZIndex = 21; b.Parent = overlay
        do local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0.3,0); c.Parent = b end
        b.MouseButton1Click:Connect(cb); b.TouchTap:Connect(cb)
    end

    makeCtrlBtn("Save", 0.08, Color3.fromRGB(30,160,60), function()
        for _, entry in ipairs(buttonRegistry) do S[entry.sKey] = entry.obj.frame.Position end
        overlay:Destroy(); editActive = false
    end)
    makeCtrlBtn("Reset", 0.39, Color3.fromRGB(160,120,10), function()
        for _, entry in ipairs(buttonRegistry) do
            entry.obj.frame.Position = D[entry.sKey]; S[entry.sKey] = D[entry.sKey]
        end
        overlay:Destroy(); editActive = false
    end)
    makeCtrlBtn("Cancel", 0.70, Color3.fromRGB(175,30,30), function()
        overlay:Destroy(); editActive = false
    end)
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
    Name = "Enable Aimlock", CurrentValue = S.aimlockEnabled,
    Flag = "AimlockEnabled", Callback = function(v) setAimlock(v) end,
})

-- ── TARGETING ────────────────────────────────────────────────
local TTarg = Window:CreateTab("Targeting", 4483362458)
TTarg:CreateSection("FOV & Range")
TTarg:CreateSlider({ Name = "FOV Radius (px)", Range = {10,800}, Increment = 5, Suffix = "px",
    CurrentValue = S.aimlockFOV, Flag = "AimlockFOV",
    Callback = function(v) S.aimlockFOV = v end })
TTarg:CreateSlider({ Name = "Max Range (studs)", Range = {50,5000}, Increment = 50, Suffix = " st",
    CurrentValue = S.aimlockRange, Flag = "AimlockRange",
    Callback = function(v) S.aimlockRange = v end })
TTarg:CreateSection("Checks")
TTarg:CreateToggle({ Name = "Team Check", CurrentValue = S.aimlockTeamCheck, Flag = "AimlockTeamCheck",
    Callback = function(v) S.aimlockTeamCheck = v end })
TTarg:CreateToggle({ Name = "Friend Check", CurrentValue = S.aimlockFriendCheck, Flag = "AimlockFriendCheck",
    Callback = function(v) S.aimlockFriendCheck = v end })
TTarg:CreateToggle({ Name = "Wall Check", CurrentValue = S.aimlockWallCheck, Flag = "AimlockWallCheck",
    Callback = function(v) S.aimlockWallCheck = v end })
TTarg:CreateSection("Target Part")
TTarg:CreateInput({ Name = "Aim Part  (e.g. Head, UpperTorso)",
    PlaceholderText = S.aimlockPart, RemoveTextAfterFocusLost = false, Flag = "AimlockPart",
    Callback = function(v) if v and v ~= "" then S.aimlockPart = v end end })

-- ── BEHAVIOUR ────────────────────────────────────────────────
local TBehav = Window:CreateTab("Behaviour", 4483362458)
TBehav:CreateSection("Lock Mode")
TBehav:CreateToggle({ Name = "Sticky Lock", CurrentValue = S.aimlockStickyLock,
    Flag = "AimlockStickyLock", Callback = function(v) S.aimlockStickyLock = v end })
TBehav:CreateToggle({ Name = "Hold-to-Aim", CurrentValue = S.aimlockHoldToAim,
    Flag = "AimlockHoldToAim", Callback = function(v) S.aimlockHoldToAim = v end })
TBehav:CreateToggle({ Name = "Cursor Mode", CurrentValue = S.aimlockCursorMode,
    Flag = "AimlockCursorMode", Callback = function(v) S.aimlockCursorMode = v end })
TBehav:CreateSlider({ Name = "Reacquire Delay (sec)", Range = {0,3}, Increment = 1, Suffix = "s",
    CurrentValue = S.aimlockReacquireDelay, Flag = "AimlockReacquireDelay",
    Callback = function(v) S.aimlockReacquireDelay = v end })
TBehav:CreateSection("Smoothing & Speed")
TBehav:CreateSlider({ Name = "Smoothing  (1=snap  20=slow glide)", Range = {1,20}, Increment = 1,
    CurrentValue = math.floor(S.aimlockSmoothing * 20 + 0.5), Flag = "AimlockSmoothing",
    Callback = function(v) S.aimlockSmoothing = v / 20 end })
TBehav:CreateSlider({ Name = "Max Deg Per Frame  (0 = no limit)", Range = {0,45}, Increment = 1,
    Suffix = "°", CurrentValue = S.aimlockMaxDegPerFrame, Flag = "AimlockMaxDeg",
    Callback = function(v) S.aimlockMaxDegPerFrame = v end })
TBehav:CreateSlider({ Name = "Humanizer  (pixel jitter, 0 = off)", Range = {0,40}, Increment = 1,
    Suffix = "px", CurrentValue = S.aimlockHumanize, Flag = "AimlockHumanize",
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
            local list = buildSwitchList()
            if #list > 0 then Aimlock.target = list[1] end
        end
    end })
TBehav:CreateSection("Target Mode  (PLR / NPC on-screen buttons)")
TBehav:CreateToggle({ Name = "Show Target Mode Buttons", CurrentValue = false,
    Flag = "ShowModeBtns",
    Callback = function(v) S._showModeBtns = v; refreshModeButtons() end })
TBehav:CreateToggle({ Name = "Target Players", CurrentValue = S.targetPlayers,
    Flag = "TargetPlayers",
    Callback = function(v) S.targetPlayers = v; refreshModeButtons() end })
TBehav:CreateToggle({ Name = "Target NPCs  (all humanoid models)", CurrentValue = S.targetNPCs,
    Flag = "TargetNPCs",
    Callback = function(v) S.targetNPCs = v; refreshModeButtons() end })

-- ── PREDICTION ───────────────────────────────────────────────
local TPred = Window:CreateTab("Prediction", 4483362458)
TPred:CreateSection("Smart AI Lead")
TPred:CreateToggle({ Name = "Smart AI", CurrentValue = S.aimlockSmartAI,
    Flag = "AimlockSmartAI", Callback = function(v) S.aimlockSmartAI = v end })
TPred:CreateSlider({ Name = "Predict Strength  (0=none  10=full)", Range = {0,10}, Increment = 1,
    CurrentValue = math.floor(S.aimlockPredictStrength * 10 + 0.5), Flag = "AimlockPredictStr",
    Callback = function(v) S.aimlockPredictStrength = v / 10 end })
TPred:CreateToggle({ Name = "Acceleration Prediction  (noisy)",
    CurrentValue = S.aimlockPredictAccel, Flag = "AimlockPredictAccel",
    Callback = function(v) S.aimlockPredictAccel = v end })

-- ── VISUALS ───────────────────────────────────────────────────
local TVis = Window:CreateTab("Visuals", 4483362458)
TVis:CreateSection("FOV Ring")
TVis:CreateToggle({ Name = "Show FOV Ring", CurrentValue = S.aimlockShowFOV,
    Flag = "AimlockShowFOV",
    Callback = function(v)
        S.aimlockShowFOV = v
        if Aimlock.fovCircle then Aimlock.fovCircle.Visible = v end
    end })
TVis:CreateSlider({ Name = "Ring Color — Red", Range = {0,255}, Increment = 5,
    CurrentValue = S.aimlockFOVColorR, Flag = "AimlockFOVR",
    Callback = function(v)
        S.aimlockFOVColorR = v
        if Aimlock.fovStroke then Aimlock.fovStroke.Color =
            Color3.fromRGB(S.aimlockFOVColorR, S.aimlockFOVColorG, S.aimlockFOVColorB) end
    end })
TVis:CreateSlider({ Name = "Ring Color — Green", Range = {0,255}, Increment = 5,
    CurrentValue = S.aimlockFOVColorG, Flag = "AimlockFOVG",
    Callback = function(v)
        S.aimlockFOVColorG = v
        if Aimlock.fovStroke then Aimlock.fovStroke.Color =
            Color3.fromRGB(S.aimlockFOVColorR, S.aimlockFOVColorG, S.aimlockFOVColorB) end
    end })
TVis:CreateSlider({ Name = "Ring Color — Blue", Range = {0,255}, Increment = 5,
    CurrentValue = S.aimlockFOVColorB, Flag = "AimlockFOVB",
    Callback = function(v)
        S.aimlockFOVColorB = v
        if Aimlock.fovStroke then Aimlock.fovStroke.Color =
            Color3.fromRGB(S.aimlockFOVColorR, S.aimlockFOVColorG, S.aimlockFOVColorB) end
    end })
TVis:CreateSection("Crosshair")
TVis:CreateToggle({ Name = "Cross Crosshair  (replaces dot with + shape)",
    CurrentValue = S.aimlockCrosshairShape == "cross", Flag = "CrosshairCross",
    Callback = function(v)
        S.aimlockCrosshairShape = v and "cross" or "dot"
        syncCrosshairShape()
    end })
TVis:CreateInput({ Name = "Crosshair X  (0.0 – 1.0, default 0.5)",
    PlaceholderText = "0.5", RemoveTextAfterFocusLost = false, Flag = "CrosshairX",
    Callback = function(v)
        local n = tonumber(v)
        if n then
            n = math.clamp(n, 0, 1)
            S.aimlockCrosshairPos = UDim2.new(n, 0, S.aimlockCrosshairPos.Y.Scale, 0)
        end
    end })
TVis:CreateInput({ Name = "Crosshair Y  (0.0 – 1.0, default 0.5)",
    PlaceholderText = "0.5", RemoveTextAfterFocusLost = false, Flag = "CrosshairY",
    Callback = function(v)
        local n = tonumber(v)
        if n then
            n = math.clamp(n, 0, 1)
            S.aimlockCrosshairPos = UDim2.new(S.aimlockCrosshairPos.X.Scale, 0, n, 0)
        end
    end })
TVis:CreateSlider({ Name = "Crosshair Opacity  (0 = solid, 100 = invisible)",
    Range = {0,100}, Increment = 5, Suffix = "%",
    CurrentValue = math.floor((S.aimlockCrosshairOpacity or 0) * 100),
    Flag = "CrosshairOpacity",
    Callback = function(v)
        S.aimlockCrosshairOpacity = v / 100
        local t = v / 100
        if Aimlock.crosshairDot    then Aimlock.crosshairDot.BackgroundTransparency    = t end
        if Aimlock.crosshairCrossH then Aimlock.crosshairCrossH.BackgroundTransparency = t end
        if Aimlock.crosshairCrossV then Aimlock.crosshairCrossV.BackgroundTransparency = t end
    end })

-- ── NPC ESP ───────────────────────────────────────────────────
local TESP = Window:CreateTab("NPC ESP", 4483362458)

TESP:CreateSection("Settings")
TESP:CreateToggle({ Name = "Enable NPC ESP", CurrentValue = S.espEnabled,
    Flag = "ESPEnabled",
    Callback = function(v)
        S.espEnabled = v
        -- Immediately destroy all Drawing objects when turning off
        if not v then clearAllESPBoxes() end
    end })

TESP:CreateSlider({ Name = "Distance  (studs)", Range = {50, 2000},
    Increment = 50, Suffix = " st", CurrentValue = S.espDistance,
    Flag = "ESPDistance",
    Callback = function(v) S.espDistance = v end })

TESP:CreateSlider({ Name = "Box Thickness  (px)", Range = {1, 5}, Increment = 1,
    CurrentValue = S.espBoxThickness, Flag = "ESPBoxThickness",
    Callback = function(v)
        S.espBoxThickness = v
        for _, e in pairs(espBoxes) do
            if e.sq then e.sq.Thickness = v end
        end
    end })

TESP:CreateToggle({ Name = "Show Name Tag", CurrentValue = S.espNameTag,
    Flag = "ESPNameTag",
    Callback = function(v)
        S.espNameTag = v
        if not v then
            for _, e in pairs(espBoxes) do
                if e.lbl then e.lbl.Visible = false end
            end
        end
    end })

TESP:CreateSection("Box Color")
TESP:CreateSlider({ Name = "Box Color — Red", Range = {0, 255}, Increment = 5,
    CurrentValue = S.espBoxColorR, Flag = "ESPBoxR",
    Callback = function(v) S.espBoxColorR = v end })
TESP:CreateSlider({ Name = "Box Color — Green", Range = {0, 255}, Increment = 5,
    CurrentValue = S.espBoxColorG, Flag = "ESPBoxG",
    Callback = function(v) S.espBoxColorG = v end })
TESP:CreateSlider({ Name = "Box Color — Blue", Range = {0, 255}, Increment = 5,
    CurrentValue = S.espBoxColorB, Flag = "ESPBoxB",
    Callback = function(v) S.espBoxColorB = v end })

-- ── LOCK LIST ────────────────────────────────────────────────
local TLL = Window:CreateTab("Lock List", 4483362458)
TLL:CreateSection("Priority Targets  (bypass friend check)")
TLL:CreateToggle({ Name = "Enable Lock List", CurrentValue = S.targetLockEnabled,
    Flag = "TargetLockEnabled", Callback = function(v) S.targetLockEnabled = v end })

local lockDropdown = TLL:CreateDropdown({
    Name = "Lock List  (select to add, deselect to remove)",
    Options = {}, CurrentOption = {}, MultipleOptions = true, Flag = "LockListDropdown",
    Callback = function(selectedNames)
        S.targetLockList = {}
        for _, name in ipairs(selectedNames) do
            S.targetLockList[string.lower(name)] = true
        end
    end,
})

TLL:CreateSection("Ignore List  (never targeted)")

local ignoreDropdown = TLL:CreateDropdown({
    Name = "Ignore List  (select to add, deselect to remove)",
    Options = {}, CurrentOption = {}, MultipleOptions = true, Flag = "IgnoreListDropdown",
    Callback = function(selectedNames)
        S.ignoreList = {}
        for _, name in ipairs(selectedNames) do
            S.ignoreList[string.lower(name)] = true
        end
    end,
})

local function refreshListDropdowns()
    local names = {}
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= LocalPlayer then table.insert(names, p.Name) end
    end
    pcall(function() lockDropdown:Refresh(names, {}) end)
    pcall(function() ignoreDropdown:Refresh(names, {}) end)
end
Players.PlayerAdded:Connect(refreshListDropdowns)
Players.PlayerRemoving:Connect(function()
    task.wait(0.1); refreshListDropdowns()
end)
refreshListDropdowns()

-- ── SETTINGS ─────────────────────────────────────────────────
local TSet = Window:CreateTab("Settings", 4483362458)
TSet:CreateSection("Button Layout")
TSet:CreateButton({ Name = "Edit Layout  (drag buttons to reposition)",
    Callback = function() enterEditMode() end })
TSet:CreateButton({ Name = "Reset Layout to Default", Callback = function()
    for _, entry in ipairs(buttonRegistry) do
        entry.obj.frame.Position = D[entry.sKey]; S[entry.sKey] = D[entry.sKey]
    end
end })
