--[[
    Aim.lua
    Aimlock-only script — Settings + Aimlock section preserved.
    All other fly/boost/sound/FX/UI systems removed.
]]

-- ============================================================
--  SERVICES
-- ============================================================
local Rayfield         = loadstring(game:HttpGet("https://sirius.menu/rayfield"))()
local Players          = game:GetService("Players")
local RunService       = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
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
    -- ── Aimlock ───────────────────────────────────────────
    aimlockEnabled            = false,
    aimlockFOV                = 200,   -- screen-space pixel radius the lock can grab targets in
    aimlockRange              = 1000,  -- max world distance to consider a target
    aimlockTeamCheck          = true,
    aimlockFriendCheck        = true,  -- skip Roblox friends (bypassed for Lock-List players)
    aimlockWallCheck          = true,
    aimlockShowFOV            = true,  -- draw the FOV circle on screen when aimlock is on
    aimlockPart               = "Head",-- target part name
    aimlockCrosshairPos       = UDim2.new(0.5, 0, 0.5, 0),
    aimlockKey                = Enum.KeyCode.P,
    aimlockBtnPos             = UDim2.new(0.34, 0, 0.80, 0),
    -- Sticky lock: once a target is acquired, KEEP locking them until aimlock
    -- is turned off OR they die. Ignores anyone else, even closer to crosshair.
    aimlockStickyLock         = true,
    -- Smart AI: predicts target position from their velocity so a moving
    -- player isn't behind your reticle. Strength 0 = no lead, 1 = full lead.
    aimlockSmartAI            = true,
    aimlockPredictStrength    = 1.0,
    -- Smoothing: 1 = instant snap, 0.05 = very gentle / human-like camera glide.
    aimlockSmoothing          = 0.55,
    -- Max degrees the camera can rotate per frame (anti-snap; 0 disables limit).
    aimlockMaxDegPerFrame     = 0,
    -- Auto-reacquire if Sticky lock loses sight (wall/out of range) for N seconds.
    aimlockReacquireDelay     = 0.6,
    -- CURSOR MODE — when on, target lands exactly at the crosshair pixel
    -- (camera rotates so the target is under the cursor, not center). When
    -- off, the camera centers the target like classic aimbots.
    aimlockCursorMode         = true,
    -- Hold-to-aim — when on, aimlock only engages while the keybind is held
    -- (or the on-screen button is being touched). Off = toggle behavior.
    aimlockHoldToAim          = false,
    -- Body-part priority chain. First valid one is used.
    aimlockPartChain          = { "Head", "UpperTorso", "Torso", "HumanoidRootPart" },
    -- Humanizer — random small pixel offset added to the aim each frame so the
    -- aim doesn't look mechanically perfect (0 = robot precision).
    aimlockHumanize           = 0,        -- pixels of random jitter (default off — was causing visible aim shake)
    -- Acceleration prediction — adds a half-a²t² term using cached velocity diff.
    aimlockPredictAccel       = false,    -- default off — noisy accel readings amplify shake
    -- Hit-chance — ignore aiming on this percentage of frames (anti-detection).
    aimlockMissChance         = 0,        -- 0..40 %
    -- FOV ring color
    aimlockFOVColorR          = 255,
    aimlockFOVColorG          = 60,
    aimlockFOVColorB          = 60,
    -- Target Lock (priority list: targets listed here are preferred over anyone else inside the FOV,
    -- even if friend-check is on)
    targetLockEnabled         = false,
    targetLockList            = {},  -- map of [lowercase player name] = true
    -- Customisable image IDs
    aimlockCrosshairImg       = "rbxassetid://107058246184363",
    aimlockOffImg             = "rbxassetid://124959989742325",
    aimlockOnImg              = "rbxassetid://119279898696244",
    -- Button size
    btnSize                   = UDim2.new(0, 72, 0, 72),
}
local S = {}
for k, v in pairs(D) do S[k] = v end

-- ============================================================
--  AIMLOCK
--  Finds the closest visible player whose world-projected part
--  is within S.aimlockFOV pixels of the crosshair and snaps the
--  camera to look at their target part each frame. Honours team
--  check and wall check options, and respects S.aimlockRange
--  world dist.
--
--  Toggle:
--    PC      → S.aimlockKey (default P)
--    Mobile  → on-screen "Aimlock" button (created below)
-- ============================================================
local Aimlock = {
    target           = nil,      -- the currently locked Player
    targetLostAt     = 0,        -- tick() when target became unreachable; used by reacquire delay
    crosshairGui     = nil,
    crosshairImg     = nil,
    fovCircle        = nil,      -- ImageLabel showing the FOV ring
    fovStroke        = nil,
    statusLabel      = nil,      -- "Locked: Name" small HUD line under crosshair
    friendCache      = {},       -- [userId] = bool
    _holdActive      = false,    -- true while user holds key/button in Hold-to-Aim mode
}

local function isFriend(plr)
    if not plr or plr == LocalPlayer then return false end
    local cached = Aimlock.friendCache[plr.UserId]
    if cached ~= nil then return cached end
    local ok, res = pcall(function() return LocalPlayer:IsFriendsWith(plr.UserId) end)
    if ok then
        Aimlock.friendCache[plr.UserId] = res
        return res
    end
    return false
end
Players.PlayerRemoving:Connect(function(p) Aimlock.friendCache[p.UserId] = nil end)

-- True if `plr` appears in the user's Lock List. Listed players bypass the
-- friend check (per spec) but still respect wall/team checks unless overridden.
local function isOnLockList(plr)
    if not plr then return false end
    return S.targetLockList[string.lower(plr.Name)] == true
end

local function getAimPart(plr)
    local char = plr.Character
    if not char then return nil end
    -- Try the user-specified part first, then walk the priority chain.
    if S.aimlockPart and S.aimlockPart ~= "" then
        local p = char:FindFirstChild(S.aimlockPart)
        if p and p:IsA("BasePart") then return p end
    end
    for _, name in ipairs(S.aimlockPartChain or {"Head","HumanoidRootPart"}) do
        local p = char:FindFirstChild(name)
        if p and p:IsA("BasePart") then return p end
    end
    return char:FindFirstChildWhichIsA("BasePart")
end

local function isAlive(plr)
    local char = plr.Character
    if not char then return false end
    local hum = char:FindFirstChildWhichIsA("Humanoid")
    return hum and hum.Health > 0
end

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
    local vp = Camera.ViewportSize
    local pos = S.aimlockCrosshairPos or UDim2.new(0.5, 0, 0.5, 0)
    return Vector2.new(
        pos.X.Scale * vp.X + pos.X.Offset,
        pos.Y.Scale * vp.Y + pos.Y.Offset
    )
end

-- Per-target velocity cache used to estimate acceleration between frames.
local _velCache = {}   -- [Player] = { v = Vector3, t = tick() }
Players.PlayerRemoving:Connect(function(p) _velCache[p] = nil end)

-- Predicted aim point for `plr` — Smart-AI lead based on velocity (and, if
-- enabled, acceleration) plus a nominal projectile travel-time. Falls back
-- to raw position when Smart AI is off.
local function predictedAimPoint(plr, hrp)
    local part = getAimPart(plr)
    if not part then return nil end
    if not S.aimlockSmartAI then return part.Position, part end
    local v   = part.AssemblyLinearVelocity
    local now = tick()
    local accel = Vector3.zero
    local cache = _velCache[plr]
    if cache then
        local dt = math.max(now - cache.t, 1e-3)
        accel = (v - cache.v) / dt
        -- clamp absurd accel from physics glitches
        if accel.Magnitude > 500 then accel = accel.Unit * 500 end
    end
    _velCache[plr] = { v = v, t = now }
    if v.Magnitude < 0.5 and accel.Magnitude < 0.5 then return part.Position, part end
    local dist  = (part.Position - (hrp and hrp.Position or Camera.CFrame.Position)).Magnitude
    local leadT = math.clamp(dist / 1000, 0, 1.5) * (S.aimlockPredictStrength or 1)
    local lead  = v * leadT
    if S.aimlockPredictAccel then
        lead = lead + accel * (0.5 * leadT * leadT)
    end
    return part.Position + lead, part
end

-- Helper extracted so isValidTarget reads clean
function p_team_eq(plr)
    return plr.Team and LocalPlayer.Team and plr.Team == LocalPlayer.Team
end

-- Returns true if `plr` is a valid (alive, in-range, not blocked, allowed by checks) target.
-- `requireInFOV` — if true, also require the player to be inside the screen FOV ring.
local function isValidTarget(plr, requireInFOV, cross)
    if not plr or plr == LocalPlayer then return false end
    if not isAlive(plr) then return false end
    local part = getAimPart(plr); if not part then return false end
    local _, hrp = getCharParts(); if not hrp then return false end
    if (part.Position - hrp.Position).Magnitude > S.aimlockRange then return false end
    if wallBlocked(hrp.Position, part) then return false end
    -- Lock-list bypasses friend check; team check still respected unless we
    -- decide otherwise. Here we let listed players bypass team check too —
    -- otherwise the list is half-useless in team games.
    local listed = isOnLockList(plr)
    if not listed then
        if S.aimlockTeamCheck and p_team_eq(plr) then return false end
        if S.aimlockFriendCheck and isFriend(plr) then return false end
    end
    if requireInFOV and cross then
        local sp, on = Camera:WorldToViewportPoint(part.Position)
        if not on or sp.Z <= 0 then return false end
        local dx, dy = sp.X - cross.X, sp.Y - cross.Y
        if (dx*dx + dy*dy) > (S.aimlockFOV * S.aimlockFOV) then return false end
    end
    return true
end

-- Acquire a NEW target from the FOV ring. Lock-list players are preferred.
local function acquireTarget()
    local _, hrp = getCharParts(); if not hrp then return nil end
    local cross = crosshairScreenPos()
    local bestListed, bestListedDist = nil, math.huge
    local bestAny,    bestAnyDist    = nil, math.huge
    for _, p in ipairs(Players:GetPlayers()) do
        if isValidTarget(p, true, cross) then
            local part = getAimPart(p)
            local sp = Camera:WorldToViewportPoint(part.Position)
            local dx, dy = sp.X - cross.X, sp.Y - cross.Y
            local pixD2 = dx*dx + dy*dy
            if isOnLockList(p) then
                if pixD2 < bestListedDist then bestListedDist, bestListed = pixD2, p end
            else
                if pixD2 < bestAnyDist then bestAnyDist, bestAny = pixD2, p end
            end
        end
    end
    return bestListed or bestAny
end

-- Crosshair GUI — visible while aimlock is enabled.
local function makeCrosshairGui()
    if Aimlock.crosshairGui then return end
    local sg = Instance.new("ScreenGui")
    sg.Name           = "FlyScriptAimlockCrosshair"
    sg.ResetOnSpawn   = false
    sg.IgnoreGuiInset = true
    sg.Parent         = LocalPlayer:WaitForChild("PlayerGui")

    -- FOV RING — drawn as a Frame + UIStroke so it's GUARANTEED to render on
    -- every device (mobile included) without depending on an asset id load.
    local ring = Instance.new("Frame")
    ring.Name              = "FOVRing"
    ring.AnchorPoint       = Vector2.new(0.5, 0.5)
    ring.Position          = S.aimlockCrosshairPos
    ring.Size              = UDim2.new(0, S.aimlockFOV * 2, 0, S.aimlockFOV * 2)
    ring.BackgroundTransparency = 1
    ring.BorderSizePixel   = 0
    ring.Visible           = S.aimlockShowFOV == true
    ring.Parent            = sg
    local ringCorner = Instance.new("UICorner")
    ringCorner.CornerRadius = UDim.new(0.5, 0); ringCorner.Parent = ring
    local ringStroke = Instance.new("UIStroke")
    ringStroke.Name        = "Stroke"
    ringStroke.Thickness   = 2
    ringStroke.Color       = Color3.fromRGB(S.aimlockFOVColorR or 255, S.aimlockFOVColorG or 60, S.aimlockFOVColorB or 60)
    ringStroke.Transparency= 0.15
    ringStroke.Parent      = ring
    Aimlock.fovCircle = ring
    Aimlock.fovStroke = ringStroke

    -- CROSSHAIR DOT — solid red circle drawn as a Frame+UICorner. No asset
    -- needed; visible on every device. Editable via the X/Y position sliders.
    local img = Instance.new("Frame")
    img.Name               = "CrosshairDot"
    img.Size               = UDim2.new(0, 14, 0, 14)
    img.AnchorPoint        = Vector2.new(0.5, 0.5)
    img.Position           = S.aimlockCrosshairPos
    img.BackgroundColor3   = Color3.fromRGB(255, 40, 40)
    img.BackgroundTransparency = 0
    img.BorderSizePixel    = 0
    img.Parent             = sg
    local dotCorner = Instance.new("UICorner")
    dotCorner.CornerRadius = UDim.new(0.5, 0); dotCorner.Parent = img
    local dotStroke = Instance.new("UIStroke")
    dotStroke.Thickness    = 2
    dotStroke.Color        = Color3.fromRGB(255, 255, 255)
    dotStroke.Transparency = 0.2
    dotStroke.Parent       = img

    -- Tiny status line just under the crosshair
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
    Aimlock.crosshairImg = img
    Aimlock.statusLabel  = lbl
end

local function destroyCrosshairGui()
    if Aimlock.crosshairGui then
        pcall(function() Aimlock.crosshairGui:Destroy() end)
        Aimlock.crosshairGui = nil
        Aimlock.crosshairImg = nil
        Aimlock.fovCircle    = nil
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

-- Per-frame: keep the camera looking at the target's aim part, with smoothing
-- and Smart-AI lead. Sticky lock keeps the same target until they die or
-- become unreachable for `aimlockReacquireDelay` seconds.
RunService:BindToRenderStep("FlyAimlock", Enum.RenderPriority.Camera.Value + 2, function()
    if not S.aimlockEnabled then return end

    -- Hold-to-aim: bail out if the toggle is on but the user isn't actually
    -- holding the keybind / mobile button this frame.
    if S.aimlockHoldToAim and not Aimlock._holdActive then
        if Aimlock.statusLabel then Aimlock.statusLabel.Text = "" end
        return
    end

    -- Live-update GUI from settings
    if Aimlock.crosshairImg then
        Aimlock.crosshairImg.Position = S.aimlockCrosshairPos
    end
    if Aimlock.fovCircle then
        Aimlock.fovCircle.Visible  = S.aimlockShowFOV == true
        Aimlock.fovCircle.Position = S.aimlockCrosshairPos
        Aimlock.fovCircle.Size     = UDim2.new(0, S.aimlockFOV * 2, 0, S.aimlockFOV * 2)
        if Aimlock.fovStroke then
            Aimlock.fovStroke.Color = Color3.fromRGB(
                S.aimlockFOVColorR or 255, S.aimlockFOVColorG or 60, S.aimlockFOVColorB or 60)
        end
    end
    if Aimlock.statusLabel then
        Aimlock.statusLabel.Position = UDim2.new(S.aimlockCrosshairPos.X.Scale, 0,
                                                 S.aimlockCrosshairPos.Y.Scale, 28)
    end

    -- Miss-chance: skip the camera adjustment on N% of frames so the aim
    -- doesn't look like 100% pixel-perfect superhuman tracking.
    local missPct = math.clamp(S.aimlockMissChance or 0, 0, 90)
    if missPct > 0 and math.random(1, 100) <= missPct then return end

    local _, hrp = getCharParts()
    if not hrp then return end
    local cross = crosshairScreenPos()
    -- Apply humanizer jitter to the effective crosshair position
    local hum = math.max(0, S.aimlockHumanize or 0)
    if hum > 0 then
        cross = Vector2.new(
            cross.X + (math.random() - 0.5) * 2 * hum,
            cross.Y + (math.random() - 0.5) * 2 * hum)
    end

    -- Sticky lock validation
    local cur = Aimlock.target
    local keep = false
    if cur and S.aimlockStickyLock then
        if isValidTarget(cur, false, cross) then
            keep = true
            Aimlock.targetLostAt = 0
        else
            -- Brief grace period so wall-flicker doesn't drop the lock instantly.
            if Aimlock.targetLostAt == 0 then Aimlock.targetLostAt = tick() end
            if (tick() - Aimlock.targetLostAt) < (S.aimlockReacquireDelay or 0.6)
            and cur and cur.Parent and isAlive(cur) then
                keep = true   -- hold the lock briefly while we wait
            else
                Aimlock.target = nil
                Aimlock.targetLostAt = 0
            end
        end
    end

    -- Acquire if nothing held
    if not keep or not Aimlock.target then
        Aimlock.target = acquireTarget()
        Aimlock.targetLostAt = 0
    end

    local t = Aimlock.target
    if not t then
        if Aimlock.statusLabel then Aimlock.statusLabel.Text = "" end
        return
    end

    -- Predict where to aim
    local aimPos = predictedAimPoint(t, hrp)
    if not aimPos then
        if Aimlock.statusLabel then Aimlock.statusLabel.Text = "" end
        return
    end

    -- ── CROSSHAIR-AWARE AIMING (always on) ──
    -- Build a camera CFrame such that `aimPos` projects to the CROSSHAIR
    -- pixel (not screen center). Compute the angular offset from screen
    -- center to the crosshair, build a "look at" CFrame, then rotate it
    -- so the target shifts off-center to land under the crosshair / FOV ring.
    -- Drives directly off S.aimlockCrosshairPos — wherever the user puts the
    -- red dot is where the target will be locked.
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

    local smooth    = math.clamp(S.aimlockSmoothing or 1, 0.05, 1)
    local newCF     = Camera.CFrame:Lerp(targetCF, smooth)

    local maxDeg = S.aimlockMaxDegPerFrame or 0
    if maxDeg > 0 then
        local curLook = Camera.CFrame.LookVector
        local newLook = newCF.LookVector
        local dot     = math.clamp(curLook:Dot(newLook), -1, 1)
        local angDeg  = math.deg(math.acos(dot))
        if angDeg > maxDeg then
            local f = maxDeg / angDeg
            newCF = Camera.CFrame:Lerp(newCF, f)
        end
    end
    Camera.CFrame = newCF

    if Aimlock.statusLabel then
        local tag = isOnLockList(t) and " [LIST]" or ""
        Aimlock.statusLabel.Text = "Locked: " .. t.Name .. tag
    end
end)

-- ============================================================
--  KEYBINDS  (aimlock only)
-- ============================================================
UserInputService.InputBegan:Connect(function(input, gpe)
    if gpe then return end
    local k = input.KeyCode
    -- Aimlock toggle (default P) — in Hold-to-aim mode the key arms _holdActive
    -- only; in classic mode it toggles the feature on/off.
    if k == S.aimlockKey then
        if S.aimlockHoldToAim then
            Aimlock._holdActive = true
            if not S.aimlockEnabled then setAimlock(true) end
        else
            setAimlock(not S.aimlockEnabled)
        end
    end
end)

-- Release Hold-to-aim when the keybind is released.
UserInputService.InputEnded:Connect(function(input, gp)
    if gp then return end
    if S.aimlockHoldToAim and input.KeyCode == S.aimlockKey then
        Aimlock._holdActive = false
    end
end)

-- ============================================================
--  SCREEN GUI  (aimlock button only)
-- ============================================================
local SG = Instance.new("ScreenGui")
SG.Name            = "AimlockUI"
SG.ResetOnSpawn    = false
SG.ZIndexBehavior  = Enum.ZIndexBehavior.Sibling
SG.IgnoreGuiInset  = true
SG.DisplayOrder    = 10
SG.Parent          = LocalPlayer.PlayerGui

local editActive = false

-- ============================================================
--  BUTTON FACTORY
--  Tap-vs-drag detection so mobile drag works correctly:
--    • Touch moves < DRAG_THRESH px  → fires callback (tap)
--    • Touch moves >= DRAG_THRESH px → drags the button
-- ============================================================
local DRAG_THRESH = 12  -- pixels of movement before drag kicks in

local allButtons = {}

local function makeButton(name, initPos, initSize, label, color, callback)
    local frame = Instance.new("Frame")
    frame.Name                  = name
    frame.Size                  = initSize
    frame.Position              = initPos
    frame.BackgroundTransparency = 1
    frame.BorderSizePixel       = 0
    frame.Active                = true
    frame.Parent                = SG

    -- Full-frame image
    local icon = Instance.new("ImageLabel")
    icon.Size               = UDim2.new(1, 0, 1, 0)
    icon.Position           = UDim2.new(0, 0, 0, 0)
    icon.AnchorPoint        = Vector2.new(0, 0)
    icon.BackgroundTransparency = 1
    icon.Image              = ""
    icon.ImageColor3        = Color3.new(1, 1, 1)
    icon.ScaleType          = Enum.ScaleType.Fit
    icon.Parent             = frame

    -- Hidden label kept so existing code referencing .lbl doesn't error
    local lbl = Instance.new("TextLabel")
    lbl.Name                = "Lbl"
    lbl.Size                = UDim2.new(1, 0, 0, 0)
    lbl.BackgroundTransparency = 1
    lbl.Text                = ""
    lbl.TextTransparency    = 1
    lbl.Parent              = frame

    local btn = Instance.new("TextButton")
    btn.Size                = UDim2.new(1,0,1,0)
    btn.BackgroundTransparency = 1
    btn.Text                = ""
    btn.ZIndex              = 5
    btn.Parent              = frame

    local activeTouches     = {}
    local currentDragTouch  = nil
    local pinchStartDist    = nil
    local pinchStartSize    = nil

    local function getTouchList()
        local list = {}
        for inp, _ in pairs(activeTouches) do table.insert(list, inp) end
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
        local info = activeTouches[input]
        if not info then return end

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
            info.dragging   = true
            currentDragTouch = input
        end

        if info.dragging and currentDragTouch == input and editActive then
            frame.Position = UDim2.new(
                info.startFramePos.X.Scale,
                info.startFramePos.X.Offset + delta.X,
                info.startFramePos.Y.Scale,
                info.startFramePos.Y.Offset + delta.Y
            )
        end
    end)

    btn.InputEnded:Connect(function(input)
        local info = activeTouches[input]
        if not info then return end

        if not info.dragging then
            callback()
        end

        activeTouches[input] = nil
        if currentDragTouch == input then currentDragTouch = nil end

        local list = getTouchList()
        if #list < 2 then
            pinchStartDist = nil
            pinchStartSize = nil
        end
    end)

    btn.MouseButton1Click:Connect(function()
        if not next(activeTouches) then
            callback()
        end
    end)

    local obj = { frame = frame, lbl = lbl, icon = icon }
    table.insert(allButtons, obj)
    return obj
end

-- ============================================================
--  AIMLOCK BUTTON
-- ============================================================
local aimlockBtnObj = makeButton("AimlockBtn",
    S.aimlockBtnPos,
    S.btnSize,
    "Aimlock [P]",
    Color3.fromRGB(180, 30, 30),
    function()
        -- In Hold-to-aim mode the click handler is a no-op; press/release
        -- below drives _holdActive instead.
        if S.aimlockHoldToAim then return end
        if _G.__FlyScript_SetAimlock then _G.__FlyScript_SetAimlock(not S.aimlockEnabled) end
    end)

-- Hold-to-aim wiring for the on-screen button (touch + mouse).
do
    local function isHoldInput(input)
        return input.UserInputType == Enum.UserInputType.Touch
            or input.UserInputType == Enum.UserInputType.MouseButton1
    end
    aimlockBtnObj.frame.InputBegan:Connect(function(input)
        if not S.aimlockHoldToAim then return end
        if not isHoldInput(input) then return end
        Aimlock._holdActive = true
        if not S.aimlockEnabled and _G.__FlyScript_SetAimlock then
            _G.__FlyScript_SetAimlock(true)
        end
    end)
    aimlockBtnObj.frame.InputEnded:Connect(function(input)
        if not S.aimlockHoldToAim then return end
        if not isHoldInput(input) then return end
        Aimlock._holdActive = false
    end)
end

aimlockBtnObj.icon.Image                  = S.aimlockOffImg or ""
aimlockBtnObj.frame.BackgroundColor3      = Color3.fromRGB(40, 20, 20)
aimlockBtnObj.frame.BackgroundTransparency = 0.2
aimlockBtnObj.frame.Visible               = true
do
    local r = Instance.new("UICorner")
    r.CornerRadius = UDim.new(0.5, 0); r.Parent = aimlockBtnObj.frame
end

-- Fallback text label so even if the icon fails to load, the button is still
-- visible and tappable on mobile.
do
    local fb = Instance.new("TextLabel")
    fb.Name                  = "Fallback"
    fb.Size                  = UDim2.new(1, 0, 1, 0)
    fb.BackgroundTransparency= 1
    fb.Text                  = "AIM"
    fb.TextScaled            = true
    fb.Font                  = Enum.Font.GothamBold
    fb.TextColor3            = Color3.fromRGB(255, 220, 220)
    fb.TextStrokeTransparency= 0.4
    fb.ZIndex                = aimlockBtnObj.icon.ZIndex - 1
    fb.Parent                = aimlockBtnObj.frame
end

-- Public hook used by setAimlock() to swap the button icon and tint
_G.__FlyScript_UpdateAimlockBtn = function()
    if not aimlockBtnObj then return end
    if S.aimlockEnabled then
        aimlockBtnObj.icon.Image            = S.aimlockOnImg or ""
        aimlockBtnObj.frame.BackgroundColor3 = Color3.fromRGB(40, 200, 80)
    else
        aimlockBtnObj.icon.Image            = S.aimlockOffImg or ""
        aimlockBtnObj.frame.BackgroundColor3 = Color3.fromRGB(180, 30, 30)
    end
end

-- ============================================================
--  RAYFIELD UI
-- ============================================================
local Window = Rayfield:CreateWindow({
    Name                   = "Aimlock",
    Icon                   = 0,
    LoadingTitle           = "Aimlock",
    LoadingSubtitle        = "Aimlock Settings",
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

-- ── MAIN TAB ─────────────────────────────────────────────────
local T = Window:CreateTab("Main", 4483362458)

T:CreateToggle({
    Name         = "Enable Aimlock",
    CurrentValue = S.aimlockEnabled,
    Flag         = "AimlockEnabled",
    Callback     = function(v)
        setAimlock(v)
    end,
})

-- ── TARGETING TAB ────────────────────────────────────────────
local TG = Window:CreateTab("Targeting", 4483362458)

TG:CreateSection("FOV & Range")
TG:CreateSlider({
    Name         = "FOV Radius (px)",
    Range        = { 10, 800 },
    Increment    = 5,
    Suffix       = "px",
    CurrentValue = S.aimlockFOV,
    Flag         = "AimlockFOV",
    Callback     = function(v) S.aimlockFOV = v end,
})
TG:CreateSlider({
    Name         = "Max Range (studs)",
    Range        = { 50, 5000 },
    Increment    = 50,
    Suffix       = " st",
    CurrentValue = S.aimlockRange,
    Flag         = "AimlockRange",
    Callback     = function(v) S.aimlockRange = v end,
})

TG:CreateSection("Checks")
TG:CreateToggle({
    Name         = "Team Check  (skip teammates)",
    CurrentValue = S.aimlockTeamCheck,
    Flag         = "AimlockTeamCheck",
    Callback     = function(v) S.aimlockTeamCheck = v end,
})
TG:CreateToggle({
    Name         = "Friend Check  (skip Roblox friends)",
    CurrentValue = S.aimlockFriendCheck,
    Flag         = "AimlockFriendCheck",
    Callback     = function(v) S.aimlockFriendCheck = v end,
})
TG:CreateToggle({
    Name         = "Wall Check  (skip targets behind walls)",
    CurrentValue = S.aimlockWallCheck,
    Flag         = "AimlockWallCheck",
    Callback     = function(v) S.aimlockWallCheck = v end,
})

TG:CreateSection("Target Part")
TG:CreateInput({
    Name                    = "Aim Part  (e.g. Head, UpperTorso)",
    PlaceholderText         = S.aimlockPart,
    RemoveTextAfterFocusLost = false,
    Flag                    = "AimlockPart",
    Callback                = function(v)
        if v and v ~= "" then S.aimlockPart = v end
    end,
})

-- ── BEHAVIOUR TAB ────────────────────────────────────────────
local BV = Window:CreateTab("Behaviour", 4483362458)

BV:CreateSection("Lock Mode")
BV:CreateToggle({
    Name         = "Sticky Lock  (keep target until they die)",
    CurrentValue = S.aimlockStickyLock,
    Flag         = "AimlockStickyLock",
    Callback     = function(v) S.aimlockStickyLock = v end,
})
BV:CreateToggle({
    Name         = "Hold-to-Aim  (hold key instead of toggle)",
    CurrentValue = S.aimlockHoldToAim,
    Flag         = "AimlockHoldToAim",
    Callback     = function(v) S.aimlockHoldToAim = v end,
})
BV:CreateToggle({
    Name         = "Cursor Mode  (aim lands at crosshair pixel)",
    CurrentValue = S.aimlockCursorMode,
    Flag         = "AimlockCursorMode",
    Callback     = function(v) S.aimlockCursorMode = v end,
})
BV:CreateSlider({
    Name         = "Reacquire Delay (sec)",
    Range        = { 0, 3 },
    Increment    = 1,
    Suffix       = "s",
    CurrentValue = S.aimlockReacquireDelay,
    Flag         = "AimlockReacquireDelay",
    Callback     = function(v) S.aimlockReacquireDelay = v end,
})

BV:CreateSection("Smoothing & Speed")
BV:CreateSlider({
    Name         = "Smoothing  (1 = snap, 0.05 = slow glide)",
    Range        = { 1, 20 },
    Increment    = 1,
    CurrentValue = math.floor(S.aimlockSmoothing * 20 + 0.5),
    Flag         = "AimlockSmoothing",
    Callback     = function(v) S.aimlockSmoothing = v / 20 end,
})
BV:CreateSlider({
    Name         = "Max Deg Per Frame  (0 = no limit)",
    Range        = { 0, 45 },
    Increment    = 1,
    Suffix       = "°",
    CurrentValue = S.aimlockMaxDegPerFrame,
    Flag         = "AimlockMaxDeg",
    Callback     = function(v) S.aimlockMaxDegPerFrame = v end,
})
BV:CreateSlider({
    Name         = "Humanizer  (pixel jitter, 0 = off)",
    Range        = { 0, 40 },
    Increment    = 1,
    Suffix       = "px",
    CurrentValue = S.aimlockHumanize,
    Flag         = "AimlockHumanize",
    Callback     = function(v) S.aimlockHumanize = v end,
})
BV:CreateSlider({
    Name         = "Miss Chance  (skip N% of frames)",
    Range        = { 0, 40 },
    Increment    = 1,
    Suffix       = "%",
    CurrentValue = S.aimlockMissChance,
    Flag         = "AimlockMissChance",
    Callback     = function(v) S.aimlockMissChance = v end,
})

-- ── PREDICTION TAB ───────────────────────────────────────────
local PR = Window:CreateTab("Prediction", 4483362458)

PR:CreateSection("Smart AI Lead")
PR:CreateToggle({
    Name         = "Smart AI  (predict moving targets)",
    CurrentValue = S.aimlockSmartAI,
    Flag         = "AimlockSmartAI",
    Callback     = function(v) S.aimlockSmartAI = v end,
})
PR:CreateSlider({
    Name         = "Predict Strength  (0 = no lead, 10 = full)",
    Range        = { 0, 10 },
    Increment    = 1,
    CurrentValue = math.floor(S.aimlockPredictStrength * 10 + 0.5),
    Flag         = "AimlockPredictStr",
    Callback     = function(v) S.aimlockPredictStrength = v / 10 end,
})
PR:CreateToggle({
    Name         = "Acceleration Prediction  (noisy — off by default)",
    CurrentValue = S.aimlockPredictAccel,
    Flag         = "AimlockPredictAccel",
    Callback     = function(v) S.aimlockPredictAccel = v end,
})

-- ── VISUALS TAB ──────────────────────────────────────────────
local VS = Window:CreateTab("Visuals", 4483362458)

VS:CreateSection("FOV Ring")
VS:CreateToggle({
    Name         = "Show FOV Ring",
    CurrentValue = S.aimlockShowFOV,
    Flag         = "AimlockShowFOV",
    Callback     = function(v)
        S.aimlockShowFOV = v
        if Aimlock.fovCircle then Aimlock.fovCircle.Visible = v end
    end,
})
VS:CreateSlider({
    Name         = "Ring Color — Red",
    Range        = { 0, 255 },
    Increment    = 5,
    CurrentValue = S.aimlockFOVColorR,
    Flag         = "AimlockFOVR",
    Callback     = function(v)
        S.aimlockFOVColorR = v
        if Aimlock.fovStroke then
            Aimlock.fovStroke.Color = Color3.fromRGB(S.aimlockFOVColorR, S.aimlockFOVColorG, S.aimlockFOVColorB)
        end
    end,
})
VS:CreateSlider({
    Name         = "Ring Color — Green",
    Range        = { 0, 255 },
    Increment    = 5,
    CurrentValue = S.aimlockFOVColorG,
    Flag         = "AimlockFOVG",
    Callback     = function(v)
        S.aimlockFOVColorG = v
        if Aimlock.fovStroke then
            Aimlock.fovStroke.Color = Color3.fromRGB(S.aimlockFOVColorR, S.aimlockFOVColorG, S.aimlockFOVColorB)
        end
    end,
})
VS:CreateSlider({
    Name         = "Ring Color — Blue",
    Range        = { 0, 255 },
    Increment    = 5,
    CurrentValue = S.aimlockFOVColorB,
    Flag         = "AimlockFOVB",
    Callback     = function(v)
        S.aimlockFOVColorB = v
        if Aimlock.fovStroke then
            Aimlock.fovStroke.Color = Color3.fromRGB(S.aimlockFOVColorR, S.aimlockFOVColorG, S.aimlockFOVColorB)
        end
    end,
})

-- ── LOCK LIST TAB ────────────────────────────────────────────
local LL = Window:CreateTab("Lock List", 4483362458)

LL:CreateSection("Priority Targets  (bypass friend check)")
LL:CreateToggle({
    Name         = "Enable Lock List",
    CurrentValue = S.targetLockEnabled,
    Flag         = "TargetLockEnabled",
    Callback     = function(v) S.targetLockEnabled = v end,
})
LL:CreateInput({
    Name                    = "Add Player  (exact username)",
    PlaceholderText         = "PlayerName",
    RemoveTextAfterFocusLost = true,
    Flag                    = "LockListAdd",
    Callback                = function(v)
        if v and v ~= "" then
            S.targetLockList[string.lower(v)] = true
        end
    end,
})
LL:CreateInput({
    Name                    = "Remove Player",
    PlaceholderText         = "PlayerName",
    RemoveTextAfterFocusLost = true,
    Flag                    = "LockListRemove",
    Callback                = function(v)
        if v and v ~= "" then
            S.targetLockList[string.lower(v)] = nil
        end
    end,
})
