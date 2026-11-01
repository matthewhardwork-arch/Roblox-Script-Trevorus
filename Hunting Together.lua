-- =========================================================================
-- Hunting Together Hub (v9.34)
-- เกม: 🎃 [HALLOWEEN] Hunting Together (Beta Test) · place 117483759937632
-- Modules: Character Stats Style GUI · Ground-Truth Farm Automation · Settings
--
-- ⚠️ กติกาการแก้ไฟล์นี้ — บังคับสำหรับทุกคน/ทุก agent ที่เข้ามาแก้
--    1. แก้ logic เมื่อไร ให้ bump เลขเวอร์ชันบรรทัดบน (vX.Y → vX.Y+1)
--       และแก้ให้ตรงกันทุกจุด: ป้าย GUI · ค่าที่ hub API คืน · ข้อความตอนโหลดเสร็จ
--       (grep เลขเก่าก่อนส่ง)
--    2. บันทึกสิ่งที่แก้ลง CHANGELOG นอกไฟล์สคริปต์:
--         .workbuddy-ai/memory/Hunting Together_CHANGELOG.md
-- =========================================================================

local VERSION = "9.34"
local HUB_KEY = "HuntingTogetherHub"
local GUI_NAME = "HuntingTogetherHubGui"
local CFG_FILE = "HuntingTogether_Config.json"

-- ===== 1. ตรวจสอบสภาพแวดล้อมและความพร้อมของ Client (Auto-Execute Resilience) =====
local EXEC = { env = getgenv() }
for _, name in ipairs({ "readfile", "writefile", "isfile", "isfolder", "makefolder", "firesignal", "queue_on_teleport", "hookfunction", "getgc", "getinfo", "getconstants", "getupvalues", "setupvalue", "getconnections", "fireproximityprompt" }) do
	EXEC[name] = rawget(EXEC.env, name) or (debug and debug[name])
end

do
	local deadline = os.clock() + 60
	while not game:IsLoaded() and os.clock() < deadline do
		task.wait(0.1)
	end
	if not game:IsLoaded() then
		EXEC.env.HuntingTogetherHub_Loaded = false
		return warn("[Hunting Together Hub] เกมยังโหลดไม่สมบูรณ์ — ขอยกเลิกการโหลด")
	end
end

local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer
if not LocalPlayer then
	local t0 = tick()
	repeat
		task.wait(0.1)
		LocalPlayer = Players.LocalPlayer
	until LocalPlayer ~= nil or (tick() - t0) > 60
end
if not LocalPlayer then
	EXEC.env.HuntingTogetherHub_Loaded = false
	return warn("[Hunting Together Hub] LocalPlayer ยังไม่พร้อม — ขอยกเลิกการโหลด")
end

local PlayerGui = LocalPlayer:WaitForChild("PlayerGui", 60)
if not PlayerGui then
	EXEC.env.HuntingTogetherHub_Loaded = false
	return warn("[Hunting Together Hub] PlayerGui ยังไม่พร้อม — ขอยกเลิกการโหลด")
end

-- ===== 2. Services =====
local RunService = game:GetService("RunService")
local UIS = game:GetService("UserInputService")
local HttpService = game:GetService("HttpService")
local GuiService = game:GetService("GuiService")
local TeleportService = game:GetService("TeleportService")
local TweenService = game:GetService("TweenService")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local PathfindingService = game:GetService("PathfindingService")
local VirtualUser = game:GetService("VirtualUser")
local okVim, VIM = pcall(game.GetService, game, "VirtualInputManager")
if not okVim then VIM = nil end

-- ===== 3. ล้าง Instance และ Connection เก่า (Idempotency & Safe Unload) =====
local prev = rawget(EXEC.env, HUB_KEY)
local prevConfig = nil
if type(prev) == "table" then
	if type(prev.Config) == "table" then
		prevConfig = {}
		for k, v in pairs(prev.Config) do
			prevConfig[k] = v
		end
	end
	if type(prev.Unload) == "function" then
		pcall(prev.Unload, prev, false, true)
	end
end

-- กำหนด Token หลัง prev.Unload() เสมอ เพื่อป้องกัน Token Desync (ทำให้ Worker ลูปไม่หลุด)
EXEC.env.HuntingTogetherHub_Token = (EXEC.env.HuntingTogetherHub_Token or 0) + 1
local MY_TOKEN = EXEC.env.HuntingTogetherHub_Token

local function cleanOldGuis(name)
	local containers = {}
	pcall(function() if gethui then table.insert(containers, gethui()) end end)
	pcall(function() table.insert(containers, game:GetService("CoreGui")) end)
	pcall(function()
		local rbxGui = game:GetService("CoreGui"):FindFirstChild("RobloxGui")
		if rbxGui then table.insert(containers, rbxGui) end
	end)
	pcall(function() table.insert(containers, PlayerGui) end)
	for _, c in ipairs(containers) do
		pcall(function()
			for _, g in ipairs(c:GetChildren()) do
				if g.Name == name then
					g:Destroy()
				end
			end
		end)
	end
end

cleanOldGuis(GUI_NAME)

-- กวาดล้าง Ghost Event Connections และ Ghost HUB Instances ที่ตกค้างจากเวอร์ชันเก่าในเซสชันเดิม
local function purgeAllGhostConnections()
	if type(EXEC.getconnections) ~= "function" then return end
	local getInfoFn = EXEC.getinfo or (debug and debug.getinfo)
	local getUpvalsFn = EXEC.getupvalues or (debug and debug.getupvalues)

	local function disconnectExecSignal(sig)
		if not sig then return end
		local okConn, conns = pcall(EXEC.getconnections, sig)
		if not okConn or type(conns) ~= "table" then return end
		for _, c in ipairs(conns) do
			local fn = c.Function
			if fn then
				local isExec = false
				if type(getInfoFn) == "function" then
					local okInfo, info = pcall(getInfoFn, fn)
					if okInfo and info and info.source and (info.source:find("loadstring") or info.source == "=") then
						isExec = true
					end
				end
				-- ค้นหาตาราง Ghost HUB เก่าใน Upvalues เพื่อสั่งปิด Alive = false และ Disconnect ทุก Connection ที่สะสมค้างอยู่
				if type(getUpvalsFn) == "function" then
					local okUv, uvs = pcall(getUpvalsFn, fn)
					if okUv and type(uvs) == "table" then
						for _, uv in pairs(uvs) do
							if type(uv) == "table" and type(uv.Connections) == "table" and uv.Alive ~= nil then
								isExec = true
								uv.Alive = false
								for _, oldConn in ipairs(uv.Connections) do
									pcall(function() oldConn:Disconnect() end)
								end
								table.clear(uv.Connections)
							end
						end
					end
				end
				if isExec then
					pcall(function() c:Disconnect() end)
				end
			end
		end
	end

	local attrSignals = {
		"GearJson", "StorageGearJson", "LocksJson", "EquipJson", "WeaponId",
		"BagSlotsUsed", "Silver", "AutoOn", "LumiSprintLock", "BotReviveWalk", "LumiFollowUserId"
	}
	for _, sigName in ipairs(attrSignals) do
		local ok, sig = pcall(LocalPlayer.GetAttributeChangedSignal, LocalPlayer, sigName)
		if ok and sig then
			disconnectExecSignal(sig)
		end
	end

	local pgui = LocalPlayer:FindFirstChild("PlayerGui")
	if pgui then
		local lumi = pgui:FindFirstChild("LumiInventory")
		if lumi then
			local win = lumi:FindFirstChild("InventoryWindow", true)
			if win then
				pcall(function() disconnectExecSignal(win:GetPropertyChangedSignal("Visible")) end)
				local sf = win:FindFirstChild("ScrollingFrame", true)
				if sf then
					disconnectExecSignal(sf.ChildAdded)
					for _, cell in ipairs(sf:GetChildren()) do
						if cell:IsA("TextButton") then
							disconnectExecSignal(cell.MouseButton1Click)
						end
					end
				end
				for _, tabName in ipairs({ "all", "item", "armor", "weapon", "garment", "shoes", "ring", "card" }) do
					local tabBtn = win:FindFirstChild(tabName, true)
					if tabBtn and tabBtn:IsA("TextButton") then
						disconnectExecSignal(tabBtn.MouseButton1Click)
					end
				end
				local searchBox = win:FindFirstChild("SearchBox", true)
				if searchBox and searchBox:IsA("TextBox") then
					pcall(function() disconnectExecSignal(searchBox:GetPropertyChangedSignal("Text")) end)
				end
			end
			local popup = lumi:FindFirstChild("ItemPopup")
			if popup then
				pcall(function() disconnectExecSignal(popup:GetPropertyChangedSignal("Visible")) end)
				local head = popup:FindFirstChild("Head")
				local title = head and head:FindFirstChild("Title")
				if title then
					pcall(function() disconnectExecSignal(title:GetPropertyChangedSignal("Text")) end)
				end
			end
		end

		for _, screenName in ipairs({ "LumiBagScreen", "HuntShop", "HuntReroll", "LumiRefine", "HuntStorage" }) do
			local scr = pgui:FindFirstChild(screenName)
			if scr then
				pcall(function() disconnectExecSignal(scr:GetPropertyChangedSignal("Enabled")) end)
			end
		end
	end
end
if prev ~= nil then
	purgeAllGhostConnections()
end

-- ล้างป้าย Tier และ/หรือ Hook Attributes (รองรับโหมด onlyHooks ตอน Hot-Reload เพื่อไม่ให้ป้ายกระพริบหาย และโหมด onlyBadges ตอนกดปิดฟีเจอร์)
local function purgeAllTierBadgesAndHooks(onlyHooks, onlyBadges)
	local pgui = LocalPlayer:FindFirstChild("PlayerGui")
	if not pgui then return end
	local doBadges = not onlyHooks
	local doHooks = not onlyBadges

	-- 1. LumiInventory: ล้างป้ายทั้งหมดและรีเซ็ต Hook Attributes ให้สคริปต์ใหม่ผูก Event ได้สดใหม่ 100%
	local lumi = pgui:FindFirstChild("LumiInventory")
	if lumi then
		for _, d in ipairs(lumi:GetDescendants()) do
			if doBadges then
				if d.Name == "TierBadge" or d.Name == "PopupTierBadge" or d.Name == "StarBadge" or d.Name == "PopupStarBadge" or d.Name == "RerollDetailStarBadge" or d.Name == "StarShadow" then
					pcall(d.Destroy, d)
				elseif d.Name == "ItemCount" and d:IsA("TextLabel") then
					d.Visible = true
					d.Position = UDim2.new(1, -67, 0, 1)
				end
			end
			if doHooks then
				if d:GetAttribute("TierClickHooked") then d:SetAttribute("TierClickHooked", nil) end
				if d:GetAttribute("TierChildHooked") then d:SetAttribute("TierChildHooked", nil) end
				if d:GetAttribute("TierReactiveHooked") then d:SetAttribute("TierReactiveHooked", nil) end
				if d:GetAttribute("TierPopupHooked") then d:SetAttribute("TierPopupHooked", nil) end
				if d:GetAttribute("TierTitleHooked") then d:SetAttribute("TierTitleHooked", nil) end
			end
		end
	end

	-- 2. LumiBagScreen: ล้าง Overlay และป้ายสวมใส่ พร้อมรีเซ็ต Hook Attributes
	local bagScreen = pgui:FindFirstChild("LumiBagScreen")
	if bagScreen then
		if doBadges then
			local overlay = bagScreen:FindFirstChild("LumiEquipTierOverlay")
			if overlay then pcall(overlay.Destroy, overlay) end
		end
		for _, d in ipairs(bagScreen:GetDescendants()) do
			if doBadges then
				if d.Name == "TierBadge" or d.Name == "StarBadge" or d.Name:match("^EquipTierBadge_") or d.Name:match("^EquipStarBadge_") then
					pcall(d.Destroy, d)
				elseif d.Name == "Count" and d:IsA("TextLabel") then
					d.Visible = true
				end
			end
			if doHooks then
				if d:GetAttribute("TierClickHooked") then d:SetAttribute("TierClickHooked", nil) end
			end
		end
	end

	-- 3. HuntShop
	local huntShop = pgui:FindFirstChild("HuntShop")
	if huntShop and doBadges then
		for _, d in ipairs(huntShop:GetDescendants()) do
			if d.Name == "TierBadge" or d.Name == "StarBadge" then
				pcall(d.Destroy, d)
			end
		end
	end

	-- 4. HuntReroll (ร้านสุ่ม Stats)
	local huntReroll = pgui:FindFirstChild("HuntReroll")
	if huntReroll then
		for _, d in ipairs(huntReroll:GetDescendants()) do
			if doBadges then
				if d.Name == "TierBadge" or d.Name == "PopupTierBadge" or d.Name == "StarBadge" or d.Name == "PopupStarBadge" or d.Name == "RerollDetailStarBadge" or d.Name == "StarShadow" then
					pcall(d.Destroy, d)
				end
			end
			if doHooks then
				if d:GetAttribute("TierRerollHooked") then d:SetAttribute("TierRerollHooked", nil) end
				if d:GetAttribute("TierDetailHooked") then d:SetAttribute("TierDetailHooked", nil) end
				if d:GetAttribute("BoundRef") then d:SetAttribute("BoundRef", nil) end
				if d:GetAttribute("TierRerollClicked") then d:SetAttribute("TierRerollClicked", nil) end
			end
		end
	end

	-- 5. LumiRefine (ร้านตีบวก)
	local lumiRefine = pgui:FindFirstChild("LumiRefine")
	if lumiRefine then
		for _, d in ipairs(lumiRefine:GetDescendants()) do
			if doBadges then
				if d.Name == "TierBadge" or d.Name == "PopupTierBadge" or d.Name == "StarBadge" or d.Name == "StarShadow" then
					pcall(d.Destroy, d)
				end
			end
			if doHooks then
				if d:GetAttribute("TierRefineHooked") then d:SetAttribute("TierRefineHooked", nil) end
			end
		end
	end

	-- 6. HuntStorage (คลังเก็บของ)
	local huntStorage = pgui:FindFirstChild("HuntStorage")
	if huntStorage then
		for _, d in ipairs(huntStorage:GetDescendants()) do
			if doBadges then
				if d.Name == "TierBadge" or d.Name == "StarBadge" or d.Name == "StarShadow" then
					pcall(d.Destroy, d)
				end
			end
			if doHooks then
				if d:GetAttribute("BoundRef") then d:SetAttribute("BoundRef", nil) end
				if d:GetAttribute("TierStorageHooked") then d:SetAttribute("TierStorageHooked", nil) end
			end
		end
	end
end
-- ตอนเริ่มโหลดสคริปต์ใหม่: ล้างเฉพาะ Hook Attributes เพื่อไม่ให้ป้ายที่แสดงอยู่บนจอกระพริบหาย (ส่วนป้ายจะถูก In-Place Mutate หรือลบตาม Config ทันทีที่โหลดเสร็จ)
purgeAllTierBadgesAndHooks(true, false)

-- ===== 4. State Management (ยุบลงตารางเดียวเพื่อคุม Register Limit) =====
local HUB = {
	Version = VERSION,
	Alive = true,
	Navigating = false,
	Dodging = false,
	FarmAnchor = nil,
	OriginCFrame = nil,
	OriginAutoOn = nil,
	LastManualMoveTime = 0,
	BotTurnedOnAuto = false,
	UserDisabledAuto = false,
	Connections = {},
	UI = {},
	Config = {
		antiAfk = true,
		autoRejoin = true,
		autoSave = true,
		autoOpenBox = false,
		autoClaim = false,
		autoDodge = false,
		dodgeRedZones = true,
		dodgeGreenZones = true,
		dodgeBuffer = 4.0,
		targetSprint = true,
		itemTierBadges = false,
		autoLock = false,
		autoLockTiers = {
			SS = true,
			S = true,
			A = false,
			B = false,
			C = false,
			D = false,
			F = false,
		},
		autoLockStars = {
			Rainbow = true,
			Gold = true,
			Silver = true,
		},
		autoLockGameTiers = {
			[1] = false,
			[2] = false,
			[3] = false,
			[4] = false,
			[5] = true,
			[6] = true,
		},
		autoLockEquipRules = {},
		autoSalvage = false,
		autoSalvageThresholdPct = 85,
		autoSell = false,
		autoSellThresholdPct = 85,
		autoSellJunk = true,
		autoSellGear = true,
		autoFarmBoss = false,
		farmBossList = {
			Boss01 = false,
			Boss02 = true,
			Boss03 = true,
			Boss04 = false,
			Boss05 = false,
		},
		autoResumeGamePlay = true,
		autoStartGame = true,
		maxLootBoxMiniboss = 1,
		bossPreSpawnThreshold = 15,
		iconPos = { ScaleX = 0, OffsetX = 346, ScaleY = 0, OffsetY = 10 },
	},
	Stats = {
		afkCount = 0,
		lastAfkTime = 0,
		lastSavedTime = 0,
		rejoinAttempts = 0,
		boxesOpened = 0,
		rewardsClaimed = 0,
		dodgesPerformed = 0,
	},
}

local _lastConnPruneTime = 0

-- Background Clean Maintenance: กวาดล้าง Dead/Disconnected Connections คืนหน่วยความจำอัตโนมัติ (Zero Memory Allocation)
function HUB:PruneConnections()
	local conns = self.Connections
	if not conns then return 0 end
	local aliveCount = 0
	local total = #conns
	for i = 1, total do
		local c = conns[i]
		local isAlive = false
		if typeof(c) == "RBXScriptConnection" then
			isAlive = c.Connected
		elseif type(c) == "table" and c.Connected ~= nil then
			isAlive = c.Connected
		end
		if isAlive then
			aliveCount = aliveCount + 1
			if aliveCount ~= i then
				conns[aliveCount] = c
			end
		end
	end
	for i = aliveCount + 1, total do
		conns[i] = nil
	end
	return aliveCount
end

function HUB:AddConnection(conn)
	if conn then
		table.insert(self.Connections, conn)
		-- หากรายการ Connection เริ่มสะสมเกิน 150 ตัว ให้ตรวจสอบและ Prune Dead Connections ทันที (จำกัดความถี่ 5s)
		if #self.Connections >= 150 then
			local now = os.clock()
			if now - _lastConnPruneTime >= 5.0 then
				_lastConnPruneTime = now
				self:PruneConnections()
			end
		end
	end
	return conn
end

function HUB.Unload(self, isShuttingDown, isReloading)
	if type(self) ~= "table" then
		isReloading = isShuttingDown
		isShuttingDown = self
		self = HUB
	end
	if not self.Alive and isShuttingDown then return end
	self.Alive = false
	EXEC.env.HuntingTogetherHub_Token = (EXEC.env.HuntingTogetherHub_Token or 0) + 1
	pcall(RunService.UnbindFromRenderStep, RunService, "HuntingTogetherHub_DodgeOverride")

	for _, conn in ipairs(self.Connections) do
		pcall(function() conn:Disconnect() end)
	end
	table.clear(self.Connections)

	if not isShuttingDown then
		if self.AutoLockCleanup then
			pcall(self.AutoLockCleanup)
		end
		if self.CancelAutoSellRoutine then
			pcall(self.CancelAutoSellRoutine)
		end
		if self.CancelAutoBossRoutine then
			pcall(self.CancelAutoBossRoutine)
		end
		pcall(function()
			LocalPlayer:SetAttribute("LumiSprintLock", false)
			LocalPlayer:SetAttribute("BotReviveWalk", nil)
			local char = LocalPlayer.Character
			if char then
				for _, p in ipairs(char:GetDescendants()) do
					if p:IsA("BasePart") then p.CanCollide = true end
				end
			end
			if isReloading then
				purgeAllTierBadgesAndHooks(true, false)
			else
				purgeAllTierBadgesAndHooks()
			end
		end)
		cleanOldGuis(GUI_NAME)
		purgeAllGhostConnections()
		print("[Hunting Together Hub] Unloaded สำเร็จ")
	else
		pcall(function()
			if self.UI and self.UI.ScreenGui then
				self.UI.ScreenGui:Destroy()
			end
		end)
	end

	EXEC.env[HUB_KEY] = nil
	EXEC.env.HuntingTogetherHub_Loaded = false
end

-- Fast Shutdown Hook: สั่งปลดลูปและ Disconnect Connections ทันทีที่ผู้เล่นกดออกจากเกม (ป้องกันอาการค้างจังหวะ C++ ทำลาย DataModel)
HUB:AddConnection(Players.PlayerRemoving:Connect(function(plr)
	if plr == LocalPlayer then
		HUB:Unload(true)
	end
end))
pcall(function()
	HUB:AddConnection(game.Close:Connect(function()
		HUB:Unload(true)
	end))
end)

-- Ground-Truth Auto Play Checker (อ่านสถานะ C4On และ AutoOn ของตัวเกมแท้)
function HUB.IsGameAutoActive()
	if LocalPlayer:GetAttribute("AutoOn") == true then
		return true
	end
	local pg = LocalPlayer:FindFirstChild("PlayerGui")
	local autoBtn = pg and pg:FindFirstChild("LumiAuto") and pg.LumiAuto:FindFirstChild("AutoButton")
	return autoBtn and autoBtn:GetAttribute("C4On") == true
end

-- สั่งเปิดใช้งาน Auto Play ของเกมต่อเนื่องอย่างน่าเชื่อถือ (Triple-Layer Redundant Fallback)
function HUB.EnsureGameAutoActive(maxRetries, retryInterval)
	HUB.BotPausingAuto = false
	HUB.UserDisabledAuto = false
	if HUB.IsGameAutoActive() then return true end

	maxRetries = maxRetries or 5
	retryInterval = retryInterval or 0.3

	for attempt = 1, maxRetries do
		if HUB.IsGameAutoActive() then return true end

		-- Layer 1: LumiMenuToggle BindableEvent (ทำงานแบบ Synchronous ทันทีใน CombatClient บรรทัด 1910)
		pcall(function()
			local menuToggle = LocalPlayer:FindFirstChild("LumiMenuToggle")
			if menuToggle and menuToggle:IsA("BindableEvent") then
				menuToggle:Fire("autoToggle")
			end
		end)

		task.wait(0.15)
		if HUB.IsGameAutoActive() then return true end

		-- Layer 2: LumiAfkResumeAuto Attribute (CombatClient บรรทัด 1846 ดักฟังสลับเปิดเฉพาะเมื่อปิดอยู่)
		pcall(function()
			LocalPlayer:SetAttribute("LumiAfkResumeAuto", tick())
		end)

		task.wait(0.2)
		if HUB.IsGameAutoActive() then return true end

		-- Layer 3: firesignal บนปุ่ม AutoButton (CombatClient บรรทัด 1900)
		pcall(function()
			local pg = LocalPlayer:FindFirstChild("PlayerGui")
			local autoBtn = pg and pg:FindFirstChild("LumiAuto") and pg.LumiAuto:FindFirstChild("AutoButton")
			if autoBtn and autoBtn:IsA("TextButton") then
				local fs = EXEC.firesignal or rawget(EXEC.env, "firesignal")
				if type(fs) == "function" then
					fs(autoBtn.MouseButton1Click)
				end
			end
		end)

		task.wait(retryInterval)
		if HUB.IsGameAutoActive() then return true end
	end

	return HUB.IsGameAutoActive()
end

-- สั่งปิด Auto Play ของเกมและล้างเป้าหมายชั่วคราวก่อนเดินนำทาง/วาร์ป (ป้องกัน CombatClient แย่งเดิน 100%)
function HUB.DisableGameAutoPlay()
	HUB.BotPausingAuto = true
	pcall(function()
		LocalPlayer:SetAttribute("LumiAfkResumeAuto", nil)
	end)

	local deadline = os.clock() + 1.2
	while HUB.IsGameAutoActive() and os.clock() < deadline do
		pcall(function()
			local menuToggle = LocalPlayer:FindFirstChild("LumiMenuToggle")
			if menuToggle and menuToggle:IsA("BindableEvent") then
				menuToggle:Fire("autoToggle")
			end
		end)
		task.wait(0.12)
		if HUB.IsGameAutoActive() then
			pcall(function()
				local pg = LocalPlayer:FindFirstChild("PlayerGui")
				local autoBtn = pg and pg:FindFirstChild("LumiAuto") and pg.LumiAuto:FindFirstChild("AutoButton")
				if autoBtn and autoBtn:IsA("TextButton") then
					local fs = EXEC.firesignal or rawget(EXEC.env, "firesignal")
					if type(fs) == "function" then
						fs(autoBtn.MouseButton1Click)
					end
				end
			end)
			task.wait(0.12)
		end
	end

	-- ล้างเป้าหมายและคำสั่งเดินของ CombatClient ทันที
	pcall(function()
		local ct = LocalPlayer:FindFirstChild("CurrentTarget")
		if ct then ct.Value = nil end
		LocalPlayer:SetAttribute("TargetLocked", false)
		LocalPlayer:SetAttribute("BotReviveWalk", nil)
		local ch = LocalPlayer.Character
		local h = ch and ch:FindFirstChildOfClass("Humanoid")
		if h then h:Move(Vector3.zero, false) end
	end)

	-- สั่งหยุด Party Follow ชั่วคราว (ป้องกัน PartyFollowClient ติดลูป setWaiting และแช่แข็งการเดิน)
	pcall(function()
		local followEv = LocalPlayer:FindFirstChild("LumiPartyFollow")
		if followEv and followEv:IsA("BindableEvent") then
			followEv:Fire("stop")
		end
		LocalPlayer:SetAttribute("LumiFollowUserId", nil)
		LocalPlayer:SetAttribute("LumiFollowPos", nil)
		LocalPlayer:SetAttribute("LumiGuideGoal", nil)
	end)

	return not HUB.IsGameAutoActive()
end

-- ตรวจสอบและกดข้ามหน้าจอโหลด / Cutscene "Press to Start" (IntroLoading) แบบ Multi-Transport (v4.6)
function HUB.BypassStartScreen(timeoutSec)
	timeoutSec = timeoutSec or 45
	local pgui = LocalPlayer:FindFirstChild("PlayerGui")
	if not pgui then return false end

	if LocalPlayer:GetAttribute("IntroLoadingDone") == true and not pgui:FindFirstChild("IntroLoading") then
		return true
	end

	local deadline = os.clock() + timeoutSec
	local dismissed = false

	while os.clock() < deadline do
		if not HUB.Alive or EXEC.env.HuntingTogetherHub_Token ~= MY_TOKEN then break end
		if LocalPlayer:GetAttribute("IntroLoadingDone") == true then
			dismissed = true
			break
		end

		local intro = pgui:FindFirstChild("IntroLoading")
		if not intro then
			dismissed = true
			break
		end

		-- หาปุ่ม TapAnywhere หรือ StartButton ใน IntroLoading
		local tapBtn = intro:FindFirstChild("TapAnywhere")
		local startBtn = intro:FindFirstChild("StartButton", true)

		if tapBtn and tapBtn:IsA("GuiButton") then
			local fs = EXEC.firesignal or rawget(EXEC.env, "firesignal")
			if type(fs) == "function" then
				pcall(fs, tapBtn.Activated)
				pcall(fs, tapBtn.MouseButton1Click)
				pcall(fs, tapBtn.MouseButton1Down)
			end
			if VIM then
				pcall(function()
					VIM:SendKeyEvent(true, Enum.KeyCode.Space, false, game)
					task.wait(0.04)
					VIM:SendKeyEvent(false, Enum.KeyCode.Space, false, game)
				end)
				pcall(function()
					VIM:SendMouseButtonEvent(640, 648, 0, true, game, 0)
					task.wait(0.04)
					VIM:SendMouseButtonEvent(640, 648, 0, false, game, 0)
				end)
			end
			if VirtualUser then
				pcall(function()
					VirtualUser:CaptureController()
					VirtualUser:ClickButton1(Vector2.new(640, 648))
				end)
			end
		elseif startBtn then
			if VIM then
				pcall(function()
					VIM:SendKeyEvent(true, Enum.KeyCode.Space, false, game)
					task.wait(0.04)
					VIM:SendKeyEvent(false, Enum.KeyCode.Space, false, game)
				end)
			end
		end

		task.wait(0.25)
	end

	if dismissed then
		print("[Hunting Together Hub] ผ่านหน้าจอ Press to Start / Intro Loading เรียบร้อย")
		if HUB.UI.StartBypassStatusLabel then
			HUB.UI.StartBypassStatusLabel.Text = "สถานะ: ข้ามหน้าจอเริ่มเกมสำเร็จ 🚀"
		end
	end
	return dismissed
end

EXEC.env[HUB_KEY] = HUB
EXEC.env.HuntingTogetherHub_Loaded = true

-- ===== 5. Helper สำหรับ Font และ Palette (ถอดแบบตรงจาก HuntStatScreen) =====
local THEME = {
	FontPrimary = nil,
	FontFallback = Enum.Font.GothamBold,
	
	-- Palette แท้จาก HuntStatScreen
	HeaderBlue = Color3.fromRGB(26, 112, 240),    -- #1A70F0 Vivid Royal Blue แถบหัวข้อหน้าต่าง
	DarkNavy = Color3.fromRGB(10, 28, 78),        -- #0A1C4E สีกรอบ InnerLine / เงา
	PanelBorder = Color3.fromRGB(222, 206, 172),  -- #DECEAC สีกรอบ Sandstone ของ Panel
	PanelBody = Color3.fromRGB(255, 251, 241),    -- #FFFBF1 สีพื้นใน Clean Pearl Ivory
	SubHeaderNavy = Color3.fromRGB(30, 48, 96),   -- #1E3060 แถบหัวข้อย่อยภายใน Panel
	TextDark = Color3.fromRGB(18, 30, 64),        -- #121E40 สีข้อความเข้มคมชัด
	TextSub = Color3.fromRGB(120, 110, 100),      -- #786E64 สีข้อความย่อย
	TextAmber = Color3.fromRGB(210, 95, 12),      -- #D25F0C สีส้มแจ้งเตือน
	
	-- Buttons (ถอดแบบจาก Auto Assign & Confirm Points)
	BtnGreen = Color3.fromRGB(46, 168, 70),       -- #2EA846 สีเขียวปุ่ม Confirm / Toggle ON
	BtnGreenStroke = Color3.fromRGB(28, 115, 46), -- #1C732E
	BtnOrange = Color3.fromRGB(232, 124, 22),     -- #E87C16 สีส้มปุ่ม Auto Assign / Save
	BtnOrangeStroke = Color3.fromRGB(170, 85, 10),-- #AA550A
	BtnOff = Color3.fromRGB(238, 232, 220),       -- #EEE8DC สีปุ่มปิด
	BtnOffStroke = Color3.fromRGB(205, 195, 180), -- #CDC3B4
	BtnClose = Color3.fromRGB(214, 60, 52),       -- #D63C34 สีแดงปุ่มปิด
	BtnMin = Color3.fromRGB(18, 70, 160),         -- #1246A0 สีน้ำเงินปุ่มย่อ
	TabActive = Color3.fromRGB(26, 112, 240),     -- Vivid Royal Blue สำหรับแท็บที่เลือก
	TabInactive = Color3.fromRGB(232, 224, 208),   -- สีนวลสำหรับแท็บที่ไม่ได้เลือก
	PanelCard = Color3.fromRGB(18, 36, 84),        -- สีกรอบไอเทม/แถวใน SubPanel
	BorderCard = Color3.fromRGB(36, 68, 140),       -- เส้นขอบไอเทม/แถวใน SubPanel
	
	-- Textures & Assets
	AtlasIcon = "rbxassetid://136571293937201",
	CloseIcon = "rbxassetid://71422265667934",
	StudsTexture = "rbxassetid://77925008706422",
	ShineTexture = "rbxassetid://94853643640247",
	SettingIconRect = Vector2.new(644, 770),
	IconSize = Vector2.new(120, 116),
}

local BOSS_DEFS = {
	{
		key = "Boss01",
		id = "terra_colossus",
		name = "Gorilla King",
		levelText = "Lv.25",
		minLevel = 25,
		pillarId = "Boss01",
		pillarName = "WarpPillar_Boss01",
		arenaPos = Vector3.new(0, 59.6, -906),
		order = 1,
	},
	{
		key = "Boss02",
		id = "bigboss_thornback_behemoth",
		name = "Whitefang Sabertooth",
		levelText = "Lv.50",
		minLevel = 50,
		pillarId = "Boss02",
		pillarName = "WarpPillar_Boss02",
		arenaPos = Vector3.new(0, 115.6, -1800),
		order = 2,
	},
	{
		key = "Boss03",
		id = "bigboss_obsidian_pharaoh",
		name = "Obsidian Pharaoh",
		levelText = "Lv.75",
		minLevel = 75,
		pillarId = "Boss03",
		pillarName = "WarpPillar_Boss03",
		arenaPos = Vector3.new(0, 171.6, -2694),
		order = 3,
	},
	{
		key = "Boss04",
		id = "bigboss_tempest_dragon_king",
		name = "Tempest Dragon King",
		levelText = "Lv.99",
		minLevel = 99,
		pillarId = "Boss04",
		pillarName = "WarpPillar_Boss04",
		arenaPos = Vector3.new(0, 227.6, -3588),
		order = 4,
	},
	{
		key = "Boss05",
		id = "bigboss_volcano_turtle_king",
		name = "Volcano Turtle King",
		levelText = "Lv.99",
		minLevel = 99,
		pillarId = "Boss05",
		pillarName = "WarpPillar_Boss05",
		arenaPos = Vector3.new(0, 283.2, -4540),
		order = 5,
	},
}
HUB.BossDefs = BOSS_DEFS

do
	local ok, f = pcall(Font.new, "rbxassetid://12187373592", Enum.FontWeight.Bold, Enum.FontStyle.Normal)
	if ok and f then
		THEME.FontPrimary = f
	end
end

local function applyFont(obj, bold)
	if THEME.FontPrimary then
		obj.FontFace = THEME.FontPrimary
	else
		obj.Font = bold and Enum.Font.GothamBold or Enum.Font.Gotham
	end
end

local function getExecutorDisplay()
	local fn = rawget(EXEC.env, "identifyexecutor") or (type(identifyexecutor) == "function" and identifyexecutor)
	if type(fn) == "function" then
		local ok, name, ver = pcall(fn)
		if ok and name and tostring(name) ~= "" then
			local nStr = tostring(name):gsub("^%s*(.-)%s*$", "%1")
			if ver and tostring(ver) ~= "" then
				local vStr = tostring(ver):gsub("^%s*(.-)%s*$", "%1")
				return string.format("%s (v%s)", nStr, vStr)
			end
			return nStr
		end
	end
	if rawget(EXEC.env, "XENO_LOADED") or rawget(EXEC.env, "Xeno") then return "Xeno" end
	if rawget(EXEC.env, "KRNL_LOADED") then return "Krnl" end
	if rawget(EXEC.env, "syn") then return "Synapse" end
	return "Active"
end

-- ===== 6. ระบบ Config Persistence (Auto-Save JSON & Icon Position & Farm Toggles) =====
local function saveConfig()
	if type(EXEC.writefile) ~= "function" then return false end
	local data = {
		version = VERSION,
		savedAt = os.date("%Y-%m-%d %H:%M:%S"),
		antiAfk = HUB.Config.antiAfk,
		autoRejoin = HUB.Config.autoRejoin,
		autoSave = HUB.Config.autoSave,
		autoOpenBox = HUB.Config.autoOpenBox,
		autoClaim = HUB.Config.autoClaim,
		autoDodge = HUB.Config.autoDodge,
		dodgeRedZones = (HUB.Config.dodgeRedZones ~= false),
		dodgeGreenZones = (HUB.Config.dodgeGreenZones ~= false),
		dodgeBuffer = HUB.Config.dodgeBuffer or 4.0,
		targetSprint = (HUB.Config.targetSprint ~= false),
		itemTierBadges = HUB.Config.itemTierBadges,
		autoLock = HUB.Config.autoLock,
		autoLockTiers = HUB.Config.autoLockTiers,
		autoLockStars = HUB.Config.autoLockStars,
		autoLockGameTiers = HUB.Config.autoLockGameTiers,
		autoLockEquipRules = HUB.Config.autoLockEquipRules,
		autoSalvage = HUB.Config.autoSalvage,
		autoSalvageThresholdPct = HUB.Config.autoSalvageThresholdPct,
		autoSell = HUB.Config.autoSell,
		autoSellThresholdPct = HUB.Config.autoSellThresholdPct,
		autoSellJunk = (HUB.Config.autoSellJunk ~= false),
		autoSellGear = (HUB.Config.autoSellGear ~= false),
		autoFarmBoss = HUB.Config.autoFarmBoss,
		farmBossList = HUB.Config.farmBossList,
		autoResumeGamePlay = (HUB.Config.autoResumeGamePlay ~= false),
		autoStartGame = (HUB.Config.autoStartGame ~= false),
		maxLootBoxMiniboss = HUB.Config.maxLootBoxMiniboss,
		bossPreSpawnThreshold = HUB.Config.bossPreSpawnThreshold or 15,
		iconPos = HUB.Config.iconPos,
	}
	local ok, json = pcall(HttpService.JSONEncode, HttpService, data)
	if ok and json then
		local writeOk = pcall(EXEC.writefile, CFG_FILE, json)
		if writeOk then
			HUB.Stats.lastSavedTime = tick()
			return true
		end
	end
	return false
end

local function loadConfig()
	if type(EXEC.readfile) == "function" and type(EXEC.isfile) == "function" and EXEC.isfile(CFG_FILE) then
		local readOk, content = pcall(EXEC.readfile, CFG_FILE)
		if readOk and content and content ~= "" then
			local decOk, data = pcall(HttpService.JSONDecode, HttpService, content)
			if decOk and type(data) == "table" then
				if data.antiAfk ~= nil then HUB.Config.antiAfk = data.antiAfk end
				if data.autoRejoin ~= nil then HUB.Config.autoRejoin = data.autoRejoin end
				if data.autoSave ~= nil then HUB.Config.autoSave = data.autoSave end
				if data.autoOpenBox ~= nil then HUB.Config.autoOpenBox = data.autoOpenBox end
				if data.autoClaim ~= nil then HUB.Config.autoClaim = data.autoClaim end
				if data.autoDodge ~= nil then HUB.Config.autoDodge = data.autoDodge end
				if data.dodgeRedZones ~= nil then HUB.Config.dodgeRedZones = data.dodgeRedZones end
				if data.dodgeGreenZones ~= nil then HUB.Config.dodgeGreenZones = data.dodgeGreenZones end
				if data.dodgeBuffer ~= nil then HUB.Config.dodgeBuffer = tonumber(data.dodgeBuffer) or 4.0 end
				if data.targetSprint ~= nil then HUB.Config.targetSprint = data.targetSprint end
				if data.itemTierBadges ~= nil then HUB.Config.itemTierBadges = data.itemTierBadges end
				if data.autoLock ~= nil then HUB.Config.autoLock = data.autoLock end
				if type(data.autoLockTiers) == "table" then
					for t, v in pairs(data.autoLockTiers) do
						HUB.Config.autoLockTiers[t] = v
					end
				end
				if type(data.autoLockStars) == "table" then
					for s, v in pairs(data.autoLockStars) do
						HUB.Config.autoLockStars[s] = v
					end
				end
				if type(data.autoLockGameTiers) == "table" then
					for t, v in pairs(data.autoLockGameTiers) do
						local tNum = tonumber(t)
						if tNum then
							HUB.Config.autoLockGameTiers[tNum] = (v == true)
						end
					end
				end
				if type(data.autoLockEquipRules) == "table" then
					HUB.Config.autoLockEquipRules = data.autoLockEquipRules
					-- Migration for WeaponPhys -> WeaponPhysMelee / WeaponPhysRanged
					if HUB.Config.autoLockEquipRules["WeaponPhys"] then
						if not HUB.Config.autoLockEquipRules["WeaponPhysMelee"] then
							HUB.Config.autoLockEquipRules["WeaponPhysMelee"] = HUB.Config.autoLockEquipRules["WeaponPhys"]
						end
						if not HUB.Config.autoLockEquipRules["WeaponPhysRanged"] then
							HUB.Config.autoLockEquipRules["WeaponPhysRanged"] = HUB.Config.autoLockEquipRules["WeaponPhys"]
						end
					end
					for _, r in pairs(HUB.Config.autoLockEquipRules) do
						if type(r) == "table" then
							if type(r.wantedSpecials) ~= "table" then
								r.wantedSpecials = {}
								if type(r.special) == "table" then
									for sk, sv in pairs(r.special) do
										if sv == true then r.wantedSpecials[sk] = true end
									end
								end
							end
							if type(r.specialStats) ~= "table" then
								r.specialStats = {}
							end
							if type(r.forbidden) ~= "table" then
								r.forbidden = {}
							end
						end
					end
				end
				if data.autoSalvage ~= nil then HUB.Config.autoSalvage = data.autoSalvage end
				if data.autoSalvageThresholdPct ~= nil then HUB.Config.autoSalvageThresholdPct = tonumber(data.autoSalvageThresholdPct) or 85 end
				if data.autoSell ~= nil then HUB.Config.autoSell = data.autoSell end
				if data.autoSellThresholdPct ~= nil then HUB.Config.autoSellThresholdPct = tonumber(data.autoSellThresholdPct) or 85 end
				if data.autoSellJunk ~= nil then HUB.Config.autoSellJunk = data.autoSellJunk end
				if data.autoSellGear ~= nil then HUB.Config.autoSellGear = data.autoSellGear end
				if data.autoFarmBoss ~= nil then HUB.Config.autoFarmBoss = data.autoFarmBoss end
				if type(data.farmBossList) == "table" then
					for k, v in pairs(data.farmBossList) do
						HUB.Config.farmBossList[k] = v
					end
				end
				if data.autoResumeGamePlay ~= nil then HUB.Config.autoResumeGamePlay = data.autoResumeGamePlay end
				if data.autoStartGame ~= nil then HUB.Config.autoStartGame = data.autoStartGame end
				if data.maxLootBoxMiniboss ~= nil then HUB.Config.maxLootBoxMiniboss = tonumber(data.maxLootBoxMiniboss) or 1 end
				if data.bossPreSpawnThreshold ~= nil then
					local bSec = tonumber(data.bossPreSpawnThreshold) or 15
					bSec = math.clamp(math.floor(bSec / 5 + 0.5) * 5, 5, 60)
					HUB.Config.bossPreSpawnThreshold = bSec
				else
					HUB.Config.bossPreSpawnThreshold = 15
				end
				if type(data.iconPos) == "table" and data.iconPos.OffsetX ~= nil then
					local cam = workspace.CurrentCamera
					local vp = cam and cam.ViewportSize or Vector2.new(1280, 720)
					local sx = data.iconPos.ScaleX or 0
					local ox = data.iconPos.OffsetX or 346
					local sy = data.iconPos.ScaleY or 0
					local oy = data.iconPos.OffsetY or 10
					local calcY = sy * vp.Y + oy
					local calcX = sx * vp.X + ox
					if calcY < 0 or calcY > (vp.Y - 40) or calcX < 0 or calcX > (vp.X - 40) then
						HUB.Config.iconPos = { ScaleX = 0, OffsetX = 346, ScaleY = 0, OffsetY = 10 }
					else
						HUB.Config.iconPos = data.iconPos
					end
				end
			end
		end
	end
	-- สืบทอดค่าจาก session ใน memory ล่าสุดที่เปิดไว้ (ไม่ให้กลายเป็น OFF ตอน execute ซ้ำ)
	if prevConfig then
		for k, v in pairs(prevConfig) do
			if HUB.Config[k] ~= nil then
				if k == "iconPos" and type(v) == "table" then
					local cam = workspace.CurrentCamera
					local vp = cam and cam.ViewportSize or Vector2.new(1280, 720)
					local calcY = (v.ScaleY or 0) * vp.Y + (v.OffsetY or 10)
					local calcX = (v.ScaleX or 0) * vp.X + (v.OffsetX or 346)
					if calcY >= 0 and calcY <= (vp.Y - 40) and calcX >= 0 and calcX <= (vp.X - 40) then
						HUB.Config.iconPos = v
					else
						HUB.Config.iconPos = { ScaleX = 0, OffsetX = 346, ScaleY = 0, OffsetY = 10 }
					end
				elseif k == "bossPreSpawnThreshold" then
					local bSec = tonumber(v) or 15
					bSec = math.clamp(math.floor(bSec / 5 + 0.5) * 5, 5, 60)
					HUB.Config.bossPreSpawnThreshold = bSec
				else
					HUB.Config[k] = v
				end
			end
		end
	end
end

loadConfig()

-- ===== 6.5 ระบบ Item Tier Ranking Engine, Central Registry & Zero-Flicker Reactive Overlay (v5.3) =====
do
	local RS = game:GetService("ReplicatedStorage")
	local Shared = RS:WaitForChild("Shared", 30)
	local gdMod = Shared and (Shared:FindFirstChild("GearData") or Shared:WaitForChild("GearData", 15))
	local guMod = Shared and (Shared:FindFirstChild("GearUtil") or Shared:WaitForChild("GearUtil", 15))
	local GearData = gdMod and require(gdMod)
	local GearUtil = guMod and require(guMod)
	HUB.GearData = GearData
	HUB.GearUtil = GearUtil

	local TIER_COLORS = {
		SS = Color3.fromRGB(255, 42, 85),   -- #FF2A55 Bold Ruby Red (God Roll)
		S  = Color3.fromRGB(255, 159, 0),  -- #FF9F00 Vivid Amber Gold (Great Roll)
		A  = Color3.fromRGB(168, 69, 255), -- #A845FF Electric Violet (Good Roll)
		B  = Color3.fromRGB(0, 132, 255),  -- #0084FF Brilliant Azure Blue (Decent Roll)
		C  = Color3.fromRGB(40, 200, 64),  -- #28C840 Emerald Green (Average Roll)
		D  = Color3.fromRGB(142, 149, 165),-- #8E95A5 Crisp Steel Blue-Gray (Poor Roll)
		F  = Color3.fromRGB(90, 96, 110),  -- #5A606E Muted Gunmetal (Scrap Roll)
	}

	local TIER_DARK_STROKES = {
		SS = Color3.fromRGB(35, 5, 10),
		S  = Color3.fromRGB(40, 20, 0),
		A  = Color3.fromRGB(30, 5, 45),
		B  = Color3.fromRGB(0, 20, 50),
		C  = Color3.fromRGB(5, 35, 15),
		D  = Color3.fromRGB(20, 25, 30),
		F  = Color3.fromRGB(15, 15, 20),
	}

	-- ตารางกฎสเตตัสต้องห้าม (Forbidden Stats) ตามชนิดของอุปกรณ์
	local FORBIDDEN_RULES = {
		melee_phys   = { INT = true, DEX = true }, -- อาวุธตีใกล้: ห้ามมี INT, DEX
		ranged_phys  = { INT = true, STR = true }, -- อาวุธตีไกล/ธนู: ห้ามมี INT, STR
		magic_weapon = { STR = true, AGI = true }, -- อาวุธเวททั่วไป (คทา/ไม้เท้า): ห้ามมี STR, AGI
		flask_magic  = { STR = true },             -- อาวุธขวดน้ำยา Alchemist: ห้ามมี STR (ปลดล็อก AGI โดยเฉพาะสำหรับขวด)
		ring_phys    = { INT = true, SP = true },  -- แหวนกายภาพ: ห้ามมี INT, SP
		ring_magic   = { STR = true },             -- แหวนเวทย์: ห้ามมี STR (AGI ปลดล็อกแล้ว ไม่ถูกหักคะแนน)
	}

	local function classifyArchetype(resolved, rawGear)
		local kind = resolved.Kind
		local slot = resolved.Slot
		local id = string.lower(resolved.Id or rawGear.Id or "")
		local isFlask = id:find("flask") or resolved.IsFlask == true or (rawGear and rawGear.IsFlask == true)
		if kind == "weapon" then
			if id:find("bow") then
				return "ranged_phys"
			elseif isFlask then
				return "flask_magic"
			elseif id:find("rod") or id:find("staff") or resolved.MATK ~= nil then
				return "magic_weapon"
			else
				return "melee_phys"
			end
		elseif slot == "Acc" or slot == "Acc1" or slot == "Acc2" then
			if id:find("ring_water") or resolved.MATK ~= nil or (resolved.MainKey == "MATK") then
				return "ring_magic"
			else
				return "ring_phys"
			end
		else
			return "armor"
		end
	end

	local ItemTier = {
		Colors = TIER_COLORS,
		Strokes = TIER_DARK_STROKES,
		LastSummary = { SS = 0, S = 0, A = 0, B = 0, C = 0, D = 0, F = 0, Total = 0 },
		InvCache = nil,
		Registry = {}, -- Central Pre-calculated Registry: [ref] = { Grade, Score, RawGrade, HasForbidden, ForbiddenList, Name, Tier, Might, SetId, Archetype }
		Signatures = {}, -- Delta Memoization Cache: [ref] = signature
		Cache = nil,   -- Backward compatibility alias to Registry
		SelectedRef = nil,
	}
	ItemTier.Cache = ItemTier.Registry
	HUB.ItemTier = ItemTier

	local lastGcAttempt = 0
	local function getInvTable()
		if ItemTier.InvCache and type(ItemTier.InvCache.cells) == "table" and type(ItemTier.InvCache.cellOf) == "table" then
			return ItemTier.InvCache
		end
		local now = os.clock()
		if now - lastGcAttempt < 3.0 then
			return nil
		end
		lastGcAttempt = now
		if type(EXEC.getgc) == "function" then
			for _, obj in ipairs(EXEC.getgc(true)) do
				if type(obj) == "table" and rawget(obj, "cellOf") and rawget(obj, "cells") then
					ItemTier.InvCache = obj
					return obj
				end
			end
		end
		return nil
	end

	function ItemTier.EvaluateGear(ref, rawGear)
		if (not GearData or not GearUtil) and Shared then
			if not GearData and Shared:FindFirstChild("GearData") then
				pcall(function() GearData = require(Shared.GearData); HUB.GearData = GearData end)
			end
			if not GearUtil and Shared:FindFirstChild("GearUtil") then
				pcall(function() GearUtil = require(Shared.GearUtil); HUB.GearUtil = GearUtil end)
			end
		end
		if not GearData or not GearUtil or type(rawGear) ~= "table" then return nil end
		local resolved = GearUtil.Resolve(ref, { [ref] = rawGear })
		if not resolved then return nil end

		local tier = rawGear.T or 1
		local might = rawGear.M or 0
		local options = rawGear.O or {}
		local setId = rawGear.S
		local kind = resolved.Kind
		local slot = resolved.Slot

		local archetype = classifyArchetype(resolved, rawGear)
		local forbiddenMap = FORBIDDEN_RULES[archetype]
		local specKeys = GearData.SpecialKeys or {}

		-- =====================================================================
		-- 1. Main Stat Min-Max Score (Normalized Roll Ratio)
		-- =====================================================================
		local mainMin, mainMax = 0, 0
		if kind == "weapon" then
			local r = GearData.Main and GearData.Main.WeaponAtk and GearData.Main.WeaponAtk[tier]
			if r then mainMin, mainMax = r[1], r[2] end
		elseif slot == "Body" then
			local r = GearData.Main and GearData.Main.BodyDef and GearData.Main.BodyDef[tier]
			if r then mainMin, mainMax = r[1], r[2] end
		elseif slot == "Acc" or slot == "Acc1" or slot == "Acc2" then
			local r = GearData.Main and GearData.Main.RingAtk and GearData.Main.RingAtk[tier]
			if r then mainMin, mainMax = r[1], r[2] end
		else
			local r = GearData.Main and GearData.Main.PieceDef and GearData.Main.PieceDef[tier]
			if r then mainMin, mainMax = r[1], r[2] end
		end

		local ratioMain = 0.5
		if mainMax > mainMin then
			ratioMain = math.clamp((might - mainMin) / (mainMax - mainMin), 0, 1)
		end

		-- =====================================================================
		-- 2. Special Option Min-Max Score (Normalized Roll Ratio)
		-- =====================================================================
		local ratioSpecial = 0
		local hasSpecialOpt = false
		local specVal = nil
		local specMax = nil
		for optKey, val in pairs(options) do
			if specKeys[optKey] then
				hasSpecialOpt = true
				specVal = val
				local r = nil
				if type(GearData.OptionRange) == "function" then
					local okRange, resRange = pcall(GearData.OptionRange, optKey, tier, true)
					if okRange and type(resRange) == "table" then r = resRange end
				end
				if not r and GearData.Options and GearData.Options.SpecialRange and GearData.Options.SpecialRange[optKey] then
					r = GearData.Options.SpecialRange[optKey][tier]
				end

				if r and type(r) == "table" and r[2] and r[1] then
					specMax = r[2]
					if r[2] > r[1] then
						ratioSpecial = math.clamp((val - r[1]) / (r[2] - r[1]), 0, 1)
					else
						ratioSpecial = 1.0
					end
				else
					ratioSpecial = 0.7
				end
				break
			end
		end

		-- =====================================================================
		-- 3. Random Stats Min-Max & Forbidden Stats Detection
		-- =====================================================================
		local hasForbidden = false
		local forbiddenList = {}
		local validStatsSum = 0
		local validStatsCount = 0

		for optKey, val in pairs(options) do
			if not specKeys[optKey] then
				if forbiddenMap and forbiddenMap[optKey] then
					hasForbidden = true
					table.insert(forbiddenList, optKey)
				else
					local r = nil
					if type(GearData.OptionRange) == "function" then
						local okRange, resRange = pcall(GearData.OptionRange, optKey, tier)
						if okRange and type(resRange) == "table" then r = resRange end
					end
					local sMin, sMax = 1, tier * 2
					if r and type(r) == "table" and r[1] and r[2] then
						sMin, sMax = r[1], r[2]
					end
					local ratio = 0.5
					if sMax > sMin then
						ratio = math.clamp((val - sMin) / (sMax - sMin), 0, 1)
					else
						ratio = 1.0
					end
					validStatsSum = validStatsSum + ratio
					validStatsCount = validStatsCount + 1
				end
			end
		end

		local avgValidRatio = (validStatsCount > 0) and (validStatsSum / validStatsCount) or 0
		local expectedLines = 3
		if GearData.Options and GearData.Options.Lines and GearData.Options.Lines[tier] then
			expectedLines = GearData.Options.Lines[tier]
		end
		local lineCompleteness = math.clamp(validStatsCount / math.max(expectedLines, 1), 0, 1)

		-- =====================================================================
		-- 4. Set Score & Weight Distribution (Total 100 Points)
		-- =====================================================================
		local sMain = 0
		local sSpecial = 0
		local sRandom = 0
		local sSet = 0

		local isGearWithSet = (archetype == "armor")
		if isGearWithSet then
			-- Armor: Main 30 | Special 30 | Random 25 | Set 15
			local maxMain, maxSpecial, maxRandom, maxSet = 30, 30, 25, 15
			if not hasSpecialOpt and tier <= 2 then
				maxMain, maxSpecial, maxRandom = 45, 0, 40
			end

			sMain = ratioMain * maxMain
			sSpecial = hasSpecialOpt and (ratioSpecial * maxSpecial) or 0
			sRandom = ((avgValidRatio * 0.75) + (lineCompleteness * 0.25)) * maxRandom

			if setId then
				if setId == "bloodlord" then
					sSet = 15
				elseif setId == "luckystar" then
					sSet = 13
				else
					sSet = 10
				end
				if setId == "warrior" and (options.STR or options.ATK or options.CRIT or options.VIT) then
					sSet = math.min(15, sSet + 2)
				elseif setId == "archmage" and (options.INT or options.MATK or options.SP or options.CastSpeed) then
					sSet = math.min(15, sSet + 2)
				elseif setId == "guardian" and (options.DEF or options.VIT or options.HP or options.DefPercent) then
					sSet = math.min(15, sSet + 2)
				elseif setId == "gale" and (options.AGI or options.ASPD or options.Speed or options.FLEE) then
					sSet = math.min(15, sSet + 2)
				elseif setId == "luckystar" and (options.LUK or options.CRIT) then
					sSet = math.min(15, sSet + 2)
				end
			end
		else
			-- Weapons & Rings: Main 35 | Special 35 | Random 30
			local maxMain, maxSpecial, maxRandom = 35, 35, 30
			if not hasSpecialOpt and tier <= 2 then
				maxMain, maxSpecial, maxRandom = 50, 0, 50
			end

			sMain = ratioMain * maxMain
			sSpecial = hasSpecialOpt and (ratioSpecial * maxSpecial) or 0

			if hasForbidden then
				sRandom = (validStatsCount / math.max(expectedLines, 1)) * (avgValidRatio * 15)
			else
				sRandom = ((avgValidRatio * 0.75) + (lineCompleteness * 0.25)) * maxRandom
			end
		end

		local total = math.floor(sMain + sSpecial + sRandom + sSet + 0.5)
		total = math.clamp(total, 0, 100)

		-- Raw Grade Thresholds
		local rawGrade = "F"
		if total >= 90 then rawGrade = "SS"
		elseif total >= 80 then rawGrade = "S"
		elseif total >= 70 then rawGrade = "A"
		elseif total >= 55 then rawGrade = "B"
		elseif total >= 40 then rawGrade = "C"
		elseif total >= 25 then rawGrade = "D"
		else rawGrade = "F"
		end

		-- =====================================================================
		-- 5. Tier Drop Penalty for Forbidden Stats
		-- Rule: Disqualify SS/S immediately + Drop 2 Grades
		-- =====================================================================
		local finalGrade = rawGrade
		if hasForbidden then
			if rawGrade == "SS" or rawGrade == "S" then
				finalGrade = "B"
			elseif rawGrade == "A" then
				finalGrade = "C"
			elseif rawGrade == "B" then
				finalGrade = "D"
			else
				finalGrade = "F"
			end
		end

		-- =====================================================================
		-- 6. Star Roll Evaluation (Main Stat + Special Stat Max Roll Quality)
		-- Rainbow: ทั้ง 2 Stats Max ทั้งคู่ (100% Both)
		-- Gold: รวมกันเฉลี่ย >= 90%
		-- Silver: รวมกันเฉลี่ย >= 80%
		-- =====================================================================
		local isMainMax = (mainMax > 0 and might >= mainMax)
		local isSpecialMax = (hasSpecialOpt and specMax and specVal and specVal >= specMax)
		local combinedScore = hasSpecialOpt and ((ratioMain + ratioSpecial) / 2) or ratioMain
		local starPct = math.floor(combinedScore * 100 + 0.5)
		local starType = nil

		if hasSpecialOpt then
			if isMainMax and isSpecialMax then
				starType = "Rainbow"
			elseif starPct >= 90 then
				starType = "Gold"
			elseif starPct >= 80 then
				starType = "Silver"
			end
		else
			if isMainMax then
				starType = "Rainbow"
			elseif starPct >= 90 then
				starType = "Gold"
			elseif starPct >= 80 then
				starType = "Silver"
			end
		end

		return {
			Grade = finalGrade,
			Score = total,
			RawGrade = rawGrade,
			HasForbidden = hasForbidden,
			ForbiddenList = forbiddenList,
			Name = resolved.Name,
			Tier = tier,
			Might = might,
			SetId = setId,
			Archetype = archetype,
			Star = starType,
			StarScore = combinedScore,
			IsMainMax = isMainMax,
			IsSpecialMax = isSpecialMax,
			RatioMain = ratioMain,
			RatioSpecial = ratioSpecial,
			Resolved = resolved,
		}
	end

	-- =========================================================================
	-- Single Source of Truth: Centralized Evaluation Registry (O(1) Instant Lookup)
	-- With Delta / Incremental Memoization Cache (Zero Stutter on Reroll / Drops)
	-- =========================================================================
	local function computeGearSig(rawGear)
		local optStr = ""
		if type(rawGear.O) == "table" then
			local parts = {}
			for k, v in pairs(rawGear.O) do
				table.insert(parts, k .. "=" .. tostring(v))
			end
			table.sort(parts)
			optStr = table.concat(parts, ",")
		end
		return (rawGear.Id or "") .. ":" .. tostring(rawGear.M or 0) .. ":" .. tostring(rawGear.T or 1) .. ":" .. tostring(rawGear.S or "") .. ":" .. optStr
	end

	function ItemTier.RefreshCache(forceFull)
		local gearJsonStr = LocalPlayer:GetAttribute("GearJson") or "{}"
		local okDecode, gearJson = pcall(HttpService.JSONDecode, HttpService, gearJsonStr)
		if not okDecode or type(gearJson) ~= "table" then
			gearJson = {}
		end

		local storageJsonStr = LocalPlayer:GetAttribute("StorageGearJson") or "{}"
		local okStorage, storageJson = pcall(HttpService.JSONDecode, HttpService, storageJsonStr)
		local storageG = (okStorage and type(storageJson) == "table" and type(storageJson.G) == "table") and storageJson.G or nil

		if not next(gearJson) and not (storageG and next(storageG)) then
			table.clear(ItemTier.Registry)
			table.clear(ItemTier.Signatures)
			ItemTier.Cache = ItemTier.Registry
			return
		end

		local oldRegistry = ItemTier.Registry
		local oldSigs = ItemTier.Signatures
		local newRegistry = {}
		local newSigs = {}
		local summary = { SS = 0, S = 0, A = 0, B = 0, C = 0, D = 0, F = 0, Total = 0 }

		local function ingestGears(gearDict)
			if type(gearDict) ~= "table" then return end
			for ref, rawGear in pairs(gearDict) do
				if type(ref) == "string" and type(rawGear) == "table" then
					local sig = computeGearSig(rawGear)
					newSigs[ref] = sig

					local res = nil
					if not forceFull and oldSigs[ref] == sig and oldRegistry[ref] ~= nil then
						res = oldRegistry[ref]
					else
						res = ItemTier.EvaluateGear(ref, rawGear)
					end

					if res then
						newRegistry[ref] = res
						summary[res.Grade] = (summary[res.Grade] or 0) + 1
						summary.Total = summary.Total + 1
					end
				end
			end
		end

		ingestGears(gearJson)
		ingestGears(storageG)

		ItemTier.Registry = newRegistry
		ItemTier.Signatures = newSigs
		ItemTier.Cache = ItemTier.Registry
		ItemTier.LastSummary = summary

		if HUB.UI.TierStatusLabel and HUB.Config.itemTierBadges then
			HUB.UI.TierStatusLabel.Text = string.format(
				"สถานะ: เปิดใช้งาน · SS:%d S:%d A:%d B:%d C:%d D:%d F:%d (รวม %d ชิ้น)",
				summary.SS, summary.S, summary.A, summary.B, summary.C, summary.D, summary.F, summary.Total
			)
		end
	end
	ItemTier.RebuildRegistry = ItemTier.RefreshCache

	-- =========================================================================
	-- Reusable In-Place Badge Binder (Anti-Flicker & Theme Immunity)
	-- =========================================================================
	local function createOrUpdateBadge(parent, ref, eval, size, pos, anchor, badgeName)
		if not parent or not eval then return nil end
		local targetName = badgeName or "TierBadge"

		-- ป้องกันป้ายซ้อนทับ: หา badge ตัวแรก และลบตัวเกินทั้งหมดทันที
		local badge = nil
		for _, child in ipairs(parent:GetChildren()) do
			if child.Name == targetName then
				if not badge then
					badge = child
				else
					pcall(child.Destroy, child)
				end
			end
		end

		local color = TIER_COLORS[eval.Grade] or TIER_COLORS.F
		local strokeColor = TIER_DARK_STROKES[eval.Grade] or Color3.fromRGB(15, 15, 20)

		if badge and not badge:GetAttribute("LumiKeepColor") then
			pcall(badge.Destroy, badge)
			badge = nil
		end

		if not badge then
			badge = Instance.new("Frame")
			badge.Name = targetName
			badge.AnchorPoint = anchor or Vector2.new(1, 0)
			badge.Position = pos or UDim2.new(1, -2, 0, 2)
			badge.Size = size or UDim2.fromOffset(20, 15)
			badge.BorderSizePixel = 0
			badge.ZIndex = 25
			badge.BackgroundColor3 = color

			-- Critical Attributes: ป้องกัน UiThemeClient แทรกแซงเปลี่ยนเป็นสีขาว/ครีม 100%
			badge:SetAttribute("LumiKeepColor", true)
			badge:SetAttribute("LumiKeepRound", true)
			badge:SetAttribute("LumiNoLine", true)
			badge:SetAttribute("LumiClickThrough", true)

			local corner = Instance.new("UICorner")
			corner.CornerRadius = UDim.new(0, 4)
			corner.Parent = badge

			local stroke = Instance.new("UIStroke")
			stroke.Name = "BadgeBorder"
			stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
			stroke.Color = strokeColor
			stroke.Thickness = 1
			stroke.Parent = badge

			local lbl = Instance.new("TextLabel")
			lbl.Name = "GradeLabel"
			lbl.Size = UDim2.fromScale(1, 1)
			lbl.BackgroundTransparency = 1
			lbl.Text = eval.Grade
			lbl.TextColor3 = Color3.fromRGB(255, 255, 255)
			lbl.Font = Enum.Font.GothamBlack
			local tSize = 13
			if size then
				if size.Y.Offset >= 20 then
					tSize = 15
				elseif size.Y.Offset >= 17 then
					tSize = 13
				else
					tSize = 12
				end
			end
			lbl.TextSize = tSize
			lbl.ZIndex = 26
			lbl:SetAttribute("LumiKeepColor", true)
			lbl:SetAttribute("LumiKeepText", true)
			lbl:SetAttribute("LumiKeepLight", true)
			lbl:SetAttribute("LumiKeepFont", true)
			lbl:SetAttribute("LumiNoTranslate", true)

			-- Contextual Text Outline: คมชัดทุกมิติ ตัวอักษรไม่กลืนกับพื้นหลัง
			local textStroke = Instance.new("UIStroke")
			textStroke.Name = "TextOutline"
			textStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
			textStroke.Color = Color3.fromRGB(5, 5, 8)
			textStroke.Thickness = 1.3
			textStroke.Parent = lbl

			lbl.Parent = badge
			badge.Parent = parent
		else
			-- In-Place Mutation: อัปเดตเฉพาะค่าที่เปลี่ยน ไม่ลบ/สร้างใหม่ ป้องกันอาการกระพริบ
			if badge.BackgroundColor3 ~= color then
				badge.BackgroundColor3 = color
			end
			if anchor and badge.AnchorPoint ~= anchor then
				badge.AnchorPoint = anchor
			end
			if pos and badge.Position ~= pos then
				badge.Position = pos
			end
			if size and badge.Size ~= size then
				badge.Size = size
			end
			local border = badge:FindFirstChild("BadgeBorder")
			if border and border.Color ~= strokeColor then
				border.Color = strokeColor
			end
			local lbl = badge:FindFirstChild("GradeLabel")
			if lbl then
				if lbl.Text ~= eval.Grade then
					lbl.Text = eval.Grade
				end
				if lbl.TextColor3 ~= Color3.fromRGB(255, 255, 255) then
					lbl.TextColor3 = Color3.fromRGB(255, 255, 255)
				end
				if not lbl:GetAttribute("LumiKeepText") then
					lbl:SetAttribute("LumiKeepColor", true)
					lbl:SetAttribute("LumiKeepText", true)
					lbl:SetAttribute("LumiKeepLight", true)
					lbl:SetAttribute("LumiKeepFont", true)
					lbl:SetAttribute("LumiNoTranslate", true)
				end
				local tSize = 13
				if size then
					if size.Y.Offset >= 20 then
						tSize = 15
					elseif size.Y.Offset >= 17 then
						tSize = 13
					else
						tSize = 12
					end
				end
				if lbl.TextSize ~= tSize then
					lbl.TextSize = tSize
				end
			end
			if not badge.Visible then
				badge.Visible = true
			end
		end

		badge:SetAttribute("BoundRef", ref)
		return badge
	end

	local STAR_IMAGE = "rbxassetid://127066642314924"
	local STAR_COLORS = {
		Silver = Color3.fromRGB(240, 248, 255),
		Gold = Color3.fromRGB(255, 215, 0),
		Rainbow = Color3.fromRGB(255, 255, 255)
	}

	local function createOrUpdateStarBadge(parent, ref, eval, size, pos, anchor, badgeName)
		if not parent then return nil end
		local targetName = badgeName or "StarBadge"
		local starType = eval and eval.Star

		if not starType then
			local firstFound = false
			for _, child in ipairs(parent:GetChildren()) do
				if child.Name == targetName then
					if not firstFound then
						firstFound = true
						if child.Visible then child.Visible = false end
					else
						pcall(child.Destroy, child)
					end
				end
			end
			return nil
		end

		local star = nil
		for _, child in ipairs(parent:GetChildren()) do
			if child.Name == targetName then
				if not star then
					star = child
				else
					pcall(child.Destroy, child)
				end
			end
		end

		if not star then
			star = Instance.new("ImageLabel")
			star.Name = targetName
			star.AnchorPoint = anchor or Vector2.new(1, 0)
			star.Position = pos or UDim2.new(1, -5, 0, 21)
			star.Size = size or UDim2.fromOffset(18, 18)
			star.BackgroundTransparency = 1
			star.Image = STAR_IMAGE
			star.ScaleType = Enum.ScaleType.Fit
			star.ZIndex = 27

			star:SetAttribute("LumiKeepColor", true)
			star:SetAttribute("LumiSkipIcon", true)
			star:SetAttribute("LumiNoLine", true)
			star:SetAttribute("LumiClickThrough", true)

			local grad = Instance.new("UIGradient")
			grad.Name = "RainbowGrad"
			grad.Color = ColorSequence.new({
				ColorSequenceKeypoint.new(0.00, Color3.fromRGB(255, 60, 60)),
				ColorSequenceKeypoint.new(0.20, Color3.fromRGB(255, 165, 30)),
				ColorSequenceKeypoint.new(0.40, Color3.fromRGB(255, 235, 40)),
				ColorSequenceKeypoint.new(0.60, Color3.fromRGB(40, 230, 90)),
				ColorSequenceKeypoint.new(0.80, Color3.fromRGB(40, 180, 255)),
				ColorSequenceKeypoint.new(1.00, Color3.fromRGB(190, 70, 255)),
			})
			grad.Rotation = 45
			grad.Enabled = (starType == "Rainbow")
			grad.Parent = star

			star.ImageColor3 = STAR_COLORS[starType] or Color3.fromRGB(255, 255, 255)
			star.Parent = parent
		else
			local shadow = star:FindFirstChild("StarShadow")
			if shadow then pcall(shadow.Destroy, shadow) end

			if pos and star.Position ~= pos then star.Position = pos end
			if size and star.Size ~= size then star.Size = size end
			if anchor and star.AnchorPoint ~= anchor then star.AnchorPoint = anchor end
			local targetColor = STAR_COLORS[starType] or Color3.fromRGB(255, 255, 255)
			if star.ImageColor3 ~= targetColor then star.ImageColor3 = targetColor end

			local grad = star:FindFirstChild("RainbowGrad")
			if grad then
				local isRainbow = (starType == "Rainbow")
				if grad.Enabled ~= isRainbow then grad.Enabled = isRainbow end
			end
			if not star.Visible then star.Visible = true end
		end

		star:SetAttribute("BoundRef", ref)
		return star
	end

	local function isTierActive()
		return HUB.Alive and EXEC.env.HuntingTogetherHub_Token == MY_TOKEN and HUB.Config.itemTierBadges
	end

	function ItemTier.ClearBadges()
		purgeAllTierBadgesAndHooks(false, true)
	end

	local function applyCellBadge(cell, ref)
		if not isTierActive() then return end
		if not cell or not cell:IsA("GuiObject") then return end
		local eval = ref and (ItemTier.Registry[ref] or ItemTier.Cache[ref])
		if eval then
			-- ย้าย Tier Badge ไปมุมบนซ้าย (Top-Left: 0, 2, 0, 2)
			createOrUpdateBadge(cell, ref, eval, UDim2.fromOffset(24, 17), UDim2.new(0, 2, 0, 2), Vector2.new(0, 0))
			-- ย้าย Star Badge ใต้ Tier Badge ที่มุมบนซ้าย (Top-Left: 0, 5, 0, 21)
			createOrUpdateStarBadge(cell, ref, eval, UDim2.fromOffset(18, 18), UDim2.new(0, 5, 0, 21), Vector2.new(0, 0))
			local itemCount = cell:FindFirstChild("ItemCount")
			if itemCount and itemCount:IsA("TextLabel") then
				if itemCount.Text:match("^[IVXLCDM]+$") then
					-- ซ่อนเลขโรมันบอกระดับ Tier ของเกม เพราะมีป้าย Tier Badge ชัดเจนแล้ว
					itemCount.Visible = false
				elseif itemCount.Text:match("^[IVXLCDM]+%+(%d+)$") then
					-- แสดงเฉพาะเลขตีบวก (+5) และคงพิกัดมุมบนขวาแท้ของเกม ไม่ดันออกข้าง
					local plus = itemCount.Text:match("%+(%d+)$")
					itemCount.Text = "+" .. plus
					itemCount.Position = UDim2.new(1, -67, 0, 1)
					itemCount.Visible = true
				end
			end
		else
			for _, child in ipairs(cell:GetChildren()) do
				if child.Name == "TierBadge" or child.Name == "StarBadge" then
					pcall(child.Destroy, child)
				end
			end
			local itemCount = cell:FindFirstChild("ItemCount")
			if itemCount and itemCount:IsA("TextLabel") then
				itemCount.Position = UDim2.new(1, -67, 0, 1)
				if not itemCount.Visible then itemCount.Visible = true end
			end
		end
	end
	ItemTier.ApplyCellBadge = applyCellBadge

	local function resolveCurrentPopupRef()
		local pgui = LocalPlayer:FindFirstChild("PlayerGui")
		if not pgui then return nil end
		local lumi = pgui:FindFirstChild("LumiInventory")
		local popup = lumi and lumi:FindFirstChild("ItemPopup")
		if not popup then return nil end

		local head = popup:FindFirstChild("Head")
		local titleLbl = head and head:FindFirstChild("Title")
		local titleText = titleLbl and titleLbl.Text or ""
		local baseTitle = titleText:match("^(.-)%s*%+%d+$") or titleText:match("^(.-)%s*x%d+$") or titleText
		baseTitle = baseTitle:match("^%s*(.-)%s*$")

		-- 1. ตรวจสอบ Upvalue ตรงจากปุ่ม Action ใน InventoryClient (u3040) — แม่นยำ 100%
		local buttons = popup:FindFirstChild("Buttons")
		if buttons and type(EXEC.getconnections) == "function" and type(EXEC.getupvalues) == "function" then
			for _, btn in ipairs(buttons:GetChildren()) do
				if btn:IsA("TextButton") then
					local conns = EXEC.getconnections(btn.MouseButton1Click)
					for _, c in ipairs(conns) do
						if c.Function then
							local uvs = EXEC.getupvalues(c.Function)
							for _, val in pairs(uvs) do
								if type(val) == "string" and val:match("^g%d+$") then
									local eval = ItemTier.Registry[val]
									if eval and (baseTitle == "" or eval.Name == baseTitle) then
										return val
									end
								end
							end
						end
					end
				end
			end
		end

		-- 2. ตรวจสอบค่า SelectedRef ปัจจุบัน ถ้าชื่อตรงกับ Title.Text ให้คงตัวเดิมไว้ (ไม่เปลี่ยนสลับไปมา)
		if ItemTier.SelectedRef and baseTitle ~= "" then
			local curEval = ItemTier.Registry[ItemTier.SelectedRef]
			if curEval and curEval.Name == baseTitle then
				return ItemTier.SelectedRef
			end
		end

		-- 3. ตรวจสอบอุปกรณ์ที่สวมใส่อยู่จาก EquipJson / WeaponId
		if baseTitle ~= "" then
			local equipJsonStr = LocalPlayer:GetAttribute("EquipJson") or "{}"
			local okEquip, equipJson = pcall(HttpService.JSONDecode, HttpService, equipJsonStr)
			if okEquip and type(equipJson) == "table" then
				local weaponId = LocalPlayer:GetAttribute("WeaponId")
				if type(weaponId) == "string" and weaponId ~= "" then
					equipJson.RightHand = weaponId
				end
				for _, ref in pairs(equipJson) do
					local eval = ref and ItemTier.Registry[ref]
					if eval and eval.Name and eval.Name == baseTitle then
						return ref
					end
				end
			end
		end

		-- 4. ค้นหาไอเทมใน InventoryCache ที่ตรงกับชื่อใน Title
		local inv = getInvTable()
		if inv and type(inv.cells) == "table" and baseTitle ~= "" then
			for ref, data in pairs(inv.cells) do
				local eval = ItemTier.Registry[ref]
				if eval and eval.Name == baseTitle then
					return ref
				end
			end
		end

		return nil
	end
	ItemTier.ResolveCurrentPopupRef = resolveCurrentPopupRef

	local function updatePopupBadge(ref)
		if not isTierActive() then return end
		local pgui = LocalPlayer:FindFirstChild("PlayerGui")
		if not pgui then return end
		local lumi = pgui:FindFirstChild("LumiInventory")
		local popup = lumi and lumi:FindFirstChild("ItemPopup")
		if not popup then return end
		local head = popup:FindFirstChild("Head")
		if not head then return end

		-- ถ้าหน้าต่าง ItemPopup ไม่ได้เปิดอยู่ ให้ซ่อน Badge ทั้งคู่
		if not popup.Visible then
			for _, b in ipairs(head:GetChildren()) do
				if (b.Name == "PopupTierBadge" or b.Name == "PopupStarBadge") and b.Visible then
					b.Visible = false
				end
			end
			return
		end

		-- ระบุ targetRef อย่างแม่นยำ
		local targetRef = ref or resolveCurrentPopupRef()
		local eval = targetRef and (ItemTier.Registry[targetRef] or ItemTier.Cache[targetRef])

		-- ถ้าไอเทมที่เลือกไม่ใช่ Gear (เช่น ยา, ขยะ, วัตถุดิบ) หรือไม่พบข้อมูล ให้ซ่อน Badge
		if not eval then
			for _, b in ipairs(head:GetChildren()) do
				if (b.Name == "PopupTierBadge" or b.Name == "PopupStarBadge") and b.Visible then
					b.Visible = false
				end
			end
			return
		end

		-- บันทึก SelectedRef ล่าสุดไว้เสมอ
		ItemTier.SelectedRef = targetRef

		local color = TIER_COLORS[eval.Grade] or TIER_COLORS.F
		local strokeColor = TIER_DARK_STROKES[eval.Grade] or Color3.fromRGB(15, 15, 20)
		local newText = string.format("TIER %s · %d%%", eval.Grade, math.floor(eval.Score + 0.5))

		-- ป้องกันป้ายซ้อนทับใน Head
		local badge = nil
		for _, child in ipairs(head:GetChildren()) do
			if child.Name == "PopupTierBadge" then
				if not badge then
					badge = child
				else
					pcall(child.Destroy, child)
				end
			end
		end

		if not badge then
			badge = Instance.new("Frame")
			badge.Name = "PopupTierBadge"
			badge.AnchorPoint = Vector2.new(1, 0)
			badge.Position = UDim2.new(1, -6, 0, 6)
			badge.Size = UDim2.fromOffset(84, 24)
			badge.BorderSizePixel = 0
			badge.ZIndex = 30
			badge.BackgroundColor3 = color
			badge:SetAttribute("LumiKeepColor", true)
			badge:SetAttribute("LumiKeepRound", true)
			badge:SetAttribute("LumiNoLine", true)
			badge:SetAttribute("LumiClickThrough", true)

			local corner = Instance.new("UICorner")
			corner.CornerRadius = UDim.new(0, 4)
			corner.Parent = badge

			local stroke = Instance.new("UIStroke")
			stroke.Name = "Border"
			stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
			stroke.Color = strokeColor
			stroke.Thickness = 1.5
			stroke.Parent = badge

			local lbl = Instance.new("TextLabel")
			lbl.Name = "Text"
			lbl.Size = UDim2.fromScale(1, 1)
			lbl.BackgroundTransparency = 1
			lbl.Font = Enum.Font.GothamBlack
			lbl.TextSize = 13
			lbl.TextColor3 = Color3.fromRGB(255, 255, 255)
			lbl.Text = newText
			lbl.ZIndex = 31
			lbl:SetAttribute("LumiKeepColor", true)
			lbl:SetAttribute("LumiKeepText", true)
			lbl:SetAttribute("LumiKeepLight", true)
			lbl:SetAttribute("LumiKeepFont", true)
			lbl:SetAttribute("LumiNoTranslate", true)

			local tstroke = Instance.new("UIStroke")
			tstroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
			tstroke.Color = Color3.fromRGB(10, 10, 15)
			tstroke.Thickness = 1
			tstroke.Parent = lbl

			lbl.Parent = badge
			badge.Parent = head
		else
			-- In-Place Mutation: ปรับเฉพาะ property ที่เปลี่ยน ไม่ destroy หรือ toggle visible ไปมา ตัดการกระพริบ 100%
			if not badge.Visible then
				badge.Visible = true
			end
			if badge.BackgroundColor3 ~= color then
				badge.BackgroundColor3 = color
			end
			local bBorder = badge:FindFirstChild("Border")
			if bBorder and bBorder.Color ~= strokeColor then
				bBorder.Color = strokeColor
			end
			local lbl = badge:FindFirstChild("Text")
			if lbl then
				if lbl.Text ~= newText then
					lbl.Text = newText
				end
				if lbl.TextColor3 ~= Color3.fromRGB(255, 255, 255) then
					lbl.TextColor3 = Color3.fromRGB(255, 255, 255)
				end
				if not lbl:GetAttribute("LumiKeepText") then
					lbl:SetAttribute("LumiKeepColor", true)
					lbl:SetAttribute("LumiKeepText", true)
					lbl:SetAttribute("LumiKeepLight", true)
					lbl:SetAttribute("LumiKeepFont", true)
					lbl:SetAttribute("LumiNoTranslate", true)
				end
			end
		end

		-- แยกสร้างหรืออัปเดต PopupStarBadge ให้เป็น Icon แยกข้างป้าย Tier
		createOrUpdateStarBadge(head, targetRef, eval, UDim2.fromOffset(22, 22), UDim2.new(1, -94, 0, 7), Vector2.new(1, 0), "PopupStarBadge")
	end
	ItemTier.UpdatePopupBadge = updatePopupBadge

	function ItemTier.UpdateBadges()
		if not HUB.Alive or EXEC.env.HuntingTogetherHub_Token ~= MY_TOKEN then return end
		if not HUB.Config.itemTierBadges then
			ItemTier.ClearBadges()
			return
		end

		local pgui = LocalPlayer:FindFirstChild("PlayerGui")
		if not pgui then return end

		-- อัปเดต Single Source of Truth Cache ถ้ายังไม่มีข้อมูล
		if not next(ItemTier.Registry) then
			ItemTier.RefreshCache()
		end

		-- =========================================================================
		-- Sub-routine A: Bag Inventory Badges (LumiInventory) — Zero Flicker & Conflict Free
		-- =========================================================================
		local lumi = pgui:FindFirstChild("LumiInventory")
		local invWin = lumi and lumi:FindFirstChild("InventoryWindow", true)
		if invWin and invWin.Visible then
			local sf = invWin:FindFirstChild("ScrollingFrame", true)
			local inv = getInvTable()
			if sf and inv and type(inv.cellOf) == "table" then
				-- In-Place Mutation 100%: ไม่ Destroy ทิ้งก่อน เพื่อตัดปัญหาภาพกะพริบ
				for _, child in ipairs(sf:GetChildren()) do
					if child:IsA("GuiObject") and child.Visible then
						local ref = inv.cellOf[child]
						applyCellBadge(child, ref)
					end
				end
			end
		end

		-- =========================================================================
		-- Sub-routine B: Equipped Slots Badges (LumiBagScreen) — Conflict Free Overlay
		-- =========================================================================
		local bagScreen = pgui:FindFirstChild("LumiBagScreen")
		if bagScreen and bagScreen.Enabled then
			local equipJsonStr = LocalPlayer:GetAttribute("EquipJson") or "{}"
			local okEquip, equipJson = pcall(HttpService.JSONDecode, HttpService, equipJsonStr)
			if not okEquip or type(equipJson) ~= "table" then equipJson = {} end

			local weaponId = LocalPlayer:GetAttribute("WeaponId")
			local slotMapping = {
				Slot_RightHand = (type(weaponId) == "string" and weaponId ~= "" and weaponId) or equipJson.RightHand,
				Slot_HeadTop = equipJson.HeadTop,
				Slot_HeadMid = equipJson.HeadMid,
				Slot_Body = equipJson.Body,
				Slot_Garment = equipJson.Garment,
				Slot_Shoes = equipJson.Shoes,
				Slot_Acc1 = equipJson.Acc1,
				Slot_Acc2 = equipJson.Acc2,
			}

			-- Persistent Overlay Container: อยู่เหนือ slotBtn และไม่ถูก LumiPage.Clear() ลบทิ้ง (ป้องกันซ้อนทับ)
			local overlay = nil
			for _, child in ipairs(bagScreen:GetChildren()) do
				if child.Name == "LumiEquipTierOverlay" then
					if not overlay then
						overlay = child
					else
						pcall(child.Destroy, child)
					end
				end
			end
			if not overlay then
				overlay = Instance.new("Frame")
				overlay.Name = "LumiEquipTierOverlay"
				overlay.Size = UDim2.fromScale(1, 1)
				overlay.Position = UDim2.new()
				overlay.BackgroundTransparency = 1
				overlay.BorderSizePixel = 0
				overlay.ZIndex = 25
				overlay:SetAttribute("LumiKeepColor", true)
				overlay:SetAttribute("LumiClickThrough", true)
				overlay.Parent = bagScreen
			elseif not overlay.Visible then
				overlay.Visible = true
			end

			for slotName, ref in pairs(slotMapping) do
				local slotBtn = bagScreen:FindFirstChild(slotName)
				local badgeName = "EquipTierBadge_" .. slotName
				local starBadgeName = "EquipStarBadge_" .. slotName
				local eval = ref and ItemTier.Cache[ref]

				if eval and slotBtn and slotBtn:IsA("GuiObject") and slotBtn.Visible then
					-- ย้ายตำแหน่ง Tier Badge ไปไว้มุมบนซ้าย (AnchorPoint 0,0) ป้องกันการทับปุ่ม UnequipX ของเกม (มุมบนขวา)
					local bPos = UDim2.new(
						slotBtn.Position.X.Scale,
						slotBtn.Position.X.Offset + 3,
						slotBtn.Position.Y.Scale,
						slotBtn.Position.Y.Offset + 3
					)
					createOrUpdateBadge(overlay, ref, eval, UDim2.fromOffset(28, 20), bPos, Vector2.new(0, 0), badgeName)

					-- วาง Star Badge รองลงมาจาก Tier Badge ฝั่งซ้ายบน (ขยายขนาดเป็น 22x22 px ให้คมชัดเห็นชัดเจน)
					local sPos = UDim2.new(
						slotBtn.Position.X.Scale,
						slotBtn.Position.X.Offset + 6,
						slotBtn.Position.Y.Scale,
						slotBtn.Position.Y.Offset + 26
					)
					createOrUpdateStarBadge(overlay, ref, eval, UDim2.fromOffset(22, 22), sPos, Vector2.new(0, 0), starBadgeName)

					-- ซ่อนป้าย Count เลขโรมันของเกมในช่องสวมใส่เพื่อไม่ให้ซ้อนทับกัน
					local gameCount = slotBtn:FindFirstChild("Count", true)
					if gameCount and gameCount:IsA("TextLabel") and gameCount.Visible then
						gameCount.Visible = false
					end
				else
					local badge = overlay:FindFirstChild(badgeName)
					if badge then
						badge.Visible = false
					end
					local starBadge = overlay:FindFirstChild(starBadgeName)
					if starBadge then
						starBadge.Visible = false
					end
					local gameCount = slotBtn and slotBtn:FindFirstChild("Count", true)
					if gameCount and gameCount:IsA("TextLabel") and not gameCount.Visible then
						gameCount.Visible = true
					end
				end
			end
		else
			local overlay = bagScreen and bagScreen:FindFirstChild("LumiEquipTierOverlay")
			if overlay then
				overlay.Visible = false
			end
		end

		-- =========================================================================
		-- Sub-routine C: Shop / Sell Items Badges (HuntShop) — In-Place Mutation
		-- =========================================================================
		local huntShop = pgui:FindFirstChild("HuntShop")
		if huntShop and huntShop.Enabled then
			local holderWin = huntShop:FindFirstChild("Holder") and huntShop.Holder:FindFirstChild("Window")
			if holderWin then
				local middleScroll = nil
				for _, c in ipairs(holderWin:GetChildren()) do
					if c:IsA("GuiObject") and c.Name:match("^Card_") and c.Name ~= "Card_หมวด" and c.Name ~= "Card_รายละเอียด" then
						middleScroll = c:FindFirstChild("Scroll", true)
						break
					end
				end

				if middleScroll then
					for _, card in ipairs(middleScroll:GetChildren()) do
						if card:IsA("GuiObject") and card.Visible then
							local ref = card.Name
							local eval = ref and ItemTier.Cache[ref]
							if eval then
								createOrUpdateBadge(card, ref, eval, UDim2.fromOffset(32, 22), UDim2.new(1, -6, 0, 6), Vector2.new(1, 0))
								createOrUpdateStarBadge(card, ref, eval, UDim2.fromOffset(20, 20), UDim2.new(1, -12, 0, 31), Vector2.new(1, 0))
							else
								local badge = card:FindFirstChild("TierBadge")
								if badge then
									pcall(badge.Destroy, badge)
								end
								local star = card:FindFirstChild("StarBadge")
								if star then
									pcall(star.Destroy, star)
								end
							end
						end
					end
				end
			end
		end
		-- Sub-routine D: ItemPopup Badge (เฉพาะเมื่อ ItemPopup กำลังแสดงผลอยู่จริง)
		local popup = lumi and lumi:FindFirstChild("ItemPopup")
		if popup and popup.Visible then
			updatePopupBadge()
		end

		-- =========================================================================
		-- Sub-routine E: Reroll Equipment List Badges (HuntReroll) — Zero Flicker & O(1) Cache
		-- =========================================================================
		local huntReroll = pgui:FindFirstChild("HuntReroll")
		if huntReroll and huntReroll.Enabled then
			local win = huntReroll:FindFirstChild("Window", true)
			local scroll = win and win:FindFirstChild("Scroll", true)
			local probeClosure = ItemTier.RerollProbeClosure
			local selectedRef = nil
			if scroll then
				for _, rowBtn in ipairs(scroll:GetChildren()) do
					if rowBtn:IsA("GuiObject") and rowBtn.Name == "KitButton" and rowBtn.Visible then
						local ref = rowBtn:GetAttribute("BoundRef")
						if not ref and type(EXEC.getconnections) == "function" and type(EXEC.getupvalues) == "function" then
							local conns = EXEC.getconnections(rowBtn.MouseButton1Click)
							for _, c in ipairs(conns) do
								if c.Function then
									if not probeClosure then
										probeClosure = c.Function
										ItemTier.RerollProbeClosure = probeClosure
									end
									local uvs = EXEC.getupvalues(c.Function)
									if type(uvs[3]) == "table" and type(uvs[3].Ref) == "string" then
										ref = uvs[3].Ref
									elseif type(uvs[2]) == "string" and uvs[2]:match("^g%d+$") then
										ref = uvs[2]
									end
								end
								if ref then
									rowBtn:SetAttribute("BoundRef", ref)
									break
								end
							end
						end

						-- ดักฟังคลิกเปลี่ยนไอเทมเพื่ออัปเดตป้ายรายละเอียดทันที 0ms
						if not rowBtn:GetAttribute("TierRerollClicked") then
							rowBtn:SetAttribute("TierRerollClicked", true)
							HUB:AddConnection(rowBtn.MouseButton1Click:Connect(function()
								task.defer(function()
									if HUB.Alive and HUB.Config.itemTierBadges then
										ItemTier.UpdateBadges()
									end
								end)
							end))
						end

						local eval = ref and ItemTier.Registry[ref]
						local itemSlot = rowBtn:FindFirstChild("ItemSlot")
						if eval and itemSlot then
							createOrUpdateBadge(itemSlot, ref, eval, UDim2.fromOffset(24, 17), UDim2.new(1, -2, 0, 2), Vector2.new(1, 0))
							createOrUpdateStarBadge(itemSlot, ref, eval, UDim2.fromOffset(18, 18), UDim2.new(1, -5, 0, 21), Vector2.new(1, 0))
						elseif itemSlot then
							local b = itemSlot:FindFirstChild("TierBadge")
							if b then pcall(b.Destroy, b) end
							local s = itemSlot:FindFirstChild("StarBadge")
							if s then pcall(s.Destroy, s) end
						end
					end
				end
			end

			-- =========================================================================
			-- Sub-routine F: Reroll Selected Item Detail Badge (HuntReroll) — O(1) Probe
			-- =========================================================================
			local detail = win and win:FindFirstChild("Detail", true)
			local banner = detail and detail:FindFirstChild("Frame")
			if banner and banner.Visible then
				if not probeClosure and scroll and type(EXEC.getconnections) == "function" then
					local firstBtn = scroll:FindFirstChild("KitButton")
					if firstBtn then
						local conns = EXEC.getconnections(firstBtn.MouseButton1Click)
						probeClosure = conns and conns[1] and conns[1].Function
						ItemTier.RerollProbeClosure = probeClosure
					end
				end
				if probeClosure and type(EXEC.getupvalues) == "function" then
					local uvs = EXEC.getupvalues(probeClosure)
					if type(uvs[2]) == "string" and uvs[2]:match("^g%d+$") then
						selectedRef = uvs[2]
					end
				end

				local eval = selectedRef and ItemTier.Registry[selectedRef]
				if eval then
					local color = TIER_COLORS[eval.Grade] or TIER_COLORS.F
					local strokeColor = TIER_DARK_STROKES[eval.Grade] or Color3.fromRGB(15, 15, 20)
					local newText = string.format("TIER %s · %d%%", eval.Grade, math.floor(eval.Score + 0.5))
					local badge = nil
					for _, child in ipairs(banner:GetChildren()) do
						if child.Name == "PopupTierBadge" then
							if not badge then
								badge = child
							else
								pcall(child.Destroy, child)
							end
						end
					end
					if not badge then
						badge = Instance.new("Frame")
						badge.Name = "PopupTierBadge"
						badge.AnchorPoint = Vector2.new(1, 0)
						badge.Position = UDim2.new(1, -12, 0, 16)
						badge.Size = UDim2.fromOffset(84, 24)
						badge.BorderSizePixel = 0
						badge.ZIndex = 15
						badge.BackgroundColor3 = color
						badge:SetAttribute("LumiKeepColor", true)
						badge:SetAttribute("LumiClickThrough", true)

						local corner = Instance.new("UICorner")
						corner.CornerRadius = UDim.new(0, 4)
						corner.Parent = badge

						local stroke = Instance.new("UIStroke")
						stroke.Name = "Border"
						stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
						stroke.Color = strokeColor
						stroke.Thickness = 1.5
						stroke.Parent = badge

						local lbl = Instance.new("TextLabel")
						lbl.Name = "Text"
						lbl.Size = UDim2.fromScale(1, 1)
						lbl.BackgroundTransparency = 1
						lbl.Font = Enum.Font.GothamBlack
						lbl.TextSize = 13
						lbl.TextColor3 = Color3.fromRGB(255, 255, 255)
						lbl.Text = newText
						lbl.ZIndex = 16
						lbl:SetAttribute("LumiKeepColor", true)
						lbl:SetAttribute("LumiKeepText", true)
						lbl:SetAttribute("LumiKeepLight", true)
						lbl:SetAttribute("LumiKeepFont", true)
						lbl:SetAttribute("LumiNoTranslate", true)

						local tstroke = Instance.new("UIStroke")
						tstroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
						tstroke.Color = Color3.fromRGB(10, 10, 15)
						tstroke.Thickness = 1
						tstroke.Parent = lbl

						lbl.Parent = badge
						badge.Parent = banner
					else
						if not badge.Visible then badge.Visible = true end
						if badge.BackgroundColor3 ~= color then badge.BackgroundColor3 = color end
						local border = badge:FindFirstChild("Border")
						if border and border.Color ~= strokeColor then border.Color = strokeColor end
						local lbl = badge:FindFirstChild("Text")
						if lbl then
							if lbl.Text ~= newText then lbl.Text = newText end
							if lbl.TextColor3 ~= Color3.fromRGB(255, 255, 255) then
								lbl.TextColor3 = Color3.fromRGB(255, 255, 255)
							end
							if not lbl:GetAttribute("LumiKeepText") then
								lbl:SetAttribute("LumiKeepColor", true)
								lbl:SetAttribute("LumiKeepText", true)
								lbl:SetAttribute("LumiKeepLight", true)
								lbl:SetAttribute("LumiKeepFont", true)
								lbl:SetAttribute("LumiNoTranslate", true)
							end
						end
					end

					createOrUpdateStarBadge(banner, selectedRef, eval, UDim2.fromOffset(22, 22), UDim2.new(1, -100, 0, 17), Vector2.new(1, 0), "RerollDetailStarBadge")
				else
					local badge = banner:FindFirstChild("PopupTierBadge")
					if badge and badge.Visible then badge.Visible = false end
					local starBadge = banner:FindFirstChild("RerollDetailStarBadge")
					if starBadge and starBadge.Visible then starBadge.Visible = false end
				end
			end
		end

		-- =========================================================================
		-- Sub-routine G: Gear Refine List Badges (LumiRefine)
		-- =========================================================================
		local lumiRefine = pgui:FindFirstChild("LumiRefine")
		if lumiRefine and lumiRefine.Enabled then
			local box = lumiRefine:FindFirstChild("Box", true)
			local scroll = box and box:FindFirstChild("Scroll", true)
			if scroll then
				for _, row in ipairs(scroll:GetChildren()) do
					if row:IsA("GuiObject") and row.Visible and row.Name:match("^g%d+$") then
						local ref = row.Name
						local eval = ItemTier.Registry[ref]
						if eval then
							createOrUpdateBadge(row, ref, eval, UDim2.fromOffset(24, 17), UDim2.new(1, -2, 0, 2), Vector2.new(1, 0))
							createOrUpdateStarBadge(row, ref, eval, UDim2.fromOffset(18, 18), UDim2.new(1, -5, 0, 21), Vector2.new(1, 0))
						else
							local b = row:FindFirstChild("TierBadge")
							if b then pcall(b.Destroy, b) end
							local s = row:FindFirstChild("StarBadge")
							if s then pcall(s.Destroy, s) end
						end
					end
				end
			end
		end

		-- =========================================================================
		-- Sub-routine H: Storage Window Badges (HuntStorage) — Zero Flicker & Central Registry
		-- =========================================================================
		local huntStorage = pgui:FindFirstChild("HuntStorage")
		if huntStorage and huntStorage.Enabled then
			local win = huntStorage:FindFirstChild("Holder") and huntStorage.Holder:FindFirstChild("Window")
			if win and win.Visible then
				local function processStorageContainer(cardName)
					local card = win:FindFirstChild(cardName)
					local scroll = card and card:FindFirstChild("Scroll", true)
					if not scroll then return end

					for _, cell in ipairs(scroll:GetChildren()) do
						if cell:IsA("GuiObject") and cell.Visible and cell.Name == "ItemSlot" then
							local ref = cell:GetAttribute("BoundRef")
							if not ref and type(EXEC.getconnections) == "function" and type(EXEC.getupvalues) == "function" then
								local hit = cell:FindFirstChild("Hit")
								if hit then
									local conns = EXEC.getconnections(hit.MouseButton1Click)
									for _, c in ipairs(conns) do
										if c.Function then
											local uvs = EXEC.getupvalues(c.Function)
											for _, val in pairs(uvs) do
												if type(val) == "string" and val:match("^g%d+$") then
													ref = val
													break
												end
											end
										end
										if ref then
											cell:SetAttribute("BoundRef", ref)
											break
										end
									end
								end
							end

							local eval = ref and ItemTier.Registry[ref]
							if eval then
								createOrUpdateBadge(cell, ref, eval, UDim2.fromOffset(24, 17), UDim2.new(1, -2, 0, 2), Vector2.new(1, 0))
								createOrUpdateStarBadge(cell, ref, eval, UDim2.fromOffset(18, 18), UDim2.new(1, -5, 0, 21), Vector2.new(1, 0))
							else
								local b = cell:FindFirstChild("TierBadge")
								if b then pcall(b.Destroy, b) end
								local s = cell:FindFirstChild("StarBadge")
								if s then pcall(s.Destroy, s) end
							end
						end
					end
				end

				processStorageContainer("Card_Storage")
				processStorageContainer("Card_Bag")
			end
		end
	end

	-- True Cancelling Debounce Scheduler (Zero Task Flooding & Zero Stutter)
	local _scheduledUpdateThread = nil
	local function scheduleUpdate(delaySec)
		if not isTierActive() then return end
		if _scheduledUpdateThread then
			task.cancel(_scheduledUpdateThread)
			_scheduledUpdateThread = nil
		end
		_scheduledUpdateThread = task.delay(delaySec or 0.05, function()
			_scheduledUpdateThread = nil
			if isTierActive() then
				ItemTier.UpdateBadges()
			end
		end)
	end

	local function triggerFullUpdate()
		if not HUB.Alive or EXEC.env.HuntingTogetherHub_Token ~= MY_TOKEN then return end
		ItemTier.RefreshCache()
		scheduleUpdate(0.05)
	end

	-- โหลดข้อมูล Registry ทันทีก่อนเริ่มผูก UI Watchers เพื่อให้ bindCell มีข้อมูลพร้อม 100% ตั้งแต่ไมโครวินาทีแรก (ตัดปัญหาป้ายหายแล้วเด้งใหม่ตอน Execute ทับ)
	ItemTier.RefreshCache()

	-- Event Watchers: ดักฟังเฉพาะสัญญาณที่เกี่ยวกับอุปกรณ์โดยตรง
	HUB:AddConnection(LocalPlayer:GetAttributeChangedSignal("GearJson"):Connect(triggerFullUpdate))
	HUB:AddConnection(LocalPlayer:GetAttributeChangedSignal("StorageGearJson"):Connect(triggerFullUpdate))
	HUB:AddConnection(LocalPlayer:GetAttributeChangedSignal("EquipJson"):Connect(function()
		scheduleUpdate(0.02)
	end))
	HUB:AddConnection(LocalPlayer:GetAttributeChangedSignal("WeaponId"):Connect(function()
		scheduleUpdate(0.02)
	end))

	-- Watch Inventory Window, Equipped Bag Screen & Shop Sell Screen
	task.spawn(function()
		local pgui = LocalPlayer:WaitForChild("PlayerGui", 30)
		if not pgui or not HUB.Alive or EXEC.env.HuntingTogetherHub_Token ~= MY_TOKEN then return end

		-- 1. LumiInventory (กระเป๋าหลัก)
		local lumi = pgui:WaitForChild("LumiInventory", 30)
		local win = lumi and lumi:FindFirstChild("InventoryWindow", true)
		if win then
			HUB:AddConnection(win:GetPropertyChangedSignal("Visible"):Connect(function()
				if isTierActive() and win.Visible then
					scheduleUpdate(0.02)
				end
			end))

			-- Hook all 8 Tab buttons (All, Item, Armor, Weapon, Garment, Shoes, Ring, Card)
			for _, tabName in ipairs({ "all", "item", "armor", "weapon", "garment", "shoes", "ring", "card" }) do
				local tabBtn = win:FindFirstChild(tabName, true)
				if tabBtn and tabBtn:IsA("TextButton") then
					HUB:AddConnection(tabBtn.MouseButton1Click:Connect(function()
						scheduleUpdate(0.02)
					end))
				end
			end

			-- Hook SearchBox to update on typing or clearing filter
			local searchBox = win:FindFirstChild("SearchBox", true)
			if searchBox and searchBox:IsA("TextBox") then
				HUB:AddConnection(searchBox:GetPropertyChangedSignal("Text"):Connect(function()
					scheduleUpdate(0.02)
				end))
			end

			-- Reactive Zero-Latency Cell Binder for ScrollingFrame
			local sf = win:FindFirstChild("ScrollingFrame", true)
			local function bindCell(child)
				if not HUB.Alive or EXEC.env.HuntingTogetherHub_Token ~= MY_TOKEN then return end
				if not child or not child:IsA("GuiObject") then return end
				if HUB.Config.itemTierBadges then
					local inv = getInvTable()
					local ref = inv and inv.cellOf and inv.cellOf[child]
					if ref then
						applyCellBadge(child, ref)
					else
						task.defer(function()
							if not isTierActive() or not child.Parent then return end
							local invNow = getInvTable()
							local r = invNow and invNow.cellOf and invNow.cellOf[child]
							if r then applyCellBadge(child, r) end
						end)
					end
				end

				-- คลิกที่ Cell: จำ SelectedRef และอัปเดต ItemPopup Badge ทันที 0ms (ตัด ChildAdded 240 ตัวออกเพื่อลดภาระ C++ Destructor ตอนออกเกม)
				if child:IsA("TextButton") and not child:GetAttribute("TierClickHooked") then
					child:SetAttribute("TierClickHooked", true)
					HUB:AddConnection(child.MouseButton1Click:Connect(function()
						if not isTierActive() then return end
						local invNow = getInvTable()
						local r = invNow and invNow.cellOf and invNow.cellOf[child]
						if r then
							ItemTier.SelectedRef = r
							task.defer(function()
								updatePopupBadge(r)
							end)
						end
					end))
				end
			end

			if sf and not sf:GetAttribute("TierReactiveHooked") then
				sf:SetAttribute("TierReactiveHooked", true)
				HUB:AddConnection(sf.ChildAdded:Connect(bindCell))
				for _, child in ipairs(sf:GetChildren()) do
					bindCell(child)
				end
			end
		end

		-- Hook ItemPopup (หน้าต่างดูรายละเอียดไอเทม)
		local popup = lumi and lumi:FindFirstChild("ItemPopup")
		if popup and not popup:GetAttribute("TierPopupHooked") then
			popup:SetAttribute("TierPopupHooked", true)
			HUB:AddConnection(popup:GetPropertyChangedSignal("Visible"):Connect(function()
				if not HUB.Alive or EXEC.env.HuntingTogetherHub_Token ~= MY_TOKEN then return end
				if popup.Visible then
					task.defer(updatePopupBadge)
				else
					local head = popup:FindFirstChild("Head")
					if head then
						for _, b in ipairs(head:GetChildren()) do
							if (b.Name == "PopupTierBadge" or b.Name == "PopupStarBadge") and b.Visible then
								b.Visible = false
							end
						end
					end
				end
			end))

			local head = popup:FindFirstChild("Head")
			local title = head and head:FindFirstChild("Title")
			if title and title:IsA("TextLabel") and not title:GetAttribute("TierTitleHooked") then
				title:SetAttribute("TierTitleHooked", true)
				HUB:AddConnection(title:GetPropertyChangedSignal("Text"):Connect(function()
					if isTierActive() and popup.Visible then
						task.defer(updatePopupBadge)
					end
				end))
			end
		end

		-- 2. LumiBagScreen (หน้าสวมใส่และโมเดลตัวละคร)
		local bagScreen = pgui:WaitForChild("LumiBagScreen", 30)
		if bagScreen then
			HUB:AddConnection(bagScreen:GetPropertyChangedSignal("Enabled"):Connect(function()
				if isTierActive() and bagScreen.Enabled then
					local overlay = bagScreen:FindFirstChild("LumiEquipTierOverlay")
					if overlay then overlay.Visible = true end
					scheduleUpdate(0.02)
				end
			end))

			local equipSlots = { "Slot_RightHand", "Slot_HeadTop", "Slot_HeadMid", "Slot_Body", "Slot_Garment", "Slot_Shoes", "Slot_Acc1", "Slot_Acc2" }
			for _, slotName in ipairs(equipSlots) do
				local slotBtn = bagScreen:FindFirstChild(slotName)
				if slotBtn and slotBtn:IsA("TextButton") and not slotBtn:GetAttribute("TierClickHooked") then
					slotBtn:SetAttribute("TierClickHooked", true)
					HUB:AddConnection(slotBtn.MouseButton1Click:Connect(function()
						if not isTierActive() then return end
						local equipJsonStr = LocalPlayer:GetAttribute("EquipJson") or "{}"
						local okEquip, equipJson = pcall(HttpService.JSONDecode, HttpService, equipJsonStr)
						if okEquip and type(equipJson) == "table" then
							local slotKey = slotName:gsub("^Slot_", "")
							local r = (slotKey == "RightHand" and (LocalPlayer:GetAttribute("WeaponId") or equipJson.RightHand)) or equipJson[slotKey]
							if r then
								ItemTier.SelectedRef = r
								task.defer(function()
									updatePopupBadge(r)
								end)
							end
						end
					end))
				end
			end
		end

		-- 3. HuntShop (หน้าร้านค้า / ขายไอเทม)
		local huntShop = pgui:WaitForChild("HuntShop", 30)
		if huntShop then
			HUB:AddConnection(huntShop:GetPropertyChangedSignal("Enabled"):Connect(function()
				if isTierActive() and huntShop.Enabled then
					scheduleUpdate(0.02)
				end
			end))
		end

		-- 4. HuntReroll (ร้านสุ่ม Stats / Reroll Options)
		local huntReroll = pgui:WaitForChild("HuntReroll", 30)
		if huntReroll then
			HUB:AddConnection(huntReroll:GetPropertyChangedSignal("Enabled"):Connect(function()
				if isTierActive() and huntReroll.Enabled then
					scheduleUpdate(0.05)
				end
			end))

			local win = huntReroll:FindFirstChild("Window", true)
			local scroll = win and win:FindFirstChild("Scroll", true)
			if scroll and not scroll:GetAttribute("TierRerollHooked") then
				scroll:SetAttribute("TierRerollHooked", true)
				HUB:AddConnection(scroll.ChildAdded:Connect(function(child)
					if isTierActive() and huntReroll.Enabled then
						scheduleUpdate(0.12)
					end
				end))
			end

			local detail = win and win:FindFirstChild("Detail", true)
			if detail and not detail:GetAttribute("TierDetailHooked") then
				detail:SetAttribute("TierDetailHooked", true)
				HUB:AddConnection(detail.ChildAdded:Connect(function(child)
					if isTierActive() and huntReroll.Enabled then
						scheduleUpdate(0.12)
					end
				end))
			end
		end

		-- 5. LumiRefine (ร้านตีบวกอุปกรณ์)
		local lumiRefine = pgui:WaitForChild("LumiRefine", 30)
		if lumiRefine then
			HUB:AddConnection(lumiRefine:GetPropertyChangedSignal("Enabled"):Connect(function()
				if isTierActive() and lumiRefine.Enabled then
					scheduleUpdate(0.02)
				end
			end))
		end

		-- 6. HuntStorage (คลังเก็บของ)
		local huntStorage = pgui:WaitForChild("HuntStorage", 30)
		if huntStorage then
			HUB:AddConnection(huntStorage:GetPropertyChangedSignal("Enabled"):Connect(function()
				if isTierActive() and huntStorage.Enabled then
					scheduleUpdate(0.05)
				end
			end))

			local win = huntStorage:FindFirstChild("Holder") and huntStorage.Holder:FindFirstChild("Window")
			local function hookStorageScroll(cardName)
				local card = win and win:FindFirstChild(cardName)
				local scroll = card and card:FindFirstChild("Scroll", true)
				if scroll and not scroll:GetAttribute("TierStorageHooked") then
					scroll:SetAttribute("TierStorageHooked", true)
					HUB:AddConnection(scroll.ChildAdded:Connect(function()
						if isTierActive() and huntStorage.Enabled then
							scheduleUpdate(0.05)
						end
					end))
				end
			end

			hookStorageScroll("Card_Storage")
			hookStorageScroll("Card_Bag")
		end

		-- Sync สถานะป้ายทันทีหลังผูก Watchers เสร็จสิ้น (In-Place 100% ไม่กระพริบ)
		if HUB.Config.itemTierBadges then
			ItemTier.UpdateBadges()
		else
			ItemTier.ClearBadges()
		end
	end)

	-- Background Heartbeat (ทุก 1.5 วินาทีขณะหน้าต่างเปิดอยู่ เพื่อ sync ข้อมูลแบบ Zero-Flicker)
	task.spawn(function()
		while HUB.Alive and EXEC.env.HuntingTogetherHub_Token == MY_TOKEN do
			task.wait(1.5)
			if not HUB.Alive or EXEC.env.HuntingTogetherHub_Token ~= MY_TOKEN then break end
			if HUB.Config.itemTierBadges and not _scheduledUpdateThread then
				local pgui = LocalPlayer:FindFirstChild("PlayerGui")
				if pgui then
					local lumi = pgui:FindFirstChild("LumiInventory")
					local invWin = lumi and lumi:FindFirstChild("InventoryWindow", true)
					local bagScreen = pgui:FindFirstChild("LumiBagScreen")
					local huntShop = pgui:FindFirstChild("HuntShop")
					local huntReroll = pgui:FindFirstChild("HuntReroll")
					local lumiRefine = pgui:FindFirstChild("LumiRefine")
					local huntStorage = pgui:FindFirstChild("HuntStorage")

					local isAnyOpen = (invWin and invWin.Visible)
						or (bagScreen and bagScreen.Enabled)
						or (huntShop and huntShop.Enabled)
						or (huntReroll and huntReroll.Enabled)
						or (lumiRefine and lumiRefine.Enabled)
						or (huntStorage and huntStorage.Enabled)
					if isAnyOpen then
						ItemTier.UpdateBadges()
					end
				end
			end
		end
	end)
end

-- ===== 6.8 ระบบคำนวณและดึงข้อมูลความจุกระเป๋า (Ground-Truth Bag Capacity Engine v9.12) =====
local function getBagStats()
	local used = tonumber(LocalPlayer:GetAttribute("BagSlotsUsed")) or 0
	local max = tonumber(LocalPlayer:GetAttribute("BagSlotsMax")) or 240
	local pct = max > 0 and math.clamp(math.floor((used / max) * 100 + 0.5), 0, 100) or 0
	local free = math.max(0, max - used)
	return {
		used = used,
		max = max,
		pct = pct,
		free = free,
		isFull = (max > 0 and used >= max),
	}
end
HUB.GetBagStats = getBagStats

local function formatComma(n)
	local s = tostring(math.floor(tonumber(n) or 0))
	local k
	while true do
		s, k = string.gsub(s, "^(-?%d+)(%d%d%d)", "%1,%2")
		if k == 0 then break end
	end
	return s
end
HUB.FormatComma = formatComma

local getJunkStats, getSellableGearStats, hasSellableItems
do
	local _cachedItemData = nil
	local _cachedJunkKeep = nil
	local function getItemData()
		if _cachedItemData then return _cachedItemData end
		local sf = ReplicatedStorage:FindFirstChild("Shared")
		local mod = sf and sf:FindFirstChild("ItemData")
		if mod then
			local ok, res = pcall(require, mod)
			if ok and type(res) == "table" then
				_cachedItemData = res
			end
		end
		local gcMod = sf and sf:FindFirstChild("GameConfig")
		if gcMod then
			local ok, gc = pcall(require, gcMod)
			if ok and type(gc) == "table" and type(gc.JunkKeep) == "table" then
				_cachedJunkKeep = gc.JunkKeep
			end
		end
		return _cachedItemData
	end

	getJunkStats = function()
		local rawItems = LocalPlayer:GetAttribute("ItemsJson") or "{}"
		local rawLocks = LocalPlayer:GetAttribute("LocksJson") or "{}"
		local ok1, itemsJson = pcall(HttpService.JSONDecode, HttpService, rawItems)
		local ok2, locksJson = pcall(HttpService.JSONDecode, HttpService, rawLocks)
		if not ok1 or type(itemsJson) ~= "table" then return { count = 0, silver = 0, types = 0 } end
		if not ok2 or type(locksJson) ~= "table" then locksJson = {} end

		local itemData = getItemData()
		if not itemData then return { count = 0, silver = 0, types = 0 } end
		local junkKeep = _cachedJunkKeep or {}

		local totalCount = 0
		local totalSilver = 0
		local typesCount = 0
		for id, count in pairs(itemsJson) do
			local def = itemData[id]
			if def and def.Kind == "etc" and (def.Sell or 0) > 0 and not locksJson[id] and not junkKeep[id] then
				totalCount = totalCount + count
				totalSilver = totalSilver + (count * (def.Sell or 0))
				typesCount = typesCount + 1
			end
		end
		return { count = totalCount, silver = totalSilver, types = typesCount }
	end

	getSellableGearStats = function()
		local rawGear = LocalPlayer:GetAttribute("GearJson") or "{}"
		local rawLocks = LocalPlayer:GetAttribute("LocksJson") or "{}"
		local rawEquip = LocalPlayer:GetAttribute("EquipJson") or "{}"
		local ok1, gearJson = pcall(HttpService.JSONDecode, HttpService, rawGear)
		local ok2, locksJson = pcall(HttpService.JSONDecode, HttpService, rawLocks)
		local ok3, equipJson = pcall(HttpService.JSONDecode, HttpService, rawEquip)
		if not ok1 or type(gearJson) ~= "table" then return 0 end
		if not ok2 or type(locksJson) ~= "table" then locksJson = {} end
		local equippedSet = {}
		local wepId = LocalPlayer:GetAttribute("WeaponId")
		if type(wepId) == "string" and wepId ~= "" then equippedSet[wepId] = true end
		if ok3 and type(equipJson) == "table" then
			for _, eqId in pairs(equipJson) do
				if type(eqId) == "string" and eqId ~= "" then equippedSet[eqId] = true end
			end
		end
		local count = 0
		for gId, _ in pairs(gearJson) do
			if not locksJson[gId] and not equippedSet[gId] then
				count = count + 1
			end
		end
		return count
	end

	hasSellableItems = function()
		local hasJunk = false
		local junk = nil
		if HUB.Config.autoSellJunk ~= false then
			junk = getJunkStats()
			if junk.count > 0 then
				hasJunk = true
			end
		end
		local hasGear = false
		local gearCount = 0
		if HUB.Config.autoSellGear ~= false then
			gearCount = getSellableGearStats()
			if gearCount > 0 then
				hasGear = true
			end
		end
		return (hasJunk or hasGear), hasJunk, hasGear, junk, gearCount
	end
end
HUB.GetJunkStats = getJunkStats
HUB.GetSellableGearStats = getSellableGearStats
HUB.HasSellableItems = hasSellableItems

-- ===== 7. สร้าง GUI: ScreenGui & Main Window & Tab System =====
do
	local targetParent = (gethui and gethui()) or CoreGui or PlayerGui
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = GUI_NAME
	screenGui.ResetOnSpawn = false
	screenGui.IgnoreGuiInset = true
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screenGui.DisplayOrder = 999
	screenGui.Parent = targetParent
	HUB.UI.ScreenGui = screenGui

	-- ---------- 7.1 Advance Floating Draggable Icon ----------
	local pCfg = HUB.Config.iconPos or { ScaleX = 0, OffsetX = 346, ScaleY = 0, OffsetY = 10 }
	local floatHolder = Instance.new("Frame")
	floatHolder.Name = "FloatingIcon"
	floatHolder.Size = UDim2.new(0, 38, 0, 38)
	floatHolder.Position = UDim2.new(pCfg.ScaleX or 0, pCfg.OffsetX or 346, pCfg.ScaleY or 0, pCfg.OffsetY or 10)
	floatHolder.BackgroundTransparency = 1
	floatHolder.Visible = false
	floatHolder.Parent = screenGui
	HUB.UI.FloatingIcon = floatHolder

	local floatScale = Instance.new("UIScale")
	floatScale.Name = "BounceScale"
	floatScale.Scale = 1.0
	floatScale.Parent = floatHolder

	local floatShadow = Instance.new("Frame")
	floatShadow.Name = "Shadow"
	floatShadow.Size = UDim2.new(1, 0, 1, 0)
	floatShadow.Position = UDim2.new(0, 0, 0, 2)
	floatShadow.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	floatShadow.BackgroundTransparency = 0.65
	floatShadow.BorderSizePixel = 0
	floatShadow.Parent = floatHolder
	local fsCorner = Instance.new("UICorner")
	fsCorner.CornerRadius = UDim.new(0, 8)
	fsCorner.Parent = floatShadow

	local floatCore = Instance.new("Frame")
	floatCore.Name = "Core"
	floatCore.Size = UDim2.new(1, 0, 1, 0)
	floatCore.Position = UDim2.new(0, 0, 0, 0)
	floatCore.BackgroundColor3 = THEME.HeaderBlue
	floatCore.BorderSizePixel = 0
	floatCore.ClipsDescendants = true
	floatCore.Parent = floatHolder
	local fcCorner = Instance.new("UICorner")
	fcCorner.CornerRadius = UDim.new(0, 8)
	fcCorner.Parent = floatCore

	local floatGradient = Instance.new("UIGradient")
	floatGradient.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0.0, Color3.fromRGB(35, 134, 255)),
		ColorSequenceKeypoint.new(0.5, Color3.fromRGB(26, 112, 240)),
		ColorSequenceKeypoint.new(1.0, Color3.fromRGB(16, 75, 195)),
	})
	floatGradient.Rotation = 45
	floatGradient.Parent = floatCore

	local floatStroke = Instance.new("UIStroke")
	floatStroke.Name = "BorderStroke"
	floatStroke.Color = Color3.fromRGB(240, 190, 60)
	floatStroke.Thickness = 1.8
	floatStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	floatStroke.Parent = floatCore

	local floatStuds = Instance.new("ImageLabel")
	floatStuds.Name = "Studs"
	floatStuds.Size = UDim2.new(1, 0, 1, 0)
	floatStuds.BackgroundTransparency = 1
	floatStuds.Image = THEME.StudsTexture
	floatStuds.ImageTransparency = 0.85
	floatStuds.Parent = floatCore

	local floatShine = Instance.new("ImageLabel")
	floatShine.Name = "Shine"
	floatShine.Size = UDim2.new(1.2, 0, 1.2, 0)
	floatShine.Position = UDim2.new(-0.1, 0, -0.1, 0)
	floatShine.BackgroundTransparency = 1
	floatShine.Image = THEME.ShineTexture
	floatShine.ImageTransparency = 0.65
	floatShine.Parent = floatCore

	local floatIconImg = Instance.new("ImageLabel")
	floatIconImg.Name = "GearIcon"
	floatIconImg.AnchorPoint = Vector2.new(0.5, 0.5)
	floatIconImg.Size = UDim2.new(0, 28, 0, 28)
	floatIconImg.Position = UDim2.new(0.5, 0, 0.5, 0)
	floatIconImg.BackgroundTransparency = 1
	floatIconImg.Image = THEME.AtlasIcon
	floatIconImg.ImageRectOffset = THEME.SettingIconRect
	floatIconImg.ImageRectSize = THEME.IconSize
	floatIconImg.Parent = floatCore

	local floatBadge = Instance.new("Frame")
	floatBadge.Name = "StatusBadge"
	floatBadge.AnchorPoint = Vector2.new(1, 0)
	floatBadge.Size = UDim2.new(0, 8, 0, 8)
	floatBadge.Position = UDim2.new(1, -2, 0, 2)
	floatBadge.BackgroundColor3 = Color3.fromRGB(46, 215, 80)
	floatBadge.BorderSizePixel = 0
	floatBadge.ZIndex = 5
	floatBadge.Parent = floatHolder
	local fbCorner = Instance.new("UICorner")
	fbCorner.CornerRadius = UDim.new(1, 0)
	fbCorner.Parent = floatBadge
	local fbStroke = Instance.new("UIStroke")
	fbStroke.Color = THEME.DarkNavy
	fbStroke.Thickness = 1.0
	fbStroke.Parent = floatBadge

	local floatTooltip = Instance.new("Frame")
	floatTooltip.Name = "Tooltip"
	floatTooltip.Size = UDim2.new(0, 140, 0, 24)
	floatTooltip.Position = UDim2.new(0.5, -70, 1, 6)
	floatTooltip.BackgroundColor3 = THEME.DarkNavy
	floatTooltip.BorderSizePixel = 0
	floatTooltip.BackgroundTransparency = 0.15
	floatTooltip.Visible = false
	floatTooltip.ZIndex = 10
	floatTooltip.Parent = floatHolder
	local ftCorner = Instance.new("UICorner")
	ftCorner.CornerRadius = UDim.new(0, 5)
	ftCorner.Parent = floatTooltip
	local ftStroke = Instance.new("UIStroke")
	ftStroke.Color = Color3.fromRGB(240, 190, 60)
	ftStroke.Thickness = 1.2
	ftStroke.Parent = floatTooltip
	local ftText = Instance.new("TextLabel")
	ftText.Size = UDim2.new(1, 0, 1, 0)
	ftText.BackgroundTransparency = 1
	ftText.Text = "คลิกเพื่อเปิด · ลากเพื่อย้าย"
	ftText.TextColor3 = Color3.fromRGB(255, 255, 255)
	ftText.TextSize = 11
	applyFont(ftText, true)
	ftText.Parent = floatTooltip

	local floatHit = Instance.new("TextButton")
	floatHit.Name = "Hitbox"
	floatHit.Size = UDim2.new(1, 0, 1, 0)
	floatHit.BackgroundTransparency = 1
	floatHit.Text = ""
	floatHit.Parent = floatHolder

	task.spawn(function()
		local blinkInfo = TweenInfo.new(0.9, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)
		local blinkTween = TweenService:Create(floatBadge, blinkInfo, {
			BackgroundTransparency = 0.75,
			BackgroundColor3 = Color3.fromRGB(70, 255, 120),
		})
		blinkTween:Play()
	end)

	local tweenHoverIn = TweenService:Create(floatScale, TweenInfo.new(0.2, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1.08 })
	local tweenHoverOut = TweenService:Create(floatScale, TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Scale = 1.0 })
	local tweenRotateIn = TweenService:Create(floatIconImg, TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Rotation = 45 })
	local tweenRotateOut = TweenService:Create(floatIconImg, TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Rotation = 0 })

	HUB:AddConnection(floatHit.MouseEnter:Connect(function()
		tweenHoverIn:Play()
		tweenRotateIn:Play()
		floatStroke.Color = Color3.fromRGB(255, 225, 120)
		floatTooltip.Visible = true
	end))

	HUB:AddConnection(floatHit.MouseLeave:Connect(function()
		tweenHoverOut:Play()
		tweenRotateOut:Play()
		floatStroke.Color = Color3.fromRGB(240, 190, 60)
		floatTooltip.Visible = false
	end))

	HUB:AddConnection(floatHit.MouseButton1Down:Connect(function()
		local squish = TweenService:Create(floatScale, TweenInfo.new(0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Scale = 0.94 })
		squish:Play()
	end))

	HUB:AddConnection(floatHit.MouseButton1Up:Connect(function()
		local spring = TweenService:Create(floatScale, TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1.08 })
		spring:Play()
	end))

	-- ---------- 7.2 Main Window (780 x 470 · Scaled 1.2x => 936 x 564) ----------
	local mainWindow = Instance.new("Frame")
	mainWindow.Name = "MainWindow"
	mainWindow.Size = UDim2.new(0, 780, 0, 470)
	mainWindow.Position = UDim2.new(0.5, -468, 0.5, -282)
	mainWindow.BackgroundTransparency = 1
	mainWindow.Visible = true
	mainWindow.Parent = screenGui
	HUB.UI.MainWindow = mainWindow

	local mainScale = Instance.new("UIScale")
	mainScale.Name = "HubScale"
	mainScale.Scale = 1.2
	mainScale.Parent = mainWindow

	local brickSkin = Instance.new("Frame")
	brickSkin.Name = "BrickSkin"
	brickSkin.Size = UDim2.new(1, 0, 1, 0)
	brickSkin.Position = UDim2.new(0, 0, 0, 0)
	brickSkin.BackgroundTransparency = 1
	brickSkin.Parent = mainWindow

	local skinShadow = Instance.new("Frame")
	skinShadow.Name = "DropShadow"
	skinShadow.Size = UDim2.new(1, 0, 1, 0)
	skinShadow.Position = UDim2.new(0, 0, 0, 4)
	skinShadow.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	skinShadow.BackgroundTransparency = 0.72
	skinShadow.BorderSizePixel = 0
	skinShadow.Parent = brickSkin
	local skinShadowCorner = Instance.new("UICorner")
	skinShadowCorner.CornerRadius = UDim.new(0, 12)
	skinShadowCorner.Parent = skinShadow

	local skinInnerLine = Instance.new("Frame")
	skinInnerLine.Name = "InnerLine"
	skinInnerLine.Size = UDim2.new(1, 0, 1, 0)
	skinInnerLine.Position = UDim2.new(0, 0, 0, 0)
	skinInnerLine.BackgroundColor3 = THEME.DarkNavy
	skinInnerLine.BorderSizePixel = 0
	skinInnerLine.Parent = brickSkin
	local skinInnerCorner = Instance.new("UICorner")
	skinInnerCorner.CornerRadius = UDim.new(0, 12)
	skinInnerCorner.Parent = skinInnerLine

	-- Header Bar (Vivid Royal Blue พร้อม Texture Shine และ Studs)
	local headerBar = Instance.new("Frame")
	headerBar.Name = "HeaderBar"
	headerBar.Size = UDim2.new(1, 0, 0, 48)
	headerBar.Position = UDim2.new(0, 0, 0, 0)
	headerBar.BackgroundColor3 = THEME.HeaderBlue
	headerBar.BorderSizePixel = 0
	headerBar.ClipsDescendants = true
	headerBar.Parent = mainWindow

	local headerCorner = Instance.new("UICorner")
	headerCorner.CornerRadius = UDim.new(0, 10)
	headerCorner.Parent = headerBar

	local headerStuds = Instance.new("ImageLabel")
	headerStuds.Name = "Studs"
	headerStuds.Size = UDim2.new(1, 0, 1, 0)
	headerStuds.BackgroundTransparency = 1
	headerStuds.Image = THEME.StudsTexture
	headerStuds.ImageTransparency = 0.88
	headerStuds.Parent = headerBar

	local headerShine = Instance.new("ImageLabel")
	headerShine.Name = "Shine"
	headerShine.Size = UDim2.new(0.56, 0, 1, 0)
	headerShine.Position = UDim2.new(0.36, 0, 0, 0)
	headerShine.BackgroundTransparency = 1
	headerShine.Image = THEME.ShineTexture
	headerShine.ImageTransparency = 0.6
	headerShine.Parent = headerBar

	local headerRule = Instance.new("Frame")
	headerRule.Name = "Rule"
	headerRule.Size = UDim2.new(1, 0, 0, 2)
	headerRule.Position = UDim2.new(0, 0, 1, -2)
	headerRule.BackgroundColor3 = THEME.DarkNavy
	headerRule.BorderSizePixel = 0
	headerRule.Parent = headerBar

	local dragHandle = Instance.new("TextButton")
	dragHandle.Name = "DragHandle"
	dragHandle.Size = UDim2.new(1, -95, 1, 0)
	dragHandle.BackgroundTransparency = 1
	dragHandle.Text = ""
	dragHandle.Parent = headerBar

	local titleIcon = Instance.new("ImageLabel")
	titleIcon.Name = "TitleIcon"
	titleIcon.Size = UDim2.new(0, 26, 0, 26)
	titleIcon.Position = UDim2.new(0, 14, 0.5, -13)
	titleIcon.BackgroundTransparency = 1
	titleIcon.Image = THEME.AtlasIcon
	titleIcon.ImageRectOffset = THEME.SettingIconRect
	titleIcon.ImageRectSize = THEME.IconSize
	titleIcon.Parent = headerBar

	local titleLabel = Instance.new("TextLabel")
	titleLabel.Name = "TitleLabel"
	titleLabel.Size = UDim2.new(0, 250, 1, 0)
	titleLabel.Position = UDim2.new(0, 46, 0, 0)
	titleLabel.BackgroundTransparency = 1
	titleLabel.Text = "Character · Stats & Hub"
	titleLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
	titleLabel.TextSize = 20
	titleLabel.TextXAlignment = Enum.TextXAlignment.Left
	applyFont(titleLabel, true)
	titleLabel.Parent = headerBar

	local verBadge = Instance.new("TextLabel")
	verBadge.Name = "VersionBadge"
	verBadge.Size = UDim2.new(0, 44, 0, 22)
	verBadge.Position = UDim2.new(0, 305, 0.5, -11)
	verBadge.BackgroundColor3 = THEME.DarkNavy
	verBadge.Text = "v" .. VERSION
	verBadge.TextColor3 = Color3.fromRGB(255, 215, 0)
	verBadge.TextSize = 12
	applyFont(verBadge, true)
	verBadge.Parent = headerBar
	local verCorner = Instance.new("UICorner")
	verCorner.CornerRadius = UDim.new(0, 4)
	verCorner.Parent = verBadge

	local minBtn = Instance.new("TextButton")
	minBtn.Name = "MinBtn"
	minBtn.Size = UDim2.new(0, 34, 0, 30)
	minBtn.Position = UDim2.new(1, -80, 0, 9)
	minBtn.BackgroundColor3 = THEME.BtnMin
	minBtn.Text = "−"
	minBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
	minBtn.TextSize = 20
	applyFont(minBtn, true)
	minBtn.Parent = headerBar
	local minCorner = Instance.new("UICorner")
	minCorner.CornerRadius = UDim.new(0, 5)
	minCorner.Parent = minBtn

	local closeBtn = Instance.new("TextButton")
	closeBtn.Name = "CloseBtn"
	closeBtn.Size = UDim2.new(0, 34, 0, 30)
	closeBtn.Position = UDim2.new(1, -40, 0, 9)
	closeBtn.BackgroundColor3 = THEME.BtnClose
	closeBtn.Text = ""
	closeBtn.Parent = headerBar
	local closeCorner = Instance.new("UICorner")
	closeCorner.CornerRadius = UDim.new(0, 5)
	closeCorner.Parent = closeBtn

	local closeIcon = Instance.new("ImageLabel")
	closeIcon.Name = "KitClose"
	closeIcon.Size = UDim2.new(0, 18, 0, 18)
	closeIcon.Position = UDim2.new(0.5, -9, 0.5, -9)
	closeIcon.BackgroundTransparency = 1
	closeIcon.Image = THEME.CloseIcon
	closeIcon.Parent = closeBtn

	-- ---------- 7.3 โครงสร้างเนื้อหา 2 Panel ----------
	local contentArea = Instance.new("Frame")
	contentArea.Name = "ContentArea"
	contentArea.Size = UDim2.new(1, -20, 1, -60)
	contentArea.Position = UDim2.new(0, 10, 0, 52)
	contentArea.BackgroundTransparency = 1
	contentArea.Parent = mainWindow

	local function createSectionPanel(parent, posX, width, headerTitle)
		local outerPanel = Instance.new("Frame")
		outerPanel.Name = "Panel_" .. headerTitle:gsub("%s+", "")
		outerPanel.Size = UDim2.new(0, width, 1, 0)
		outerPanel.Position = UDim2.new(0, posX, 0, 0)
		outerPanel.BackgroundColor3 = THEME.PanelBorder
		outerPanel.BorderSizePixel = 0
		outerPanel.Parent = parent

		local oCorner = Instance.new("UICorner")
		oCorner.CornerRadius = UDim.new(0, 4)
		oCorner.Parent = outerPanel

		local innerBody = Instance.new("Frame")
		innerBody.Name = "Body"
		innerBody.Size = UDim2.new(1, -2, 1, -2)
		innerBody.Position = UDim2.new(0, 1, 0, 1)
		innerBody.BackgroundColor3 = THEME.PanelBody
		innerBody.BorderSizePixel = 0
		innerBody.ClipsDescendants = true
		innerBody.Parent = outerPanel

		local iCorner = Instance.new("UICorner")
		iCorner.CornerRadius = UDim.new(0, 4)
		iCorner.Parent = innerBody

		local pHeader = Instance.new("Frame")
		pHeader.Name = "Header"
		pHeader.Size = UDim2.new(1, 0, 0, 30)
		pHeader.Position = UDim2.new(0, 0, 0, 0)
		pHeader.BackgroundColor3 = THEME.SubHeaderNavy
		pHeader.BorderSizePixel = 0
		pHeader.Parent = innerBody

		local pHeaderText = Instance.new("TextLabel")
		pHeaderText.Name = "Title"
		pHeaderText.Size = UDim2.new(1, -16, 1, 0)
		pHeaderText.Position = UDim2.new(0, 10, 0, 0)
		pHeaderText.BackgroundTransparency = 1
		pHeaderText.Text = headerTitle
		pHeaderText.TextColor3 = Color3.fromRGB(255, 255, 255)
		pHeaderText.TextSize = 14
		pHeaderText.TextXAlignment = Enum.TextXAlignment.Left
		applyFont(pHeaderText, true)
		pHeaderText.Parent = pHeader

		return innerBody
	end

	-- แผงด้านซ้าย: Character Profile & Status Summary
	local leftBody = createSectionPanel(contentArea, 0, 275, "Character Profile")

	local avatarFrame = Instance.new("ImageLabel")
	avatarFrame.Name = "AvatarHeadshot"
	avatarFrame.Size = UDim2.new(0, 80, 0, 80)
	avatarFrame.Position = UDim2.new(0, 12, 0, 38)
	avatarFrame.BackgroundColor3 = Color3.fromRGB(222, 233, 248)
	avatarFrame.Image = "rbxthumb://type=AvatarHeadShot&id=" .. LocalPlayer.UserId .. "&w=150&h=150"
	avatarFrame.Parent = leftBody
	local avCorner = Instance.new("UICorner")
	avCorner.CornerRadius = UDim.new(0, 6)
	avCorner.Parent = avatarFrame
	local avStroke = Instance.new("UIStroke")
	avStroke.Color = Color3.fromRGB(150, 180, 220)
	avStroke.Thickness = 2
	avStroke.Parent = avatarFrame

	local nameLabel = Instance.new("TextLabel")
	nameLabel.Name = "DisplayName"
	nameLabel.Size = UDim2.new(0, 160, 0, 22)
	nameLabel.Position = UDim2.new(0, 100, 0, 38)
	nameLabel.BackgroundTransparency = 1
	nameLabel.Text = LocalPlayer.DisplayName
	nameLabel.TextColor3 = THEME.TextDark
	nameLabel.TextSize = 16
	nameLabel.TextXAlignment = Enum.TextXAlignment.Left
	applyFont(nameLabel, true)
	nameLabel.Parent = leftBody

	local userLabel = Instance.new("TextLabel")
	userLabel.Name = "UserName"
	userLabel.Size = UDim2.new(0, 160, 0, 18)
	userLabel.Position = UDim2.new(0, 100, 0, 58)
	userLabel.BackgroundTransparency = 1
	userLabel.Text = "@" .. LocalPlayer.Name
	userLabel.TextColor3 = THEME.TextAmber
	userLabel.TextSize = 12
	userLabel.TextXAlignment = Enum.TextXAlignment.Left
	applyFont(userLabel, false)
	userLabel.Parent = leftBody

	local powerBox = Instance.new("Frame")
	powerBox.Name = "HubBadge"
	powerBox.Size = UDim2.new(0, 160, 0, 38)
	powerBox.Position = UDim2.new(0, 100, 0, 80)
	powerBox.BackgroundColor3 = THEME.SubHeaderNavy
	powerBox.BorderSizePixel = 0
	powerBox.Parent = leftBody
	local pbCorner = Instance.new("UICorner")
	pbCorner.CornerRadius = UDim.new(0, 4)
	pbCorner.Parent = powerBox

	local pbTitle = Instance.new("TextLabel")
	pbTitle.Size = UDim2.new(1, 0, 0, 14)
	pbTitle.Position = UDim2.new(0, 0, 0, 3)
	pbTitle.BackgroundTransparency = 1
	pbTitle.Text = "CURRENT EXECUTOR"
	pbTitle.TextColor3 = Color3.fromRGB(160, 185, 230)
	pbTitle.TextSize = 9
	applyFont(pbTitle, true)
	pbTitle.Parent = powerBox

	local pbVal = Instance.new("TextLabel")
	pbVal.Size = UDim2.new(1, 0, 0, 18)
	pbVal.Position = UDim2.new(0, 0, 0, 17)
	pbVal.BackgroundTransparency = 1
	pbVal.Text = getExecutorDisplay()
	pbVal.TextColor3 = Color3.fromRGB(255, 215, 0)
	pbVal.TextSize = 13
	applyFont(pbVal, true)
	pbVal.Parent = powerBox

	local leftRule = Instance.new("Frame")
	leftRule.Size = UDim2.new(1, -24, 0, 1)
	leftRule.Position = UDim2.new(0, 12, 0, 128)
	leftRule.BackgroundColor3 = THEME.PanelBorder
	leftRule.BorderSizePixel = 0
	leftRule.Parent = leftBody

	local function createStatRow(parent, posY, labelTitle, initialVal)
		local row = Instance.new("Frame")
		row.Size = UDim2.new(1, -24, 0, 24)
		row.Position = UDim2.new(0, 12, 0, posY)
		row.BackgroundColor3 = Color3.fromRGB(246, 240, 228)
		row.BorderSizePixel = 0
		row.Parent = parent
		local rCorner = Instance.new("UICorner")
		rCorner.CornerRadius = UDim.new(0, 3)
		rCorner.Parent = row

		local l = Instance.new("TextLabel")
		l.Size = UDim2.new(0, 130, 1, 0)
		l.Position = UDim2.new(0, 8, 0, 0)
		l.BackgroundTransparency = 1
		l.Text = labelTitle
		l.TextColor3 = THEME.TextDark
		l.TextSize = 12
		l.TextXAlignment = Enum.TextXAlignment.Left
		applyFont(l, true)
		l.Parent = row

		local v = Instance.new("TextLabel")
		v.Size = UDim2.new(1, -145, 1, 0)
		v.Position = UDim2.new(0, 135, 0, 0)
		v.BackgroundTransparency = 1
		v.Text = initialVal
		v.TextColor3 = THEME.TextAmber
		v.TextSize = 11
		v.TextXAlignment = Enum.TextXAlignment.Right
		applyFont(v, false)
		v.Parent = row

		return v
	end

	local statAfkCount = createStatRow(leftBody, 136, "Anti-AFK Bumps", "0 ครั้ง")
	local statBoxCount = createStatRow(leftBody, 164, "Boxes Opened", "0 กล่อง")
	local statConfigStatus = createStatRow(leftBody, 192, "Config Persistence", "บันทึกอัตโนมัติ")
	local statPlaceVer = createStatRow(leftBody, 220, "Server Version", "v" .. tostring(game.PlaceVersion))

	HUB.UI.StatAfkCount = statAfkCount
	HUB.UI.StatBoxCount = statBoxCount

	local leftSaveBtn = Instance.new("TextButton")
	leftSaveBtn.Name = "LeftSaveBtn"
	leftSaveBtn.Size = UDim2.new(1, -24, 0, 34)
	leftSaveBtn.Position = UDim2.new(0, 12, 1, -82)
	leftSaveBtn.BackgroundColor3 = THEME.BtnOrange
	leftSaveBtn.BorderSizePixel = 0
	leftSaveBtn.Text = "💾 บันทึกการตั้งค่า (Save)"
	leftSaveBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
	leftSaveBtn.TextSize = 14
	applyFont(leftSaveBtn, true)
	leftSaveBtn.Parent = leftBody
	local lsbCorner = Instance.new("UICorner")
	lsbCorner.CornerRadius = UDim.new(0, 4)
	lsbCorner.Parent = leftSaveBtn
	local lsbStroke = Instance.new("UIStroke")
	lsbStroke.Color = THEME.BtnOrangeStroke
	lsbStroke.Thickness = 1.5
	lsbStroke.Parent = leftSaveBtn

	HUB:AddConnection(leftSaveBtn.MouseButton1Click:Connect(function()
		local ok = saveConfig()
		if ok then
			statConfigStatus.Text = "บันทึก " .. os.date("%H:%M:%S")
		else
			statConfigStatus.Text = "บันทึกล้มเหลว"
		end
	end))

	local leftRejoinBtn = Instance.new("TextButton")
	leftRejoinBtn.Name = "LeftRejoinBtn"
	leftRejoinBtn.Size = UDim2.new(1, -24, 0, 32)
	leftRejoinBtn.Position = UDim2.new(0, 12, 1, -42)
	leftRejoinBtn.BackgroundColor3 = THEME.SubHeaderNavy
	leftRejoinBtn.BorderSizePixel = 0
	leftRejoinBtn.Text = "🔄 Rejoin เซิร์ฟเวอร์เดี๋ยวนี้"
	leftRejoinBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
	leftRejoinBtn.TextSize = 13
	applyFont(leftRejoinBtn, true)
	leftRejoinBtn.Parent = leftBody
	local lrbCorner = Instance.new("UICorner")
	lrbCorner.CornerRadius = UDim.new(0, 4)
	lrbCorner.Parent = leftRejoinBtn

	HUB:AddConnection(leftRejoinBtn.MouseButton1Click:Connect(function()
		pcall(function() TeleportService:Teleport(game.PlaceId, LocalPlayer) end)
	end))

	-- ---------- 7.4 แผงด้านขวา: Automation & Control Panel (พร้อม Tab Switcher) ----------
	local rightBody = createSectionPanel(contentArea, 285, 475, "Automation & Controls")

	-- Tab Switcher Bar
	local tabBar = Instance.new("Frame")
	tabBar.Name = "TabBar"
	tabBar.Size = UDim2.new(1, -16, 0, 32)
	tabBar.Position = UDim2.new(0, 8, 0, 36)
	tabBar.BackgroundColor3 = Color3.fromRGB(238, 230, 214)
	tabBar.BorderSizePixel = 0
	tabBar.Parent = rightBody
	local tbCorner = Instance.new("UICorner")
	tbCorner.CornerRadius = UDim.new(0, 4)
	tbCorner.Parent = tabBar

	local tabCombatBtn = Instance.new("TextButton")
	tabCombatBtn.Name = "TabCombat"
	tabCombatBtn.Size = UDim2.new(1/3, -4, 1, -4)
	tabCombatBtn.Position = UDim2.new(0, 2, 0, 2)
	tabCombatBtn.BackgroundColor3 = THEME.TabActive
	tabCombatBtn.Text = "⚔️ Combat"
	tabCombatBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
	tabCombatBtn.TextSize = 13
	applyFont(tabCombatBtn, true)
	tabCombatBtn.Parent = tabBar
	local tcCorner = Instance.new("UICorner")
	tcCorner.CornerRadius = UDim.new(0, 3)
	tcCorner.Parent = tabCombatBtn

	local tabItemBtn = Instance.new("TextButton")
	tabItemBtn.Name = "TabItem"
	tabItemBtn.Size = UDim2.new(1/3, -4, 1, -4)
	tabItemBtn.Position = UDim2.new(1/3, 2, 0, 2)
	tabItemBtn.BackgroundColor3 = THEME.TabInactive
	tabItemBtn.Text = "🎒 Item"
	tabItemBtn.TextColor3 = THEME.TextDark
	tabItemBtn.TextSize = 13
	applyFont(tabItemBtn, true)
	tabItemBtn.Parent = tabBar
	local tiCorner = Instance.new("UICorner")
	tiCorner.CornerRadius = UDim.new(0, 3)
	tiCorner.Parent = tabItemBtn

	local tabSettingsBtn = Instance.new("TextButton")
	tabSettingsBtn.Name = "TabSettings"
	tabSettingsBtn.Size = UDim2.new(1/3, -4, 1, -4)
	tabSettingsBtn.Position = UDim2.new(2/3, 2, 0, 2)
	tabSettingsBtn.BackgroundColor3 = THEME.TabInactive
	tabSettingsBtn.Text = "⚙️ Settings"
	tabSettingsBtn.TextColor3 = THEME.TextDark
	tabSettingsBtn.TextSize = 13
	applyFont(tabSettingsBtn, true)
	tabSettingsBtn.Parent = tabBar
	local tsCorner = Instance.new("UICorner")
	tsCorner.CornerRadius = UDim.new(0, 3)
	tsCorner.Parent = tabSettingsBtn

	local function createScrollContainer(name)
		local scroll = Instance.new("ScrollingFrame")
		scroll.Name = name
		scroll.Size = UDim2.new(1, -16, 1, -78)
		scroll.Position = UDim2.new(0, 8, 0, 72)
		scroll.BackgroundTransparency = 1
		scroll.BorderSizePixel = 0
		scroll.ScrollBarThickness = 5
		scroll.ScrollBarImageColor3 = Color3.fromRGB(180, 170, 155)
		scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
		scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
		scroll.Parent = rightBody

		local layout = Instance.new("UIListLayout")
		layout.Padding = UDim.new(0, 8)
		layout.SortOrder = Enum.SortOrder.LayoutOrder
		layout.Parent = scroll

		local pad = Instance.new("UIPadding")
		pad.PaddingTop = UDim.new(0, 4)
		pad.PaddingBottom = UDim.new(0, 36)
		pad.PaddingLeft = UDim.new(0, 2)
		pad.PaddingRight = UDim.new(0, 6)
		pad.Parent = scroll

		return scroll
	end

	local scrollCombat = createScrollContainer("ScrollCombat")
	local scrollItem = createScrollContainer("ScrollItem")
	scrollItem.Visible = false
	local scrollSettings = createScrollContainer("ScrollSettings")
	scrollSettings.Visible = false

	local function selectTab(activeTab)
		local isCombat = (activeTab == "Combat" or activeTab == true)
		local isItem = (activeTab == "Item")
		local isSettings = (activeTab == "Settings" or activeTab == false)

		scrollCombat.Visible = isCombat
		scrollItem.Visible = isItem
		scrollSettings.Visible = isSettings

		tabCombatBtn.BackgroundColor3 = isCombat and THEME.TabActive or THEME.TabInactive
		tabCombatBtn.TextColor3 = isCombat and Color3.fromRGB(255, 255, 255) or THEME.TextDark

		tabItemBtn.BackgroundColor3 = isItem and THEME.TabActive or THEME.TabInactive
		tabItemBtn.TextColor3 = isItem and Color3.fromRGB(255, 255, 255) or THEME.TextDark

		tabSettingsBtn.BackgroundColor3 = isSettings and THEME.TabActive or THEME.TabInactive
		tabSettingsBtn.TextColor3 = isSettings and Color3.fromRGB(255, 255, 255) or THEME.TextDark
	end
	HUB.SelectTab = selectTab

	HUB:AddConnection(tabCombatBtn.MouseButton1Click:Connect(function() selectTab("Combat") end))
	HUB:AddConnection(tabItemBtn.MouseButton1Click:Connect(function() selectTab("Item") end))
	HUB:AddConnection(tabSettingsBtn.MouseButton1Click:Connect(function() selectTab("Settings") end))

	-- Helper สำหรับสร้าง Toggle Card พร้อมปุ่ม Action เพิ่มเติมหรือแถบตั้งค่าขยายในตัว
	local cardOrderCount = 0
	local function createCard(parentScroll, titleText, descText, initialVal, onToggle, extraBtnData, settingPanelBuilder, customGearAction)
		cardOrderCount = cardOrderCount + 1
		local card = Instance.new("Frame")
		card.Name = "Card_" .. titleText:gsub("%s+", "")
		card.LayoutOrder = cardOrderCount
		card.Size = UDim2.new(1, 0, 0, 74)
		card.BackgroundColor3 = Color3.fromRGB(246, 240, 228)
		card.BorderSizePixel = 0
		card.ClipsDescendants = true
		card.Parent = parentScroll

		local cCorner = Instance.new("UICorner")
		cCorner.CornerRadius = UDim.new(0, 4)
		cCorner.Parent = card

		local cStroke = Instance.new("UIStroke")
		cStroke.Color = THEME.PanelBorder
		cStroke.Thickness = 1
		cStroke.Parent = card

		local hasSettings = (settingPanelBuilder ~= nil or customGearAction ~= nil)
		local rightOffset = (extraBtnData and hasSettings and -220) or (extraBtnData and -180) or (hasSettings and -135) or -95

		local cTitle = Instance.new("TextLabel")
		cTitle.Name = "Title"
		cTitle.Size = UDim2.new(1, rightOffset, 0, 22)
		cTitle.Position = UDim2.new(0, 12, 0, 6)
		cTitle.BackgroundTransparency = 1
		cTitle.Text = titleText
		cTitle.TextColor3 = THEME.TextDark
		cTitle.TextSize = 14
		cTitle.TextXAlignment = Enum.TextXAlignment.Left
		applyFont(cTitle, true)
		cTitle.Parent = card

		local cDesc = Instance.new("TextLabel")
		cDesc.Name = "Desc"
		cDesc.Size = UDim2.new(1, rightOffset, 0, 20)
		cDesc.Position = UDim2.new(0, 12, 0, 28)
		cDesc.BackgroundTransparency = 1
		cDesc.Text = descText
		cDesc.TextColor3 = THEME.TextSub
		cDesc.TextSize = 11
		cDesc.TextXAlignment = Enum.TextXAlignment.Left
		applyFont(cDesc, false)
		cDesc.Parent = card

		local cStatus = Instance.new("TextLabel")
		cStatus.Name = "Status"
		cStatus.Size = UDim2.new(1, rightOffset, 0, 16)
		cStatus.Position = UDim2.new(0, 12, 0, 48)
		cStatus.BackgroundTransparency = 1
		cStatus.Text = "สถานะ: " .. (initialVal and "เปิดใช้งาน" or "ปิดใช้งาน")
		cStatus.TextColor3 = THEME.TextAmber
		cStatus.TextSize = 11
		cStatus.TextXAlignment = Enum.TextXAlignment.Left
		applyFont(cStatus, false)
		cStatus.Parent = card

		local toggleBtn = Instance.new("TextButton")
		toggleBtn.Name = "ToggleBtn"
		toggleBtn.Size = UDim2.new(0, 74, 0, 34)
		toggleBtn.Position = UDim2.new(1, -84, 0, 20)
		toggleBtn.BorderSizePixel = 0
		applyFont(toggleBtn, true)
		toggleBtn.TextSize = 14
		toggleBtn.Parent = card

		local btnCorner = Instance.new("UICorner")
		btnCorner.CornerRadius = UDim.new(0, 4)
		btnCorner.Parent = toggleBtn

		local btnStroke = Instance.new("UIStroke")
		btnStroke.Thickness = 1.5
		btnStroke.Parent = toggleBtn

		local state = initialVal
		local function refreshBtn()
			if state then
				toggleBtn.BackgroundColor3 = THEME.BtnGreen
				toggleBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
				toggleBtn.Text = "ON"
				btnStroke.Color = THEME.BtnGreenStroke
			else
				toggleBtn.BackgroundColor3 = THEME.BtnOff
				toggleBtn.TextColor3 = THEME.TextDark
				toggleBtn.Text = "OFF"
				btnStroke.Color = THEME.BtnOffStroke
			end
		end
		refreshBtn()
		if onToggle then pcall(onToggle, state, cStatus) end

		HUB:AddConnection(toggleBtn.MouseButton1Click:Connect(function()
			state = not state
			refreshBtn()
			if onToggle then onToggle(state, cStatus) end
			if HUB.Config.autoSave then saveConfig() end
		end))

		-- ปุ่มรูปฟันเฟืองสำหรับคลี่แถบตั้งค่าในตัวการ์ด (Inline Expandable Settings) หรือเปิด Custom Action (Modal)
		if settingPanelBuilder or customGearAction then
			local isExpanded = false

			local subPanel = nil
			if settingPanelBuilder then
				subPanel = Instance.new("Frame")
				subPanel.Name = "SettingPanel"
				subPanel.Size = UDim2.new(1, -24, 0, 46)
				subPanel.Position = UDim2.new(0, 12, 0, 72)
				subPanel.BackgroundColor3 = THEME.DarkNavy
				subPanel.BorderSizePixel = 0
				subPanel.Visible = false
				subPanel.Parent = card
				local spCorner = Instance.new("UICorner")
				spCorner.CornerRadius = UDim.new(0, 4)
				spCorner.Parent = subPanel
				local spStroke = Instance.new("UIStroke")
				spStroke.Color = Color3.fromRGB(240, 190, 60)
				spStroke.Thickness = 1.2
				spStroke.Parent = subPanel
			end

			local gearBtn = Instance.new("TextButton")
			gearBtn.Name = "GearSettingBtn"
			gearBtn.Size = UDim2.new(0, 34, 0, 34)
			gearBtn.Position = UDim2.new(1, -124, 0, 20)
			gearBtn.BackgroundColor3 = THEME.DarkNavy
			gearBtn.BorderSizePixel = 0
			gearBtn.Text = ""
			gearBtn.AutoButtonColor = true
			gearBtn.Parent = card

			local gbCorner = Instance.new("UICorner")
			gbCorner.CornerRadius = UDim.new(0, 4)
			gbCorner.Parent = gearBtn

			local gbStroke = Instance.new("UIStroke")
			gbStroke.Color = Color3.fromRGB(240, 190, 60)
			gbStroke.Thickness = 1.2
			gbStroke.Parent = gearBtn

			local gearIcon = Instance.new("ImageLabel")
			gearIcon.Name = "Icon"
			gearIcon.AnchorPoint = Vector2.new(0.5, 0.5)
			gearIcon.Size = UDim2.new(0, 22, 0, 22)
			gearIcon.Position = UDim2.new(0.5, 0, 0.5, 0)
			gearIcon.BackgroundTransparency = 1
			gearIcon.Image = THEME.AtlasIcon
			gearIcon.ImageRectOffset = THEME.SettingIconRect
			gearIcon.ImageRectSize = THEME.IconSize
			gearIcon.Parent = gearBtn

			local expCardHeight = 126

			local function onGearClick()
				if customGearAction then
					pcall(customGearAction)
					return
				end
				if subPanel then
					isExpanded = not isExpanded
					if isExpanded then
						card.Size = UDim2.new(1, 0, 0, expCardHeight)
						subPanel.Visible = true
						gearBtn.BackgroundColor3 = THEME.TabActive
					else
						card.Size = UDim2.new(1, 0, 0, 74)
						subPanel.Visible = false
						gearBtn.BackgroundColor3 = THEME.DarkNavy
					end
				end
			end

			HUB:AddConnection(gearBtn.MouseButton1Click:Connect(onGearClick))

			if settingPanelBuilder and subPanel then
				local function setExpandHeight(panelH, cardH)
					expCardHeight = cardH or (panelH + 80)
					subPanel.Size = UDim2.new(1, -24, 0, panelH)
				end

				-- เรียก builder เพื่อสร้างเนื้อหาใน subPanel
				settingPanelBuilder(subPanel, card, cStatus, setExpandHeight)
			end
		end

		-- ปุ่ม Action เพิ่มเติม (เช่น เคลมทันที หรือ อัพแต้ม)
		if extraBtnData then
			local extraBtn = Instance.new("TextButton")
			extraBtn.Name = "ExtraActionBtn"
			extraBtn.Size = UDim2.new(0, 80, 0, 34)
			extraBtn.Position = UDim2.new(1, ((settingPanelBuilder or customGearAction) and -210 or -170), 0, 20)
			extraBtn.BackgroundColor3 = THEME.BtnOrange
			extraBtn.BorderSizePixel = 0
			extraBtn.Text = extraBtnData.Text or "Action"
			extraBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
			extraBtn.TextSize = 12
			applyFont(extraBtn, true)
			extraBtn.Parent = card
			local ebCorner = Instance.new("UICorner")
			ebCorner.CornerRadius = UDim.new(0, 4)
			ebCorner.Parent = extraBtn
			local ebStroke = Instance.new("UIStroke")
			ebStroke.Color = THEME.BtnOrangeStroke
			ebStroke.Thickness = 1.2
			ebStroke.Parent = extraBtn

			if extraBtnData.OnClick then
				HUB:AddConnection(extraBtn.MouseButton1Click:Connect(function()
					extraBtnData.OnClick(cStatus)
				end))
			end
		end

		return card, cStatus
	end

	-- ---------- 7.5 Cards ในแท็บ Combat ----------
	local _, dodgeStatus = createCard(
		scrollCombat,
		"Auto Dodge (หลบวงแดง & เข้าโซนเขียว)",
		"สปริ้นต์หลบวงแดงอัตโนมัติ และสปริ้นต์ตลอดเวลาเมื่อ Auto Play เล็งเป้ามอนสเตอร์ (Stamina Sprint)",
		HUB.Config.autoDodge,
		function(enabled, label)
			HUB.Config.autoDodge = enabled
			local buf = HUB.Config.dodgeBuffer or 4.0
			label.Text = string.format("สถานะ: %s · หลบแล้ว %d ครั้ง (ระยะเผื่อ %.1f studs)", enabled and "เปิดใช้งาน" or "ปิดใช้งาน", HUB.Stats.dodgesPerformed, buf)
		end,
		nil,
		function(subPanel, card, cStatus, setExpandHeight)
			if setExpandHeight then
				setExpandHeight(152, 240)
			end
			subPanel.Size = UDim2.new(1, -24, 0, 152)

			-- แถวที่ 1: หลบวงแดง (Dodge Red Circles / Danger Zones)
			local lblRed = Instance.new("TextLabel")
			lblRed.Size = UDim2.new(1, -165, 0, 28)
			lblRed.Position = UDim2.new(0, 10, 0, 4)
			lblRed.BackgroundTransparency = 1
			lblRed.Text = "🔴 หลบวงแดง (Danger Zone):"
			lblRed.TextColor3 = Color3.fromRGB(255, 220, 100)
			lblRed.TextSize = 12
			lblRed.TextXAlignment = Enum.TextXAlignment.Left
			applyFont(lblRed, true)
			lblRed.Parent = subPanel

			local redToggleBtn = Instance.new("TextButton")
			redToggleBtn.Size = UDim2.new(0, 145, 0, 28)
			redToggleBtn.Position = UDim2.new(1, -155, 0, 4)
			redToggleBtn.BorderSizePixel = 0
			applyFont(redToggleBtn, true)
			redToggleBtn.TextSize = 12
			redToggleBtn.Parent = subPanel
			local rtbCorner = Instance.new("UICorner")
			rtbCorner.CornerRadius = UDim.new(0, 6)
			rtbCorner.Parent = redToggleBtn

			local function refreshRedBtn()
				local on = (HUB.Config.dodgeRedZones ~= false)
				redToggleBtn.BackgroundColor3 = on and THEME.BtnGreen or THEME.BtnOff
				redToggleBtn.TextColor3 = on and Color3.fromRGB(255, 255, 255) or THEME.TextDark
				redToggleBtn.Text = on and "เปิดใช้งาน (ON)" or "ปิดใช้งาน (OFF)"
			end
			refreshRedBtn()

			HUB:AddConnection(redToggleBtn.MouseButton1Click:Connect(function()
				HUB.Config.dodgeRedZones = not (HUB.Config.dodgeRedZones ~= false)
				refreshRedBtn()
				if HUB.Config.autoSave then saveConfig() end
			end))

			-- แถวที่ 2: เข้าโซนเขียว (Safe Green Zones)
			local lblGreen = Instance.new("TextLabel")
			lblGreen.Size = UDim2.new(1, -165, 0, 28)
			lblGreen.Position = UDim2.new(0, 10, 0, 40)
			lblGreen.BackgroundTransparency = 1
			lblGreen.Text = "🟢 เข้าโซนเขียว (Safe Zone):"
			lblGreen.TextColor3 = Color3.fromRGB(255, 220, 100)
			lblGreen.TextSize = 12
			lblGreen.TextXAlignment = Enum.TextXAlignment.Left
			applyFont(lblGreen, true)
			lblGreen.Parent = subPanel

			local greenToggleBtn = Instance.new("TextButton")
			greenToggleBtn.Size = UDim2.new(0, 145, 0, 28)
			greenToggleBtn.Position = UDim2.new(1, -155, 0, 40)
			greenToggleBtn.BorderSizePixel = 0
			applyFont(greenToggleBtn, true)
			greenToggleBtn.TextSize = 12
			greenToggleBtn.Parent = subPanel
			local gtbCorner = Instance.new("UICorner")
			gtbCorner.CornerRadius = UDim.new(0, 6)
			gtbCorner.Parent = greenToggleBtn

			local function refreshGreenBtn()
				local on = (HUB.Config.dodgeGreenZones ~= false)
				greenToggleBtn.BackgroundColor3 = on and THEME.BtnGreen or THEME.BtnOff
				greenToggleBtn.TextColor3 = on and Color3.fromRGB(255, 255, 255) or THEME.TextDark
				greenToggleBtn.Text = on and "เปิดใช้งาน (ON)" or "ปิดใช้งาน (OFF)"
			end
			refreshGreenBtn()

			HUB:AddConnection(greenToggleBtn.MouseButton1Click:Connect(function()
				HUB.Config.dodgeGreenZones = not (HUB.Config.dodgeGreenZones ~= false)
				refreshGreenBtn()
				if HUB.Config.autoSave then saveConfig() end
			end))

			-- แถวที่ 3: ระยะเผื่อพ้นขอบวงแดง (Buffer)
			local lblBuf = Instance.new("TextLabel")
			lblBuf.Size = UDim2.new(1, -165, 0, 30)
			lblBuf.Position = UDim2.new(0, 10, 0, 76)
			lblBuf.BackgroundTransparency = 1
			lblBuf.Text = "📏 ระยะเผื่อพ้นขอบวงแดง (Buffer):"
			lblBuf.TextColor3 = Color3.fromRGB(255, 220, 100)
			lblBuf.TextSize = 12
			lblBuf.TextXAlignment = Enum.TextXAlignment.Left
			applyFont(lblBuf, true)
			lblBuf.Parent = subPanel

			local stepBox = Instance.new("Frame")
			stepBox.Size = UDim2.new(0, 145, 0, 30)
			stepBox.Position = UDim2.new(1, -155, 0, 76)
			stepBox.BackgroundColor3 = Color3.fromRGB(246, 240, 228)
			stepBox.BorderSizePixel = 0
			stepBox.Parent = subPanel
			local sbCorner = Instance.new("UICorner")
			sbCorner.CornerRadius = UDim.new(0, 6)
			sbCorner.Parent = stepBox

			local currentBuf = HUB.Config.dodgeBuffer or 4.0

			local minusBtn = Instance.new("TextButton")
			minusBtn.Size = UDim2.new(0, 34, 1, 0)
			minusBtn.Position = UDim2.new(0, 0, 0, 0)
			minusBtn.BackgroundColor3 = THEME.BtnOrange
			minusBtn.Text = "-"
			minusBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
			minusBtn.TextSize = 16
			applyFont(minusBtn, true)
			minusBtn.Parent = stepBox
			local mbCorner = Instance.new("UICorner")
			mbCorner.CornerRadius = UDim.new(0, 4)
			mbCorner.Parent = minusBtn

			local valLabel = Instance.new("TextLabel")
			valLabel.Size = UDim2.new(1, -68, 1, 0)
			valLabel.Position = UDim2.new(0, 34, 0, 0)
			valLabel.BackgroundTransparency = 1
			valLabel.Text = string.format("%.1f studs", currentBuf)
			valLabel.TextColor3 = THEME.TextDark
			valLabel.TextSize = 12
			applyFont(valLabel, true)
			valLabel.Parent = stepBox

			local plusBtn = Instance.new("TextButton")
			plusBtn.Size = UDim2.new(0, 34, 1, 0)
			plusBtn.Position = UDim2.new(1, -34, 0, 0)
			plusBtn.BackgroundColor3 = THEME.BtnGreen
			plusBtn.Text = "+"
			plusBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
			plusBtn.TextSize = 16
			applyFont(plusBtn, true)
			plusBtn.Parent = stepBox
			local pbCorner = Instance.new("UICorner")
			pbCorner.CornerRadius = UDim.new(0, 4)
			pbCorner.Parent = plusBtn

			local function updateBuf(delta)
				currentBuf = math.clamp(currentBuf + delta, 2.0, 15.0)
				valLabel.Text = string.format("%.1f studs", currentBuf)
				HUB.Config.dodgeBuffer = currentBuf
				if HUB.Config.autoSave then saveConfig() end
				cStatus.Text = string.format("สถานะ: %s · หลบแล้ว %d ครั้ง (ระยะเผื่อ %.1f studs)", HUB.Config.autoDodge and "เปิดใช้งาน" or "ปิดใช้งาน", HUB.Stats.dodgesPerformed, currentBuf)
			end

			HUB:AddConnection(minusBtn.MouseButton1Click:Connect(function() updateBuf(-1.0) end))
			HUB:AddConnection(plusBtn.MouseButton1Click:Connect(function() updateBuf(1.0) end))

			-- แถวที่ 4: สปริ้นต์เมื่อ Auto Play เล็งเป้ามอนสเตอร์ (Target Sprint)
			local lblSprint = Instance.new("TextLabel")
			lblSprint.Size = UDim2.new(1, -165, 0, 28)
			lblSprint.Position = UDim2.new(0, 10, 0, 114)
			lblSprint.BackgroundTransparency = 1
			lblSprint.Text = "⚡ สปริ้นต์เมื่อ Auto Play เล็งเป้า:"
			lblSprint.TextColor3 = Color3.fromRGB(255, 220, 100)
			lblSprint.TextSize = 12
			lblSprint.TextXAlignment = Enum.TextXAlignment.Left
			applyFont(lblSprint, true)
			lblSprint.Parent = subPanel

			local sprintToggleBtn = Instance.new("TextButton")
			sprintToggleBtn.Size = UDim2.new(0, 145, 0, 28)
			sprintToggleBtn.Position = UDim2.new(1, -155, 0, 114)
			sprintToggleBtn.BorderSizePixel = 0
			applyFont(sprintToggleBtn, true)
			sprintToggleBtn.TextSize = 12
			sprintToggleBtn.Parent = subPanel
			local stbCorner = Instance.new("UICorner")
			stbCorner.CornerRadius = UDim.new(0, 6)
			stbCorner.Parent = sprintToggleBtn

			local function refreshSprintBtn()
				local on = (HUB.Config.targetSprint ~= false)
				sprintToggleBtn.BackgroundColor3 = on and THEME.BtnGreen or THEME.BtnOff
				sprintToggleBtn.TextColor3 = on and Color3.fromRGB(255, 255, 255) or THEME.TextDark
				sprintToggleBtn.Text = on and "เปิดใช้งาน (ON)" or "ปิดใช้งาน (OFF)"
			end
			refreshSprintBtn()

			HUB:AddConnection(sprintToggleBtn.MouseButton1Click:Connect(function()
				HUB.Config.targetSprint = not (HUB.Config.targetSprint ~= false)
				refreshSprintBtn()
				if HUB.Config.autoSave then saveConfig() end
			end))
		end
	)
	HUB.UI.DodgeStatusLabel = dodgeStatus

	-- ---------- 7.5.2 Card ในแท็บ Combat: Auto Open LootBox (วิ่งไปเปิดและกลับที่เดิม) ----------
	local _, boxStatus = createCard(
		scrollCombat,
		"Auto Open LootBox (วิ่งไปเปิดและกลับที่เดิม)",
		"วิ่งไปเปิดกล่องสมบัติในระยะฟาร์มของเกม แล้ววิ่งกลับมายังจุดฟาร์มเดิมอัตโนมัติ",
		HUB.Config.autoOpenBox,
		function(enabled, label)
			HUB.Config.autoOpenBox = enabled
			local limit = HUB.Config.maxLootBoxMiniboss or 1
			label.Text = string.format("สถานะ: %s · เปิดแล้ว %d (จำกัด Mini-Boss %d ตัว)", enabled and "เปิดใช้งาน" or "ปิดใช้งาน", HUB.Stats.boxesOpened, limit)
		end,
		nil,
		function(subPanel, card, cStatus)
			local lbl = Instance.new("TextLabel")
			lbl.Size = UDim2.new(1, -165, 1, 0)
			lbl.Position = UDim2.new(0, 10, 0, 0)
			lbl.BackgroundTransparency = 1
			lbl.Text = "หยุดเปิดกล่องเมื่อเจอ Mini-Boss เกิน:"
			lbl.TextColor3 = Color3.fromRGB(255, 220, 100)
			lbl.TextSize = 12
			lbl.TextXAlignment = Enum.TextXAlignment.Left
			applyFont(lbl, true)
			lbl.Parent = subPanel

			local stepBox = Instance.new("Frame")
			stepBox.Size = UDim2.new(0, 145, 0, 32)
			stepBox.Position = UDim2.new(1, -155, 0.5, -16)
			stepBox.BackgroundColor3 = Color3.fromRGB(246, 240, 228)
			stepBox.BorderSizePixel = 0
			stepBox.Parent = subPanel
			local sbCorner = Instance.new("UICorner")
			sbCorner.CornerRadius = UDim.new(0, 4)
			sbCorner.Parent = stepBox

			local currentLimit = HUB.Config.maxLootBoxMiniboss or 1

			local minusBtn = Instance.new("TextButton")
			minusBtn.Size = UDim2.new(0, 34, 1, 0)
			minusBtn.Position = UDim2.new(0, 0, 0, 0)
			minusBtn.BackgroundColor3 = THEME.BtnOrange
			minusBtn.Text = "-"
			minusBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
			minusBtn.TextSize = 16
			applyFont(minusBtn, true)
			minusBtn.Parent = stepBox
			local mbCorner = Instance.new("UICorner")
			mbCorner.CornerRadius = UDim.new(0, 4)
			mbCorner.Parent = minusBtn

			local valLabel = Instance.new("TextLabel")
			valLabel.Size = UDim2.new(1, -68, 1, 0)
			valLabel.Position = UDim2.new(0, 34, 0, 0)
			valLabel.BackgroundTransparency = 1
			valLabel.Text = tostring(currentLimit) .. " ตัว"
			valLabel.TextColor3 = THEME.TextDark
			valLabel.TextSize = 13
			applyFont(valLabel, true)
			valLabel.Parent = stepBox

			local plusBtn = Instance.new("TextButton")
			plusBtn.Size = UDim2.new(0, 34, 1, 0)
			plusBtn.Position = UDim2.new(1, -34, 0, 0)
			plusBtn.BackgroundColor3 = THEME.BtnGreen
			plusBtn.Text = "+"
			plusBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
			plusBtn.TextSize = 16
			applyFont(plusBtn, true)
			plusBtn.Parent = stepBox
			local pbCorner = Instance.new("UICorner")
			pbCorner.CornerRadius = UDim.new(0, 4)
			pbCorner.Parent = plusBtn

			local function updateVal(delta)
				currentLimit = math.clamp(currentLimit + delta, 1, 10)
				valLabel.Text = tostring(currentLimit) .. " ตัว"
				HUB.Config.maxLootBoxMiniboss = currentLimit
				if HUB.Config.autoSave then saveConfig() end
				cStatus.Text = string.format("สถานะ: %s · เปิดแล้ว %d (จำกัด Mini-Boss %d ตัว)", HUB.Config.autoOpenBox and "เปิดใช้งาน" or "ปิดใช้งาน", HUB.Stats.boxesOpened, currentLimit)
			end

			HUB:AddConnection(minusBtn.MouseButton1Click:Connect(function() updateVal(-1) end))
			HUB:AddConnection(plusBtn.MouseButton1Click:Connect(function() updateVal(1) end))
		end
	)
	HUB.UI.BoxStatusLabel = boxStatus

	-- ---------- 7.5.3 Card ในแท็บ Item: Auto Claim Rewards (ตรวจจับและเคลมอัตโนมัติ) ----------
	local _, claimStatus = createCard(
		scrollItem,
		"Auto Claim Rewards (ตรวจจับและเคลมอัตโนมัติ)",
		"ตรวจจับแบบ Real-Time และเคลมทันทีเมื่อมีของรางวัลให้รับ (Daily, Mailbox, Battle Pass, Playtime, Ach)",
		HUB.Config.autoClaim,
		function(enabled, label)
			HUB.Config.autoClaim = enabled
			label.Text = string.format("สถานะ: %s (เคลมแล้ว %d รอบ)", enabled and "เปิดใช้งาน (ตรวจจับอัตโนมัติ)" or "ปิดใช้งาน", HUB.Stats.rewardsClaimed)
			if enabled and type(HUB.DetectClaimableRewards) == "function" then
				local det = HUB.DetectClaimableRewards()
				if det.any and type(HUB.ClaimAllRewards) == "function" then
					HUB.ClaimAllRewards(table.concat(det.reasons, ", "))
				end
			end
		end,
		{
			Text = "🎁 เคลมทันที",
			OnClick = function(label)
				if type(HUB.ClaimAllRewards) == "function" then
					HUB.ClaimAllRewards()
					label.Text = "สถานะ: ส่งคำขอเคลมรางวัลแล้ว!"
				end
			end
		}
	)
	HUB.UI.ClaimStatusLabel = claimStatus

	-- ---------- 7.5.4 Card ในแท็บ Item: Item Tier Ranking (SS - F Overlay) ----------
	local _, tierStatus = createCard(
		scrollItem,
		"Item Tier Ranking (SS - F Overlay)",
		"คัดแยกเกรดไอเทมตามค่าพลัง สเตตัสตรงสาย และชุดเซ็ต พร้อมแสดง Badge มุมซ้ายบนในกระเป๋า",
		HUB.Config.itemTierBadges,
		function(enabled, label)
			HUB.Config.itemTierBadges = enabled
			if enabled then
				local s = HUB.ItemTier and HUB.ItemTier.LastSummary
				if s and s.Total > 0 then
					label.Text = string.format("สถานะ: เปิดใช้งาน · SS:%d S:%d A:%d B:%d C:%d D:%d F:%d (รวม %d ชิ้น)", s.SS, s.S, s.A, s.B, s.C, s.D, s.F, s.Total)
				else
					label.Text = "สถานะ: เปิดใช้งาน Overlay (ค่ากลางสากล)"
				end
				if HUB.ItemTier then task.spawn(HUB.ItemTier.UpdateBadges) end
			else
				label.Text = "สถานะ: ปิดการแสดง Badge"
				if HUB.ItemTier then task.spawn(HUB.ItemTier.ClearBadges) end
			end
		end,
		nil,
		nil
	)
	HUB.UI.TierStatusLabel = tierStatus

	-- =========================================================================
	-- 7.5.4.1 Modal Dialog: การตั้งค่า Auto Lock Item ขั้นสูง (v9.18)
	-- =========================================================================
	local autoLockModalInstance = nil
	local currentCatDef = nil
	local refreshAllBadges = nil
	local renderDetail = nil

	local modalConns = {}
	local detailConns = {}
	local cardsConns = {}

	local function clearConns(t)
		for _, c in ipairs(t) do
			pcall(function() c:Disconnect() end)
		end
		table.clear(t)
	end

	local function openAutoLockModal()
		if autoLockModalInstance and autoLockModalInstance.Parent then
			autoLockModalInstance.Visible = true
			if refreshAllBadges then refreshAllBadges() end
			if renderDetail and currentCatDef then
				renderDetail(currentCatDef)
			end
			return
		end

		local function applyGameIcon(img, sampleKey, fallbackId)
			img.Image = fallbackId or ""
			img.ImageRectOffset = Vector2.zero
			img.ImageRectSize = Vector2.zero
		end

		local CATEGORY_DEFS = {
			{
				Id = "GLOBAL",
				Name = "⭐ เกรด & ระดับดาว",
				Sub = "ตั้งค่าสากลสำหรับทุกประเภทอุปกรณ์",
				FallbackIcon = "rbxassetid://127066642314924",
				IsGlobal = true
			},
			{
				Id = "RingMatk",
				Name = "💍 แหวนเวทย์ (MATK Ring)",
				Sub = "กลุ่ม: RingMatk · แหวนเวทย์ / INT / SP",
				SampleKey = "Items/ring_water_t5",
				FallbackIcon = "rbxassetid://105824855649695",
				Specials = { "CRIT", "Cooldown", "MatkPercent", "CastSpeed", "ASPD", "SkillSingle", "SkillAoe" },
				Pool = { "INT", "AGI", "DEX", "LUK", "SP", "MATK", "DropPct", "ExpPct" },
				ForbiddenCandidates = { "STR", "VIT", "DEF", "HP", "FLEE", "MDEF", "MeleeDmg", "RangedDmg" }
			},
			{
				Id = "RingAtk",
				Name = "💍 แหวนกาย (ATK Ring)",
				Sub = "กลุ่ม: RingAtk · แหวนกายภาพ / STR / โจมตีเร็ว",
				SampleKey = "Items/ring_fire_t5",
				FallbackIcon = "rbxassetid://139585878328077",
				Specials = { "ASPD", "CRIT", "Cooldown", "CastSpeed", "SkillSingle", "SkillAoe" },
				Pool = { "STR", "AGI", "DEX", "LUK", "SP", "ATK", "MeleeDmg", "RangedDmg", "DropPct", "ExpPct" },
				ForbiddenCandidates = { "INT", "VIT", "DEF", "HP", "FLEE", "MDEF" }
			},
			{
				Id = "WeaponPhysMelee",
				Name = "⚔️ อาวุธกายประชิด (Melee Phys)",
				Sub = "กลุ่ม: ดาบ / ขวาน / มีด / คาตานะ",
				SampleKey = "Items/sword_t5",
				FallbackIcon = "rbxassetid://88552333464833",
				Specials = { "CRIT", "AtkPercent", "AtkMatkPercent", "Pierce", "ASPD", "CritDmg", "SkillSingle", "SkillAoe" },
				Pool = { "STR", "AGI", "DEX", "LUK", "MeleeDmg", "ATK", "DropPct", "ExpPct" },
				ForbiddenCandidates = { "INT", "SP", "VIT", "DEF", "HP", "MATK", "RangedDmg", "MPierce" }
			},
			{
				Id = "WeaponPhysRanged",
				Name = "🏹 อาวุธกายระยะไกล (Ranged Phys)",
				Sub = "กลุ่ม: ธนู (Bow)",
				SampleKey = "Items/bow_t5",
				FallbackIcon = "rbxassetid://95385333161493",
				Specials = { "CRIT", "AtkPercent", "AtkMatkPercent", "Pierce", "ASPD", "CritDmg", "SkillSingle", "SkillAoe" },
				Pool = { "DEX", "AGI", "STR", "LUK", "RangedDmg", "ATK", "DropPct", "ExpPct" },
				ForbiddenCandidates = { "INT", "SP", "VIT", "DEF", "HP", "MATK", "MeleeDmg", "MPierce" }
			},
			{
				Id = "WeaponMagic",
				Name = "🪄 อาวุธเวทย์ (Magic Weapon)",
				Sub = "กลุ่ม: WeaponMagic · คทา / คัมภีร์เวทย์",
				SampleKey = "Items/rod_t5",
				FallbackIcon = "rbxassetid://97000273852760",
				Specials = { "CRIT", "MatkPercent", "AtkMatkPercent", "MPierce", "Cooldown", "CastSpeed", "CritDmg", "SkillSingle", "SkillAoe" },
				Pool = { "INT", "DEX", "LUK", "SP", "MATK", "DropPct", "ExpPct" },
				ForbiddenCandidates = { "STR", "AGI", "VIT", "DEF", "HP", "MeleeDmg", "RangedDmg", "Pierce" }
			},
			{
				Id = "WeaponFlask",
				Name = "⚗️ อาวุธปรุงยา (Flask)",
				Sub = "กลุ่ม: WeaponFlask · ขวดปรุงยานักเล่นแร่แปรธาตุ",
				SampleKey = "Items/flask_t5",
				FallbackIcon = "rbxassetid://135145414807744",
				Specials = { "CRIT", "MatkPercent", "AtkMatkPercent", "MPierce", "Cooldown", "ASPD", "CritDmg", "SkillSingle", "SkillAoe" },
				Pool = { "INT", "AGI", "DEX", "LUK", "SP", "ATK", "MATK", "DropPct", "ExpPct" },
				ForbiddenCandidates = { "STR", "VIT", "DEF", "HP", "MeleeDmg", "RangedDmg" }
			},
			{
				Id = "HeadTop",
				Name = "⛑️ หมวกบน (HeadTop / Helm)",
				Sub = "กลุ่ม: HeadTop · หมวกเกราะป้องกัน",
				SampleKey = "Items/helm_t5",
				FallbackIcon = "rbxassetid://94616329517195",
				Specials = { "HpPercent", "PotionPct", "DmgReduce" },
				Pool = { "HP", "VIT", "DEF", "FLEE", "SpeedR", "SkillTaken", "HitTaken" },
				ForbiddenCandidates = { "SP", "INT", "STR", "MDEF" }
			},
			{
				Id = "HeadMid",
				Name = "🥽 หน้ากาก (HeadMid / Mask)",
				Sub = "กลุ่ม: HeadMid · หน้ากากและแว่นตา",
				SampleKey = "Items/mask_t5",
				FallbackIcon = "rbxassetid://74422487789148",
				Specials = { "SpPercent", "SpCost", "DmgReduce" },
				Pool = { "HP", "VIT", "DEF", "MDEF", "SP", "FLEE", "SpeedR", "SkillTaken", "HitTaken" },
				ForbiddenCandidates = { "STR", "AGI", "INT", "LUK" }
			},
			{
				Id = "Body",
				Name = "🥋 เสื้อเกราะ (Body / Armor)",
				Sub = "กลุ่ม: Body · เสื้อเกราะลำตัว",
				SampleKey = "Items/armor_t5",
				FallbackIcon = "rbxassetid://87889334606143",
				Specials = { "HpPercent", "DefPercent", "DmgReduce" },
				Pool = { "HP", "VIT", "DEF", "FLEE", "SpeedR", "SkillTaken", "HitTaken" },
				ForbiddenCandidates = { "SP", "INT", "STR", "MDEF" }
			},
			{
				Id = "Garment",
				Name = "🧶 ผ้าคลุม (Garment / Cloak)",
				Sub = "กลุ่ม: Garment · ผ้าคลุมหลัง",
				SampleKey = "Items/cloak_t5",
				FallbackIcon = "rbxassetid://119982170018269",
				Specials = { "DmgReduce", "HpRegenMax", "SpRegenPercent", "DefPercent", "Speed" },
				Pool = { "HP", "VIT", "DEF", "FLEE", "SpeedR", "SkillTaken", "HitTaken" },
				ForbiddenCandidates = { "STR", "INT", "DEX", "LUK" }
			},
			{
				Id = "Shoes",
				Name = "🥾 รองเท้า (Shoes / Boots)",
				Sub = "กลุ่ม: Shoes · รองเท้าเดินไว",
				SampleKey = "Items/boots_t5",
				FallbackIcon = "rbxassetid://125143879461934",
				Specials = { "Speed", "DmgReduce", "DefPercent", "HpPercent" },
				Pool = { "HP", "VIT", "DEF", "FLEE", "SpeedR", "SkillTaken", "HitTaken" },
				ForbiddenCandidates = { "SP", "INT", "STR", "MDEF" }
			}
		}

		local OPTION_LABELS = {
			CRIT = "CRIT (คริ)",
			Cooldown = "CD (ลดคูล)",
			MatkPercent = "MATK% (เวทย์)",
			CastSpeed = "Cast (ร่ายไว)",
			ASPD = "ASPD (ตีไว)",
			AtkPercent = "ATK% (กาย)",
			Pierce = "Pierce (เจาะเกราะ)",
			MPierce = "M.Pierce (เจาะเวทย์)",
			HpPercent = "HP% (เลือด)",
			PotionPct = "Potion% (ยา)",
			SpPercent = "SP% (มานา)",
			SpCost = "SP Cost (ลดใช้)",
			DefPercent = "DEF% (ป้องกัน)",
			DmgReduce = "Dmg Red (ลดดาเมจ)",
			HpRegenMax = "HP Regen (ฟื้นเลือด)",
			SpRegenPercent = "SP Regen (ฟื้นมานา)",
			Speed = "Speed (วิ่งไว)",
			-- New T6 / Endgame Options
			AtkMatkPercent = "ATK&MATK% (กาย+เวทย์)",
			CritDmg = "Crit DMG% (แรงคริ)",
			SkillSingle = "Single Skill% (สกิลเดี่ยว)",
			SkillAoe = "AoE Skill% (สกิลหมู่)",
			MeleeDmg = "Melee DMG% (ดาเมจประชิด)",
			RangedDmg = "Ranged DMG% (ดาเมจไกล)",
			ATK = "ATK (พลังโจมตี)",
			MATK = "MATK (พลังเวทย์)",
			DropPct = "Drop% (อัตราดรอป)",
			ExpPct = "EXP% (โบนัส EXP)",
			SpeedR = "Move Speed% (วิ่งไว)",
			SkillTaken = "Skill Resist% (กันสกิล)",
			HitTaken = "Hit Resist% (กันตีปกติ)",
		}

		local STAT_COLORS = {
			STR = Color3.fromRGB(220, 90, 40),
			AGI = Color3.fromRGB(40, 180, 80),
			INT = Color3.fromRGB(40, 140, 240),
			DEX = Color3.fromRGB(230, 180, 30),
			LUK = Color3.fromRGB(160, 70, 220),
			VIT = Color3.fromRGB(230, 80, 140),
			HP  = Color3.fromRGB(220, 60, 60),
			SP  = Color3.fromRGB(60, 120, 230),
			DEF = Color3.fromRGB(120, 120, 140),
			MDEF= Color3.fromRGB(90, 140, 160),
			FLEE= Color3.fromRGB(50, 170, 140),
			ATK = Color3.fromRGB(220, 90, 40),
			MATK= Color3.fromRGB(40, 140, 240),
			MeleeDmg = Color3.fromRGB(220, 90, 40),
			RangedDmg = Color3.fromRGB(230, 170, 30),
			DropPct = Color3.fromRGB(240, 200, 30),
			ExpPct = Color3.fromRGB(50, 200, 120),
			SpeedR = Color3.fromRGB(40, 180, 200),
			SkillTaken = Color3.fromRGB(80, 120, 220),
			HitTaken = Color3.fromRGB(120, 140, 160),
			AtkMatkPercent = Color3.fromRGB(210, 60, 60),
			CritDmg = Color3.fromRGB(220, 140, 20),
			SkillSingle = Color3.fromRGB(180, 50, 220),
			SkillAoe = Color3.fromRGB(220, 50, 180),
		}

		local modalHolder = Instance.new("Frame")
		modalHolder.Name = "AutoLockModalHolder"
		modalHolder.Size = UDim2.new(1, 0, 1, 0)
		modalHolder.Position = UDim2.new(0, 0, 0, 0)
		modalHolder.BackgroundTransparency = 1
		modalHolder.ZIndex = 60
		modalHolder.Parent = screenGui
		autoLockModalInstance = modalHolder

		local backdrop = Instance.new("TextButton")
		backdrop.Name = "Backdrop"
		backdrop.Size = UDim2.new(1, 0, 1, 0)
		backdrop.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
		backdrop.BackgroundTransparency = 0.55
		backdrop.BorderSizePixel = 0
		backdrop.Text = ""
		backdrop.AutoButtonColor = false
		backdrop.ZIndex = 60
		backdrop.Parent = modalHolder

		local dialog = Instance.new("Frame")
		dialog.Name = "Dialog"
		dialog.Size = UDim2.new(0, 680, 0, 500)
		dialog.AnchorPoint = Vector2.new(0.5, 0.5)
		dialog.Position = UDim2.new(0.5, 0, 0.5, 0)
		dialog.BackgroundColor3 = THEME.PanelBody
		dialog.BorderSizePixel = 0
		dialog.ClipsDescendants = true
		dialog.ZIndex = 61
		dialog.Parent = modalHolder

		local dScale = Instance.new("UIScale")
		dScale.Name = "ModalScale"
		dScale.Scale = 1.2
		dScale.Parent = dialog

		local dCorner = Instance.new("UICorner")
		dCorner.CornerRadius = UDim.new(0, 8)
		dCorner.Parent = dialog

		local dStroke = Instance.new("UIStroke")
		dStroke.Color = THEME.HeaderBlue
		dStroke.Thickness = 2
		dStroke.Parent = dialog

		-- Header Bar (44px)
		local header = Instance.new("Frame")
		header.Name = "Header"
		header.Size = UDim2.new(1, 0, 0, 44)
		header.BackgroundColor3 = THEME.HeaderBlue
		header.BorderSizePixel = 0
		header.ZIndex = 62
		header.Parent = dialog

		local hCorner = Instance.new("UICorner")
		hCorner.CornerRadius = UDim.new(0, 8)
		hCorner.Parent = header

		local isDragging = false
		local dragStart = nil
		local startPos = nil

		table.insert(modalConns, header.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
				isDragging = true
				dragStart = input.Position
				startPos = dialog.Position
				local conn
				conn = input.Changed:Connect(function()
					if input.UserInputState == Enum.UserInputState.End then
						isDragging = false
						conn:Disconnect()
					end
				end)
			end
		end))

		table.insert(modalConns, UIS.InputChanged:Connect(function(input)
			if isDragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
				local delta = input.Position - dragStart
				dialog.Position = UDim2.new(
					startPos.X.Scale,
					startPos.X.Offset + delta.X,
					startPos.Y.Scale,
					startPos.Y.Offset + delta.Y
				)
			end
		end))

		local hTitle = Instance.new("TextLabel")
		hTitle.Name = "Title"
		hTitle.Size = UDim2.new(1, -60, 0, 22)
		hTitle.Position = UDim2.new(0, 14, 0, 3)
		hTitle.BackgroundTransparency = 1
		hTitle.Text = "🔒 Auto Lock Item — ตั้งค่าการล็อคอุปกรณ์ขั้นสูง"
		hTitle.TextColor3 = Color3.fromRGB(255, 255, 255)
		hTitle.TextSize = 14
		hTitle.TextXAlignment = Enum.TextXAlignment.Left
		applyFont(hTitle, true)
		hTitle.ZIndex = 63
		hTitle.Parent = header

		local hSub = Instance.new("TextLabel")
		hSub.Name = "Subtitle"
		hSub.Size = UDim2.new(1, -60, 0, 16)
		hSub.Position = UDim2.new(0, 14, 0, 23)
		hSub.BackgroundTransparency = 1
		hSub.Text = "เลือกล็อคตามเกรด/ดาวทั่วไป หรือกำหนดเงื่อนไขเฉพาะหมวดอุปกรณ์ตามฐานข้อมูลจริง"
		hSub.TextColor3 = THEME.TextAmber
		hSub.TextSize = 11
		hSub.TextXAlignment = Enum.TextXAlignment.Left
		applyFont(hSub, false)
		hSub.ZIndex = 63
		hSub.Parent = header

		local closeBtn = Instance.new("TextButton")
		closeBtn.Name = "CloseBtn"
		closeBtn.Size = UDim2.new(0, 30, 0, 30)
		closeBtn.Position = UDim2.new(1, -38, 0, 7)
		closeBtn.BackgroundColor3 = THEME.BtnClose
		closeBtn.BorderSizePixel = 0
		closeBtn.Text = "✖"
		closeBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
		closeBtn.TextSize = 15
		applyFont(closeBtn, true)
		closeBtn.ZIndex = 63
		closeBtn.Parent = header

		local cbCorner = Instance.new("UICorner")
		cbCorner.CornerRadius = UDim.new(0, 4)
		cbCorner.Parent = closeBtn

		local function closeModal()
			if autoLockModalInstance then
				autoLockModalInstance.Visible = false
			end
		end

		table.insert(modalConns, closeBtn.MouseButton1Click:Connect(closeModal))
		table.insert(modalConns, backdrop.MouseButton1Click:Connect(closeModal))

		local bodyArea = Instance.new("Frame")
		bodyArea.Name = "BodyArea"
		bodyArea.Size = UDim2.new(1, -16, 1, -52)
		bodyArea.Position = UDim2.new(0, 8, 0, 48)
		bodyArea.BackgroundTransparency = 1
		bodyArea.ZIndex = 62
		bodyArea.Parent = dialog

		-- Left Sidebar (Categories)
		local leftSidebar = Instance.new("Frame")
		leftSidebar.Name = "LeftSidebar"
		leftSidebar.Size = UDim2.new(0, 210, 1, 0)
		leftSidebar.Position = UDim2.new(0, 0, 0, 0)
		leftSidebar.BackgroundColor3 = Color3.fromRGB(235, 228, 214)
		leftSidebar.BorderSizePixel = 0
		leftSidebar.ZIndex = 63
		leftSidebar.Parent = bodyArea

		local lsCorner = Instance.new("UICorner")
		lsCorner.CornerRadius = UDim.new(0, 6)
		lsCorner.Parent = leftSidebar

		local lsStroke = Instance.new("UIStroke")
		lsStroke.Color = THEME.PanelBorder
		lsStroke.Thickness = 1
		lsStroke.Parent = leftSidebar

		local lsScroll = Instance.new("ScrollingFrame")
		lsScroll.Name = "Scroll"
		lsScroll.Size = UDim2.new(1, -4, 1, -8)
		lsScroll.Position = UDim2.new(0, 2, 0, 4)
		lsScroll.BackgroundTransparency = 1
		lsScroll.BorderSizePixel = 0
		lsScroll.ScrollBarThickness = 4
		lsScroll.ScrollBarImageColor3 = Color3.fromRGB(180, 170, 155)
		lsScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
		lsScroll.ScrollingDirection = Enum.ScrollingDirection.Y
		lsScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
		lsScroll.ZIndex = 64
		lsScroll.Parent = leftSidebar

		local lsLayout = Instance.new("UIListLayout")
		lsLayout.Padding = UDim.new(0, 4)
		lsLayout.SortOrder = Enum.SortOrder.LayoutOrder
		lsLayout.Parent = lsScroll

		-- Right Detail Panel
		local rightPanel = Instance.new("Frame")
		rightPanel.Name = "RightPanel"
		rightPanel.Size = UDim2.new(1, -218, 1, 0)
		rightPanel.Position = UDim2.new(0, 218, 0, 0)
		rightPanel.BackgroundColor3 = Color3.fromRGB(250, 246, 238)
		rightPanel.BorderSizePixel = 0
		rightPanel.ZIndex = 63
		rightPanel.Parent = bodyArea

		local rpCorner = Instance.new("UICorner")
		rpCorner.CornerRadius = UDim.new(0, 6)
		rpCorner.Parent = rightPanel

		local rpStroke = Instance.new("UIStroke")
		rpStroke.Color = THEME.PanelBorder
		rpStroke.Thickness = 1
		rpStroke.Parent = rightPanel

		local rightScroll = Instance.new("ScrollingFrame")
		rightScroll.Name = "RightScroll"
		rightScroll.Size = UDim2.new(1, -12, 1, -12)
		rightScroll.Position = UDim2.new(0, 6, 0, 6)
		rightScroll.BackgroundTransparency = 1
		rightScroll.BorderSizePixel = 0
		rightScroll.ScrollBarThickness = 4
		rightScroll.ScrollBarImageColor3 = Color3.fromRGB(180, 170, 155)
		rightScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
		rightScroll.ScrollingDirection = Enum.ScrollingDirection.Y
		rightScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
		rightScroll.ZIndex = 64
		rightScroll.Parent = rightPanel

		local rsLayout = Instance.new("UIListLayout")
		rsLayout.Padding = UDim.new(0, 10)
		rsLayout.SortOrder = Enum.SortOrder.LayoutOrder
		rsLayout.Parent = rightScroll

		local selectedCatId = "GLOBAL"
		local categoryBtnMap = {}

		local function isCategoryActive(catDef)
			if catDef.IsGlobal then
				return true
			end
			local r = HUB.Config.autoLockEquipRules and HUB.Config.autoLockEquipRules[catDef.Id]
			return r and r.enabled == true
		end

		refreshAllBadges = function()
			for _, def in ipairs(CATEGORY_DEFS) do
				local entry = categoryBtnMap[def.Id]
				if entry then
					local active = isCategoryActive(def)
					if def.IsGlobal then
						entry.Badge.Text = "[MAIN]"
						entry.Badge.TextColor3 = Color3.fromRGB(240, 190, 60)
					elseif active then
						entry.Badge.Text = "[ON]"
						entry.Badge.TextColor3 = Color3.fromRGB(40, 220, 100)
					else
						entry.Badge.Text = "[OFF]"
						entry.Badge.TextColor3 = Color3.fromRGB(150, 150, 150)
					end

					local isSelected = (selectedCatId == def.Id)
					if isSelected then
						entry.Button.BackgroundColor3 = THEME.TabActive
						entry.Name.TextColor3 = Color3.fromRGB(255, 255, 255)
					else
						entry.Button.BackgroundColor3 = Color3.fromRGB(246, 240, 228)
						entry.Name.TextColor3 = THEME.TextDark
					end
				end
			end
		end

		renderDetail = function(catDef)
			currentCatDef = catDef
			clearConns(detailConns)
			clearConns(cardsConns)

			for _, child in ipairs(rightScroll:GetChildren()) do
				if child ~= rsLayout then
					child:Destroy()
				end
			end

			if catDef.IsGlobal then
				-- Global Settings (Tiers & Stars)
				local gHeader = Instance.new("Frame")
				gHeader.Name = "GlobalHeader"
				gHeader.LayoutOrder = 1
				gHeader.Size = UDim2.new(1, 0, 0, 52)
				gHeader.BackgroundColor3 = THEME.SubHeaderNavy
				gHeader.BorderSizePixel = 0
				gHeader.ZIndex = 65
				gHeader.Parent = rightScroll

				local ghCorner = Instance.new("UICorner")
				ghCorner.CornerRadius = UDim.new(0, 6)
				ghCorner.Parent = gHeader

				local ghIcon = Instance.new("ImageLabel")
				ghIcon.Name = "Icon"
				ghIcon.Size = UDim2.new(0, 32, 0, 32)
				ghIcon.Position = UDim2.new(0, 10, 0.5, -16)
				ghIcon.BackgroundTransparency = 1
				ghIcon.Image = "rbxassetid://127066642314924"
				ghIcon.ImageColor3 = Color3.fromRGB(255, 215, 0)
				ghIcon.ZIndex = 66
				ghIcon.Parent = gHeader

				local ghTitle = Instance.new("TextLabel")
				ghTitle.Name = "Title"
				ghTitle.Size = UDim2.new(1, -54, 0, 20)
				ghTitle.Position = UDim2.new(0, 48, 0, 6)
				ghTitle.BackgroundTransparency = 1
				ghTitle.Text = "⭐ เลือกล็อคตามระดับเกรดและระดับดาว (สากล)"
				ghTitle.TextColor3 = Color3.fromRGB(255, 255, 255)
				ghTitle.TextSize = 13
				ghTitle.TextXAlignment = Enum.TextXAlignment.Left
				applyFont(ghTitle, true)
				ghTitle.ZIndex = 66
				ghTitle.Parent = gHeader

				local ghSub = Instance.new("TextLabel")
				ghSub.Name = "Sub"
				ghSub.Size = UDim2.new(1, -54, 0, 16)
				ghSub.Position = UDim2.new(0, 48, 0, 26)
				ghSub.BackgroundTransparency = 1
				ghSub.Text = "ไอเทมที่ได้เกรดหรือระดับดาวที่เลือก จะถูกสั่งล็อคทันทีที่เข้ากระเป๋า"
				ghSub.TextColor3 = THEME.TextAmber
				ghSub.TextSize = 11
				ghSub.TextXAlignment = Enum.TextXAlignment.Left
				applyFont(ghSub, false)
				ghSub.ZIndex = 66
				ghSub.Parent = gHeader

				-- Section 1: Tierlist Grades
				local tSec = Instance.new("Frame")
				tSec.Name = "TierSection"
				tSec.LayoutOrder = 2
				tSec.Size = UDim2.new(1, 0, 0, 68)
				tSec.BackgroundColor3 = Color3.fromRGB(242, 236, 222)
				tSec.BorderSizePixel = 0
				tSec.ZIndex = 65
				tSec.Parent = rightScroll
				local tsCorner = Instance.new("UICorner")
				tsCorner.CornerRadius = UDim.new(0, 6)
				tsCorner.Parent = tSec

				local tTitle = Instance.new("TextLabel")
				tTitle.Name = "Title"
				tTitle.Size = UDim2.new(1, -16, 0, 18)
				tTitle.Position = UDim2.new(0, 8, 0, 6)
				tTitle.BackgroundTransparency = 1
				tTitle.Text = "เลือกระดับเกรด Tierlist ที่ต้องการล็อค (คลิกเพื่อสลับ):"
				tTitle.TextColor3 = THEME.TextDark
				tTitle.TextSize = 12
				tTitle.TextXAlignment = Enum.TextXAlignment.Left
				applyFont(tTitle, true)
				tTitle.ZIndex = 66
				tTitle.Parent = tSec

				local tRow = Instance.new("Frame")
				tRow.Name = "TierRow"
				tRow.Size = UDim2.new(1, -16, 0, 28)
				tRow.Position = UDim2.new(0, 8, 0, 28)
				tRow.BackgroundTransparency = 1
				tRow.ZIndex = 66
				tRow.Parent = tSec

				local trLayout = Instance.new("UIListLayout")
				trLayout.FillDirection = Enum.FillDirection.Horizontal
				trLayout.Padding = UDim.new(0, 6)
				trLayout.SortOrder = Enum.SortOrder.LayoutOrder
				trLayout.Parent = tRow

				local tiers = { "F", "D", "C", "B", "A", "S", "SS" }
				local tierColors = {
					SS = Color3.fromRGB(220, 40, 40),
					S  = Color3.fromRGB(230, 120, 20),
					A  = Color3.fromRGB(160, 60, 210),
					B  = Color3.fromRGB(40, 120, 230),
					C  = Color3.fromRGB(40, 180, 80),
					D  = Color3.fromRGB(140, 140, 140),
					F  = Color3.fromRGB(90, 90, 90)
				}

				for idx, t in ipairs(tiers) do
					local b = Instance.new("TextButton")
					b.Name = "Btn_" .. t
					b.LayoutOrder = idx
					b.Size = UDim2.new(0, 48, 0, 26)
					b.BorderSizePixel = 0
					b.Text = t
					b.TextSize = 13
					b.TextColor3 = Color3.fromRGB(255, 255, 255)
					applyFont(b, true)
					b.ZIndex = 67
					b.Parent = tRow

					local bc = Instance.new("UICorner")
					bc.CornerRadius = UDim.new(0, 4)
					bc.Parent = b

					local bs = Instance.new("UIStroke")
					bs.Thickness = 1.2
					bs.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
					bs.Parent = b

					b.TextStrokeTransparency = 1

					local function refreshTierBtn()
						local active = (HUB.Config.autoLockTiers and HUB.Config.autoLockTiers[t] == true)
						b.TextColor3 = Color3.fromRGB(255, 255, 255)
						b.TextStrokeTransparency = 1
						if active then
							b.BackgroundColor3 = tierColors[t] or THEME.BtnGreen
							bs.Color = tierColors[t] or THEME.BtnGreen
						else
							b.BackgroundColor3 = Color3.fromRGB(25, 30, 45)
							bs.Color = Color3.fromRGB(50, 60, 80)
						end
					end
					refreshTierBtn()

					table.insert(detailConns, b.MouseButton1Click:Connect(function()
						if not HUB.Config.autoLockTiers then HUB.Config.autoLockTiers = {} end
						HUB.Config.autoLockTiers[t] = not HUB.Config.autoLockTiers[t]
						refreshTierBtn()
						if HUB.Config.autoSave then saveConfig() end
						if HUB.Config.autoLock and HUB.RunAutoLockCheck then task.spawn(HUB.RunAutoLockCheck) end
					end))
				end

				-- Section 2: Star Ratings
				local sSec = Instance.new("Frame")
				sSec.Name = "StarSection"
				sSec.LayoutOrder = 3
				sSec.Size = UDim2.new(1, 0, 0, 72)
				sSec.BackgroundColor3 = Color3.fromRGB(242, 236, 222)
				sSec.BorderSizePixel = 0
				sSec.ZIndex = 65
				sSec.Parent = rightScroll
				local ssCorner = Instance.new("UICorner")
				ssCorner.CornerRadius = UDim.new(0, 6)
				ssCorner.Parent = sSec

				local sTitle = Instance.new("TextLabel")
				sTitle.Name = "Title"
				sTitle.Size = UDim2.new(1, -16, 0, 18)
				sTitle.Position = UDim2.new(0, 8, 0, 6)
				sTitle.BackgroundTransparency = 1
				sTitle.Text = "เลือกระดับดาวที่ต้องการล็อค (คลิกเพื่อสลับ):"
				sTitle.TextColor3 = THEME.TextDark
				sTitle.TextSize = 12
				sTitle.TextXAlignment = Enum.TextXAlignment.Left
				applyFont(sTitle, true)
				sTitle.ZIndex = 66
				sTitle.Parent = sSec

				local sRow = Instance.new("Frame")
				sRow.Name = "StarRow"
				sRow.Size = UDim2.new(1, -16, 0, 28)
				sRow.Position = UDim2.new(0, 8, 0, 28)
				sRow.BackgroundTransparency = 1
				sRow.ZIndex = 66
				sRow.Parent = sSec

				local srLayout = Instance.new("UIListLayout")
				srLayout.FillDirection = Enum.FillDirection.Horizontal
				srLayout.Padding = UDim.new(0, 8)
				srLayout.SortOrder = Enum.SortOrder.LayoutOrder
				srLayout.Parent = sRow

				local starDefs = {
					{ Key = "Silver",  Label = "ดาวเงิน", StarColor = Color3.fromRGB(240, 248, 255), ActiveBg = Color3.fromRGB(70, 85, 115),  ActiveStroke = Color3.fromRGB(70, 85, 115) },
					{ Key = "Gold",    Label = "ดาวทอง", StarColor = Color3.fromRGB(255, 215, 0),   ActiveBg = Color3.fromRGB(160, 115, 20), ActiveStroke = Color3.fromRGB(160, 115, 20) },
					{ Key = "Rainbow", Label = "ดาวรุ้ง", StarColor = Color3.fromRGB(255, 255, 255), ActiveBg = Color3.fromRGB(120, 50, 145), ActiveStroke = Color3.fromRGB(120, 50, 145), Rainbow = true },
				}

				for idx, sDef in ipairs(starDefs) do
					local b = Instance.new("TextButton")
					b.Name = "Btn_Star_" .. sDef.Key
					b.LayoutOrder = idx
					b.Size = UDim2.new(0, 110, 0, 28)
					b.BorderSizePixel = 0
					b.Text = ""
					b.AutoButtonColor = false
					b.ZIndex = 67
					b.Parent = sRow

					local bc = Instance.new("UICorner")
					bc.CornerRadius = UDim.new(0, 4)
					bc.Parent = b

					local bs = Instance.new("UIStroke")
					bs.Thickness = 1.2
					bs.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
					bs.Parent = b

					local starIcon = Instance.new("ImageLabel")
					starIcon.Name = "StarIcon"
					starIcon.Size = UDim2.fromOffset(18, 18)
					starIcon.Position = UDim2.new(0, 8, 0.5, -9)
					starIcon.BackgroundTransparency = 1
					starIcon.Image = "rbxassetid://127066642314924"
					starIcon.ImageColor3 = sDef.StarColor
					starIcon.ZIndex = 68
					starIcon.Parent = b

					if sDef.Rainbow then
						local starGrad = Instance.new("UIGradient")
						starGrad.Color = ColorSequence.new({
							ColorSequenceKeypoint.new(0.00, Color3.fromRGB(255, 70, 70)),
							ColorSequenceKeypoint.new(0.20, Color3.fromRGB(255, 165, 30)),
							ColorSequenceKeypoint.new(0.40, Color3.fromRGB(255, 235, 40)),
							ColorSequenceKeypoint.new(0.60, Color3.fromRGB(40, 230, 90)),
							ColorSequenceKeypoint.new(0.80, Color3.fromRGB(40, 160, 255)),
							ColorSequenceKeypoint.new(1.00, Color3.fromRGB(180, 70, 240)),
						})
						starGrad.Rotation = 45
						starGrad.Parent = starIcon
					end

					local txtLbl = Instance.new("TextLabel")
					txtLbl.Name = "BtnText"
					txtLbl.Size = UDim2.new(1, -32, 1, 0)
					txtLbl.Position = UDim2.new(0, 30, 0, 0)
					txtLbl.BackgroundTransparency = 1
					txtLbl.Text = sDef.Label
					txtLbl.TextColor3 = Color3.fromRGB(255, 255, 255)
					txtLbl.TextStrokeTransparency = 1
					txtLbl.TextSize = 12
					txtLbl.TextXAlignment = Enum.TextXAlignment.Center
					applyFont(txtLbl, true)
					txtLbl.ZIndex = 68
					txtLbl.Parent = b

					local function refreshStarBtn()
						local active = (HUB.Config.autoLockStars and HUB.Config.autoLockStars[sDef.Key] == true)
						txtLbl.TextColor3 = Color3.fromRGB(255, 255, 255)
						txtLbl.TextStrokeTransparency = 1
						if active then
							b.BackgroundColor3 = sDef.ActiveBg
							bs.Color = sDef.ActiveStroke
						else
							b.BackgroundColor3 = Color3.fromRGB(25, 30, 45)
							bs.Color = Color3.fromRGB(50, 60, 80)
						end
					end
					refreshStarBtn()

					table.insert(detailConns, b.MouseButton1Click:Connect(function()
						if not HUB.Config.autoLockStars then HUB.Config.autoLockStars = {} end
						HUB.Config.autoLockStars[sDef.Key] = not HUB.Config.autoLockStars[sDef.Key]
						refreshStarBtn()
						if HUB.Config.autoSave then saveConfig() end
						if HUB.Config.autoLock and HUB.RunAutoLockCheck then task.spawn(HUB.RunAutoLockCheck) end
					end))
				end

				-- Section 3: Game Tiers (Tier I - VI: ขาว, เขียว, ฟ้า, ม่วง, ทอง, แดง)
				local gtSec = Instance.new("Frame")
				gtSec.Name = "GameTierSection"
				gtSec.LayoutOrder = 4
				gtSec.Size = UDim2.new(1, 0, 0, 72)
				gtSec.BackgroundColor3 = Color3.fromRGB(242, 236, 222)
				gtSec.BorderSizePixel = 0
				gtSec.ZIndex = 65
				gtSec.Parent = rightScroll
				local gtCorner = Instance.new("UICorner")
				gtCorner.CornerRadius = UDim.new(0, 6)
				gtCorner.Parent = gtSec

				local gtTitle = Instance.new("TextLabel")
				gtTitle.Name = "Title"
				gtTitle.Size = UDim2.new(1, -16, 0, 18)
				gtTitle.Position = UDim2.new(0, 8, 0, 6)
				gtTitle.BackgroundTransparency = 1
				gtTitle.Text = "เลือกระดับ Tier ในเกมที่ต้องการล็อค (ขาว/เขียว/ฟ้า/ม่วง/ทอง/แดง):"
				gtTitle.TextColor3 = THEME.TextDark
				gtTitle.TextSize = 12
				gtTitle.TextXAlignment = Enum.TextXAlignment.Left
				applyFont(gtTitle, true)
				gtTitle.ZIndex = 66
				gtTitle.Parent = gtSec

				local gtRow = Instance.new("Frame")
				gtRow.Name = "GameTierRow"
				gtRow.Size = UDim2.new(1, -16, 0, 28)
				gtRow.Position = UDim2.new(0, 8, 0, 28)
				gtRow.BackgroundTransparency = 1
				gtRow.ZIndex = 66
				gtRow.Parent = gtSec

				local gtrLayout = Instance.new("UIListLayout")
				gtrLayout.FillDirection = Enum.FillDirection.Horizontal
				gtrLayout.Padding = UDim.new(0, 6)
				gtrLayout.SortOrder = Enum.SortOrder.LayoutOrder
				gtrLayout.Parent = gtRow

				local gameTierDefs = {
					{ Tier = 1, Label = "I (ขาว)",   Color = Color3.fromRGB(120, 128, 142) },
					{ Tier = 2, Label = "II (เขียว)", Color = Color3.fromRGB(47, 143, 62) },
					{ Tier = 3, Label = "III (ฟ้า)",  Color = Color3.fromRGB(42, 111, 214) },
					{ Tier = 4, Label = "IV (ม่วง)", Color = Color3.fromRGB(122, 69, 201) },
					{ Tier = 5, Label = "V (ทอง)",  Color = Color3.fromRGB(217, 120, 26) },
					{ Tier = 6, Label = "VI (แดง)",  Color = Color3.fromRGB(201, 42, 54) },
				}

				for idx, gtDef in ipairs(gameTierDefs) do
					local b = Instance.new("TextButton")
					b.Name = "Btn_GameTier_" .. gtDef.Tier
					b.LayoutOrder = idx
					b.Size = UDim2.new(0, 66, 0, 26)
					b.BorderSizePixel = 0
					b.Text = gtDef.Label
					b.TextSize = 11
					b.TextColor3 = Color3.fromRGB(255, 255, 255)
					applyFont(b, true)
					b.ZIndex = 67
					b.Parent = gtRow

					local bc = Instance.new("UICorner")
					bc.CornerRadius = UDim.new(0, 4)
					bc.Parent = b

					local bs = Instance.new("UIStroke")
					bs.Thickness = 1.2
					bs.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
					bs.Parent = b

					local function refreshGameTierBtn()
						local active = (HUB.Config.autoLockGameTiers and (HUB.Config.autoLockGameTiers[gtDef.Tier] == true or HUB.Config.autoLockGameTiers[tostring(gtDef.Tier)] == true))
						b.TextColor3 = Color3.fromRGB(255, 255, 255)
						b.TextStrokeTransparency = 1
						if active then
							b.BackgroundColor3 = gtDef.Color
							bs.Color = gtDef.Color
						else
							b.BackgroundColor3 = Color3.fromRGB(25, 30, 45)
							b.TextColor3 = Color3.fromRGB(150, 160, 175)
							bs.Color = Color3.fromRGB(50, 60, 80)
						end
					end
					refreshGameTierBtn()

					table.insert(detailConns, b.MouseButton1Click:Connect(function()
						if not HUB.Config.autoLockGameTiers then HUB.Config.autoLockGameTiers = {} end
						local cur = (HUB.Config.autoLockGameTiers[gtDef.Tier] == true or HUB.Config.autoLockGameTiers[tostring(gtDef.Tier)] == true)
						HUB.Config.autoLockGameTiers[gtDef.Tier] = not cur
						refreshGameTierBtn()
						if HUB.Config.autoSave then saveConfig() end
						if HUB.Config.autoLock and HUB.RunAutoLockCheck then task.spawn(HUB.RunAutoLockCheck) end
					end))
				end

			else
				-- Equipment Category Specific Rules
				if not HUB.Config.autoLockEquipRules then HUB.Config.autoLockEquipRules = {} end
				if not HUB.Config.autoLockEquipRules[catDef.Id] then
					HUB.Config.autoLockEquipRules[catDef.Id] = {
						enabled = false,
						wantedSpecials = {},
						specialStats = {},
						forbidden = {}
					}
				end
				local rule = HUB.Config.autoLockEquipRules[catDef.Id]
				if type(rule.wantedSpecials) ~= "table" then
					rule.wantedSpecials = {}
					-- Migration from v9.16 rule.special
					if type(rule.special) == "table" then
						for k, v in pairs(rule.special) do
							if v == true then rule.wantedSpecials[k] = true end
						end
					end
				end
				if type(rule.specialStats) ~= "table" then rule.specialStats = {} end
				if type(rule.forbidden) ~= "table" then rule.forbidden = {} end

				-- Header Banner
				local eHeader = Instance.new("Frame")
				eHeader.Name = "EquipHeader"
				eHeader.LayoutOrder = 1
				eHeader.Size = UDim2.new(1, 0, 0, 56)
				eHeader.BackgroundColor3 = THEME.DarkNavy
				eHeader.BorderSizePixel = 0
				eHeader.ZIndex = 65
				eHeader.Parent = rightScroll

				local ehCorner = Instance.new("UICorner")
				ehCorner.CornerRadius = UDim.new(0, 6)
				ehCorner.Parent = eHeader

				local ehIcon = Instance.new("ImageLabel")
				ehIcon.Name = "SampleIcon"
				ehIcon.Size = UDim2.new(0, 40, 0, 40)
				ehIcon.Position = UDim2.new(0, 8, 0.5, -20)
				ehIcon.BackgroundTransparency = 1
				applyGameIcon(ehIcon, catDef.SampleKey, catDef.FallbackIcon)
				ehIcon.ZIndex = 66
				ehIcon.Parent = eHeader

				local ehTitle = Instance.new("TextLabel")
				ehTitle.Name = "Title"
				ehTitle.Size = UDim2.new(1, -190, 0, 20)
				ehTitle.Position = UDim2.new(0, 54, 0, 8)
				ehTitle.BackgroundTransparency = 1
				ehTitle.Text = catDef.Name
				ehTitle.TextColor3 = Color3.fromRGB(255, 255, 255)
				ehTitle.TextSize = 13
				ehTitle.TextXAlignment = Enum.TextXAlignment.Left
				applyFont(ehTitle, true)
				ehTitle.ZIndex = 66
				ehTitle.Parent = eHeader

				local ehSub = Instance.new("TextLabel")
				ehSub.Name = "Sub"
				ehSub.Size = UDim2.new(1, -190, 0, 16)
				ehSub.Position = UDim2.new(0, 54, 0, 28)
				ehSub.BackgroundTransparency = 1
				ehSub.Text = catDef.Sub
				ehSub.TextColor3 = THEME.TextAmber
				ehSub.TextSize = 11
				ehSub.TextXAlignment = Enum.TextXAlignment.Left
				applyFont(ehSub, false)
				ehSub.ZIndex = 66
				ehSub.Parent = eHeader

				local enableBtn = Instance.new("TextButton")
				enableBtn.Name = "EnableBtn"
				enableBtn.Size = UDim2.new(0, 128, 0, 32)
				enableBtn.Position = UDim2.new(1, -136, 0.5, -16)
				enableBtn.BorderSizePixel = 0
				applyFont(enableBtn, true)
				enableBtn.TextSize = 11
				enableBtn.ZIndex = 67
				enableBtn.Parent = eHeader

				local ebCorner = Instance.new("UICorner")
				ebCorner.CornerRadius = UDim.new(0, 4)
				ebCorner.Parent = enableBtn

				local ebStroke = Instance.new("UIStroke")
				ebStroke.Thickness = 1.2
				ebStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
				ebStroke.Parent = enableBtn

				local function refreshEnableBtn()
					local en = (rule.enabled == true)
					enableBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
					enableBtn.TextStrokeTransparency = 1
					if en then
						enableBtn.BackgroundColor3 = THEME.BtnGreen
						ebStroke.Color = THEME.BtnGreen
						enableBtn.Text = "✔ เปิดใช้งานเงื่อนไข"
					else
						enableBtn.BackgroundColor3 = Color3.fromRGB(25, 30, 45)
						ebStroke.Color = Color3.fromRGB(50, 60, 80)
						enableBtn.Text = "✖ ปิดเงื่อนไขหมวดนี้"
					end
				end
				refreshEnableBtn()

				table.insert(detailConns, enableBtn.MouseButton1Click:Connect(function()
					rule.enabled = not (rule.enabled == true)
					refreshEnableBtn()
					refreshAllBadges()
					if HUB.Config.autoSave then saveConfig() end
					if HUB.Config.autoLock and HUB.RunAutoLockCheck then task.spawn(HUB.RunAutoLockCheck) end
				end))

				-- =========================================================
				-- ส่วนที่ 1 (Top Section): เลือก Special Option ที่ต้องการล็อค
				-- =========================================================
				local specSec = Instance.new("Frame")
				specSec.Name = "SpecialSection"
				specSec.LayoutOrder = 2
				specSec.Size = UDim2.new(1, 0, 0, 0)
				specSec.AutomaticSize = Enum.AutomaticSize.Y
				specSec.BackgroundColor3 = Color3.fromRGB(242, 236, 222)
				specSec.BorderSizePixel = 0
				specSec.ZIndex = 65
				specSec.Parent = rightScroll
				local spCorner = Instance.new("UICorner")
				spCorner.CornerRadius = UDim.new(0, 6)
				spCorner.Parent = specSec

				local spSecLayout = Instance.new("UIListLayout")
				spSecLayout.FillDirection = Enum.FillDirection.Vertical
				spSecLayout.Padding = UDim.new(0, 6)
				spSecLayout.SortOrder = Enum.SortOrder.LayoutOrder
				spSecLayout.Parent = specSec

				local spSecPad = Instance.new("UIPadding")
				spSecPad.PaddingTop = UDim.new(0, 6)
				spSecPad.PaddingBottom = UDim.new(0, 8)
				spSecPad.PaddingLeft = UDim.new(0, 8)
				spSecPad.PaddingRight = UDim.new(0, 8)
				spSecPad.Parent = specSec

				local specTop = Instance.new("Frame")
				specTop.Name = "TopRow"
				specTop.LayoutOrder = 1
				specTop.Size = UDim2.new(1, 0, 0, 22)
				specTop.BackgroundTransparency = 1
				specTop.ZIndex = 66
				specTop.Parent = specSec

				local specTitle = Instance.new("TextLabel")
				specTitle.Name = "Title"
				specTitle.Size = UDim2.new(1, 0, 1, 0)
				specTitle.BackgroundTransparency = 1
				specTitle.Text = "✦ 1. เลือกออปชันพิเศษที่ต้องการล็อค (Special Options):"
				specTitle.TextColor3 = Color3.fromRGB(170, 110, 15)
				specTitle.TextSize = 12
				specTitle.TextXAlignment = Enum.TextXAlignment.Left
				applyFont(specTitle, true)
				specTitle.ZIndex = 66
				specTitle.Parent = specTop

				local specPills = Instance.new("Frame")
				specPills.Name = "Pills"
				specPills.LayoutOrder = 2
				specPills.Size = UDim2.new(1, 0, 0, 0)
				specPills.AutomaticSize = Enum.AutomaticSize.Y
				specPills.BackgroundTransparency = 1
				specPills.ZIndex = 66
				specPills.Parent = specSec

				local spLayout = Instance.new("UIGridLayout")
				spLayout.CellSize = UDim2.new(0, 104, 0, 24)
				spLayout.CellPadding = UDim2.new(0, 6, 0, 4)
				spLayout.SortOrder = Enum.SortOrder.LayoutOrder
				spLayout.Parent = specPills

				-- Container ด้านล่าง สำหรับการ์ดตั้งค่าสเตตัสสุ่มแยกราย Special Option
				local cardsHeader = Instance.new("Frame")
				cardsHeader.Name = "CardsHeader"
				cardsHeader.LayoutOrder = 3
				cardsHeader.Size = UDim2.new(1, 0, 0, 22)
				cardsHeader.BackgroundTransparency = 1
				cardsHeader.ZIndex = 65
				cardsHeader.Parent = rightScroll

				local chTitle = Instance.new("TextLabel")
				chTitle.Name = "Title"
				chTitle.Size = UDim2.new(1, 0, 1, 0)
				chTitle.BackgroundTransparency = 1
				chTitle.Text = "⚙️ 2. กำหนดสเตตัสสุ่มเฉพาะของแต่ละออปชันที่เลือก:"
				chTitle.TextColor3 = THEME.TextDark
				chTitle.TextSize = 12
				chTitle.TextXAlignment = Enum.TextXAlignment.Left
				applyFont(chTitle, true)
				chTitle.ZIndex = 66
				chTitle.Parent = cardsHeader

				local cardsHolder = Instance.new("Frame")
				cardsHolder.Name = "CardsHolder"
				cardsHolder.LayoutOrder = 4
				cardsHolder.Size = UDim2.new(1, 0, 0, 0)
				cardsHolder.AutomaticSize = Enum.AutomaticSize.Y
				cardsHolder.BackgroundTransparency = 1
				cardsHolder.ZIndex = 65
				cardsHolder.Parent = rightScroll

				local chLayout = Instance.new("UIListLayout")
				chLayout.Padding = UDim.new(0, 8)
				chLayout.SortOrder = Enum.SortOrder.LayoutOrder
				chLayout.Parent = cardsHolder

				local rebuildCards = nil -- forward declaration

				for idx, optKey in ipairs(catDef.Specials or {}) do
					local pb = Instance.new("TextButton")
					pb.Name = "Pill_" .. optKey
					pb.LayoutOrder = idx
					pb.BorderSizePixel = 0
					pb.Text = OPTION_LABELS[optKey] or optKey
					pb.TextSize = 11
					pb.TextColor3 = Color3.fromRGB(255, 255, 255)
					pb.TextStrokeTransparency = 1
					applyFont(pb, true)
					pb.ZIndex = 67
					pb.Parent = specPills

					local pbc = Instance.new("UICorner")
					pbc.CornerRadius = UDim.new(0, 4)
					pbc.Parent = pb
					local pbs = Instance.new("UIStroke")
					pbs.Thickness = 1.2
					pbs.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
					pbs.Parent = pb

					local function refreshPill()
						local sel = (rule.wantedSpecials[optKey] == true)
						pb.TextColor3 = Color3.fromRGB(255, 255, 255)
						pb.TextStrokeTransparency = 1
						if sel then
							pb.BackgroundColor3 = Color3.fromRGB(175, 120, 20)
							pbs.Color = Color3.fromRGB(175, 120, 20)
						else
							pb.BackgroundColor3 = Color3.fromRGB(25, 30, 45)
							pbs.Color = Color3.fromRGB(50, 60, 80)
						end
					end
					refreshPill()

					table.insert(detailConns, pb.MouseButton1Click:Connect(function()
						rule.wantedSpecials[optKey] = not (rule.wantedSpecials[optKey] == true)
						refreshPill()
						if rebuildCards then rebuildCards() end
						if HUB.Config.autoSave then saveConfig() end
						if HUB.Config.autoLock and HUB.RunAutoLockCheck then task.spawn(HUB.RunAutoLockCheck) end
					end))
				end

				-- =========================================================
				-- ฟังก์ชันสร้างการ์ดสเตตัสสุ่มเฉพาะของแต่ละ Special Option ที่เลือก
				-- =========================================================
				rebuildCards = function()
					clearConns(cardsConns)

					for _, ch in ipairs(cardsHolder:GetChildren()) do
						if ch ~= chLayout then
							ch:Destroy()
						end
					end

					local activeCount = 0
					for _, optKey in ipairs(catDef.Specials or {}) do
						if rule.wantedSpecials[optKey] == true then
							activeCount = activeCount + 1
							if not rule.specialStats[optKey] then
								rule.specialStats[optKey] = {
									stats = {},
									minMatch = 1
								}
							end
							local sConf = rule.specialStats[optKey]
							if type(sConf.stats) ~= "table" then sConf.stats = {} end

							-- สร้าง Card Frame
							local cFrame = Instance.new("Frame")
							cFrame.Name = "Card_" .. optKey
							cFrame.Size = UDim2.new(1, 0, 0, 0)
							cFrame.AutomaticSize = Enum.AutomaticSize.Y
							cFrame.BackgroundColor3 = Color3.fromRGB(242, 236, 222)
							cFrame.BorderSizePixel = 0
							cFrame.ZIndex = 65
							cFrame.Parent = cardsHolder

							local cfCorner = Instance.new("UICorner")
							cfCorner.CornerRadius = UDim.new(0, 6)
							cfCorner.Parent = cFrame

							local cfStroke = Instance.new("UIStroke")
							cfStroke.Color = Color3.fromRGB(222, 214, 198)
							cfStroke.Thickness = 1
							cfStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
							cfStroke.Parent = cFrame

							local cfLayout = Instance.new("UIListLayout")
							cfLayout.FillDirection = Enum.FillDirection.Vertical
							cfLayout.Padding = UDim.new(0, 6)
							cfLayout.SortOrder = Enum.SortOrder.LayoutOrder
							cfLayout.Parent = cFrame

							local cfPad = Instance.new("UIPadding")
							cfPad.PaddingTop = UDim.new(0, 6)
							cfPad.PaddingBottom = UDim.new(0, 8)
							cfPad.PaddingLeft = UDim.new(0, 8)
							cfPad.PaddingRight = UDim.new(0, 8)
							cfPad.Parent = cFrame

							-- แถวบน: ชื่อ Special Option + Stepper
							local cTop = Instance.new("Frame")
							cTop.Name = "TopRow"
							cTop.LayoutOrder = 1
							cTop.Size = UDim2.new(1, 0, 0, 22)
							cTop.BackgroundTransparency = 1
							cTop.ZIndex = 66
							cTop.Parent = cFrame

							local cTitle = Instance.new("TextLabel")
							cTitle.Name = "Title"
							cTitle.Size = UDim2.new(0, 175, 1, 0)
							cTitle.BackgroundTransparency = 1
							cTitle.Text = "✦ " .. (OPTION_LABELS[optKey] or optKey)
							cTitle.TextColor3 = Color3.fromRGB(170, 110, 15)
							cTitle.TextSize = 12
							cTitle.TextXAlignment = Enum.TextXAlignment.Left
							applyFont(cTitle, true)
							cTitle.ZIndex = 66
							cTitle.Parent = cTop

							-- Stepper for Min Match
							local stepHolder = Instance.new("Frame")
							stepHolder.Name = "Stepper"
							stepHolder.Size = UDim2.new(1, -180, 1, 0)
							stepHolder.Position = UDim2.new(0, 180, 0, 0)
							stepHolder.BackgroundTransparency = 1
							stepHolder.ZIndex = 66
							stepHolder.Parent = cTop

							local sMinus = Instance.new("TextButton")
							sMinus.Name = "Minus"
							sMinus.Size = UDim2.new(0, 22, 1, 0)
							sMinus.BackgroundColor3 = THEME.DarkNavy
							sMinus.BorderSizePixel = 0
							sMinus.Text = "−"
							sMinus.TextColor3 = Color3.fromRGB(255, 255, 255)
							sMinus.TextStrokeTransparency = 1
							sMinus.TextSize = 13
							applyFont(sMinus, true)
							sMinus.ZIndex = 67
							sMinus.Parent = stepHolder
							local smc = Instance.new("UICorner")
							smc.CornerRadius = UDim.new(0, 4)
							smc.Parent = sMinus

							local sLabel = Instance.new("TextLabel")
							sLabel.Name = "Label"
							sLabel.Size = UDim2.new(1, -50, 1, 0)
							sLabel.Position = UDim2.new(0, 25, 0, 0)
							sLabel.BackgroundColor3 = Color3.fromRGB(226, 220, 206)
							sLabel.BorderSizePixel = 0
							sLabel.TextColor3 = THEME.TextDark
							sLabel.TextStrokeTransparency = 1
							sLabel.TextSize = 11
							applyFont(sLabel, true)
							sLabel.ZIndex = 67
							sLabel.Parent = stepHolder
							local slc = Instance.new("UICorner")
							slc.CornerRadius = UDim.new(0, 4)
							slc.Parent = sLabel

							local sPlus = Instance.new("TextButton")
							sPlus.Name = "Plus"
							sPlus.Size = UDim2.new(0, 22, 1, 0)
							sPlus.Position = UDim2.new(1, -22, 0, 0)
							sPlus.BackgroundColor3 = THEME.DarkNavy
							sPlus.BorderSizePixel = 0
							sPlus.Text = "+"
							sPlus.TextColor3 = Color3.fromRGB(255, 255, 255)
							sPlus.TextStrokeTransparency = 1
							sPlus.TextSize = 13
							applyFont(sPlus, true)
							sPlus.ZIndex = 67
							sPlus.Parent = stepHolder
							local spc = Instance.new("UICorner")
							spc.CornerRadius = UDim.new(0, 4)
							spc.Parent = sPlus

							-- แถวสเตตัสสุ่ม (Pool Pills)
							local pillsRow = Instance.new("Frame")
							pillsRow.Name = "PillsRow"
							pillsRow.LayoutOrder = 2
							pillsRow.Size = UDim2.new(1, 0, 0, 0)
							pillsRow.AutomaticSize = Enum.AutomaticSize.Y
							pillsRow.BackgroundTransparency = 1
							pillsRow.ZIndex = 66
							pillsRow.Parent = cFrame

							local prLayout = Instance.new("UIGridLayout")
							prLayout.CellSize = UDim2.new(0, 68, 0, 24)
							prLayout.CellPadding = UDim2.new(0, 6, 0, 4)
							prLayout.SortOrder = Enum.SortOrder.LayoutOrder
							prLayout.Parent = pillsRow

							-- Dynamic Hint Label
							local hintLabel = Instance.new("TextLabel")
							hintLabel.Name = "Hint"
							hintLabel.LayoutOrder = 3
							hintLabel.Size = UDim2.new(1, 0, 0, 14)
							hintLabel.BackgroundTransparency = 1
							hintLabel.TextSize = 10
							hintLabel.TextXAlignment = Enum.TextXAlignment.Left
							applyFont(hintLabel, false)
							hintLabel.ZIndex = 66
							hintLabel.Parent = cFrame

							local function refreshCard()
								local val = tonumber(sConf.minMatch) or 1
								local hasSelected = false
								for _, w in pairs(sConf.stats) do
									if w == true then hasSelected = true break end
								end

								if not hasSelected or val <= 0 then
									sLabel.Text = "ไม่กรองสเตตัส"
									hintLabel.Text = "○ ไม่ได้เลือกสเตตัส = จะล็อคทุกชิ้นที่มี " .. (OPTION_LABELS[optKey] or optKey) .. " (ไม่กรองสเตตัส)"
									hintLabel.TextColor3 = Color3.fromRGB(160, 110, 20)
								else
									sLabel.Text = string.format("ตรงอย่างน้อย %d แถว", val)
									hintLabel.Text = string.format("✔ ล็อคเมื่อมีสเตตัสที่เลือกตรงอย่างน้อย %d แถวขึ้นไป", val)
									hintLabel.TextColor3 = Color3.fromRGB(30, 140, 60)
								end
							end
							refreshCard()

							table.insert(cardsConns, sMinus.MouseButton1Click:Connect(function()
								local val = tonumber(sConf.minMatch) or 1
								val = math.clamp(val - 1, 0, 4)
								sConf.minMatch = val
								refreshCard()
								if HUB.Config.autoSave then saveConfig() end
								if HUB.Config.autoLock and HUB.RunAutoLockCheck then task.spawn(HUB.RunAutoLockCheck) end
							end))

							table.insert(cardsConns, sPlus.MouseButton1Click:Connect(function()
								local val = tonumber(sConf.minMatch) or 1
								val = math.clamp(val + 1, 0, 4)
								sConf.minMatch = val
								refreshCard()
								if HUB.Config.autoSave then saveConfig() end
								if HUB.Config.autoLock and HUB.RunAutoLockCheck then task.spawn(HUB.RunAutoLockCheck) end
							end))

							for pIdx, statKey in ipairs(catDef.Pool or {}) do
								local pb = Instance.new("TextButton")
								pb.Name = "CardPill_" .. statKey
								pb.LayoutOrder = pIdx
								pb.BorderSizePixel = 0
								pb.Text = statKey
								pb.TextSize = 12
								pb.TextColor3 = Color3.fromRGB(255, 255, 255)
								pb.TextStrokeTransparency = 1
								applyFont(pb, true)
								pb.ZIndex = 67
								pb.Parent = pillsRow

								local pbc = Instance.new("UICorner")
								pbc.CornerRadius = UDim.new(0, 4)
								pbc.Parent = pb
								local pbs = Instance.new("UIStroke")
								pbs.Thickness = 1.2
								pbs.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
								pbs.Parent = pb

								local col = STAT_COLORS[statKey] or THEME.BtnGreen

								local function refreshRandPill()
									local sel = (sConf.stats[statKey] == true)
									pb.TextColor3 = Color3.fromRGB(255, 255, 255)
									pb.TextStrokeTransparency = 1
									if sel then
										pb.BackgroundColor3 = col
										pbs.Color = col
									else
										pb.BackgroundColor3 = Color3.fromRGB(25, 30, 45)
										pbs.Color = Color3.fromRGB(50, 60, 80)
									end
								end
								refreshRandPill()

								table.insert(cardsConns, pb.MouseButton1Click:Connect(function()
									sConf.stats[statKey] = not (sConf.stats[statKey] == true)
									refreshRandPill()
									refreshCard()
									if HUB.Config.autoSave then saveConfig() end
									if HUB.Config.autoLock and HUB.RunAutoLockCheck then task.spawn(HUB.RunAutoLockCheck) end
								end))
							end
						end
					end

					if activeCount == 0 then
						local emptyBox = Instance.new("Frame")
						emptyBox.Name = "EmptyNotice"
						emptyBox.Size = UDim2.new(1, 0, 0, 44)
						emptyBox.BackgroundColor3 = Color3.fromRGB(238, 232, 218)
						emptyBox.BorderSizePixel = 0
						emptyBox.ZIndex = 65
						emptyBox.Parent = cardsHolder

						local ebCorner = Instance.new("UICorner")
						ebCorner.CornerRadius = UDim.new(0, 6)
						ebCorner.Parent = emptyBox

						local ebLbl = Instance.new("TextLabel")
						ebLbl.Name = "NoticeText"
						ebLbl.Size = UDim2.new(1, -20, 1, 0)
						ebLbl.Position = UDim2.new(0, 10, 0, 0)
						ebLbl.BackgroundTransparency = 1
						ebLbl.Text = "ℹ️ ยังไม่ได้เลือก Special Option ด้านบน (คลิกเลือกออปชันด้านบนเพื่อตั้งค่าสเตตัส)"
						ebLbl.TextColor3 = Color3.fromRGB(140, 130, 115)
						ebLbl.TextSize = 11
						applyFont(ebLbl, false)
						ebLbl.ZIndex = 66
						ebLbl.Parent = emptyBox
					end
				end
				rebuildCards()

				-- =========================================================
				-- ส่วนที่ 3 (Bottom Section): สเตตัสต้องห้ามประจำหมวด
				-- =========================================================
				local forbSec = Instance.new("Frame")
				forbSec.Name = "ForbiddenSection"
				forbSec.LayoutOrder = 5
				forbSec.Size = UDim2.new(1, 0, 0, 0)
				forbSec.AutomaticSize = Enum.AutomaticSize.Y
				forbSec.BackgroundColor3 = Color3.fromRGB(242, 236, 222)
				forbSec.BorderSizePixel = 0
				forbSec.ZIndex = 65
				forbSec.Parent = rightScroll
				local fbCorner = Instance.new("UICorner")
				fbCorner.CornerRadius = UDim.new(0, 6)
				fbCorner.Parent = forbSec

				local fbSecLayout = Instance.new("UIListLayout")
				fbSecLayout.FillDirection = Enum.FillDirection.Vertical
				fbSecLayout.Padding = UDim.new(0, 6)
				fbSecLayout.SortOrder = Enum.SortOrder.LayoutOrder
				fbSecLayout.Parent = forbSec

				local fbSecPad = Instance.new("UIPadding")
				fbSecPad.PaddingTop = UDim.new(0, 6)
				fbSecPad.PaddingBottom = UDim.new(0, 8)
				fbSecPad.PaddingLeft = UDim.new(0, 8)
				fbSecPad.PaddingRight = UDim.new(0, 8)
				fbSecPad.Parent = forbSec

				local fbTop = Instance.new("Frame")
				fbTop.Name = "TopRow"
				fbTop.LayoutOrder = 1
				fbTop.Size = UDim2.new(1, 0, 0, 22)
				fbTop.BackgroundTransparency = 1
				fbTop.ZIndex = 66
				fbTop.Parent = forbSec

				local fbTitle = Instance.new("TextLabel")
				fbTitle.Name = "Title"
				fbTitle.Size = UDim2.new(1, 0, 1, 0)
				fbTitle.BackgroundTransparency = 1
				fbTitle.Text = "⛔ 3. สเตตัสต้องห้าม (หากมีสเตตัสที่เลือก จะไม่ล็อคเด็ดขาด):"
				fbTitle.TextColor3 = Color3.fromRGB(200, 40, 40)
				fbTitle.TextSize = 12
				fbTitle.TextXAlignment = Enum.TextXAlignment.Left
				applyFont(fbTitle, true)
				fbTitle.ZIndex = 66
				fbTitle.Parent = fbTop

				local forbPills = Instance.new("Frame")
				forbPills.Name = "Pills"
				forbPills.LayoutOrder = 2
				forbPills.Size = UDim2.new(1, 0, 0, 0)
				forbPills.AutomaticSize = Enum.AutomaticSize.Y
				forbPills.BackgroundTransparency = 1
				forbPills.ZIndex = 66
				forbPills.Parent = forbSec

				local fpLayout = Instance.new("UIGridLayout")
				fpLayout.CellSize = UDim2.new(0, 68, 0, 24)
				fpLayout.CellPadding = UDim2.new(0, 6, 0, 4)
				fpLayout.SortOrder = Enum.SortOrder.LayoutOrder
				fpLayout.Parent = forbPills

				for idx, statKey in ipairs(catDef.ForbiddenCandidates or {}) do
					local pb = Instance.new("TextButton")
					pb.Name = "ForbPill_" .. statKey
					pb.LayoutOrder = idx
					pb.BorderSizePixel = 0
					pb.Text = statKey
					pb.TextSize = 12
					pb.TextColor3 = Color3.fromRGB(255, 255, 255)
					pb.TextStrokeTransparency = 1
					applyFont(pb, true)
					pb.ZIndex = 67
					pb.Parent = forbPills

					local pbc = Instance.new("UICorner")
					pbc.CornerRadius = UDim.new(0, 4)
					pbc.Parent = pb
					local pbs = Instance.new("UIStroke")
					pbs.Thickness = 1.2
					pbs.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
					pbs.Parent = pb

					local function refreshForbPill()
						local sel = (rule.forbidden[statKey] == true)
						pb.TextColor3 = Color3.fromRGB(255, 255, 255)
						pb.TextStrokeTransparency = 1
						if sel then
							pb.BackgroundColor3 = Color3.fromRGB(180, 35, 35)
							pbs.Color = Color3.fromRGB(180, 35, 35)
						else
							pb.BackgroundColor3 = Color3.fromRGB(25, 30, 45)
							pbs.Color = Color3.fromRGB(50, 60, 80)
						end
					end
					refreshForbPill()

					table.insert(detailConns, pb.MouseButton1Click:Connect(function()
						rule.forbidden[statKey] = not (rule.forbidden[statKey] == true)
						refreshForbPill()
						if HUB.Config.autoSave then saveConfig() end
						if HUB.Config.autoLock and HUB.RunAutoLockCheck then task.spawn(HUB.RunAutoLockCheck) end
					end))
				end
			end
		end

		-- Populate Left Sidebar Categories
		for idx, def in ipairs(CATEGORY_DEFS) do
			local catBtn = Instance.new("TextButton")
			catBtn.Name = "CatBtn_" .. def.Id
			catBtn.LayoutOrder = idx
			catBtn.Size = UDim2.new(1, -6, 0, 36)
			catBtn.BackgroundColor3 = Color3.fromRGB(246, 240, 228)
			catBtn.BorderSizePixel = 0
			catBtn.Text = ""
			catBtn.AutoButtonColor = false
			catBtn.ZIndex = 65
			catBtn.Parent = lsScroll

			local cbc = Instance.new("UICorner")
			cbc.CornerRadius = UDim.new(0, 4)
			cbc.Parent = catBtn

			local cbs = Instance.new("UIStroke")
			cbs.Color = THEME.PanelBorder
			cbs.Thickness = 1
			cbs.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
			cbs.Parent = catBtn

			local catIcon = Instance.new("ImageLabel")
			catIcon.Name = "Icon"
			catIcon.Size = UDim2.new(0, 26, 0, 26)
			catIcon.Position = UDim2.new(0, 5, 0.5, -13)
			catIcon.BackgroundTransparency = 1
			applyGameIcon(catIcon, def.SampleKey, def.FallbackIcon)
			catIcon.ZIndex = 66
			catIcon.Parent = catBtn

			local nameLabel = Instance.new("TextLabel")
			nameLabel.Name = "Name"
			nameLabel.Size = UDim2.new(1, -78, 1, 0)
			nameLabel.Position = UDim2.new(0, 36, 0, 0)
			nameLabel.BackgroundTransparency = 1
			nameLabel.Text = def.Name
			nameLabel.TextColor3 = THEME.TextDark
			nameLabel.TextStrokeTransparency = 1
			nameLabel.TextSize = 11
			nameLabel.TextXAlignment = Enum.TextXAlignment.Left
			nameLabel.TextTruncate = Enum.TextTruncate.AtEnd
			applyFont(nameLabel, true)
			nameLabel.ZIndex = 66
			nameLabel.Parent = catBtn

			local badge = Instance.new("TextLabel")
			badge.Name = "Badge"
			badge.Size = UDim2.new(0, 38, 1, 0)
			badge.Position = UDim2.new(1, -42, 0, 0)
			badge.BackgroundTransparency = 1
			badge.Text = "[OFF]"
			badge.TextColor3 = Color3.fromRGB(150, 150, 150)
			badge.TextStrokeTransparency = 1
			badge.TextSize = 10
			badge.TextXAlignment = Enum.TextXAlignment.Right
			applyFont(badge, true)
			badge.ZIndex = 66
			badge.Parent = catBtn

			categoryBtnMap[def.Id] = {
				Button = catBtn,
				Name = nameLabel,
				Badge = badge,
				Def = def
			}

			table.insert(modalConns, catBtn.MouseButton1Click:Connect(function()
				selectedCatId = def.Id
				refreshAllBadges()
				renderDetail(def)
			end))
		end

		refreshAllBadges()
		renderDetail(CATEGORY_DEFS[1])
	end
	HUB.OpenAutoLockModal = openAutoLockModal
	HUB.AutoLockCleanup = function()
		clearConns(cardsConns)
		clearConns(detailConns)
		clearConns(modalConns)
		if autoLockModalInstance then
			pcall(function() autoLockModalInstance:Destroy() end)
			autoLockModalInstance = nil
		end
	end

	-- ---------- 7.5.5 Card ในแท็บ Item: Auto Lock Item (คัดแยกล็อคของอัตโนมัติ) ----------
	local _, lockStatus = createCard(
		scrollItem,
		"Auto Lock Item (คัดแยกล็อคของอัตโนมัติ)",
		"ตรวจสอบของในกระเป๋าและล็อคอัตโนมัติตามเกรด/ออปชันอุปกรณ์ที่เลือก (คลิก ⚙️ เพื่อเปิดหน้าต่างตั้งค่า)",
		HUB.Config.autoLock,
		function(enabled, label)
			HUB.Config.autoLock = enabled
			if enabled then
				label.Text = "สถานะ: เปิดใช้งาน (ล็อคอัตโนมัติเมื่อได้ของใหม่)"
				if HUB.RunAutoLockCheck then task.spawn(HUB.RunAutoLockCheck) end
			else
				label.Text = "สถานะ: ปิดใช้งาน"
			end
		end,
		nil,
		function(subPanel, card, cStatus, setExpandHeight)
			if setExpandHeight then setExpandHeight(118, 198) end

			local openModalBtn = Instance.new("TextButton")
			openModalBtn.Name = "OpenModalBtn"
			openModalBtn.Size = UDim2.new(1, -16, 0, 24)
			openModalBtn.Position = UDim2.new(0, 8, 0, 4)
			openModalBtn.BackgroundColor3 = THEME.BtnOrange
			openModalBtn.BorderSizePixel = 0
			openModalBtn.Text = "⚙️ เปิดหน้าต่างตั้งค่าขั้นสูง (Auto Lock Modal)"
			openModalBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
			openModalBtn.TextSize = 11
			applyFont(openModalBtn, true)
			openModalBtn.Parent = subPanel
			local omCorner = Instance.new("UICorner")
			omCorner.CornerRadius = UDim.new(0, 4)
			omCorner.Parent = openModalBtn
			local omStroke = Instance.new("UIStroke")
			omStroke.Color = THEME.BtnOrangeStroke
			omStroke.Thickness = 1.2
			omStroke.Parent = openModalBtn
			HUB:AddConnection(openModalBtn.MouseButton1Click:Connect(openAutoLockModal))

			local subTitle = Instance.new("TextLabel")
			subTitle.Name = "SubTitle"
			subTitle.Size = UDim2.new(1, -16, 0, 14)
			subTitle.Position = UDim2.new(0, 8, 0, 32)
			subTitle.BackgroundTransparency = 1
			subTitle.Text = "เลือกเกรดที่ต้องการล็อค (คลิกปุ่มเพื่อสลับ):"
			subTitle.TextColor3 = THEME.TextSub
			subTitle.TextSize = 11
			subTitle.TextXAlignment = Enum.TextXAlignment.Left
			applyFont(subTitle, false)
			subTitle.Parent = subPanel

			local btnRow = Instance.new("Frame")
			btnRow.Name = "TierBtnRow"
			btnRow.Size = UDim2.new(1, -16, 0, 20)
			btnRow.Position = UDim2.new(0, 8, 0, 48)
			btnRow.BackgroundTransparency = 1
			btnRow.Parent = subPanel

			local rowLayout = Instance.new("UIListLayout")
			rowLayout.SortOrder = Enum.SortOrder.LayoutOrder
			rowLayout.FillDirection = Enum.FillDirection.Horizontal
			rowLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
			rowLayout.VerticalAlignment = Enum.VerticalAlignment.Center
			rowLayout.Padding = UDim.new(0, 6)
			rowLayout.Parent = btnRow

			local tiers = { "F", "D", "C", "B", "A", "S", "SS" }
			local tierColors = {
				SS = Color3.fromRGB(220, 40, 40),
				S  = Color3.fromRGB(230, 120, 20),
				A  = Color3.fromRGB(160, 60, 210),
				B  = Color3.fromRGB(40, 120, 230),
				C  = Color3.fromRGB(40, 180, 80),
				D  = Color3.fromRGB(140, 140, 140),
				F  = Color3.fromRGB(90, 90, 90)
			}

			for idx, t in ipairs(tiers) do
				local b = Instance.new("TextButton")
				b.Name = "Btn_" .. t
				b.LayoutOrder = idx
				b.Size = UDim2.new(0, 36, 0, 20)
				b.BorderSizePixel = 0
				b.Text = t
				b.TextSize = 12
				b.TextColor3 = Color3.fromRGB(255, 255, 255)
				applyFont(b, true)
				b.Parent = btnRow

				local bc = Instance.new("UICorner")
				bc.CornerRadius = UDim.new(0, 4)
				bc.Parent = b

				local bs = Instance.new("UIStroke")
				bs.Thickness = 1.2
				bs.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
				bs.Parent = b

				b.TextStrokeTransparency = 1

				local function refreshTierBtn()
					local active = (HUB.Config.autoLockTiers and HUB.Config.autoLockTiers[t] == true)
					b.TextColor3 = Color3.fromRGB(255, 255, 255)
					b.TextStrokeTransparency = 1
					if active then
						b.BackgroundColor3 = tierColors[t] or THEME.BtnGreen
						bs.Color = tierColors[t] or THEME.BtnGreen
					else
						b.BackgroundColor3 = Color3.fromRGB(25, 30, 45)
						bs.Color = Color3.fromRGB(50, 60, 80)
					end
				end
				refreshTierBtn()

				HUB:AddConnection(b.MouseButton1Click:Connect(function()
					if not HUB.Config.autoLockTiers then HUB.Config.autoLockTiers = {} end
					HUB.Config.autoLockTiers[t] = not HUB.Config.autoLockTiers[t]
					refreshTierBtn()
					if HUB.Config.autoSave then saveConfig() end
					if HUB.Config.autoLock and HUB.RunAutoLockCheck then
						task.spawn(HUB.RunAutoLockCheck)
					end
				end))
			end

			-- แถว 2: เลือกล็อคตามระดับดาว (ดาวเงิน, ดาวทอง, ดาวรุ้ง)
			local starTitle = Instance.new("TextLabel")
			starTitle.Name = "StarTitle"
			starTitle.Size = UDim2.new(1, -16, 0, 14)
			starTitle.Position = UDim2.new(0, 8, 0, 72)
			starTitle.BackgroundTransparency = 1
			starTitle.Text = "เลือกล็อคตามระดับดาว (คลิกปุ่มเพื่อสลับ):"
			starTitle.TextColor3 = THEME.TextSub
			starTitle.TextSize = 11
			starTitle.TextXAlignment = Enum.TextXAlignment.Left
			applyFont(starTitle, false)
			starTitle.Parent = subPanel

			local starRow = Instance.new("Frame")
			starRow.Name = "StarBtnRow"
			starRow.Size = UDim2.new(1, -16, 0, 22)
			starRow.Position = UDim2.new(0, 8, 0, 88)
			starRow.BackgroundTransparency = 1
			starRow.Parent = subPanel

			local starLayout = Instance.new("UIListLayout")
			starLayout.SortOrder = Enum.SortOrder.LayoutOrder
			starLayout.FillDirection = Enum.FillDirection.Horizontal
			starLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
			starLayout.VerticalAlignment = Enum.VerticalAlignment.Center
			starLayout.Padding = UDim.new(0, 6)
			starLayout.Parent = starRow

			local starDefs = {
				{ Key = "Silver",  Label = "ดาวเงิน", StarColor = Color3.fromRGB(240, 248, 255), ActiveBg = Color3.fromRGB(70, 85, 115),  ActiveStroke = Color3.fromRGB(150, 175, 215) },
				{ Key = "Gold",    Label = "ดาวทอง", StarColor = Color3.fromRGB(255, 215, 0),   ActiveBg = Color3.fromRGB(160, 115, 20), ActiveStroke = Color3.fromRGB(220, 170, 40) },
				{ Key = "Rainbow", Label = "ดาวรุ้ง", StarColor = Color3.fromRGB(255, 255, 255), ActiveBg = Color3.fromRGB(120, 50, 145), ActiveStroke = Color3.fromRGB(200, 100, 220), Rainbow = true },
			}

			for idx, sDef in ipairs(starDefs) do
				local b = Instance.new("TextButton")
				b.Name = "Btn_Star_" .. sDef.Key
				b.LayoutOrder = idx
				b.Size = UDim2.new(0, 86, 0, 22)
				b.BorderSizePixel = 0
				b.Text = ""
				b.AutoButtonColor = false
				b.Parent = starRow

				local bc = Instance.new("UICorner")
				bc.CornerRadius = UDim.new(0, 4)
				bc.Parent = b

				local bs = Instance.new("UIStroke")
				bs.Thickness = 1.2
				bs.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
				bs.Parent = b

				local starIcon = Instance.new("ImageLabel")
				starIcon.Name = "StarIcon"
				starIcon.Size = UDim2.fromOffset(15, 15)
				starIcon.Position = UDim2.new(0, 7, 0.5, -7)
				starIcon.BackgroundTransparency = 1
				starIcon.Image = "rbxassetid://127066642314924"
				starIcon.ImageColor3 = sDef.StarColor
				starIcon.Parent = b

				if sDef.Rainbow then
					local starGrad = Instance.new("UIGradient")
					starGrad.Name = "RainbowStarGrad"
					starGrad.Color = ColorSequence.new({
						ColorSequenceKeypoint.new(0.00, Color3.fromRGB(255, 70, 70)),
						ColorSequenceKeypoint.new(0.20, Color3.fromRGB(255, 165, 30)),
						ColorSequenceKeypoint.new(0.40, Color3.fromRGB(255, 235, 40)),
						ColorSequenceKeypoint.new(0.60, Color3.fromRGB(40, 230, 90)),
						ColorSequenceKeypoint.new(0.80, Color3.fromRGB(40, 160, 255)),
						ColorSequenceKeypoint.new(1.00, Color3.fromRGB(180, 70, 240)),
					})
					starGrad.Rotation = 45
					starGrad.Parent = starIcon
				end

				local txtLbl = Instance.new("TextLabel")
				txtLbl.Name = "BtnText"
				txtLbl.Size = UDim2.new(1, -26, 1, 0)
				txtLbl.Position = UDim2.new(0, 24, 0, 0)
				txtLbl.BackgroundTransparency = 1
				txtLbl.Text = sDef.Label
				txtLbl.TextColor3 = Color3.fromRGB(255, 255, 255)
				txtLbl.TextStrokeTransparency = 1
				txtLbl.TextSize = 11
				txtLbl.TextXAlignment = Enum.TextXAlignment.Center
				applyFont(txtLbl, true)
				txtLbl.Parent = b

				local function refreshStarBtn()
					local active = (HUB.Config.autoLockStars and HUB.Config.autoLockStars[sDef.Key] == true)
					txtLbl.TextColor3 = Color3.fromRGB(255, 255, 255)
					txtLbl.TextStrokeTransparency = 1
					if active then
						b.BackgroundColor3 = sDef.ActiveBg
						bs.Color = sDef.ActiveBg
					else
						b.BackgroundColor3 = Color3.fromRGB(25, 30, 45)
						bs.Color = Color3.fromRGB(50, 60, 80)
					end
				end
				refreshStarBtn()

				HUB:AddConnection(b.MouseButton1Click:Connect(function()
					if not HUB.Config.autoLockStars then HUB.Config.autoLockStars = {} end
					HUB.Config.autoLockStars[sDef.Key] = not HUB.Config.autoLockStars[sDef.Key]
					refreshStarBtn()
					if HUB.Config.autoSave then saveConfig() end
					if HUB.Config.autoLock and HUB.RunAutoLockCheck then
						task.spawn(HUB.RunAutoLockCheck)
					end
				end))
			end
		end,
		openAutoLockModal
	)
	HUB.UI.LockStatusLabel = lockStatus

	-- ---------- 7.5.6 Card ในแท็บ Item: Auto Salvage (ย่อยอุปกรณ์ที่ไม่ได้ล็อคอัตโนมัติ) ----------
	local _, salvageStatus = createCard(
		scrollItem,
		"Auto Salvage (ย่อยอุปกรณ์ที่ไม่ได้ล็อค)",
		"ย่อยอุปกรณ์ Tier 1-5 ที่ไม่ได้ล็อคทันทีเมื่อกระเป๋าถึง % ที่ตั้งไว้ ทำงานได้ทุกที่ในโลก ไม่ต้องวาร์ปกลับเมือง",
		HUB.Config.autoSalvage,
		function(enabled, label)
			HUB.Config.autoSalvage = enabled
			local stats = getBagStats()
			local threshold = HUB.Config.autoSalvageThresholdPct or 85
			if enabled then
				label.Text = string.format("สถานะ: เปิดใช้งาน · ย่อยเมื่อเต็ม >= %d%% (ปัจจุบัน: %d%% [%d/%d])", threshold, stats.pct, stats.used, stats.max)
				if stats.pct >= threshold or (threshold == 100 and stats.isFull) then
					if HUB.RunAutoSalvageRoutine then task.spawn(HUB.RunAutoSalvageRoutine) end
				end
			else
				label.Text = string.format("สถานะ: ปิดใช้งาน (ความจุกระเป๋า: %d%% [%d/%d])", stats.pct, stats.used, stats.max)
			end
			if HUB.Config.autoSave then saveConfig() end
		end,
		nil,
		function(subPanel)
			local subTitle = Instance.new("TextLabel")
			subTitle.Name = "SubTitle"
			subTitle.Size = UDim2.new(1, -16, 0, 16)
			subTitle.Position = UDim2.new(0, 8, 0, 4)
			subTitle.BackgroundTransparency = 1
			subTitle.Text = "ย่อยอุปกรณ์เมื่อกระเป๋าเต็มถึง (คลิกเลือก %):"
			subTitle.TextColor3 = THEME.TextSub
			subTitle.TextSize = 11
			subTitle.TextXAlignment = Enum.TextXAlignment.Left
			applyFont(subTitle, false)
			subTitle.Parent = subPanel

			local btnRow = Instance.new("Frame")
			btnRow.Name = "PctBtnRow"
			btnRow.Size = UDim2.new(1, -16, 0, 20)
			btnRow.Position = UDim2.new(0, 8, 0, 22)
			btnRow.BackgroundTransparency = 1
			btnRow.Parent = subPanel

			local rowLayout = Instance.new("UIListLayout")
			rowLayout.SortOrder = Enum.SortOrder.LayoutOrder
			rowLayout.FillDirection = Enum.FillDirection.Horizontal
			rowLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
			rowLayout.VerticalAlignment = Enum.VerticalAlignment.Center
			rowLayout.Padding = UDim.new(0, 5)
			rowLayout.Parent = btnRow

			local presets = { 70, 80, 85, 90, 95, 100 }
			local pctBtns = {}

			local function refreshAllSalvagePctBtns()
				local currentThresh = HUB.Config.autoSalvageThresholdPct or 85
				for val, b in pairs(pctBtns) do
					local bs = b:FindFirstChildOfClass("UIStroke")
					b.TextColor3 = Color3.fromRGB(255, 255, 255)
					if val == currentThresh then
						b.BackgroundColor3 = THEME.BtnGreen
						if bs then bs.Color = THEME.BtnGreenStroke end
					else
						b.BackgroundColor3 = Color3.fromRGB(25, 30, 45)
						if bs then bs.Color = Color3.fromRGB(50, 60, 80) end
					end
				end
				if HUB.UI.SalvageStatusLabel and HUB.Config.autoSalvage then
					local stats = getBagStats()
					HUB.UI.SalvageStatusLabel.Text = string.format("สถานะ: เปิดใช้งาน · ย่อยเมื่อเต็ม >= %d%% (ปัจจุบัน: %d%% [%d/%d])", currentThresh, stats.pct, stats.used, stats.max)
				end
			end

			for idx, val in ipairs(presets) do
				local b = Instance.new("TextButton")
				b.Name = "Btn_" .. val
				b.LayoutOrder = idx
				b.Size = UDim2.new(0, 42, 0, 20)
				b.BorderSizePixel = 0
				b.Text = val .. "%"
				b.TextSize = 11
				b.TextColor3 = Color3.fromRGB(255, 255, 255)
				applyFont(b, true)
				b.Parent = btnRow

				local bc = Instance.new("UICorner")
				bc.CornerRadius = UDim.new(0, 4)
				bc.Parent = b

				local bs = Instance.new("UIStroke")
				bs.Thickness = 1.2
				bs.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
				bs.Parent = b

				pctBtns[val] = b

				HUB:AddConnection(b.MouseButton1Click:Connect(function()
					HUB.Config.autoSalvageThresholdPct = val
					refreshAllSalvagePctBtns()
					if HUB.Config.autoSave then saveConfig() end
					if HUB.Config.autoSalvage then
						local stats = getBagStats()
						if stats.pct >= val or (val == 100 and stats.isFull) then
							if HUB.RunAutoSalvageRoutine then task.spawn(HUB.RunAutoSalvageRoutine) end
						end
					end
				end))
			end
			refreshAllSalvagePctBtns()
		end
	)
	HUB.UI.SalvageStatusLabel = salvageStatus

	-- ---------- 7.5.7 Card ในแท็บ Item: Auto Sell (วาร์ปขายขยะ & กลับมาฟาร์ม) ----------
	local _, sellStatus = createCard(
		scrollItem,
		"Auto Sell (วาร์ปขายขยะ & กลับมาฟาร์ม)",
		"วาร์ปกลับเมืองไปขายของที่ Merchant เมื่อกระเป๋าเต็มตาม % ที่ตั้งไว้ แล้ววาร์ปกลับมาฟาร์มต่ออัตโนมัติ",
		HUB.Config.autoSell,
		function(enabled, label)
			HUB.Config.autoSell = enabled
			if enabled then
				if HUB.RefreshSellStatusLabel then
					HUB.RefreshSellStatusLabel()
				else
					local stats = getBagStats()
					local threshold = HUB.Config.autoSellThresholdPct or 85
					label.Text = string.format("สถานะ: เปิดใช้งาน · ขายเมื่อเต็ม >= %d%% (ปัจจุบัน: %d%% [%d/%d])", threshold, stats.pct, stats.used, stats.max)
				end
				if HUB.IsAutoSellNeeded and HUB.IsAutoSellNeeded() then
					if HUB.RunAutoSellRoutine then task.spawn(HUB.RunAutoSellRoutine) end
				end
			else
				local stats = getBagStats()
				label.Text = string.format("สถานะ: ปิดใช้งาน (ความจุกระเป๋า: %d%% [%d/%d])", stats.pct, stats.used, stats.max)
				if HUB.CancelAutoSellRoutine then HUB.CancelAutoSellRoutine() end
			end
		end,
		nil,
		function(subPanel, card, cStatus, setExpandHeight)
			if setExpandHeight then setExpandHeight(124, 210) end

			local subTitle = Instance.new("TextLabel")
			subTitle.Name = "SubTitle"
			subTitle.Size = UDim2.new(1, -16, 0, 16)
			subTitle.Position = UDim2.new(0, 8, 0, 4)
			subTitle.BackgroundTransparency = 1
			subTitle.Text = "วาร์ปขายของเมื่อกระเป๋าเต็มถึง (คลิกเลือก %):"
			subTitle.TextColor3 = THEME.TextSub
			subTitle.TextSize = 11
			subTitle.TextXAlignment = Enum.TextXAlignment.Left
			applyFont(subTitle, false)
			subTitle.Parent = subPanel

			local btnRow = Instance.new("Frame")
			btnRow.Name = "PctBtnRow"
			btnRow.Size = UDim2.new(1, -16, 0, 20)
			btnRow.Position = UDim2.new(0, 8, 0, 22)
			btnRow.BackgroundTransparency = 1
			btnRow.Parent = subPanel

			local rowLayout = Instance.new("UIListLayout")
			rowLayout.SortOrder = Enum.SortOrder.LayoutOrder
			rowLayout.FillDirection = Enum.FillDirection.Horizontal
			rowLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
			rowLayout.VerticalAlignment = Enum.VerticalAlignment.Center
			rowLayout.Padding = UDim.new(0, 5)
			rowLayout.Parent = btnRow

			local presets = { 70, 80, 85, 90, 95, 100 }
			local pctBtns = {}

			local function refreshAllPctBtns()
				local currentThresh = HUB.Config.autoSellThresholdPct or 85
				for val, b in pairs(pctBtns) do
					local bs = b:FindFirstChildOfClass("UIStroke")
					b.TextColor3 = Color3.fromRGB(255, 255, 255)
					if val == currentThresh then
						b.BackgroundColor3 = THEME.BtnGreen
						if bs then bs.Color = THEME.BtnGreenStroke end
					else
						b.BackgroundColor3 = Color3.fromRGB(25, 30, 45)
						if bs then bs.Color = Color3.fromRGB(50, 60, 80) end
					end
				end
				if HUB.RefreshSellStatusLabel then
					HUB.RefreshSellStatusLabel()
				end
			end

			for idx, val in ipairs(presets) do
				local b = Instance.new("TextButton")
				b.Name = "Btn_" .. val
				b.LayoutOrder = idx
				b.Size = UDim2.new(0, 42, 0, 20)
				b.BorderSizePixel = 0
				b.Text = val .. "%"
				b.TextSize = 11
				b.TextColor3 = Color3.fromRGB(255, 255, 255)
				applyFont(b, true)
				b.Parent = btnRow

				local bc = Instance.new("UICorner")
				bc.CornerRadius = UDim.new(0, 4)
				bc.Parent = b

				local bs = Instance.new("UIStroke")
				bs.Thickness = 1.2
				bs.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
				bs.Parent = b

				pctBtns[val] = b

				HUB:AddConnection(b.MouseButton1Click:Connect(function()
					HUB.Config.autoSellThresholdPct = val
					refreshAllPctBtns()
					if HUB.Config.autoSave then saveConfig() end
					if HUB.Config.autoSell and HUB.IsAutoSellNeeded and HUB.IsAutoSellNeeded() then
						if HUB.RunAutoSellRoutine then task.spawn(HUB.RunAutoSellRoutine) end
					end
				end))
			end

			-- ส่วนที่ 2: เลือกประเภทที่ต้องการขาย (ขยะ / อุปกรณ์)
			local typeTitle = Instance.new("TextLabel")
			typeTitle.Name = "TypeTitle"
			typeTitle.Size = UDim2.new(1, -16, 0, 16)
			typeTitle.Position = UDim2.new(0, 8, 0, 46)
			typeTitle.BackgroundTransparency = 1
			typeTitle.Text = "เลือกประเภทที่ต้องการขาย (คลิกเปิด/ปิด):"
			typeTitle.TextColor3 = THEME.TextSub
			typeTitle.TextSize = 11
			typeTitle.TextXAlignment = Enum.TextXAlignment.Left
			applyFont(typeTitle, false)
			typeTitle.Parent = subPanel

			local typeBtnRow = Instance.new("Frame")
			typeBtnRow.Name = "TypeBtnRow"
			typeBtnRow.Size = UDim2.new(1, -16, 0, 22)
			typeBtnRow.Position = UDim2.new(0, 8, 0, 64)
			typeBtnRow.BackgroundTransparency = 1
			typeBtnRow.Parent = subPanel

			local typeLayout = Instance.new("UIListLayout")
			typeLayout.SortOrder = Enum.SortOrder.LayoutOrder
			typeLayout.FillDirection = Enum.FillDirection.Horizontal
			typeLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
			typeLayout.VerticalAlignment = Enum.VerticalAlignment.Center
			typeLayout.Padding = UDim.new(0, 8)
			typeLayout.Parent = typeBtnRow

			local function createTypeToggle(btnName, textOn, textOff, getConfigVal, setConfigVal)
				local b = Instance.new("TextButton")
				b.Name = btnName
				b.Size = UDim2.new(0, 126, 0, 22)
				b.BorderSizePixel = 0
				b.TextSize = 11
				applyFont(b, true)
				b.Parent = typeBtnRow

				local bc = Instance.new("UICorner")
				bc.CornerRadius = UDim.new(0, 4)
				bc.Parent = b

				local bs = Instance.new("UIStroke")
				bs.Thickness = 1.2
				bs.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
				bs.Parent = b

				local function refresh()
					local val = getConfigVal()
					if val then
						b.Text = textOn
						b.BackgroundColor3 = THEME.BtnGreen
						b.TextColor3 = Color3.fromRGB(255, 255, 255)
						bs.Color = THEME.BtnGreenStroke
					else
						b.Text = textOff
						b.BackgroundColor3 = Color3.fromRGB(25, 30, 45)
						b.TextColor3 = Color3.fromRGB(150, 160, 175)
						bs.Color = Color3.fromRGB(50, 60, 80)
					end
				end

				HUB:AddConnection(b.MouseButton1Click:Connect(function()
					local cur = getConfigVal()
					setConfigVal(not cur)
					refresh()
					if HUB.RefreshSellStatusLabel then HUB.RefreshSellStatusLabel() end
					if HUB.Config.autoSave then saveConfig() end
				end))

				refresh()
				return refresh
			end

			local refreshJunkBtn = createTypeToggle(
				"Btn_SellJunk",
				"🗑️ ขายขยะ: ON",
				"🗑️ ขายขยะ: OFF",
				function() return HUB.Config.autoSellJunk ~= false end,
				function(v) HUB.Config.autoSellJunk = v end
			)

			local refreshGearBtn = createTypeToggle(
				"Btn_SellGear",
				"⚔️ ขายอุปกรณ์: ON",
				"⚔️ ขายอุปกรณ์: OFF",
				function() return HUB.Config.autoSellGear ~= false end,
				function(v) HUB.Config.autoSellGear = v end
			)

			-- ส่วนที่ 3: ปุ่มสั่งวาร์ปไปขายที่ Merchant ทันที (Manual Action)
			local btnSellNow = Instance.new("TextButton")
			btnSellNow.Name = "Btn_SellNow"
			btnSellNow.Size = UDim2.new(1, -16, 0, 24)
			btnSellNow.Position = UDim2.new(0, 8, 0, 92)
			btnSellNow.BackgroundColor3 = Color3.fromRGB(180, 110, 25)
			btnSellNow.BorderSizePixel = 0
			btnSellNow.Text = "💰 วาร์ปไปขายที่ Merchant เดี๋ยวนี้ (Manual Sell)"
			btnSellNow.TextColor3 = Color3.fromRGB(255, 255, 255)
			btnSellNow.TextSize = 11
			applyFont(btnSellNow, true)
			btnSellNow.Parent = subPanel

			local bsnCorner = Instance.new("UICorner")
			bsnCorner.CornerRadius = UDim.new(0, 4)
			bsnCorner.Parent = btnSellNow

			local bsnStroke = Instance.new("UIStroke")
			bsnStroke.Thickness = 1.2
			bsnStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
			bsnStroke.Color = Color3.fromRGB(240, 160, 40)
			bsnStroke.Parent = btnSellNow

			HUB:AddConnection(btnSellNow.MouseButton1Click:Connect(function()
				local canSell = hasSellableItems()
				if not canSell then
					if HUB.UI.SellStatusLabel then
						HUB.UI.SellStatusLabel.Text = "สถานะ: ไม่มีไอเทมที่ต้องขาย (ขยะว่าง / ไม่มีอุปกรณ์ไม่ล็อค)"
					end
					return
				end
				if HUB.RunAutoSellRoutine then
					task.spawn(function()
						HUB.RunAutoSellRoutine(true)
					end)
				end
			end))

			refreshAllPctBtns()
		end
	)
	HUB.UI.SellStatusLabel = sellStatus

	-- ---------- 7.5.8 Card ในแท็บ Combat: Auto Farm Boss (ล่าบอสอัตโนมัติ & วาร์ปกลับจุดเดิม) ----------
	local _, bossStatus = createCard(
		scrollCombat,
		"Auto Farm Boss (ล่าบอสอัตโนมัติเมื่อเกิด)",
		"ตรวจจับบอสเกิด วาร์ปเสาไปสู้ด้วย Auto Play + Smart Dodge และวาร์ปกลับจุดเดิมเมื่อเสร็จ",
		HUB.Config.autoFarmBoss,
		function(enabled, label)
			HUB.Config.autoFarmBoss = enabled
			if enabled then
				label.Text = "สถานะ: เปิดใช้งาน · สแตนด์บายรอบอสเกิด..."
				if HUB.CheckAndTriggerAutoBoss then task.spawn(HUB.CheckAndTriggerAutoBoss) end
			else
				label.Text = "สถานะ: ปิดใช้งาน"
				if HUB.CancelAutoBossRoutine then HUB.CancelAutoBossRoutine() end
			end
			if HUB.Config.autoSave then saveConfig() end
		end,
		nil,
		function(subPanel, card, cStatus, setExpandHeight)
			if setExpandHeight then setExpandHeight(274, 358) end

			local subTitle = Instance.new("TextLabel")
			subTitle.Name = "SubTitle"
			subTitle.Size = UDim2.new(1, -150, 0, 20)
			subTitle.Position = UDim2.new(0, 10, 0, 5)
			subTitle.BackgroundTransparency = 1
			subTitle.Text = "🎯 เลือกบอสที่ต้องการล่าเมื่อเกิด:"
			subTitle.TextColor3 = Color3.fromRGB(255, 220, 100)
			subTitle.TextSize = 12
			subTitle.TextXAlignment = Enum.TextXAlignment.Left
			applyFont(subTitle, true)
			subTitle.Parent = subPanel

			local bossWidgets = {}

			local function refreshAllRows()
				for _, w in pairs(bossWidgets) do
					if w.refresh then w.refresh() end
				end
			end

			-- ปุ่มลัด: เลือกทั้งหมด / ล้างทั้งหมด
			local btnSelectAll = Instance.new("TextButton")
			btnSelectAll.Name = "BtnSelectAll"
			btnSelectAll.Size = UDim2.new(0, 68, 0, 20)
			btnSelectAll.Position = UDim2.new(1, -142, 0, 5)
			btnSelectAll.BackgroundColor3 = Color3.fromRGB(28, 72, 138)
			btnSelectAll.BorderSizePixel = 0
			btnSelectAll.Text = "เลือกทั้งหมด"
			btnSelectAll.TextColor3 = Color3.fromRGB(235, 245, 255)
			btnSelectAll.TextSize = 10
			applyFont(btnSelectAll, true)
			btnSelectAll.Parent = subPanel
			local bsaCorner = Instance.new("UICorner")
			bsaCorner.CornerRadius = UDim.new(0, 4)
			bsaCorner.Parent = btnSelectAll

			local btnClearAll = Instance.new("TextButton")
			btnClearAll.Name = "BtnClearAll"
			btnClearAll.Size = UDim2.new(0, 62, 0, 20)
			btnClearAll.Position = UDim2.new(1, -70, 0, 5)
			btnClearAll.BackgroundColor3 = Color3.fromRGB(68, 52, 62)
			btnClearAll.BorderSizePixel = 0
			btnClearAll.Text = "ล้างทั้งหมด"
			btnClearAll.TextColor3 = Color3.fromRGB(235, 225, 230)
			btnClearAll.TextSize = 10
			applyFont(btnClearAll, true)
			btnClearAll.Parent = subPanel
			local bcaCorner = Instance.new("UICorner")
			bcaCorner.CornerRadius = UDim.new(0, 4)
			bcaCorner.Parent = btnClearAll

			HUB:AddConnection(btnSelectAll.MouseButton1Click:Connect(function()
				if not HUB.Config.farmBossList then HUB.Config.farmBossList = {} end
				for _, bDef in ipairs(BOSS_DEFS) do
					HUB.Config.farmBossList[bDef.key] = true
				end
				refreshAllRows()
				if HUB.Config.autoSave then saveConfig() end
				if HUB.Config.autoFarmBoss and HUB.CheckAndTriggerAutoBoss then
					task.spawn(HUB.CheckAndTriggerAutoBoss)
				end
			end))

			HUB:AddConnection(btnClearAll.MouseButton1Click:Connect(function()
				if not HUB.Config.farmBossList then HUB.Config.farmBossList = {} end
				for _, bDef in ipairs(BOSS_DEFS) do
					HUB.Config.farmBossList[bDef.key] = false
				end
				refreshAllRows()
				if HUB.Config.autoSave then saveConfig() end
			end))

			for idx, bDef in ipairs(BOSS_DEFS) do
				local rowY = 29 + (idx - 1) * 32
				local row = Instance.new("Frame")
				row.Name = "Row_" .. bDef.key
				row.Size = UDim2.new(1, -16, 0, 28)
				row.Position = UDim2.new(0, 8, 0, rowY)
				row.BackgroundColor3 = Color3.fromRGB(16, 40, 96)
				row.BorderSizePixel = 0
				row.Parent = subPanel

				local rCorner = Instance.new("UICorner")
				rCorner.CornerRadius = UDim.new(0, 6)
				rCorner.Parent = row

				-- ชื่อบอสและเลเวลทางซ้าย (คลิกสลับได้ด้วย)
				local nameBtn = Instance.new("TextButton")
				nameBtn.Name = "BossNameBtn"
				nameBtn.Size = UDim2.new(1, -198, 1, 0)
				nameBtn.Position = UDim2.new(0, 10, 0, 0)
				nameBtn.BackgroundTransparency = 1
				nameBtn.BorderSizePixel = 0
				nameBtn.TextSize = 12
				nameBtn.TextXAlignment = Enum.TextXAlignment.Left
				nameBtn.TextTruncate = Enum.TextTruncate.AtEnd
				applyFont(nameBtn, true)
				nameBtn.Parent = row

				-- ป้ายแสดงสถานะสดและเวลานับถอยหลังตรงกลาง-ขวา
				local statusBadge = Instance.new("TextLabel")
				statusBadge.Name = "StatusBadge"
				statusBadge.Size = UDim2.new(0, 96, 0, 22)
				statusBadge.Position = UDim2.new(1, -188, 0, 3)
				statusBadge.BorderSizePixel = 0
				statusBadge.TextSize = 11
				statusBadge.TextColor3 = Color3.fromRGB(255, 255, 255)
				applyFont(statusBadge, true)
				statusBadge.Parent = row

				local sbCorner = Instance.new("UICorner")
				sbCorner.CornerRadius = UDim.new(0, 5)
				sbCorner.Parent = statusBadge

				-- ปุ่มสวิตช์เลือกบอส (ON / OFF มาตรฐานเดียวกับทั้ง Hub)
				local toggleBtn = Instance.new("TextButton")
				toggleBtn.Name = "ToggleBtn"
				toggleBtn.Size = UDim2.new(0, 82, 0, 22)
				toggleBtn.Position = UDim2.new(1, -86, 0, 3)
				toggleBtn.BorderSizePixel = 0
				toggleBtn.TextSize = 11
				applyFont(toggleBtn, true)
				toggleBtn.Parent = row

				local tbCorner = Instance.new("UICorner")
				tbCorner.CornerRadius = UDim.new(0, 5)
				tbCorner.Parent = toggleBtn

				local function refreshRow()
					local isSelected = (HUB.Config.farmBossList and HUB.Config.farmBossList[bDef.key] == true)
					nameBtn.Text = string.format("%s · %s", bDef.levelText, bDef.name)
					if isSelected then
						row.BackgroundColor3 = Color3.fromRGB(20, 52, 114)
						nameBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
						toggleBtn.BackgroundColor3 = THEME.BtnGreen
						toggleBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
						toggleBtn.Text = "ล่า (ON)"
					else
						row.BackgroundColor3 = Color3.fromRGB(14, 34, 84)
						nameBtn.TextColor3 = Color3.fromRGB(175, 192, 220)
						toggleBtn.BackgroundColor3 = THEME.BtnOff
						toggleBtn.TextColor3 = THEME.TextDark
						toggleBtn.Text = "ข้าม (OFF)"
					end
				end

				bossWidgets[bDef.key] = {
					def = bDef,
					row = row,
					nameBtn = nameBtn,
					btn = toggleBtn,
					badge = statusBadge,
					refresh = refreshRow,
				}

				refreshRow()

				local function onToggleBoss()
					if not HUB.Config.farmBossList then HUB.Config.farmBossList = {} end
					HUB.Config.farmBossList[bDef.key] = not HUB.Config.farmBossList[bDef.key]
					refreshRow()
					if HUB.Config.autoSave then saveConfig() end
					if HUB.Config.autoFarmBoss and HUB.Config.farmBossList[bDef.key] and HUB.CheckAndTriggerAutoBoss then
						task.spawn(HUB.CheckAndTriggerAutoBoss)
					end
				end

				HUB:AddConnection(toggleBtn.MouseButton1Click:Connect(onToggleBoss))
				HUB:AddConnection(nameBtn.MouseButton1Click:Connect(onToggleBoss))
			end

			-- ส่วนที่ 2: เลือกระยะเวลารอบอสล่วงหน้า (5 วิ ถึง 60 วิ ทีละ 5 วิ — 12 ปุ่มตรงตัว)
			local sbTitle = Instance.new("TextLabel")
			sbTitle.Name = "StandbyTitle"
			sbTitle.Size = UDim2.new(1, -16, 0, 18)
			sbTitle.Position = UDim2.new(0, 8, 0, 194)
			sbTitle.BackgroundTransparency = 1
			sbTitle.Text = "⏱️ เดินทางไปรอก่อนบอสเกิด (คลิกเลือกเวลา):"
			sbTitle.TextColor3 = Color3.fromRGB(255, 220, 100)
			sbTitle.TextSize = 12
			sbTitle.TextXAlignment = Enum.TextXAlignment.Left
			applyFont(sbTitle, true)
			sbTitle.Parent = subPanel

			local standbyBtnMap = {}
			local function refreshStandbyBtns()
				local cur = HUB.Config.bossPreSpawnThreshold or 15
				for val, btn in pairs(standbyBtnMap) do
					local bs = btn:FindFirstChildOfClass("UIStroke")
					if val == cur then
						btn.BackgroundColor3 = THEME.BtnGreen
						btn.TextColor3 = Color3.fromRGB(255, 255, 255)
						if bs then bs.Color = THEME.BtnGreenStroke end
					else
						btn.BackgroundColor3 = Color3.fromRGB(25, 30, 45)
						btn.TextColor3 = Color3.fromRGB(200, 215, 235)
						if bs then bs.Color = Color3.fromRGB(50, 60, 80) end
					end
				end
			end

			local rowsData = {
				{ y = 216, vals = { 5, 10, 15, 20, 25, 30 } },
				{ y = 242, vals = { 35, 40, 45, 50, 55, 60 } },
			}

			for rIdx, rInfo in ipairs(rowsData) do
				local rFrame = Instance.new("Frame")
				rFrame.Name = "StandbyRow" .. rIdx
				rFrame.Size = UDim2.new(1, -16, 0, 22)
				rFrame.Position = UDim2.new(0, 8, 0, rInfo.y)
				rFrame.BackgroundTransparency = 1
				rFrame.Parent = subPanel

				local rLayout = Instance.new("UIListLayout")
				rLayout.FillDirection = Enum.FillDirection.Horizontal
				rLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
				rLayout.VerticalAlignment = Enum.VerticalAlignment.Center
				rLayout.SortOrder = Enum.SortOrder.LayoutOrder
				rLayout.Padding = UDim.new(0, 6)
				rLayout.Parent = rFrame

				for idx, secVal in ipairs(rInfo.vals) do
					local b = Instance.new("TextButton")
					b.Name = "Btn_" .. secVal
					b.LayoutOrder = idx
					b.Size = UDim2.new(1/6, -5, 1, 0)
					b.BorderSizePixel = 0
					b.Text = secVal .. " วิ"
					b.TextSize = 11
					b.TextColor3 = Color3.fromRGB(255, 255, 255)
					applyFont(b, true)
					b.Parent = rFrame

					local bc = Instance.new("UICorner")
					bc.CornerRadius = UDim.new(0, 4)
					bc.Parent = b

					local bs = Instance.new("UIStroke")
					bs.Thickness = 1.2
					bs.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
					bs.Parent = b

					standbyBtnMap[secVal] = b

					HUB:AddConnection(b.MouseButton1Click:Connect(function()
						HUB.Config.bossPreSpawnThreshold = secVal
						refreshStandbyBtns()
						if HUB.Config.autoSave then saveConfig() end
						if HUB.Config.autoFarmBoss and HUB.CheckAndTriggerAutoBoss then
							task.spawn(HUB.CheckAndTriggerAutoBoss)
						end
					end))
				end
			end

			refreshStandbyBtns()

			local function updateBadges()
				local myLevel = LocalPlayer:GetAttribute("Level") or 1
				for _, w in pairs(bossWidgets) do
					local bDef = w.def
					if myLevel < (bDef.minLevel or 0) then
						w.badge.BackgroundColor3 = Color3.fromRGB(62, 48, 78)
						w.badge.TextColor3 = Color3.fromRGB(220, 195, 245)
						w.badge.Text = string.format("🔒 ล็อค Lv.%d", bDef.minLevel)
					else
						local alive = HUB.IsBossAlive and HUB.IsBossAlive(bDef)
						if alive then
							w.badge.BackgroundColor3 = Color3.fromRGB(24, 135, 52)
							w.badge.TextColor3 = Color3.fromRGB(255, 255, 255)
							w.badge.Text = "🟢 มีชีวิตอยู่"
						else
							local remaining = HUB.GetBossCountdown and HUB.GetBossCountdown(bDef) or 0
							if remaining > 0 then
								w.badge.BackgroundColor3 = Color3.fromRGB(165, 92, 20)
								w.badge.TextColor3 = Color3.fromRGB(255, 245, 215)
								w.badge.Text = string.format("⏳ %02d:%02d", math.floor(remaining / 60), remaining % 60)
							else
								w.badge.BackgroundColor3 = Color3.fromRGB(85, 38, 38)
								w.badge.TextColor3 = Color3.fromRGB(235, 195, 195)
								w.badge.Text = "⭕ ตายแล้ว"
							end
						end
					end
				end
			end

			task.defer(updateBadges)

			-- Live status updater loop สำหรับอัปเดตเวลานับถอยหลังของบอสทุก 1 วินาที
			task.spawn(function()
				while HUB.Alive and EXEC.env.HuntingTogetherHub_Token == MY_TOKEN do
					task.wait(1.0)
					if subPanel and subPanel.Parent and subPanel.Visible then
						updateBadges()
					end
				end
			end)
		end
	)
	HUB.UI.BossStatusLabel = bossStatus

	-- ---------- 7.6 Cards ในแท็บ Settings ----------
	local _, afkStatusLabel = createCard(
		scrollSettings,
		"Anti-AFK (กันหลุด 20 นาที)",
		"รีเซ็ต idle อัตโนมัติในเบื้องหลังด้วย Silent VIM Pulse + Memory Sync ป้องกันเตะ 100%",
		HUB.Config.antiAfk,
		function(enabled, label)
			HUB.Config.antiAfk = enabled
			local idleSec = HUB.GetGroundTruthIdleSeconds and HUB.GetGroundTruthIdleSeconds() or 0
			label.Text = string.format("สถานะ: %s · รีเซ็ตแล้ว %d ครั้ง (Idle: %.1fs)", enabled and "เปิดใช้งาน" or "ปิดใช้งาน", HUB.Stats.afkCount, idleSec)
		end
	)
	HUB.UI.AfkStatusLabel = afkStatusLabel

	local _, rejoinStatusLabel = createCard(
		scrollSettings,
		"Auto Rejoin (เชื่อมต่อใหม่อัตโนมัติ)",
		"ตรวจจับการตัดการเชื่อมต่อและวาร์ปกลับเข้าเซิร์ฟเวอร์ทันที",
		HUB.Config.autoRejoin,
		function(enabled, label)
			HUB.Config.autoRejoin = enabled
			label.Text = "สถานะ: " .. (enabled and "พร้อมทำงาน" or "ปิดใช้งาน")
		end
	)
	HUB.UI.RejoinStatusLabel = rejoinStatusLabel

	local _, autoResumeStatus = createCard(
		scrollSettings,
		"Auto Resume Play (เปิด Auto Play อัตโนมัติ)",
		"หากหลุดแล้ว Rejoin หรือเพิ่ง Execute เข้ามา ระบบจะกดเปิด Auto Play ต่อเมื่อพบมอนในระยะ 30 studs",
		HUB.Config.autoResumeGamePlay ~= false,
		function(enabled, label)
			HUB.Config.autoResumeGamePlay = enabled
			if enabled then
				HUB.UserDisabledAuto = false
				label.Text = "สถานะ: เปิดใช้งาน (จะเปิดต่อเมื่อพบมอนในระยะ 30s)"
			else
				label.Text = "สถานะ: ปิดใช้งาน"
			end
		end
	)
	HUB.UI.AutoResumeStatusLabel = autoResumeStatus

	local _, saveStatusLabel = createCard(
		scrollSettings,
		"Auto Save (บันทึกค่าลงไฟล์ JSON)",
		"บันทึกและโหลดค่าการตั้งค่าจาก workspace อัตโนมัติทุกรอบ",
		HUB.Config.autoSave,
		function(enabled, label)
			HUB.Config.autoSave = enabled
			if enabled then
				saveConfig()
				label.Text = "สถานะ: บันทึกล่าสุด " .. os.date("%H:%M:%S")
			end
		end
	)
	HUB.UI.SaveStatusLabel = saveStatusLabel

	-- ---------- 7.7 กลไกการย่อ/ขยายหน้าต่าง ----------
	local function setMinimized(minimized)
		if minimized then
			mainWindow.Visible = false
			floatHolder.Visible = true
		else
			floatHolder.Visible = false
			contentArea.Visible = true
			if leftBody and leftBody.Parent then leftBody.Parent.Visible = true end
			if rightBody and rightBody.Parent then rightBody.Parent.Visible = true end
			leftBody.Visible = true
			rightBody.Visible = true
			mainWindow.Visible = true
		end
	end
	HUB.SetMinimized = setMinimized
	HUB.UI.MainWindow = mainWindow
	HUB.UI.ScrollCombat = scrollCombat
	HUB.UI.ScrollItem = scrollItem
	HUB.UI.ScrollFarm = scrollCombat
	HUB.UI.ScrollSettings = scrollSettings

	HUB:AddConnection(minBtn.MouseButton1Click:Connect(function()
		setMinimized(true)
	end))

	HUB:AddConnection(closeBtn.MouseButton1Click:Connect(function()
		setMinimized(true)
	end))

	-- ---------- 7.8 Dragging System (พร้อมบันทึกตำแหน่งไอคอนอัตโนมัติ) ----------
	local function makeDraggable(handle, frame, onDragEnd)
		local dragging = false
		local dragStart, startPos = nil, nil
		local dragDistance = 0

		HUB:AddConnection(handle.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
				dragging = true
				dragStart = UIS:GetMouseLocation()
				startPos = frame.Position
				dragDistance = 0
			end
		end))

		HUB:AddConnection(UIS.InputChanged:Connect(function(input)
			if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
				local currentMouse = UIS:GetMouseLocation()
				local delta = currentMouse - dragStart
				dragDistance = delta.Magnitude
				frame.Position = UDim2.new(
					startPos.X.Scale,
					startPos.X.Offset + delta.X,
					startPos.Y.Scale,
					startPos.Y.Offset + delta.Y
				)
			end
		end))

		local function endDrag()
			if dragging then
				dragging = false
				if onDragEnd then onDragEnd(frame.Position) end
			end
		end

		HUB:AddConnection(handle.InputEnded:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
				endDrag()
			end
		end))
		HUB:AddConnection(UIS.InputEnded:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
				endDrag()
			end
		end))

		return function() return dragDistance end
	end

	makeDraggable(dragHandle, mainWindow)
	
	local getFloatDragDist = makeDraggable(floatHit, floatHolder, function(newPos)
		local cam = workspace.CurrentCamera
		local vp = cam and cam.ViewportSize or Vector2.new(1280, 720)
		local clampedX = math.clamp(newPos.X.Scale * vp.X + newPos.X.Offset, 0, vp.X - 38)
		local clampedY = math.clamp(newPos.Y.Scale * vp.Y + newPos.Y.Offset, 0, vp.Y - 38)
		local safePos = {
			ScaleX = 0,
			OffsetX = math.floor(clampedX),
			ScaleY = 0,
			OffsetY = math.floor(clampedY),
		}
		floatHolder.Position = UDim2.new(0, safePos.OffsetX, 0, safePos.OffsetY)
		HUB.Config.iconPos = safePos
		if HUB.Config.autoSave then
			saveConfig()
		end
	end)

	HUB:AddConnection(floatHit.MouseButton1Click:Connect(function()
		if getFloatDragDist() < 5 then
			setMinimized(false)
		end
	end))

	HUB:AddConnection(UIS.InputBegan:Connect(function(input, processed)
		if processed then return end
		if input.KeyCode == Enum.KeyCode.RightControl or input.KeyCode == Enum.KeyCode.Insert then
			if mainWindow.Visible then
				setMinimized(true)
			else
				setMinimized(false)
			end
		end
	end))

	-- บังคับเปิดหน้าต่างหลักตรงกลางหน้าจอเสมอเมื่อเริ่มต้น Execute สคริปต์
	setMinimized(false)
end

-- ===== 8. (Removed hookfunction on RemoteFunction.InvokeServer to prevent C-Closure corruption & crash on Rejoin) =====

-- ===== 9. Farm Automation Background Workers (Ground-Truth Verified) =====

local function getDetectRadius()
	local botJsonStr = LocalPlayer:GetAttribute("BotJson")
	if type(botJsonStr) == "string" then
		local ok, data = pcall(HttpService.JSONDecode, HttpService, botJsonStr)
		if ok and type(data) == "table" and type(data.Radius) == "number" and data.Radius > 0 then
			return data.Radius
		end
	end
	return 70 -- ระยะเริ่มต้นอิงตามระบบฟาร์มของเกม
end

local _lastMinibossCheck = 0
local _cachedMinibossCount = 0

local function countActiveMinibosses(farmRadius)
	local now = os.clock()
	if now - _lastMinibossCheck < 0.8 then
		return _cachedMinibossCount
	end
	_lastMinibossCheck = now

	local char = LocalPlayer.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if not root then return _cachedMinibossCount end

	local count = 0
	local monsters = CollectionService:GetTagged("Monster")
	local myUserId = LocalPlayer.UserId

	for _, m in ipairs(monsters) do
		if m:IsA("Model") and m.Parent then
			local isMini = m:GetAttribute("IsMiniBoss") == true
			local isBoss = m:GetAttribute("IsBoss") == true
			local monsterId = tostring(m:GetAttribute("MonsterId") or "")
			local isBossType = isMini or isBoss or monsterId:sub(1, 5) == "boss_" or monsterId:sub(1, 8) == "bigboss_"

			if isBossType then
				local hum = m:FindFirstChildOfClass("Humanoid")
				local hp = tonumber(m:GetAttribute("HP")) or (hum and hum.Health) or 0
				if hp > 0 then
					local mPos = m.PrimaryPart and m.PrimaryPart.Position or (m:GetPivot() and m:GetPivot().Position)
					if mPos then
						local dist = (mPos - root.Position).Magnitude
						local threat = m:GetAttribute("ThreatUserId")
						local isMyThreat = (threat == myUserId)
						if isMyThreat or dist <= (farmRadius or 70) then
							count = count + 1
						end
					end
				end
			end
		end
	end
	_cachedMinibossCount = count
	return count
end

-- ตรวจสอบว่าผู้เล่นกำลังกดปุ่มเคลื่อนที่เอง (Manual Player Input: WASD / Arrows) หรือไม่
local function isPlayerManualInput()
	if UIS:GetFocusedTextBox() ~= nil then return false end
	return UIS:IsKeyDown(Enum.KeyCode.W)
		or UIS:IsKeyDown(Enum.KeyCode.A)
		or UIS:IsKeyDown(Enum.KeyCode.S)
		or UIS:IsKeyDown(Enum.KeyCode.D)
		or UIS:IsKeyDown(Enum.KeyCode.Up)
		or UIS:IsKeyDown(Enum.KeyCode.Down)
		or UIS:IsKeyDown(Enum.KeyCode.Left)
		or UIS:IsKeyDown(Enum.KeyCode.Right)
end

-- ควบคุมระบบวิ่ง (Sprint & Stamina) แท้ของเกมผ่าน LumiSprintLock
local function setSprinting(enabled)
	pcall(function()
		LocalPlayer:SetAttribute("LumiSprintLock", enabled == true)
	end)
end

-- ตรวจสอบว่าระบบ Auto Attack ของตัวเกมเปิดใช้งานอยู่หรือไม่ (Ground-Truth จาก LumiAuto.AutoButton.C4On / AutoOn)
local function isGameAutoActive()
	return HUB.IsGameAutoActive()
end

-- ตรวจสอบว่าตัวละครกำลังมีมอนสเตอร์เป้าหมายและกำลังต่อสู้อยู่จริงหรือไม่
local function isPlayerInActiveCombat()
	local curTarget = LocalPlayer:FindFirstChild("CurrentTarget")
	local target = curTarget and curTarget.Value
	if target and target.Parent and (CollectionService:HasTag(target, "Monster") or target:GetAttribute("HP") ~= nil) then
		local hp = tonumber(target:GetAttribute("HP")) or 0
		return hp > 0
	end
	return false
end

-- ตรวจสอบว่ามีมอนสเตอร์ที่มีชีวิตอยู่ในรัศมีที่กำหนดหรือไม่ (ค่าเริ่มต้น 30 studs)
local function isMonsterWithinRadius(radius)
	local char = LocalPlayer.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if not root then return false end

	radius = radius or 30
	local monsters = CollectionService:GetTagged("Monster")
	for _, m in ipairs(monsters) do
		if m:IsA("Model") and m.Parent then
			local hum = m:FindFirstChildOfClass("Humanoid")
			local hp = tonumber(m:GetAttribute("HP")) or (hum and hum.Health) or 0
			if hp > 0 then
				local mPos = m.PrimaryPart and m.PrimaryPart.Position or (m:GetPivot() and m:GetPivot().Position)
				if mPos and (mPos - root.Position).Magnitude <= radius then
					return true
				end
			end
		end
	end
	return false
end

-- ค้นหามอนสเตอร์ที่มีชีวิตที่อยู่ใกล้จุดอ้างอิงที่สุด
local function findNearestLiveMonster(centerPos, maxRadius)
	if not centerPos then return nil, (1 / 0) end
	local monsters = CollectionService:GetTagged("Monster")
	local bestMonster = nil
	local minD = maxRadius or 65
	for _, m in ipairs(monsters) do
		if m and m:IsA("Model") and m.Parent then
			local hum = m:FindFirstChildOfClass("Humanoid")
			local hp = tonumber(m:GetAttribute("HP")) or (hum and hum.Health) or 0
			if hp > 0 then
				local mPos = m.PrimaryPart and m.PrimaryPart.Position or (m:GetPivot() and m:GetPivot().Position)
				if mPos then
					local dist = (mPos - centerPos).Magnitude
					if dist <= minD then
						minD = dist
						bestMonster = m
					end
				end
			end
		end
	end
	return bestMonster, minD
end

-- ตรวจจับมอนสเตอร์ที่เกิด/โผล่ออกมาจากกล่องสมบัติโดยตรง (รัศมีประชิดจุดวางกล่อง <= 12.0 studs)
local function findMonsterFromBox(boxPos, maxRadius)
	if not boxPos then return nil end
	return findNearestLiveMonster(boxPos, maxRadius or 12.0)
end

-- ยิงเป้ามอนสเตอร์ให้ CombatClient ทันที 0 ms ผ่าน LumiLockTarget เพื่อข้ามคูลดาวน์ 1.5s ของเกม
local function instantResumeAutoCombat(centerPos)
	local lock = LocalPlayer:FindFirstChild("LumiLockTarget")
	if not lock or not lock:IsA("BindableEvent") then return false end
	local monster = findNearestLiveMonster(centerPos, 65)
	if monster then
		pcall(function()
			lock:Fire(monster)
		end)
		return true
	end
	return false
end

-- อัปเดต Farming Anchor: ถ้าผู้เล่นเดินไปจุดใหม่ และหยุดเดินนิ่ง ให้จำตำแหน่งใหม่เป็นจุดฟาร์ม (Throttled)
local _lastAnchorUpdate = 0
local function updateFarmingAnchor(root)
	if not root then return end
	-- GUARD: ห้ามบันทึกพิกัดในเมือง (Z > -300) เป็นจุดฟาร์มเด็ดขาด เพราะในเมืองไม่มีมอนสเตอร์ให้ฟาร์ม
	if root.Position.Z > -300 then return end

	local now = os.clock()
	if isPlayerManualInput() then
		HUB.LastManualMoveTime = now
		if not HUB.IsBossRoutineActive and not HUB.IsSellingRoutineActive then
			HUB.OriginCFrame = nil
			HUB.OriginAutoOn = nil
		end
		if HUB.Navigating then
			-- หากผู้เล่นกดเดินเองขณะที่ HUB กำลังนำทาง ให้ยกเลิกทันทีเพื่อคืนการควบคุมให้ผู้เล่น
			HUB.Navigating = false
			setSprinting(false)
		end
		return
	end

	-- Throttle update ทุก 0.5 วินาที เพื่อไม่ให้แย่งกันคำนวณซ้ำซ้อน
	if now - _lastAnchorUpdate < 0.5 then return end
	_lastAnchorUpdate = now

	-- หากผู้เล่นหยุดเดินเองเกิน 1.2 วินาที และไม่ได้อยู่ในโหมดนำทางของ HUB
	if not HUB.Navigating and (now - (HUB.LastManualMoveTime or 0) >= 1.2) then
		if not HUB.FarmAnchor or (HUB.FarmAnchor - root.Position).Magnitude > 25 then
			HUB.FarmAnchor = root.Position
		end
	end
end

-- =========================================================================
-- Central Pathfinding Navigation Engine (Smart Navigation Engine v9.8)
-- ป้องกันเดินติดขอบเหว (Barrier_Sky), ซุ้มฟักทองจุดเกิด (EventBooth) และตรวจจับความเร็วจริงคำนวณทางใหม่ทันที
-- =========================================================================
local function snapToGround(pos, fallbackY)
	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Exclude
	local char = LocalPlayer.Character
	if char then rp.FilterDescendantsInstances = {char} end
	local hit = workspace:Raycast(pos + Vector3.new(0, 6, 0), Vector3.new(0, -32, 0), rp)
	if hit and hit.Instance and hit.Instance.CanCollide then
		return Vector3.new(pos.X, hit.Position.Y + 2.5, pos.Z)
	end
	return Vector3.new(pos.X, fallbackY or pos.Y, pos.Z)
end

local function getWhiskerAvoidance(curPos, moveDir)
	if moveDir.Magnitude < 0.1 then return Vector3.zero end
	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Exclude
	local char = LocalPlayer.Character
	if char then rp.FilterDescendantsInstances = {char} end

	local fRay = workspace:Raycast(curPos + Vector3.new(0, 0.5, 0), moveDir.Unit * 4.2, rp)
	if not fRay then return Vector3.zero end

	local leftDir = (CFrame.Angles(0, math.rad(45), 0):VectorToWorldSpace(moveDir.Unit)).Unit
	local rightDir = (CFrame.Angles(0, math.rad(-45), 0):VectorToWorldSpace(moveDir.Unit)).Unit
	local lRay = workspace:Raycast(curPos + Vector3.new(0, 0.5, 0), leftDir * 4.2, rp)
	local rRay = workspace:Raycast(curPos + Vector3.new(0, 0.5, 0), rightDir * 4.2, rp)

	if not lRay and rRay then
		return leftDir
	elseif not rRay and lRay then
		return rightDir
	elseif not lRay and not rRay then
		return leftDir
	end
	return Vector3.zero
end

local function navigatePath(goalPos, options)
	options = options or {}
	local stopDist = options.stopDistance or 4.0
	local timeout = options.timeout or 30.0
	local shouldAbort = options.shouldAbort
	local customReached = options.customReached
	local sprint = (options.sprint ~= false)
	local emulatePlayerMove = (options.emulatePlayerMove == true)

	local char = LocalPlayer.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if not root or not hum or hum.Health <= 0 then return false end

	HUB.Navigating = true
	if sprint then setSprinting(true) end

	-- Simulated Player Movement (Priority 102 ก่อนหน้า CombatClient 105 เพื่อให้ Auto Play ยอมให้เดินโดยไม่แย่ง 100%)
	local MANUAL_MOVE_BIND = "HuntingTogetherHub_SimulatedManualMove"
	local activeMoveDir = Vector3.zero
	local isManualMoveBound = false

	local function ensureManualMoveBound()
		if not isManualMoveBound then
			isManualMoveBound = true
			pcall(RunService.BindToRenderStep, RunService, MANUAL_MOVE_BIND, Enum.RenderPriority.Input.Value + 2, function()
				if activeMoveDir and activeMoveDir.Magnitude > 0.1 then
					local ch = LocalPlayer.Character
					local h = ch and ch:FindFirstChildOfClass("Humanoid")
					if h and h.Health > 0 then
						h:Move(activeMoveDir, false)
					end
				end
			end)
		end
	end

	local function cleanupManualMove()
		if isManualMoveBound then
			isManualMoveBound = false
			pcall(RunService.UnbindFromRenderStep, RunService, MANUAL_MOVE_BIND)
		end
		activeMoveDir = Vector3.zero
	end

	local function checkAbort()
		if not HUB.Alive or EXEC.env.HuntingTogetherHub_Token ~= MY_TOKEN then return true end
		if isPlayerManualInput() then return true end
		if shouldAbort and shouldAbort() then return true end
		char = LocalPlayer.Character
		root = char and char:FindFirstChild("HumanoidRootPart")
		hum = char and char:FindFirstChildOfClass("Humanoid")
		if not root or not hum or hum.Health <= 0 then return true end
		return false
	end

	local effectiveGoal = goalPos

	local function computeWaypoints(fromPos, toPos)
		local groundFrom = snapToGround(fromPos, fromPos.Y)
		local groundTo = snapToGround(toPos, toPos.Y)
		effectiveGoal = groundTo

		local function createAndRun(fP, tP)
			local path = PathfindingService:CreatePath({
				AgentRadius = 2.6,
				AgentHeight = 5.0,
				AgentCanJump = true,
				WaypointSpacing = 4.0,
			})
			local ok = pcall(function() path:ComputeAsync(fP, tP) end)
			local st = ok and path.Status
			local pts = (st == Enum.PathStatus.Success) and path:GetWaypoints() or nil
			pcall(path.Destroy, path)
			if pts and #pts > 1 then
				local list = {}
				for i = 1, #pts do
					list[i] = { Position = pts[i].Position, Action = pts[i].Action }
				end
				return list, st
			end
			return nil, st
		end

		-- ขั้นที่ 1: พยายามคำนวณเส้นทางสมบูรณ์ (Enum.PathStatus.Success เท่านั้น)
		local extracted, lastSt = createAndRun(groundFrom, groundTo)
		if extracted then return extracted end

		-- ขั้นที่ 2: Goal Sanitization (ขยับจุดเป้าหมาย 8 ทิศทางรอบด้าน 4.5 studs)
		local offsets = {
			Vector3.new(0, 0, -4.5), Vector3.new(0, 0, 4.5),
			Vector3.new(-4.5, 0, 0), Vector3.new(4.5, 0, 0),
			Vector3.new(-3.5, 0, -3.5), Vector3.new(3.5, 0, -3.5),
			Vector3.new(-3.5, 0, 3.5), Vector3.new(3.5, 0, 3.5),
		}
		for _, off in ipairs(offsets) do
			local testGoal = snapToGround(groundTo + off, groundTo.Y)
			extracted = createAndRun(groundFrom, testGoal)
			if extracted then
				effectiveGoal = testGoal
				return extracted
			end
		end

		-- ขั้นที่ 3: Start Sanitization (หากจุดเริ่มต้นชิดกำแพง/ขอบเหว ขยับจุดเริ่มต้น 4.5 studs)
		for _, off in ipairs(offsets) do
			local testStart = snapToGround(groundFrom + off, groundFrom.Y)
			extracted = createAndRun(testStart, groundTo)
			if extracted then
				return extracted
			end
		end

		-- ขั้นที่ 4: Bridge/Stairs Waypoint Check (หาบันไดและสะพานที่เชื่อมระหว่างพื้นที่ เพื่อเดินข้ามโซนผ่านบันได)
		local bf = workspace:FindFirstChild("Map") and workspace.Map:FindFirstChild("BlockFields")
		if bf and math.abs(groundFrom.Z - groundTo.Z) >= 60.0 then
			local bridges = {}
			for _, field in ipairs(bf:GetChildren()) do
				local b = field:FindFirstChild("Bridge")
				if b then
					local p = b:GetPivot().Position
					if p.Z < -100 then
						table.insert(bridges, { z = p.Z, y = p.Y })
					end
				end
			end
			table.sort(bridges, function(a, b) return a.z < b.z end)

			local activePortals = { groundFrom }
			local walkingNorth = (groundFrom.Z < groundTo.Z)

			if walkingNorth then
				for _, b in ipairs(bridges) do
					if b.z > (groundFrom.Z + 25.0) and b.z < (groundTo.Z - 25.0) then
						local top = snapToGround(Vector3.new(0, b.y + 5.0, b.z), b.y)
						local bottom = snapToGround(Vector3.new(0, b.y - 15.0, b.z + 55.0), b.y)
						table.insert(activePortals, top)
						table.insert(activePortals, bottom)
					end
				end
			else
				for i = #bridges, 1, -1 do
					local b = bridges[i]
					if b.z < (groundFrom.Z - 25.0) and b.z > (groundTo.Z + 25.0) then
						local bottom = snapToGround(Vector3.new(0, b.y - 15.0, b.z + 55.0), b.y)
						local top = snapToGround(Vector3.new(0, b.y + 5.0, b.z), b.y)
						table.insert(activePortals, bottom)
						table.insert(activePortals, top)
					end
				end
			end
			table.insert(activePortals, groundTo)

			if #activePortals > 2 then
				local chainedWaypoints = {}
				for s = 1, #activePortals - 1 do
					local pA = activePortals[s]
					local pB = activePortals[s + 1]
					local segWps = createAndRun(pA, pB)
					if segWps and #segWps > 0 then
						for i = (s == 1 and 1 or 2), #segWps do
							table.insert(chainedWaypoints, segWps[i])
						end
					else
						-- Fallback บนตัวบันได/สะพาน (Linear bridge interpolation ตามแนว X = 0)
						local d = (pB - pA).Magnitude
						local steps = math.max(1, math.floor(d / 6.0))
						for step = 1, steps do
							local alpha = step / steps
							local mid = pA:Lerp(pB, alpha)
							table.insert(chainedWaypoints, { Position = mid, Action = Enum.PathWaypointAction.Walk })
						end
					end
				end

				if #chainedWaypoints > 0 then
					return chainedWaypoints
				end
			end
		end

		-- Fallback สุดท้าย: เดินตรงสู่เป้าหมาย
		return { { Position = groundTo, Action = Enum.PathWaypointAction.Walk } }
	end

	local function computeDetourWaypoints(fromPos, targetGoal, stuckPos, moveDir)
		local flatDir = Vector3.new(moveDir.X, 0, moveDir.Z)
		if flatDir.Magnitude < 0.1 then flatDir = Vector3.new(0, 0, 1) end
		flatDir = flatDir.Unit

		-- เวกเตอร์ตั้งฉาก ซ้าย / ขวา (90 องศา)
		local leftPerp = Vector3.new(-flatDir.Z, 0, flatDir.X)
		local rightPerp = Vector3.new(flatDir.Z, 0, -flatDir.X)

		-- ตรวจสอบด้วย Raycast ว่าด้านซ้ายหรือขวามีสิ่งกีดขวางน้อยกว่า (หาช่องทางโล่ง)
		local rp = RaycastParams.new()
		rp.FilterType = Enum.RaycastFilterType.Exclude
		local ch = LocalPlayer.Character
		if ch then rp.FilterDescendantsInstances = {ch} end

		local leftClearDist = 14.0
		local rightClearDist = 14.0
		local lHit = workspace:Raycast(stuckPos + Vector3.new(0, 1.5, 0), leftPerp * 14.0, rp)
		if lHit then leftClearDist = (lHit.Position - stuckPos).Magnitude end
		local rHit = workspace:Raycast(stuckPos + Vector3.new(0, 1.5, 0), rightPerp * 14.0, rp)
		if rHit then rightClearDist = (rHit.Position - stuckPos).Magnitude end

		-- เลือกด้านที่เปิดกว้างกว่า
		local chosenDir = (leftClearDist >= rightClearDist) and leftPerp or rightPerp
		local detourDist = math.max(6.0, math.min(13.0, math.max(leftClearDist, rightClearDist) - 1.5))

		-- วางจุดแวะเบี่ยง (Intermediate Detour Waypoint) ออกด้านข้างและถอยออกจากสิ่งกีดขวางเล็กน้อย
		local detourPoint = snapToGround(stuckPos + chosenDir * detourDist - flatDir * 2.5, fromPos.Y)

		-- คำนวณเส้นทาง 2 ช่วง (2-Leg Path)
		local leg1 = computeWaypoints(fromPos, detourPoint)
		local leg2 = computeWaypoints(detourPoint, targetGoal)

		if leg1 and #leg1 > 0 and leg2 and #leg2 > 0 then
			local combined = {}
			for _, wp in ipairs(leg1) do table.insert(combined, wp) end
			for i = 2, #leg2 do table.insert(combined, leg2[i]) end
			return combined, detourPoint, chosenDir
		elseif leg2 and #leg2 > 0 then
			return leg2, detourPoint, chosenDir
		end
		return computeWaypoints(fromPos, targetGoal), detourPoint, chosenDir
	end

	local waypoints = computeWaypoints(root.Position, goalPos)
	local wpIndex = (waypoints and #waypoints > 1) and 2 or 1

	local startTime = os.clock()
	local lastSampleTime = os.clock()
	local lastSamplePos = root.Position
	local stuckAccumTime = 0
	local lastStuckPos = nil
	local consecutiveStuckCount = 0
	local reached = false

	while (os.clock() - startTime < timeout) and not checkAbort() do
		local curPos = root.Position
		local distToGoal = math.min(
			Vector3.new(goalPos.X - curPos.X, 0, goalPos.Z - curPos.Z).Magnitude,
			Vector3.new(effectiveGoal.X - curPos.X, 0, effectiveGoal.Z - curPos.Z).Magnitude
		)
		if distToGoal <= stopDist or (customReached and customReached(curPos)) then
			reached = true
			break
		end

		-- เลื่อน Waypoint Index ตามระยะประชิด (รัศมี 2.6 studs ป้องกัน Corner Cutting เข้าขอบเหวหรือซุ้มฟักทอง)
		if waypoints and #waypoints > 0 then
			local curWp = waypoints[wpIndex]
			while curWp do
				local xzDist = Vector3.new(curWp.Position.X - curPos.X, 0, curWp.Position.Z - curPos.Z).Magnitude
				if xzDist < 2.6 then
					wpIndex = wpIndex + 1
					curWp = waypoints[wpIndex]
					if curWp and curWp.Action == Enum.PathWaypointAction.Jump then
						hum.Jump = true
					end
				else
					break
				end
			end
		end

		local nextTarget = (waypoints and waypoints[wpIndex] and waypoints[wpIndex].Position) or effectiveGoal
		local flatDelta = Vector3.new(nextTarget.X - curPos.X, 0, nextTarget.Z - curPos.Z)
		local moveDir = (flatDelta.Magnitude > 0.3) and flatDelta.Unit or Vector3.zero

		-- Real-time Whisker Avoidance: เบี่ยงเวกเตอร์เป้าหมายหลบสิ่งกีดขวางระดับลำตัวก่อนชน
		local whiskerOffset = getWhiskerAvoidance(curPos, moveDir)
		local steerTarget = nextTarget
		local finalDir = moveDir
		if whiskerOffset.Magnitude > 0 then
			steerTarget = nextTarget + whiskerOffset * 2.5
			local steerDelta = Vector3.new(steerTarget.X - curPos.X, 0, steerTarget.Z - curPos.Z)
			if steerDelta.Magnitude > 0.3 then
				finalDir = steerDelta.Unit
			end
		end

		if emulatePlayerMove then
			ensureManualMoveBound()
			activeMoveDir = finalDir
		else
			hum:MoveTo(steerTarget)
		end

		-- Velocity-Based Stuck Detection: ตรวจจับการเคลื่อนที่แนวราบ XZ เทียบกับ WalkSpeed จริง
		local dt = os.clock() - lastSampleTime
		if dt >= 0.40 then
			local flatMoved = Vector3.new(curPos.X - lastSamplePos.X, 0, curPos.Z - lastSamplePos.Z).Magnitude
			local currentSpeed = hum.WalkSpeed
			if currentSpeed <= 0 then currentSpeed = 16 end
			local expectedDist = currentSpeed * dt

			if flatMoved < (expectedDist * 0.22) then
				stuckAccumTime = stuckAccumTime + dt

				if stuckAccumTime >= 0.40 and stuckAccumTime < 0.80 then
					hum.Jump = true
				elseif stuckAccumTime >= 0.80 then
					-- ตรวจสอบระยะห่างจากจุดติดครั้งก่อนหน้า
					if lastStuckPos and (curPos - lastStuckPos).Magnitude <= 8.5 then
						consecutiveStuckCount = consecutiveStuckCount + 1
					else
						consecutiveStuckCount = 1
						lastStuckPos = curPos
					end

					-- Tier 4: Max Retry Guard (หากติดซ้ำที่จุดเดิมเกิน 3 ครั้ง ให้ตัดจบลูปทันที เพื่อไม่ให้เกิด Ping-Pong Loop)
					if consecutiveStuckCount >= 4 then
						warn("[Hunting Together Hub] NavigatePath: ติดสิ่งกีดขวางที่พิกัดเดิมเกิน 3 ครั้ง — ตัดจบลูปตาม Max Retry Guard เพื่อป้องกันการเดินวน")
						break
					end

					local flatDir = (moveDir.Magnitude > 0.1) and moveDir.Unit or Vector3.new(0, 0, 1)
					local leftPerp = Vector3.new(-flatDir.Z, 0, flatDir.X)
					local rightPerp = Vector3.new(flatDir.Z, 0, -flatDir.X)

					-- ยิง Raycast เช็คทิศทางโล่งด้านข้าง
					local rp = RaycastParams.new()
					rp.FilterType = Enum.RaycastFilterType.Exclude
					local ch = LocalPlayer.Character
					if ch then rp.FilterDescendantsInstances = {ch} end

					local lHit = workspace:Raycast(curPos + Vector3.new(0, 1.5, 0), leftPerp * 10.0, rp)
					local rHit = workspace:Raycast(curPos + Vector3.new(0, 1.5, 0), rightPerp * 10.0, rp)
					local leftDist = lHit and (lHit.Position - curPos).Magnitude or 10.0
					local rightDist = rHit and (rHit.Position - curPos).Magnitude or 10.0
					local sideDir = (leftDist >= rightDist) and leftPerp or rightPerp

					if consecutiveStuckCount == 1 then
						-- Tier 1: ติดครั้งแรก -> Lateral Evasion (ฉากหลบออกด้านข้าง 90 องศา 6 studs + กระโดด ไม่ถอยหลังตรงๆ 180 องศา)
						pcall(function()
							local evadeTarget = curPos + sideDir * 6.0 - flatDir * 1.5
							hum.Jump = true
							if emulatePlayerMove then
								ensureManualMoveBound()
								activeMoveDir = (sideDir * 0.85 - flatDir * 0.25).Unit
							else
								hum:MoveTo(evadeTarget)
							end
							task.wait(0.25)
						end)
						char = LocalPlayer.Character
						root = char and char:FindFirstChild("HumanoidRootPart")
						if root then
							-- ข้าม Waypoint ปัจจุบันที่ติดไปยัง Waypoint ถัดไป
							if waypoints and wpIndex < #waypoints then
								wpIndex = wpIndex + 1
							end
							lastSamplePos = root.Position
							lastSampleTime = os.clock()
							stuckAccumTime = 0
						end
					else
						-- Tier 2 & 3: ติดซ้ำที่จุดเดิม (ครั้งที่ 2 หรือ 3) -> Dynamic 2-Leg Detour Pathfinding (สร้างเส้นทางอ้อมจริง)
						pcall(function()
							local evadeTarget = curPos + sideDir * 8.0 - flatDir * 3.0
							hum.Jump = true
							if emulatePlayerMove then
								ensureManualMoveBound()
								activeMoveDir = (sideDir * 0.85 - flatDir * 0.35).Unit
							else
								hum:MoveTo(evadeTarget)
							end
							task.wait(0.35)
						end)
						char = LocalPlayer.Character
						root = char and char:FindFirstChild("HumanoidRootPart")
						if root then
							local detourWps, detourPoint, chosenDir = computeDetourWaypoints(root.Position, goalPos, root.Position, flatDir)
							if detourWps and #detourWps > 0 then
								waypoints = detourWps
								wpIndex = (waypoints and #waypoints > 1) and 2 or 1
							else
								waypoints = computeWaypoints(root.Position, goalPos)
								wpIndex = (waypoints and #waypoints > 1) and 2 or 1
							end
							lastSamplePos = root.Position
							lastSampleTime = os.clock()
							stuckAccumTime = 0
						end
					end
				end
			else
				stuckAccumTime = math.max(0, stuckAccumTime - dt * 2)
				if (curPos - (lastStuckPos or curPos)).Magnitude > 12.0 then
					consecutiveStuckCount = 0
				end
				lastSamplePos = curPos
				lastSampleTime = os.clock()
			end
		end

		task.wait(0.05)
	end

	-- Cleanup & Restore State
	if emulatePlayerMove then
		cleanupManualMove()
	end
	pcall(function()
		local c = LocalPlayer.Character
		local h = c and c:FindFirstChildOfClass("Humanoid")
		if h then
			h:Move(Vector3.zero, false)
		end
	end)
	if sprint then setSprinting(false) end
	HUB.Navigating = false

	return reached
end
HUB.NavigatePath = navigatePath

-- =========================================================================
-- Central Pillar Warp Synchronization Engine (Zero Silver Drain & Handshake Guaranteed)
-- =========================================================================
local function executePillarWarp(nearPillar, targetPillarId, shouldAbortFn)
	if not nearPillar or not targetPillarId then return false end
	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
	local pillarWarp = remotes and remotes:FindFirstChild("PillarWarp")
	if not pillarWarp then return false end

	local char = LocalPlayer.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if not root or not hum or hum.Health <= 0 then return false end

	local currentWarpId = nearPillar:GetAttribute("WarpId")
	local warpPillarsFolder = workspace:FindFirstChild("Map") and workspace.Map:FindFirstChild("WarpPillars")
	local targetPillarModel = warpPillarsFolder and warpPillarsFolder:FindFirstChild("WarpPillar_" .. targetPillarId)

	-- 0. SAME-PILLAR SKIP: หากอยู่ที่เสาปลายทางอยู่แล้ว คืนค่า true ทันที ไม่ต้องกดเสาและไม่เสีย Silver
	if currentWarpId == targetPillarId then
		return true
	end
	if targetPillarModel then
		local dToTarget = (root.Position - targetPillarModel:GetPivot().Position).Magnitude
		if dToTarget <= 45.0 then
			return true
		end
	end

	-- 0.1 PRE-FLIGHT VALIDATION: ตรวจสอบความถูกต้องของเสาปลายทางก่อนเริ่มเดิน
	-- 0.1.1 ตรวจสอบว่าเสาปลายทางถูกปลดล็อคแล้วจริงหรือไม่
	if targetPillarId ~= "Town" then
		local unlockedStr = LocalPlayer:GetAttribute("WarpPillars") or ""
		local isUnlocked = false
		for pId in string.gmatch(unlockedStr, "([^,]+)") do
			if pId == targetPillarId then
				isUnlocked = true
				break
			end
		end
		if not isUnlocked then
			warn(string.format("[Hunting Together Hub] Pillar Warp: เสาปลายทาง %s ยังไม่ถูกปลดล็อค — ยกเลิกการวาร์ป", tostring(targetPillarId)))
			return false
		end
	end

	-- 0.1.2 ตรวจสอบ Silver ว่าพอจ่ายค่าวาร์ปหรือไม่
	local cost = (targetPillarId ~= "Town" and tonumber((string.match(targetPillarId, "(%d+)$"))) or 0) * 1000
	local silver = LocalPlayer:GetAttribute("Silver") or 0
	if cost > 0 and silver < cost then
		warn(string.format("[Hunting Together Hub] Pillar Warp: Silver ไม่พอวาร์ปไป %s (ต้องการ %d, มี %d) — ยกเลิก", tostring(targetPillarId), cost, silver))
		return false
	end

	-- 0.5 ปิด Auto Play และล้างเป้าก่อนเดินเข้าหาเสา 100% เพื่อไม่ให้ CombatClient ดึงตัวละครกลับไปตีมอนสเตอร์
	if HUB.DisableGameAutoPlay then
		HUB.DisableGameAutoPlay()
	end

	local fpp = EXEC.fireproximityprompt or rawget(getgenv(), "fireproximityprompt")
	local warpedOk = false
	local startRootPos = root.Position
	local MAX_WARP_ATTEMPTS = 3

	for attempt = 1, MAX_WARP_ATTEMPTS do
		if shouldAbortFn and shouldAbortFn() then break end

		char = LocalPlayer.Character
		root = char and char:FindFirstChild("HumanoidRootPart")
		hum = char and char:FindFirstChildOfClass("Humanoid")
		if not root or not hum or hum.Health <= 0 then return false end

		-- 1. เข้าประชิดหน้าเสา (ห่างจากแกนเสา ~4.2 studs ในระยะ ProximityPrompt 12 studs เสมอ)
		-- หากเป็นการ Retry รอบที่ 2-3 หรือตัวละครถูกมอนสเตอร์ชนกระเด็น ให้เดินกลับมาแนบเสาใหม่เสมอ
		local piv = nearPillar:GetPivot().Position
		local flatDist = Vector3.new(root.Position.X - piv.X, 0, root.Position.Z - piv.Z).Magnitude
		if flatDist > 6.8 or attempt > 1 then
			if HUB.DisableGameAutoPlay then HUB.DisableGameAutoPlay() end
			local approachDir = (flatDist > 0.5) and Vector3.new(root.Position.X - piv.X, 0, root.Position.Z - piv.Z).Unit or Vector3.new(0, 0, -1)
			local standY = (currentWarpId == "Town") and 4.25 or (piv.Y + 2.0)
			local standPos = Vector3.new(piv.X + approachDir.X * 4.2, standY, piv.Z + approachDir.Z * 4.2)
			local walkTimeout = (attempt == 1) and math.max(25.0, math.ceil(flatDist / 12.0) + 15.0) or 8.0
			navigatePath(standPos, {
				stopDistance = 3.0,
				timeout = walkTimeout,
				sprint = true,
				shouldAbort = shouldAbortFn,
				customReached = function(curPos)
					return Vector3.new(curPos.X - piv.X, 0, curPos.Z - piv.Z).Magnitude <= 6.8
				end,
			})
			char = LocalPlayer.Character
			root = char and char:FindFirstChild("HumanoidRootPart")
			hum = char and char:FindFirstChildOfClass("Humanoid")
			if not root or not hum or hum.Health <= 0 then return false end
		end

		-- 2. หยุดความเร็วกายภาพตัวละครให้สนิท 100% (AssemblyLinearVelocity = 0) ป้องกัน Desync / Rubber-band
		setSprinting(false)
		pcall(function()
			hum:Move(Vector3.zero, false)
			hum:MoveTo(root.Position)
			root.AssemblyLinearVelocity = Vector3.zero
			root.AssemblyAngularVelocity = Vector3.zero
		end)
		task.wait(0.2)

		-- เช็ค Silver ก่อน เพื่อตรวจสอบผลกระทบจริง
		local silverBefore = LocalPlayer:GetAttribute("Silver") or 0

		-- กระตุ้น ProximityPrompt
		local prompt = nearPillar:FindFirstChildWhichIsA("ProximityPrompt", true)
		if prompt and type(fpp) == "function" then
			pcall(fpp, prompt, 0)
		end
		task.wait(0.2)

		-- ส่งคำสั่งวาร์ปไปยังเซิร์ฟเวอร์
		pillarWarp:FireServer(targetPillarId)

		-- ปิด UI เสาวาร์ปของเกมที่อาจเด้งขึ้นมา
		pcall(function()
			local pg = LocalPlayer:FindFirstChild("PlayerGui")
			local wpGui = pg and (pg:FindFirstChild("HuntWarpPillar") or pg:FindFirstChild("LumiPage_HuntWarpPillar"))
			if wpGui then wpGui.Enabled = false end
		end)

		-- รอการเทเลพอร์ตทางกายภาพ (สูงสุด 4.5 วินาที)
		local wT0 = os.clock()
		while os.clock() - wT0 < 4.5 and not (shouldAbortFn and shouldAbortFn()) do
			task.wait(0.1)
			char = LocalPlayer.Character
			root = char and char:FindFirstChild("HumanoidRootPart")
			if root then
				if targetPillarId == "Town" then
					if root.Position.Z > -250 then
						warpedOk = true
						break
					end
				else
					if targetPillarModel then
						local d = (root.Position - targetPillarModel:GetPivot().Position).Magnitude
						if d <= 60.0 then
							warpedOk = true
							break
						end
					else
						if (root.Position - startRootPos).Magnitude > 120.0 then
							warpedOk = true
							break
						end
					end
				end
			end
		end

		if warpedOk then break end

		-- หากยังไม่วาร์ป แต่เงิน Silver ถูกหักไปแล้ว แสดงว่า Server กำลังประมวลผล / กำลัง Replicate
		local silverNow = LocalPlayer:GetAttribute("Silver") or 0
		if cost > 0 and (silverBefore - silverNow >= cost) then
			-- เงินลดแล้ว! ห้ามยิงคำสั่งซ้ำเด็ดขาด รอ replicate อีก 2.5 วินาที
			local extraWait = os.clock()
			while os.clock() - extraWait < 2.5 and not (shouldAbortFn and shouldAbortFn()) do
				task.wait(0.1)
				char = LocalPlayer.Character
				root = char and char:FindFirstChild("HumanoidRootPart")
				if root then
					if targetPillarId == "Town" then
						if root.Position.Z > -250 then warpedOk = true break end
					else
						if targetPillarModel then
							local d = (root.Position - targetPillarModel:GetPivot().Position).Magnitude
							if d <= 60.0 then warpedOk = true break end
						else
							if (root.Position - startRootPos).Magnitude > 120.0 then warpedOk = true break end
						end
					end
				end
			end
			if warpedOk then break end
			break -- ป้องกันการเสียเงินซ้ำเด็ดขาด
		end

		if attempt < MAX_WARP_ATTEMPTS then
			warn(string.format("[Hunting Together Hub] Pillar Warp: วาร์ปไปเสา %s ล้มเหลว (รอบที่ %d/%d) — กำลัง Re-approach และลองใหม่...", tostring(targetPillarId), attempt, MAX_WARP_ATTEMPTS))
			task.wait(0.4)
		end
	end

	if warpedOk then
		root = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
		if root then
			local tWarpDone = os.clock()
			while (root.Anchored and os.clock() - tWarpDone < 1.8) do
				task.wait(0.08)
			end
			pcall(function()
				LocalPlayer:RequestStreamAroundAsync(root.Position, 3)
			end)
			task.wait(0.15)
		end
	end

	return warpedOk
end
HUB.ExecutePillarWarp = executePillarWarp

-- =========================================================================
-- Central Origin & Return Synchronization Engine (Auto Sell & Auto Boss Shared)
-- =========================================================================
local function captureOriginIfNeeded()
	local char = LocalPlayer.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if not root then return end

	-- ห้ามจำพิกัดในเมือง (Z > -250) เป็นจุดฟาร์มเด็ดขาด ป้องกัน Origin ปนเปื้อน
	if root.Position.Z > -250 then return end

	-- ห้ามจำพิกัดหน้าเสาวาร์ป (ระยะ <= 35 studs จากเสาใดๆ) เป็นจุดฟาร์ม
	local warpPillarsFolder = workspace:FindFirstChild("Map") and workspace.Map:FindFirstChild("WarpPillars")
	if warpPillarsFolder then
		for _, p in ipairs(warpPillarsFolder:GetChildren()) do
			if (p:GetPivot().Position - root.Position).Magnitude <= 35.0 then
				return
			end
		end
	end

	if HUB.OriginCFrame == nil then
		HUB.OriginCFrame = root.CFrame
		-- หากจุดเริ่มต้นอยู่ในโซนล่ามอนสเตอร์นอกเมือง (Z < -300) ให้ถือว่าต้องกลับมาเปิด Auto Play ฟาร์มต่อเสมอ
		HUB.OriginAutoOn = (root.Position.Z < -300) or (HUB.IsGameAutoActive and HUB.IsGameAutoActive()) or (LocalPlayer:GetAttribute("AutoOn") == true)
		-- จดจำสถานะ Party Follow ก่อนเริ่มรูทีน (เพื่อ Re-sync หลังเดินทางกลับ)
		HUB.OriginFollowUserId = tonumber(LocalPlayer:GetAttribute("LumiFollowUserId"))
	end
	return HUB.OriginCFrame
end
HUB.CaptureOriginIfNeeded = captureOriginIfNeeded

local function clearOrigin()
	HUB.OriginCFrame = nil
	HUB.OriginAutoOn = nil
	HUB.OriginFollowUserId = nil
end
HUB.ClearOrigin = clearOrigin

local function getNearbyBossPillar(pos)
	if not pos then return nil, math.huge, nil end
	local warpPillarsFolder = workspace:FindFirstChild("Map") and workspace.Map:FindFirstChild("WarpPillars")
	if not warpPillarsFolder then return nil, math.huge, nil end

	for _, bDef in ipairs(BOSS_DEFS) do
		local pModel = warpPillarsFolder:FindFirstChild("WarpPillar_" .. bDef.pillarId)
		if pModel then
			local pPos = pModel:GetPivot().Position
			local dToPillar = (pos - pPos).Magnitude
			local dToArena = (pos - bDef.arenaPos).Magnitude
			-- หากอยู่ในรัศมี 240 studs จากเสา หรือ 160 studs จากห้องบอส ถือว่าอยู่ในโซนบอสนี้อย่างแน่นอน
			if dToPillar <= 240.0 or dToArena <= 160.0 then
				return pModel, dToPillar, bDef
			end
		end
	end
	return nil, math.huge, nil
end
HUB.GetNearbyBossPillar = getNearbyBossPillar

local function getNearestUnlockedPillar(pos)
	if not pos then return nil, math.huge end
	local warpPillarsFolder = workspace:FindFirstChild("Map") and workspace.Map:FindFirstChild("WarpPillars")
	if not warpPillarsFolder then return nil, math.huge end
	local unlockedStr = LocalPlayer:GetAttribute("WarpPillars") or ""
	local unlockedSet = { Town = true }
	for pId in string.gmatch(unlockedStr, "([^,]+)") do
		unlockedSet[pId] = true
	end

	local nearestP, minD = nil, math.huge
	for _, p in ipairs(warpPillarsFolder:GetChildren()) do
		local warpId = p:GetAttribute("WarpId") or string.gsub(p.Name, "^WarpPillar_", "")
		if unlockedSet[warpId] == true then
			local d = (p:GetPivot().Position - pos).Magnitude
			if d < minD then
				minD = d
				nearestP = p
			end
		end
	end
	return nearestP, minD
end
HUB.GetNearestUnlockedPillar = getNearestUnlockedPillar

local function resumeFarmOrFollow(targetPos)
	local followUid = HUB.OriginFollowUserId
	local restoredFollow = false

	if followUid then
		local inMyParty = false
		pcall(function()
			local partyJson = LocalPlayer:GetAttribute("PartyJson")
			if type(partyJson) == "string" and #partyJson > 0 then
				local data = HttpService:JSONDecode(partyJson)
				if data and data.Members then
					for _, m in ipairs(data.Members) do
						if m.UserId == followUid then
							inMyParty = true
							break
						end
					end
				end
			end
		end)

		if inMyParty then
			local followEv = LocalPlayer:FindFirstChild("LumiPartyFollow")
			if followEv and followEv:IsA("BindableEvent") then
				followEv:Fire(followUid)
				restoredFollow = true
			end
		end
	end

	if not restoredFollow then
		if (targetPos and targetPos.Z < -300) or HUB.OriginAutoOn then
			if HUB.EnsureGameAutoActive then
				HUB.EnsureGameAutoActive(6, 0.25)
			end
		end
	end
end

local function returnToOrigin(shouldAbortFn, updateStatusFn)
	local char = LocalPlayer.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if not root or not hum or hum.Health <= 0 then return false end

	local origin = HUB.OriginCFrame
	if not origin then
		return true
	end

	-- ปิด Auto Play ชั่วคราวก่อนเดินทางกลับ เพื่อไม่ให้ถูกมอนสเตอร์ระหว่างทางดึงตัวละครออกนอกเส้นทาง
	if HUB.DisableGameAutoPlay then
		HUB.DisableGameAutoPlay()
	end

	local originPos = origin.Position
	local distToOrigin = (root.Position - originPos).Magnitude

	-- 1. ถ้าอยู่ใกล้จุดหมายเดิมอยู่แล้ว (<= 250 studs เช่น อยู่ในเมืองอยู่แล้ว หรือฟาร์มหน้าห้องบอสที่เพิ่งตี)
	-- ไม่ต้องกดเสาวาร์ปใดๆ ทั้งสิ้น เดิน navigatePath กลับได้ทันที
	if distToOrigin <= 250.0 then
		if updateStatusFn then
			updateStatusFn("สถานะ: กำลังเดินกลับจุดเริ่มต้น...")
		end
		navigatePath(originPos, {
			stopDistance = 8.0,
			timeout = 45.0,
			sprint = true,
			shouldAbort = shouldAbortFn,
		})
		char = LocalPlayer.Character
		root = char and char:FindFirstChild("HumanoidRootPart")
		if root and not (shouldAbortFn and shouldAbortFn()) then
			resumeFarmOrFollow(originPos)
			clearOrigin()
			return true
		end
		return false
	end

	-- 2. อยู่คนละโซน (> 250 studs): ต้องเดินทางผ่านเสาวาร์ป
	local warpPillarsFolder = workspace:FindFirstChild("Map") and workspace.Map:FindFirstChild("WarpPillars")
	local unlockedStr = LocalPlayer:GetAttribute("WarpPillars") or ""
	local unlocked = {}
	for pId in string.gmatch(unlockedStr, "([^,]+)") do
		unlocked[pId] = true
	end

	-- หาเสาวาร์ปที่ใกล้จุด origin ที่สุด (อนุญาตเสา "Town" ด้วย)
	local returnPillarId = nil
	local minPillarDist = math.huge
	if warpPillarsFolder then
		for _, p in ipairs(warpPillarsFolder:GetChildren()) do
			local wId = p:GetAttribute("WarpId")
			if wId and (wId == "Town" or unlocked[wId]) then
				local d = (p:GetPivot().Position - originPos).Magnitude
				if d < minPillarDist then
					minPillarDist = d
					returnPillarId = wId
				end
			end
		end
	end

	-- Fallback ถ้าหาไม่เจอ
	if not returnPillarId then
		if originPos.Z > -250 then
			returnPillarId = "Town"
		elseif unlocked["Boss05"] then
			returnPillarId = "Boss05"
		elseif unlocked["Boss04"] then
			returnPillarId = "Boss04"
		else
			returnPillarId = "Boss01"
		end
	end

	-- หาเสาวาร์ปที่อยู่ใกล้ตัวละครปัจจุบัน (<= 350 studs ในโซนเดียวกัน)
	local nearestP, minD = nil, math.huge
	if warpPillarsFolder then
		for _, p in ipairs(warpPillarsFolder:GetChildren()) do
			local d = (p:GetPivot().Position - root.Position).Magnitude
			if d < minD then
				minD = d
				nearestP = p
			end
		end
	end

	-- ตรวจสอบเสาวาร์ปในโซนปัจจุบันด้วย Pillar-First Architecture (Zero Silver Drain & Zero Cooldown)
	local localPillar, distToLocal = getNearbyBossPillar(root.Position)
	local townPillar = warpPillarsFolder and warpPillarsFolder:FindFirstChild("WarpPillar_Town")

	-- หากไม่ได้ตรวจพบผ่าน getNearbyBossPillar แต่มีเสาใกล้ตัวในระยะ <= 240 studs (และไม่ใช่เสาเมืองขณะอยู่นอกเมือง)
	if not localPillar and nearestP and minD <= 240.0 then
		if root.Position.Z <= -200 and nearestP == townPillar then
			localPillar = nil
		else
			localPillar = nearestP
		end
	end

	local currentNearPillar = nil
	local remotes = ReplicatedStorage:FindFirstChild("Remotes")

	if localPillar then
		-- ลำดับ 1 (Pillar-First Priority): มีเสาวาร์ปอยู่หน้าห้องบอสหรือในโซนนี้
		-- ให้เดินไปใช้เสาวาร์ปนี้เดินทางไปยัง returnPillarId ทันที (แม้ returnPillarId จะเป็น "Town" ก็ตาม!)
		-- ข้อดีมหาศาล: เสีย 0 Silver เมื่อวาร์ปไป Town, ใช้เวลา 0.5s, และไม่ทำให้ปุ่ม HomeWarp ติดคูลดาวน์ 60 วินาที!
		currentNearPillar = localPillar
		if updateStatusFn then
			updateStatusFn(string.format("สถานะ: เดินไปเสาวาร์ปหน้าห้องเพื่อเดินทางไปยัง %s...", tostring(returnPillarId)))
		end
	elseif root.Position.Z > -200 and townPillar then
		-- ลำดับ 2: อยู่ในเมืองหลวงอยู่แล้ว ให้ใช้เสาเมืองหลวง
		currentNearPillar = townPillar
	else
		-- ลำดับ 3: อยู่ในทุ่งมอนสเตอร์ลึกๆ ที่ไม่มีเสาวาร์ปในระยะเดินถึง -> ร่าย HomeWarp กลับเมืองหลวง
		if updateStatusFn then updateStatusFn("สถานะ: วาร์ปเข้าเมืองเพื่อต่อเสาวาร์ป...") end

		-- เช็คคูลดาวน์ HomeWarp หากมีเศษคูลดาวน์สั้นๆ (<= 12 วิ) ให้รอให้พร้อมก่อน
		local readyAt = tonumber(LocalPlayer:GetAttribute("HomeWarpReadyAt")) or 0
		local cdLeft = math.max(0, math.ceil(readyAt - workspace:GetServerTimeNow()))
		if cdLeft > 0 and cdLeft <= 12 then
			if updateStatusFn then
				updateStatusFn(string.format("สถานะ: รอ HomeWarp คูลดาวน์อีก %d วิ...", cdLeft))
			end
			local cdT0 = os.clock()
			while (os.clock() - cdT0 < (cdLeft + 0.2)) and not (shouldAbortFn and shouldAbortFn()) do
				task.wait(0.2)
			end
			cdLeft = 0
		end

		local reachedTown = false
		if cdLeft == 0 and not (shouldAbortFn and shouldAbortFn()) then
			if root then root.Anchored = true end
			local homeWarp = remotes and remotes:FindFirstChild("HomeWarp")
			if homeWarp then
				homeWarp:FireServer("start", "merchant")
			else
				local LumiMenuToggle = LocalPlayer:FindFirstChild("LumiMenuToggle")
				if LumiMenuToggle then pcall(function() LumiMenuToggle:Fire("homeWarpMerchant") end) end
			end
			local t0 = os.clock()
			while os.clock() - t0 < 8.0 and not (shouldAbortFn and shouldAbortFn()) do
				task.wait(0.1)
				char = LocalPlayer.Character
				root = char and char:FindFirstChild("HumanoidRootPart")
				if root and root.Position.Z > -200 then
					reachedTown = true
					break
				end
			end
			if root then root.Anchored = false end
		end

		if reachedTown and townPillar then
			currentNearPillar = townPillar
		end
	end

	char = LocalPlayer.Character
	root = char and char:FindFirstChild("HumanoidRootPart")
	if not root then return false end

	-- วาร์ปไปยัง returnPillarId (ถ้ายังไม่ได้อยู่ที่นั่น และมีเสาต้นทางที่ถูกต้อง)
	if currentNearPillar and returnPillarId then
		if updateStatusFn then
			updateStatusFn(string.format("สถานะ: วาร์ปไปยังเสา %s...", tostring(returnPillarId)))
		end
		local okWarp = executePillarWarp(currentNearPillar, returnPillarId, shouldAbortFn)
		-- Caller-Level Smart Retry: หากวาร์ปกลับจุดฟาร์มไม่สำเร็จ ให้ค้นหาเสาใกล้ตัวใหม่และลองอีกครั้ง
		if not okWarp and not (shouldAbortFn and shouldAbortFn()) then
			task.wait(0.4)
			char = LocalPlayer.Character
			root = char and char:FindFirstChild("HumanoidRootPart")
			if root then
				local retryPillar = (root.Position.Z > -200 and townPillar) or getNearbyBossPillar(root.Position)
				if retryPillar then
					if updateStatusFn then
						updateStatusFn(string.format("สถานะ: วาร์ปไม่สำเร็จ — กำลังลองใหม่ไปยังเสา %s...", tostring(returnPillarId)))
					end
					executePillarWarp(retryPillar, returnPillarId, shouldAbortFn)
				end
			end
		end
	end

	char = LocalPlayer.Character
	root = char and char:FindFirstChild("HumanoidRootPart")
	if not root then return false end

	-- Same-Zone Navigation Guard (<= 500 studs):
	-- ห้ามสั่ง navigatePath วิ่งข้ามโซนเด็ดขาดถ้าตัวละครยังอยู่คนละโซน
	local postWarpDist = (root.Position - originPos).Magnitude
	if postWarpDist > 500.0 then
		warn(string.format("[Hunting Together Hub] ReturnToOrigin: ยังอยู่ห่างจากเป้าหมาย %.1f studs (ต่างโซน) — ยกเลิกการวิ่งชนกำแพง", postWarpDist))
		-- Self-Healing: เคลียร์ Origin ที่เป็นไปไม่ได้ทิ้ง และเปิด Auto Play/Follow ในโซนปัจจุบันทันที ป้องกันยืนนิ่ง
		if root.Position.Z <= -300 then
			resumeFarmOrFollow(root.Position)
		end
		clearOrigin()
		return false
	end

	-- ปิด Auto Play อีกครั้งเผื่อถูกกระตุ้นระหว่างวาร์ป ก่อนเดินกลับจุดฟาร์มเดิม
	if HUB.DisableGameAutoPlay then
		HUB.DisableGameAutoPlay()
	end

	-- เดินกลับสู่ originPos
	if updateStatusFn then
		updateStatusFn("สถานะ: ถึงโซนแล้ว กำลังเดินกลับจุดเริ่มต้น...")
	end
	navigatePath(originPos, {
		stopDistance = 8.0,
		timeout = 45.0,
		sprint = true,
		shouldAbort = shouldAbortFn,
	})

	char = LocalPlayer.Character
	root = char and char:FindFirstChild("HumanoidRootPart")
	if root and not (shouldAbortFn and shouldAbortFn()) and (root.Position - originPos).Magnitude <= 250.0 then
		-- เมื่อกลับมาถึงโซนฟาร์มมอนสเตอร์ หรือเคยเปิด Auto Play ไว้ ให้สั่งเปิด Auto Play/Follow ทันที 100%!
		resumeFarmOrFollow(originPos)
		clearOrigin()
		return true
	end

	-- Self-Healing Fallback: ถ้าเดินไม่ถึงใน 45s หรือหลงทาง แต่ตัวละครอยู่ในโซนมอนสเตอร์แล้ว ให้เปิด Auto Play/Follow และเคลียร์ Origin เพื่อไม่ให้ยืนแข็งทื่อ
	if root and root.Position.Z <= -300 then
		resumeFarmOrFollow(root.Position)
		clearOrigin()
	end

	return false
end
HUB.ReturnToOrigin = returnToOrigin

-- 9.1 Auto Open LootBox Worker (วิ่งไปเปิดกล่องสมบัติในระยะฟาร์มของเกม — Cooperative Combat-Aware)
task.spawn(function()
	local remotes = ReplicatedStorage:WaitForChild("Remotes", 10)
	local openBox = remotes and remotes:FindFirstChild("OpenLootBox")
	local pickup = remotes and remotes:FindFirstChild("PickupDrop")

	local function isAlive()
		return HUB.Alive and EXEC.env.HuntingTogetherHub_Token == MY_TOKEN and HUB.Config.autoOpenBox
	end

	while HUB.Alive and EXEC.env.HuntingTogetherHub_Token == MY_TOKEN do
		task.wait(0.3)
		if not HUB.Alive or EXEC.env.HuntingTogetherHub_Token ~= MY_TOKEN then break end

		local char = LocalPlayer.Character
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		local root = char and char:FindFirstChild("HumanoidRootPart")
		if root and hum and hum.Health > 0 and not HUB.IsBossRoutineActive and not HUB.IsSellingRoutineActive then
			updateFarmingAnchor(root)
		end

		if HUB.Config.autoOpenBox and not HUB.Navigating and not HUB.IsBossRoutineActive and not HUB.IsSellingRoutineActive then
			-- หากผู้เล่นกำลังกดเดินเอง หรือเพิ่งหยุดเดิน < 1.0 วิ ให้งดแทรกแซงการเดิน
			if isPlayerManualInput() or (os.clock() - (HUB.LastManualMoveTime or 0) < 1.0) then
				continue
			end

			if hum and root and hum.Health > 0 then
				local radius = getDetectRadius()
				local maxMiniboss = HUB.Config.maxLootBoxMiniboss or 1
				local activeMinibosses = countActiveMinibosses(radius)

				-- หากมี Mini-Boss ในระยะ >= โควต้าที่ตั้งไว้ ให้หยุดเปิดกล่องชั่วคราวเพื่อรอเคลียร์ก่อน
				if activeMinibosses >= maxMiniboss then
					if HUB.UI.BoxStatusLabel then
						HUB.UI.BoxStatusLabel.Text = string.format("สถานะ: รอเคลียร์ Mini-Boss (%d/%d ตัว) ก่อนเปิดกล่องต่อ", activeMinibosses, maxMiniboss)
					end
					task.wait(0.8)
					continue
				end

				local inCombat = isPlayerInActiveCombat()
				local gameAuto = isGameAutoActive()

				local now = workspace:GetServerTimeNow()
				local boxes = CollectionService:GetTagged("LootBox")

				local targetBox = nil
				local minDistance = radius
				for _, box in ipairs(boxes) do
					if box and box.Parent then
						local owner = box:GetAttribute("OwnerUserId")
						local freeAt = box:GetAttribute("FreeAt") or 0
						local canOpen = (owner == nil or owner == 0 or owner == LocalPlayer.UserId) or (now >= freeAt)

						if canOpen then
							local boxPos = box.Position or (box:IsA("Model") and box:GetPivot().Position)
							if boxPos then
								local dist = (boxPos - root.Position).Magnitude
								if dist <= minDistance then
									minDistance = dist
									targetBox = box
								end
							end
						end
					end
				end

				if targetBox and targetBox.Parent then
					local targetPos = targetBox.Position or (targetBox:IsA("Model") and targetBox:GetPivot().Position)
					if targetPos then
						local curDist = (targetPos - root.Position).Magnitude

						local prompt = targetBox:FindFirstChild("OpenPrompt", true) or targetBox:FindFirstChildOfClass("ProximityPrompt")
						local fpp = EXEC.fireproximityprompt or rawget(getgenv(), "fireproximityprompt")

						-- ฟังก์ชันช่วยเปิดกล่องและเก็บของ
						local function doOpenAndCollect()
							if prompt and prompt.Parent then
								if type(fpp) == "function" then
									pcall(fpp, prompt, 0)
								end
								pcall(function()
									prompt:InputHoldBegin()
									task.wait(0.05)
									if prompt.Parent then prompt:InputHoldEnd() end
								end)
							end
							if not openBox and remotes then
								openBox = remotes:FindFirstChild("OpenLootBox")
							end
							if openBox then
								pcall(function() openBox:FireServer(targetBox) end)
							end

							-- รอการเปิดกล่องและตรวจ Ground-Truth
							local t0 = os.clock()
							local opened = false
							while os.clock() - t0 < 0.6 do
								if not targetBox.Parent or targetBox:GetAttribute("OpenTitle") or not targetBox:FindFirstChild("OpenPrompt", true) then
									opened = true
									break
								end
								task.wait(0.05)
							end

							if opened or not targetBox.Parent then
								HUB.Stats.boxesOpened = HUB.Stats.boxesOpened + 1
								if HUB.UI.StatBoxCount then
									HUB.UI.StatBoxCount.Text = tostring(HUB.Stats.boxesOpened) .. " กล่อง"
								end
								if HUB.UI.BoxStatusLabel then
									local limit = HUB.Config.maxLootBoxMiniboss or 1
									HUB.UI.BoxStatusLabel.Text = string.format("สถานะ: เปิดใช้งาน · เปิดแล้ว %d (จำกัด Mini-Boss %d ตัว)", HUB.Stats.boxesOpened, limit)
								end
							end

							-- สั่งดูดไอเทมที่ดรอปจากกล่อง
							task.wait(0.12)
							if not pickup and remotes then
								pickup = remotes:FindFirstChild("PickupDrop")
							end
							if pickup then
								pcall(function() pickup:FireServer(true) end)
							end
						end

						-- ฟังก์ชันช่วยจัดการล็อกเป้าหมายหลังเปิดกล่องสมบัติ (Tiered Target Handoff 0 ms)
						local function handoffCombatAfterBox(originPos, targetPos)
							task.wait(0.15)
							char = LocalPlayer.Character
							root = char and char:FindFirstChild("HumanoidRootPart")
							if not root or not isAlive() or isPlayerManualInput() then return end

							-- ลำดับ 1 (ความสำคัญสูงสุด): ตรวจจับมอนสเตอร์ที่เกิด/โผล่ออกมาจากกล่องสมบัติโดยตรง (Mimic / Trap / Spawned Mob)
							local boxMonster = findMonsterFromBox(targetPos, 12.0)
							if boxMonster then
								local lock = LocalPlayer:FindFirstChild("LumiLockTarget")
								if lock and lock:IsA("BindableEvent") then
									lock:Fire(boxMonster)
								end
								return
							end

							-- ลำดับ 2: ถ้าไม่มีมอนสเตอร์จากกล่อง ให้ดูว่ามีมอนสเตอร์อื่นรอบตัวในระยะ <= 35 studs และอยู่ในโซนฟาร์ม (<= 40 studs จาก FarmAnchor)
							local curDistToAnchor = (originPos - root.Position).Magnitude
							local nearMonster = findNearestLiveMonster(root.Position, 35.0)
							if nearMonster and curDistToAnchor <= 40.0 then
								local lock = LocalPlayer:FindFirstChild("LumiLockTarget")
								if lock and lock:IsA("BindableEvent") then
									lock:Fire(nearMonster)
								end
								return
							end

							-- ลำดับ 3: หากกล่องพาหลุดโซน (> 40 studs) หรือไม่มีมอนสเตอร์รอบตัว ให้เดินกลับจุดฟาร์มเดิม
							if isAlive() and not isPlayerManualInput() and curDistToAnchor > 40.0 then
								navigatePath(originPos, {
									stopDistance = 5.0,
									timeout = 6.0,
									sprint = true,
									emulatePlayerMove = true,
									shouldAbort = function()
										return not isAlive() or isPlayerManualInput()
									end,
								})
							end

							-- ถึงจุดฟาร์มเดิมแล้ว ยิงเป้ามอนสเตอร์ในจุดฟาร์มทันที 0 ms ข้ามคูลดาวน์ 1.5s ของเกม
							char = LocalPlayer.Character
							root = char and char:FindFirstChild("HumanoidRootPart")
							if root and isAlive() and not isPlayerManualInput() then
								instantResumeAutoCombat(originPos)
							end
						end

						-- กรณี 1: กล่องอยู่ในระยะประชิด (<= 8.5 studs) เปิดได้ทันทีโดยไม่ต้องเดิน
						if curDist <= 8.5 then
							local originPos = HUB.FarmAnchor or root.Position
							doOpenAndCollect()
							handoffCombatAfterBox(originPos, targetPos)
						else
							-- กรณี 2: กล่องอยู่ไกล (> 8.5 studs) — เดินไปเปิดแบบจำลองคนกดเดิน (ไม่ปิด Auto Play และไม่ใช้ VIM 100%)
							local originPos = HUB.FarmAnchor or root.Position

							-- เฟส 1: วิ่งไปหากล่องสมบัติด้วย Smart Navigation (โหมด emulatePlayerMove ชนะ CombatClient อย่างเป็นธรรมชาติ)
							local arrived = navigatePath(targetPos, {
								stopDistance = 7.5,
								timeout = 7.0,
								sprint = true,
								emulatePlayerMove = true,
								shouldAbort = function()
									return not isAlive() or isPlayerManualInput() or not targetBox or not targetBox.Parent
								end,
							})

							-- เฟส 2: เปิดกล่องและดูดของ
							char = LocalPlayer.Character
							root = char and char:FindFirstChild("HumanoidRootPart")
							local boxLivePos = targetBox and targetBox.Parent and (targetBox.Position or (targetBox:IsA("Model") and targetBox:GetPivot().Position))
							local closeEnough = root and boxLivePos and (boxLivePos - root.Position).Magnitude <= 9.0
							if isAlive() and not isPlayerManualInput() and targetBox and targetBox.Parent and (arrived or closeEnough) then
								pcall(function()
									local h = char and char:FindFirstChildOfClass("Humanoid")
									if h then h:Move(Vector3.zero, false) end
								end)
								doOpenAndCollect()
							end

							-- เฟส 3: ส่งมอบเป้าหมายต่อสู้ทันที (0 ms) & จัดการระยะเดินกลับอัจฉริยะ
							handoffCombatAfterBox(originPos, targetPos)

							task.wait(0.15)
						end
					end
				end
			end
		end
	end
end)

-- ===== 9.2 Reactive Event-Driven Auto Claim Engine (ตรวจจับและเคลมทันทีเมื่อมีของรางวัล 100% Location-Independent) =====
do
	local shared = ReplicatedStorage:FindFirstChild("Shared")
	local achieveData = shared and shared:FindFirstChild("AchievementData") and require(shared.AchievementData)

	-- 1. ฟังก์ชันตรวจจับว่ามีของรางวัลรอให้เคลมอยู่หรือไม่ (Smart Ground-Truth Detection)
	local function detectClaimableRewards()
		local claimable = {
			daily = false,
			mail = false,
			pass = false,
			reward = false,
			achieve = false,
			any = false,
			reasons = {}
		}

		-- 1.1 Daily Login Claim Check
		local dailyStr = LocalPlayer:GetAttribute("DailyJson")
		if dailyStr then
			local ok, d = pcall(HttpService.JSONDecode, HttpService, dailyStr)
			if ok and d and d.CanClaim == true then
				claimable.daily = true
				claimable.any = true
				table.insert(claimable.reasons, "Daily Login")
			end
		end

		-- 1.2 Mailbox Check (MailUnclaimed > 0 หรือมีจดหมายที่มีไอเทม/เงิน)
		local mailUnclaimed = tonumber(LocalPlayer:GetAttribute("MailUnclaimed")) or 0
		if mailUnclaimed > 0 then
			claimable.mail = true
			claimable.any = true
			table.insert(claimable.reasons, "Mailbox (" .. tostring(mailUnclaimed) .. ")")
		else
			local mailStr = LocalPlayer:GetAttribute("MailJson")
			if mailStr and mailStr ~= "[]" then
				local ok, mails = pcall(HttpService.JSONDecode, HttpService, mailStr)
				if ok and type(mails) == "table" and #mails > 0 then
					for _, m in ipairs(mails) do
						if (m.Items and #m.Items > 0) or (m.Silver and m.Silver > 0) or m.Gold then
							claimable.mail = true
							claimable.any = true
							table.insert(claimable.reasons, "Mailbox")
							break
						end
					end
				end
			end
		end

		-- 1.3 Battle Pass Check (BattlePassReady > 0)
		local bpReady = tonumber(LocalPlayer:GetAttribute("BattlePassReady")) or 0
		if bpReady > 0 then
			claimable.pass = true
			claimable.any = true
			table.insert(claimable.reasons, "Battle Pass (" .. tostring(bpReady) .. ")")
		end

		-- 1.4 Playtime & Check-in Check (RewardsReady > 0 หรือ C8 / Online พร้อมรับ)
		local rewardsReady = tonumber(LocalPlayer:GetAttribute("RewardsReady")) or 0
		if rewardsReady > 0 then
			claimable.reward = true
			claimable.any = true
			table.insert(claimable.reasons, "Rewards (" .. tostring(rewardsReady) .. ")")
		else
			local rewStr = LocalPlayer:GetAttribute("RewardsJson")
			if rewStr then
				local ok, r = pcall(HttpService.JSONDecode, HttpService, rewStr)
				if ok and type(r) == "table" then
					if r.C8 and r.C8.Can == true then
						claimable.reward = true
						claimable.any = true
						table.insert(claimable.reasons, "8-Day Check-in")
					end
					if r.Online and type(r.Online.Got) == "table" and type(r.Online.Sec) == "number" then
						local gotMap = {}
						for _, slot in ipairs(r.Online.Got) do gotMap[slot] = true end
						local thresholds = { 300, 600, 1200, 1800, 2700, 3600 }
						for slot, reqSec in ipairs(thresholds) do
							if not gotMap[slot] and r.Online.Sec >= reqSec then
								claimable.reward = true
								claimable.any = true
								table.insert(claimable.reasons, "Online " .. tostring(math.floor(reqSec / 60)) .. "m")
								break
							end
						end
					end
				end
			end
		end

		-- 1.5 Achievements Check (AchieveReady > 0)
		local achReady = tonumber(LocalPlayer:GetAttribute("AchieveReady")) or 0
		if achReady > 0 then
			claimable.achieve = true
			claimable.any = true
			table.insert(claimable.reasons, "Achievements (" .. tostring(achReady) .. ")")
		end

		return claimable
	end

	-- 2. ฟังก์ชันส่งคำขอเคลมรางวัล (Targeted & Rate-Limit Spacing)
	local claimingNow = false
	local function claimAll(reason)
		if claimingNow then return end
		local rFolder = ReplicatedStorage:FindFirstChild("Remotes")
		if not rFolder then return end

		claimingNow = true

		-- 2.1 Daily Login Claim
		local daily = rFolder:FindFirstChild("DailyClaim")
		if daily then
			pcall(function() daily:FireServer() end)
			task.wait(0.08)
		end

		-- 2.2 Intro Gift
		local intro = rFolder:FindFirstChild("IntroGift")
		if intro then
			pcall(function() intro:FireServer() end)
			task.wait(0.08)
		end

		-- 2.3 Mailbox
		local mail = rFolder:FindFirstChild("MailAction")
		if mail then
			pcall(function()
				mail:FireServer("claimall")
				task.wait(0.12)
				mail:FireServer("deleteclaimed")
			end)
			task.wait(0.08)
		end

		-- 2.4 Battle Pass
		local battlePass = rFolder:FindFirstChild("BattlePassAction")
		if battlePass then
			pcall(function()
				battlePass:FireServer("claimAll")
				task.wait(0.1)
				battlePass:FireServer("missionAll")
			end)
			task.wait(0.08)
		end

		-- 2.5 Playtime & Check-in (RewardAction)
		local rewardAction = rFolder:FindFirstChild("RewardAction")
		if rewardAction then
			pcall(function() rewardAction:FireServer("c8", nil) end)
			task.wait(0.05)
			pcall(function() rewardAction:FireServer("month", nil) end)
			task.wait(0.05)
			for _, m in ipairs({ 7, 14, 21, 28 }) do
				pcall(function() rewardAction:FireServer("mile", m) end)
				task.wait(0.04)
			end
			for slot = 1, 6 do
				pcall(function() rewardAction:FireServer("online", slot) end)
				task.wait(0.06)
			end
		end

		-- 2.6 Achievements
		local achieveAction = rFolder:FindFirstChild("AchieveAction")
		if achieveAction and achieveData then
			local aAttr = LocalPlayer:GetAttribute("AchieveJson")
			if aAttr then
				local decOk, aJson = pcall(HttpService.JSONDecode, HttpService, aAttr)
				if decOk and type(aJson) == "table" then
					local got = aJson.Got or {}
					local counts = aJson.C or {}
					local myLvl = LocalPlayer:GetAttribute("Level") or 1
					local allAch = achieveData.List or achieveData.Achievements or {}
					for _, ach in ipairs(allAch) do
						if not got[ach.Id] then
							local val = (ach.Type == "level") and myLvl or (counts[ach.Type] or 0)
							if val >= (ach.Count or 1) then
								pcall(function() achieveAction:FireServer("claim", ach.Id, false) end)
								task.wait(0.08)
							end
						end
					end
				end
			end
		end

		HUB.Stats.rewardsClaimed = HUB.Stats.rewardsClaimed + 1
		local triggerInfo = (reason and reason ~= "") and (" [" .. tostring(reason) .. "]") or ""
		if HUB.UI.ClaimStatusLabel then
			HUB.UI.ClaimStatusLabel.Text = string.format("สถานะ: ตรวจจับอัตโนมัติ · เคลมแล้ว %d รอบ (%s)%s", HUB.Stats.rewardsClaimed, os.date("%H:%M:%S"), triggerInfo)
		end
		if HUB.UI.StatRewardCount then
			HUB.UI.StatRewardCount.Text = tostring(HUB.Stats.rewardsClaimed) .. " รอบ"
		end

		claimingNow = false
	end

	HUB.ClaimAllRewards = claimAll
	HUB.DetectClaimableRewards = detectClaimableRewards

	-- 3. Reactive Event Listeners (ตรวจจับอัตโนมัติ Real-Time เมื่อเซิร์ฟเวอร์แจ้งมีของให้รับ)
	local scheduled = false
	local function triggerReactiveClaim(attrName)
		if not HUB.Alive or not HUB.Config.autoClaim then return end
		if scheduled then return end
		scheduled = true
		task.delay(0.25, function()
			scheduled = false
			if not HUB.Alive or not HUB.Config.autoClaim then return end
			local det = detectClaimableRewards()
			if det.any then
				local reasonStr = table.concat(det.reasons, ", ")
				claimAll(reasonStr)
			end
		end)
	end

	-- ดักจับสัญญาณการเปลี่ยนแปลงของ Attributes รางวัลทั้งหมด
	local rewardSignals = {
		"RewardsReady",
		"DailyJson",
		"MailUnclaimed",
		"MailJson",
		"BattlePassReady",
		"BattlePassJson",
		"AchieveReady",
		"RewardsJson",
		"Level",
	}
	for _, attr in ipairs(rewardSignals) do
		HUB:AddConnection(LocalPlayer:GetAttributeChangedSignal(attr):Connect(function()
			triggerReactiveClaim(attr)
		end))
	end

	-- 4. Initial Check on Startup / Boot
	task.defer(function()
		task.wait(2.0)
		if HUB.Alive and HUB.Config.autoClaim then
			local det = detectClaimableRewards()
			if det.any then
				claimAll(table.concat(det.reasons, ", "))
			end
		end
	end)

	-- 5. Fallback Safety Net (ตรวจเช็คทุก 60 วินาที เฉพาะเมื่อมีของรอเคลม เพื่อกันหลุดรอบ)
	task.spawn(function()
		while HUB.Alive and EXEC.env.HuntingTogetherHub_Token == MY_TOKEN do
			task.wait(60)
			if not HUB.Alive or EXEC.env.HuntingTogetherHub_Token ~= MY_TOKEN then break end
			if HUB.Config.autoClaim then
				local det = detectClaimableRewards()
				if det.any then
					claimAll("Safety Net: " .. table.concat(det.reasons, ", "))
				end
			end
		end
	end)
end

-- =========================================================================
-- 9.30 Auto Lock & Auto Sell Workers (Event-Driven, Zero Heavy Scan)
-- =========================================================================
do
	local _lastLockScan = 0
	local _lockScanThread = nil

	local function shouldItemBeLocked(id, data, wantTiers, wantStars, equipRules, specKeys, GearData, GearUtil)
		if type(data) ~= "table" then return false end
		local eval = HUB.ItemTier and HUB.ItemTier.EvaluateGear and HUB.ItemTier.EvaluateGear(id, data)
		if not eval then return false end

		-- ด่านที่ 1: ตรวจสอบเงื่อนไขหลัก (Grade & Star & GameTier Pre-requisite Gate จากแท็บ ⭐ เกรด & ระดับดาว)
		local wantGameTiers = HUB.Config.autoLockGameTiers or {}
		local resolved = eval.Resolved or (GearUtil and GearUtil.Resolve and GearUtil.Resolve(id, { [id] = data }))
		local itemTier = tonumber(data.T) or (eval and tonumber(eval.Tier)) or (resolved and tonumber(resolved.Tier))

		-- 1.1 ตรวจสอบระดับ Tier ในเกม (I - VI)
		local hasGameTierFilter = false
		for _, v in pairs(wantGameTiers) do
			if v == true then hasGameTierFilter = true break end
		end
		if hasGameTierFilter then
			local matchGameTier = false
			if itemTier and (wantGameTiers[itemTier] == true or wantGameTiers[tostring(itemTier)] == true) then
				matchGameTier = true
			end
			if not matchGameTier then
				return false -- ตกเกณฑ์ระดับ Tier ในเกมทันที (เช่น ไม่ได้เลือก Tier I-IV แต่ไอเทมเป็น Tier I-IV)
			end
		end

		-- 1.2 ตรวจสอบเกรด Tierlist (F..SS) และระดับดาว (Silver, Gold, Rainbow)
		local hasGradeFilter = false
		for _, v in pairs(wantTiers or {}) do
			if v == true then hasGradeFilter = true break end
		end
		local hasStarFilter = false
		for _, v in pairs(wantStars or {}) do
			if v == true then hasStarFilter = true break end
		end

		if hasGradeFilter or hasStarFilter then
			local matchGrade = (eval.Grade and wantTiers and wantTiers[eval.Grade] == true)
			local matchStar = (eval.Star and wantStars and wantStars[eval.Star] == true)
			local passQuality = false
			if hasGradeFilter and hasStarFilter then
				passQuality = (matchGrade or matchStar)
			elseif hasGradeFilter then
				passQuality = matchGrade
			elseif hasStarFilter then
				passQuality = matchStar
			end
			if not passQuality then
				return false -- ตกเกณฑ์เกรดหรือระดับดาวที่กำหนดไว้ในแท็บหลัก
			end
		elseif not hasGameTierFilter then
			-- ไม่ได้เลือกเงื่อนไขใดๆ ในแท็บ ⭐ เกรด & ระดับดาว เลย = ไม่ล็อค
			return false
		end

		-- ตรวจสอบเงื่อนไขเฉพาะหมวดหมู่อุปกรณ์
		local grp = (resolved and GearData and type(GearData.GroupOf) == "function" and GearData.GroupOf(resolved))
		if grp == "WeaponPhys" then
			local idLower = string.lower(id or "")
			if (resolved and (resolved.SubKind == "bow" or resolved.WeaponType == "bow")) or idLower:find("bow") then
				grp = "WeaponPhysRanged"
			else
				grp = "WeaponPhysMelee"
			end
		end
		local rule = grp and equipRules and equipRules[grp]

		-- ถ้าไม่ได้เปิดใช้งานเงื่อนไขเฉพาะหมวดหมู่นี้ = ไม่กรองออปชันพิเศษ (ล็อคตามเกณฑ์เกรด/ดาวหลักทันที)
		if not rule or rule.enabled ~= true then
			return true
		end

		local options = data.O or {}

		-- ด่านย่อย 1: ตรวจสอบสเตตัสต้องห้าม (Forbidden Stats)
		if type(rule.forbidden) == "table" then
			for optK, isForb in pairs(rule.forbidden) do
				if isForb == true and options[optK] ~= nil then
					return false -- มีสเตตัสต้องห้าม = ไม่ล็อคเด็ดขาด
				end
			end
		end

		-- ด่านย่อย 2: ตรวจหา Special Option ของไอเทม
		local itemSpecialKey = nil
		for optK, _ in pairs(options) do
			if specKeys[optK] then
				itemSpecialKey = optK
				break
			end
		end

		if itemSpecialKey then
			-- ไอเทมมี Special Option: ตรวจสอบว่าผู้ใช้ติ๊กเลือกเก็บออปชันนี้ไว้ที่ด้านบนหรือไม่
			local isWanted = (rule.wantedSpecials and rule.wantedSpecials[itemSpecialKey] == true)
			if not isWanted and rule.special and rule.special[itemSpecialKey] == true then
				isWanted = true
			end
			if not isWanted then
				return false
			end

			-- ตรวจสอบสเตตัสสุ่มของการ์ดออปชันนี้
			local sConf = rule.specialStats and rule.specialStats[itemSpecialKey]
			local wantStats = (sConf and sConf.stats) or {}
			local minMatch = (sConf and tonumber(sConf.minMatch)) or 0

			local hasStatSelection = false
			for _, w in pairs(wantStats) do
				if w == true then hasStatSelection = true break end
			end

			-- "ถ้าไม่เลือกก็จะไม่กรอง": หากไม่ได้เลือกสเตตัสสุ่มใดๆ หรือ minMatch <= 0 -> ล็อคทันที
			if not hasStatSelection or minMatch <= 0 then
				return true
			end

			local matchCount = 0
			for optK, _ in pairs(options) do
				if not specKeys[optK] and wantStats[optK] == true then
					matchCount = matchCount + 1
				end
			end
			return matchCount >= minMatch
		else
			-- ไอเทมไม่มี Special Option เลย แต่ผ่านเกรด & ดาวหลักมาแล้ว -> ล็อค
			return true
		end
	end

	local function runAutoLockCheck()
		if not HUB.Alive or not HUB.Config.autoLock or EXEC.env.HuntingTogetherHub_Token ~= MY_TOKEN then return false, 0 end
		local rawGear = LocalPlayer:GetAttribute("GearJson") or "{}"
		local rawLocks = LocalPlayer:GetAttribute("LocksJson") or "{}"
		local ok1, gearJson = pcall(HttpService.JSONDecode, HttpService, rawGear)
		local ok2, locksJson = pcall(HttpService.JSONDecode, HttpService, rawLocks)
		if not ok1 or not ok2 or type(gearJson) ~= "table" or type(locksJson) ~= "table" then return false, 0 end

		local wantTiers = HUB.Config.autoLockTiers or {}
		local wantStars = HUB.Config.autoLockStars or {}
		local equipRules = HUB.Config.autoLockEquipRules or {}
		local toLock = {}

		local GearData = HUB.GearData
		local GearUtil = HUB.GearUtil
		local specKeys = (GearData and GearData.SpecialKeys) or {}

		for id, data in pairs(gearJson) do
			if not locksJson[id] and type(data) == "table" then
				if shouldItemBeLocked(id, data, wantTiers, wantStars, equipRules, specKeys, GearData, GearUtil) then
					table.insert(toLock, id)
				end
			end
		end

		if #toLock > 0 then
			if not HUB.Config.autoLock or not HUB.Alive or EXEC.env.HuntingTogetherHub_Token ~= MY_TOKEN then return false, 0 end
			local rem = ReplicatedStorage:FindFirstChild("Remotes")
			local bagLock = rem and rem:FindFirstChild("BagLock")
			if bagLock then
				bagLock:FireServer(toLock, true)
				warn(string.format("[Hunting Together Hub] Auto Lock: ล็อคอุปกรณ์ %d ชิ้น สำเร็จ!", #toLock))
				return true, #toLock
			end
		end
		return false, 0
	end
	HUB.RunAutoLockCheck = runAutoLockCheck

	-- Event-driven watcher: ทำงานเฉพาะเมื่อ GearJson มีการเปลี่ยนแปลง + Trailing Debounce 0.5s (Zero Heavy Scan)
	HUB:AddConnection(LocalPlayer:GetAttributeChangedSignal("GearJson"):Connect(function()
		if not HUB.Alive or not HUB.Config.autoLock or EXEC.env.HuntingTogetherHub_Token ~= MY_TOKEN then return end
		if _lockScanThread then
			pcall(task.cancel, _lockScanThread)
			_lockScanThread = nil
		end
		_lockScanThread = task.delay(0.5, function()
			_lockScanThread = nil
			if HUB.Alive and HUB.Config.autoLock and EXEC.env.HuntingTogetherHub_Token == MY_TOKEN then
				runAutoLockCheck()
			end
		end)
	end))

	-- -------------------- Auto Salvage Worker --------------------
	local _isSalvagingRoutine = false
	local _lastSalvageTime = 0

	local function refreshSalvageStatusLabel(customText)
		if not HUB.UI.SalvageStatusLabel then return end
		if customText then
			HUB.UI.SalvageStatusLabel.Text = customText
			return
		end
		local stats = getBagStats()
		local thresh = HUB.Config.autoSalvageThresholdPct or 85
		if HUB.Config.autoSalvage then
			HUB.UI.SalvageStatusLabel.Text = string.format("สถานะ: พร้อมทำงาน · ย่อยเมื่อเต็ม >= %d%% (ปัจจุบัน: %d%% [%d/%d])", thresh, stats.pct, stats.used, stats.max)
		else
			HUB.UI.SalvageStatusLabel.Text = string.format("สถานะ: ปิดใช้งาน (ความจุกระเป๋า: %d%% [%d/%d])", stats.pct, stats.used, stats.max)
		end
	end
	HUB.RefreshSalvageStatusLabel = refreshSalvageStatusLabel

	-- ปิดหน้าต่าง "Salvage Complete" (คลิกปุ่ม OK / KitButton) อัตโนมัติหลังย่อยของ
	local function dismissSalvageResultModal()
		pcall(function()
			local salvageGui = PlayerGui:FindFirstChild("LumiSalvageResult")
			if not salvageGui then return end
			local holder = salvageGui:FindFirstChild("Holder")
			if not holder then return end
			local popupLayer = holder:FindFirstChild("PopupLayer")
			if not popupLayer then return end
			local miniWindow = popupLayer:FindFirstChild("MiniWindow")
			local body = miniWindow and miniWindow:FindFirstChild("Body")
			local kitBtn = body and body:FindFirstChild("KitButton")
			if kitBtn then
				local FIRESIGNAL = rawget(EXEC.env, "firesignal")
				if type(FIRESIGNAL) == "function" then
					pcall(FIRESIGNAL, kitBtn.MouseButton1Click)
				end
				for _, conn in ipairs(getconnections(kitBtn.MouseButton1Click)) do
					pcall(function() conn:Fire() end)
				end
			end
			-- Fallback: ยิง connection ของ PopupLayer หากมีอยู่
			if holder:FindFirstChild("PopupLayer") then
				for _, conn in ipairs(getconnections(popupLayer.MouseButton1Click)) do
					pcall(function() conn:Fire() end)
				end
			end
		end)
	end

	-- Reactive Listener: ตรวจจับและปิดหน้าต่าง Salvage Complete ทันทีที่ PopupLayer ถูกสร้างขึ้นมา
	pcall(function()
		local salvageGui = PlayerGui:WaitForChild("LumiSalvageResult", 10)
		if salvageGui then
			local holder = salvageGui:WaitForChild("Holder", 5)
			if holder then
				HUB:AddConnection(holder.ChildAdded:Connect(function(child)
					if child.Name == "PopupLayer" then
						task.wait(0.08)
						dismissSalvageResultModal()
					end
				end))
			end
		end
	end)

	local function runAutoSalvageRoutine()
		if _isSalvagingRoutine or not HUB.Alive or not HUB.Config.autoSalvage or EXEC.env.HuntingTogetherHub_Token ~= MY_TOKEN then return end
		_isSalvagingRoutine = true
		HUB.IsSalvagingRoutineActive = true

		local ok, err = pcall(function()
			-- 1. Safety Pre-Lock Gate: ตรวจสอบและล็อคไอเทมใหม่ตามเงื่อนไข Auto-Lock ก่อนเสมอ
			if HUB.Config.autoLock and runAutoLockCheck then
				local lockedAny, lockCount = runAutoLockCheck()
				if lockedAny and lockCount > 0 then
					task.wait(0.2)
				end
			end

			-- 2. ดึงข้อมูลกระเป๋าและไอเทมปัจจุบัน
			local rawGear = LocalPlayer:GetAttribute("GearJson") or "{}"
			local rawLocks = LocalPlayer:GetAttribute("LocksJson") or "{}"
			local rawEquip = LocalPlayer:GetAttribute("EquipJson") or "{}"
			local ok1, gearJson = pcall(HttpService.JSONDecode, HttpService, rawGear)
			local ok2, locksJson = pcall(HttpService.JSONDecode, HttpService, rawLocks)
			local ok3, equipJson = pcall(HttpService.JSONDecode, HttpService, rawEquip)

			if not (ok1 and ok2 and type(gearJson) == "table" and type(locksJson) == "table") then
				return
			end

			local equippedSet = {}
			local wepId = LocalPlayer:GetAttribute("WeaponId")
			if type(wepId) == "string" and wepId ~= "" then
				equippedSet[wepId] = true
			end
			if ok3 and type(equipJson) == "table" then
				for _, eqId in pairs(equipJson) do
					if type(eqId) == "string" and eqId ~= "" then
						equippedSet[eqId] = true
					end
				end
			end

			local wantTiers = HUB.Config.autoLockTiers or {}
			local wantStars = HUB.Config.autoLockStars or {}
			local equipRules = HUB.Config.autoLockEquipRules or {}
			local GearData = HUB.GearData
			local GearUtil = HUB.GearUtil
			local specKeys = (GearData and GearData.SpecialKeys) or {}

			local salvageList = {}
			for id, data in pairs(gearJson) do
				if type(data) == "table" and not locksJson[id] and not equippedSet[id] then
					-- ดึงระดับ Tier ของไอเทม (ตัวเกมอนุญาตเฉพาะ Tier 1-5)
					local tier = tonumber(data.T)
					if not tier and GearUtil and GearUtil.Resolve then
						local resolved = GearUtil.Resolve(id, { [id] = data })
						tier = resolved and tonumber(resolved.Tier)
					end

					if tier and tier >= 1 and tier <= 5 then
						local isProtected = false
						if HUB.Config.autoLock and shouldItemBeLocked(id, data, wantTiers, wantStars, equipRules, specKeys, GearData, GearUtil) then
							isProtected = true
						end
						if not isProtected then
							table.insert(salvageList, id)
						end
					end
				end
			end

			if #salvageList > 0 then
				local rem = ReplicatedStorage:FindFirstChild("Remotes")
				local bagSalvage = rem and rem:FindFirstChild("BagSalvage")
				if bagSalvage then
					bagSalvage:FireServer(salvageList)
					warn(string.format("[Hunting Together Hub] Auto Salvage: ส่งคำสั่งย่อยอุปกรณ์ %d ชิ้น สำเร็จ!", #salvageList))
					_lastSalvageTime = os.clock()

					-- ปิดหน้าต่างผลลัพธ์ Salvage Complete (ปุ่ม OK) อัตโนมัติทันที
					task.spawn(function()
						local t0 = os.clock()
						while os.clock() - t0 < 2.0 and HUB.Alive do
							dismissSalvageResultModal()
							local salvageGui = PlayerGui:FindFirstChild("LumiSalvageResult")
							local holder = salvageGui and salvageGui:FindFirstChild("Holder")
							if not (holder and holder:FindFirstChild("PopupLayer")) then
								if os.clock() - t0 > 0.3 then break end
							end
							task.wait(0.1)
						end
					end)

					task.wait(0.3)
					local curStats = getBagStats()
					if HUB.UI.SalvageStatusLabel then
						HUB.UI.SalvageStatusLabel.Text = string.format("สถานะ: ย่อยสำเร็จ %d ชิ้น (กระเป๋า: %d%% [%d/%d])", #salvageList, curStats.pct, curStats.used, curStats.max)
					end
				end
			else
				local curStats = getBagStats()
				if HUB.UI.SalvageStatusLabel then
					HUB.UI.SalvageStatusLabel.Text = string.format("สถานะ: กระเป๋า %d%% แต่ไม่มีอุปกรณ์ T1-5 ที่ย่อยได้ (ล็อค/สวม/T6)", curStats.pct)
				end
			end
		end)

		if not ok and err then
			warn("[Hunting Together Hub] Auto Salvage Routine Error: " .. tostring(err))
		end

		_isSalvagingRoutine = false
		HUB.IsSalvagingRoutineActive = false
		task.delay(3.0, function()
			if not _isSalvagingRoutine then
				refreshSalvageStatusLabel()
			end
		end)
	end
	HUB.RunAutoSalvageRoutine = runAutoSalvageRoutine

	-- -------------------- Auto Sell Worker --------------------
	local _isSellingRoutine = false
	local _cancelSellRoutine = false
	local _lastSellCheck = 0

	local function cancelAutoSellRoutine()
		_cancelSellRoutine = true
		_isSellingRoutine = false
		HUB.IsSellingRoutineActive = false
		HUB.SellRoutineStartTime = nil
		pcall(function()
			local char = LocalPlayer.Character
			local root = char and char:FindFirstChild("HumanoidRootPart")
			local hum = char and char:FindFirstChildOfClass("Humanoid")
			if root then root.Anchored = false end
			if hum then hum:Move(Vector3.zero, false) end
			setSprinting(false)
		end)
		warn("[Hunting Together Hub] Auto Sell: ยกเลิกลูปขายของ")
		if not HUB.Config.autoSell and not HUB.Config.autoFarmBoss then
			clearOrigin()
		end
	end
	HUB.CancelAutoSellRoutine = cancelAutoSellRoutine

	local function runAutoSellRoutine(forceRun)
		if _isSellingRoutine or not HUB.Alive or HUB.IsBossRoutineActive or EXEC.env.HuntingTogetherHub_Token ~= MY_TOKEN then return end
		if not forceRun and not HUB.Config.autoSell then return end
		local char = LocalPlayer.Character
		local root = char and char:FindFirstChild("HumanoidRootPart")
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		if not root or not hum or hum.Health <= 0 then return end

		-- 0. Salvage Pre-Check Gate: หากเปิด Auto Salvage ให้ย่อยอุปกรณ์กลางจุดฟาร์มก่อนเสมอ (Location-Independent)
		if not forceRun and HUB.Config.autoSalvage and runAutoSalvageRoutine and not _isSalvagingRoutine and not HUB.IsSalvagingRoutineActive then
			if HUB.UI.SellStatusLabel then
				HUB.UI.SellStatusLabel.Text = "สถานะ: ย่อยอุปกรณ์เบื้องหลังก่อนวาร์ป..."
			end
			runAutoSalvageRoutine()
			task.wait(0.4)
			-- ตรวจสอบว่ายังมีไอเทมที่เข้าเกณฑ์ขายหรือไม่ (Junk หรือ Gear ที่ไม่ได้ย่อย)
			local canSell = hasSellableItems()
			if not canSell then
				local afterStats = getBagStats()
				if HUB.UI.SellStatusLabel then
					HUB.UI.SellStatusLabel.Text = string.format("สถานะ: ย่อยอุปกรณ์สำเร็จ กระเป๋าว่างแล้ว (%d%%) · ไม่มีของต้องขาย ข้ามการวาร์ป", afterStats.pct)
				end
				return
			end
		else
			local canSell = hasSellableItems()
			if not canSell and not forceRun then
				return
			end
		end

		_isSellingRoutine = true
		_cancelSellRoutine = false
		HUB.IsSellingRoutineActive = true
		HUB.SellRoutineStartTime = os.clock()

		local success, err = pcall(function()
			local function shouldAbort()
				return not HUB.Alive or not HUB.Config.autoSell or _cancelSellRoutine or EXEC.env.HuntingTogetherHub_Token ~= MY_TOKEN
			end

			if shouldAbort() then return end

			if HUB.UI.SellStatusLabel then
				HUB.UI.SellStatusLabel.Text = "สถานะ: เริ่มต้นลูปขายของ... กำลังเดินทางไป Merchant"
			end

			captureOriginIfNeeded()
			local LumiMenuToggle = LocalPlayer:FindFirstChild("LumiMenuToggle")
			local alreadyInTown = (root.Position.Z > -200)

			-- 1. ปิด Auto-Hunt ชั่วคราวและปลดล็อกเป้าหมายเพื่อให้วาร์ปและเดินในเมืองได้อย่างราบรื่น
			if HUB.DisableGameAutoPlay then
				HUB.DisableGameAutoPlay()
			elseif LocalPlayer:GetAttribute("AutoOn") == true and LumiMenuToggle then
				pcall(function() LumiMenuToggle:Fire("autoToggle") end)
				task.wait(0.1)
			end

			if shouldAbort() then return end

			-- 2. เดินทางกลับไปที่ร้าน Merchant (เฉพาะเมื่ออยู่นอกเมือง Z <= -200)
			if not alreadyInTown then
				local reachedTown = false

				-- 2.1 ตรวจสอบคูลดาวน์ HomeWarp
				local readyAt = tonumber(LocalPlayer:GetAttribute("HomeWarpReadyAt")) or 0
				local cdLeft = math.max(0, math.ceil(readyAt - workspace:GetServerTimeNow()))

				-- ถ้าติดคูลดาวน์สั้นๆ (<= 12 วินาที) ให้รอจนพร้อม
				if cdLeft > 0 and cdLeft <= 12 then
					if HUB.UI.SellStatusLabel then
						HUB.UI.SellStatusLabel.Text = string.format("สถานะ: กระเป๋าเต็ม — รอ HomeWarp อีก %d วิ...", cdLeft)
					end
					local cdWaitT0 = os.clock()
					while (os.clock() - cdWaitT0 < (cdLeft + 0.2)) and not shouldAbort() do
						task.wait(0.2)
					end
					cdLeft = 0
				end

				-- ถ้าไม่มีคูลดาวน์ ให้ยิง HomeWarp
				if cdLeft == 0 and not shouldAbort() then
					if root then root.Anchored = true end
					local homeWarp = remotes and remotes:FindFirstChild("HomeWarp")
					if homeWarp then
						homeWarp:FireServer("start", "merchant")
					elseif LumiMenuToggle then
						pcall(function() LumiMenuToggle:Fire("homeWarpMerchant") end)
					end

					-- รอ Cast 5 วินาที + เช็คยืนยันว่าเข้าสู่เขตเมืองแล้วจริง (Position.Z > -200)
					local t0 = os.clock()
					while os.clock() - t0 < 8 and not shouldAbort() do
						task.wait(0.1)
						char = LocalPlayer.Character
						root = char and char:FindFirstChild("HumanoidRootPart")
						hum = char and char:FindFirstChildOfClass("Humanoid")
						if not root or not hum or hum.Health <= 0 then break end

						if root.Position.Z > -200 then
							reachedTown = true
							break
						end
					end
					if root then root.Anchored = false end
				end

				-- 2.2 ถ้า HomeWarp ไม่สำเร็จหรือติดคูลดาวน์นาน (> 12 วิ) ให้ตรวจหาเสาวาร์ปใกล้ตัวเพื่อวาร์ปเข้าเมือง (Town Warp: 0 Silver, 0 Cooldown)
				if not reachedTown and not shouldAbort() then
					local localPillar = getNearbyBossPillar(root.Position)
					if localPillar then
						if HUB.UI.SellStatusLabel then
							HUB.UI.SellStatusLabel.Text = "สถานะ: ใช้เสาวาร์ปใกล้เคียงเพื่อเดินทางเข้าเมือง (Zero Cooldown)..."
						end
						local okWarp = executePillarWarp(localPillar, "Town", shouldAbort)
						if okWarp then
							char = LocalPlayer.Character
							root = char and char:FindFirstChild("HumanoidRootPart")
							if root and root.Position.Z > -200 then
								reachedTown = true
							end
						end
					end
				end

				if shouldAbort() or not root or not hum or hum.Health <= 0 then return end

				if not reachedTown then
					warn("[Hunting Together Hub] Auto Sell: วาร์ปเข้าเมืองไม่สำเร็จ — เลื่อนรอบการขายและเปิด Auto Play ต่อ")
					if HUB.EnsureGameAutoActive and root.Position.Z <= -300 then
						HUB.EnsureGameAutoActive(4, 0.3)
					end
					return
				end

				-- รอ WarpLandClient ปล่อย Anchored และ RequestStreamAroundAsync พื้นที่เมืองรอบตัว
				local tWarpDone = os.clock()
				while (root and root.Anchored and os.clock() - tWarpDone < 1.8) do
					task.wait(0.08)
				end
				pcall(function()
					LocalPlayer:RequestStreamAroundAsync(root.Position, 3)
				end)
				task.wait(0.15)
			end

			if shouldAbort() then return end

			if HUB.UI.SellStatusLabel then
				HUB.UI.SellStatusLabel.Text = "สถานะ: ถึงเมืองแล้ว กำลังขาย Junk & อุปกรณ์ที่ไม่ได้ล็อค..."
			end

			-- 3. เดินเข้าหาระยะ Merchant ด้วย Pathfinding Navigation (หลบสิ่งกีดขวางในเมือง)
			local merchantModel = nil
			local tFind = os.clock()
			while os.clock() - tFind < 4.0 and not shouldAbort() do
				merchantModel = workspace:FindFirstChild("Map") and workspace.Map:FindFirstChild("NPCs") and workspace.Map.NPCs:FindFirstChild("merchant")
				if merchantModel then break end
				task.wait(0.2)
			end

			if merchantModel then
				local mPos = merchantModel:GetPivot().Position
				navigatePath(mPos, {
					stopDistance = 10.0,
					timeout = 10.0,
					sprint = true,
					shouldAbort = shouldAbort,
				})
			end

			if shouldAbort() then return end

			-- Merchant Proximity Check: ตรวจสอบและขยับเข้าใกล้ Merchant ให้แน่นอน (<= 14 studs)
			char = LocalPlayer.Character
			root = char and char:FindFirstChild("HumanoidRootPart")
			if merchantModel and root then
				local mPos = merchantModel:GetPivot().Position
				local distToM = (root.Position - mPos).Magnitude
				if distToM > 14.0 and not shouldAbort() then
					hum = char and char:FindFirstChildOfClass("Humanoid")
					if hum then
						hum:MoveTo(mPos)
						local tClose = os.clock()
						while (root.Position - mPos).Magnitude > 12.0 and os.clock() - tClose < 2.5 and not shouldAbort() do
							task.wait(0.1)
						end
					end
				end
			end

			if shouldAbort() then return end

			local rem = ReplicatedStorage:FindFirstChild("Remotes")

			-- ขาย Junk ทั้งหมด (ตาม config autoSellJunk)
			if HUB.Config.autoSellJunk ~= false then
				local shopSellJunk = rem and rem:FindFirstChild("ShopSellJunk")
				if shopSellJunk and not shouldAbort() then
					local preSilver = tonumber(LocalPlayer:GetAttribute("Silver")) or 0
					local preJunk = getJunkStats()

					if HUB.UI.SellStatusLabel then
						HUB.UI.SellStatusLabel.Text = string.format("สถานะ: กำลังขาย Junk %s ชิ้น ที่ Merchant...", formatComma(preJunk.count))
					end

					shopSellJunk:FireServer()

					-- Side-Effect Verification: รอจนกระทั่ง Silver เพิ่มขึ้น หรือจำนวน Junk ลดลง
					local tWaitSell = os.clock()
					while os.clock() - tWaitSell < 2.5 and not shouldAbort() do
						task.wait(0.15)
						local curSilver = tonumber(LocalPlayer:GetAttribute("Silver")) or 0
						local curJunk = getJunkStats()
						if curSilver > preSilver or curJunk.count < preJunk.count then
							break
						end
					end

					local postSilver = tonumber(LocalPlayer:GetAttribute("Silver")) or 0
					local postJunk = getJunkStats()
					local earnedSilver = postSilver - preSilver
					local soldCount = preJunk.count - postJunk.count
					if soldCount > 0 or earnedSilver > 0 then
						if HUB.UI.SellStatusLabel then
							HUB.UI.SellStatusLabel.Text = string.format("สถานะ: ขาย Junk สำเร็จ (%s ชิ้น · +%s Silver)", formatComma(soldCount), formatComma(earnedSilver))
						end
					end
					task.wait(0.2)
				end
			end

			if shouldAbort() then return end

			-- ขายอุปกรณ์ทั้งหมดที่ไม่ได้ล็อคและไม่ได้สวมใส่ (ตาม config autoSellGear)
			if HUB.Config.autoSellGear ~= false then
				-- ตรวจสอบและล็อคไอเทมใหม่ก่อนขายเสมอ (Safety Pre-Lock Gate)
				if HUB.Config.autoLock and runAutoLockCheck then
					local lockedAny, lockCount = runAutoLockCheck()
					if lockedAny and lockCount > 0 then
						task.wait(0.35)
					end
				end

				-- ขายอุปกรณ์ทั้งหมดที่ไม่ได้ล็อคและไม่ได้สวมใส่ (ข้ามหน้าต่างกดค้าง ValuableConfirm ของ Client ได้โดยตรง 100%)
				local rawGear = LocalPlayer:GetAttribute("GearJson") or "{}"
				local rawLocks = LocalPlayer:GetAttribute("LocksJson") or "{}"
				local rawEquip = LocalPlayer:GetAttribute("EquipJson") or "{}"
				local ok1, gearJson = pcall(HttpService.JSONDecode, HttpService, rawGear)
				local ok2, locksJson = pcall(HttpService.JSONDecode, HttpService, rawLocks)
				local ok3, equipJson = pcall(HttpService.JSONDecode, HttpService, rawEquip)
				if ok1 and ok2 and type(gearJson) == "table" and type(locksJson) == "table" then
					local equippedSet = {}
					local wepId = LocalPlayer:GetAttribute("WeaponId")
					if type(wepId) == "string" and wepId ~= "" then
						equippedSet[wepId] = true
					end
					if ok3 and type(equipJson) == "table" then
						for _, eqId in pairs(equipJson) do
							if type(eqId) == "string" and eqId ~= "" then
								equippedSet[eqId] = true
							end
						end
					end

					local wantTiers = HUB.Config.autoLockTiers or {}
					local wantStars = HUB.Config.autoLockStars or {}
					local equipRules = HUB.Config.autoLockEquipRules or {}
					local GearData = HUB.GearData
					local GearUtil = HUB.GearUtil
					local specKeys = (GearData and GearData.SpecialKeys) or {}

					local sellList = {}
					for id, data in pairs(gearJson) do
						if not locksJson[id] and not equippedSet[id] then
							local isProtected = false
							if HUB.Config.autoLock and shouldItemBeLocked(id, data, wantTiers, wantStars, equipRules, specKeys, GearData, GearUtil) then
								isProtected = true
							end
							if not isProtected then
								table.insert(sellList, {id, 1})
							end
						end
					end
					if #sellList > 0 and not shouldAbort() then
						local shopSellMany = rem and rem:FindFirstChild("ShopSellMany")
						if shopSellMany then
							shopSellMany:FireServer(sellList)
							task.wait(0.25)
						end
						HUB.AllItemsProtectedAlert = false
					elseif #sellList == 0 then
						local curStats = getBagStats()
						local curThresh = HUB.Config.autoSellThresholdPct or 85
						if curStats.pct >= curThresh or curStats.isFull then
							HUB.AllItemsProtectedAlert = true
							if HUB.UI.SellStatusLabel then
								HUB.UI.SellStatusLabel.Text = string.format("สถานะ: กระเป๋า %d%% แต่ทุกชิ้นถูกล็อค/ป้องกัน (ไม่มีของขาย)", curStats.pct)
							end
						end
					end
				end
			end

			if shouldAbort() then return end

			-- 4. ตรวจสอบการส่งไม้ต่อให้ Auto Boss (Smart Handoff) หรือเดินทางกลับจุดเดิม (Return to Origin)
			if HUB.Config.autoFarmBoss and HUB.HasAliveSelectedBoss and HUB.HasAliveSelectedBoss() then
				if HUB.UI.SellStatusLabel then
					HUB.UI.SellStatusLabel.Text = "สถานะ: ขายของเสร็จสิ้น · ส่งไม้ต่อให้ Auto Boss ทันที"
				end
				_isSellingRoutine = false
				HUB.IsSellingRoutineActive = false
				HUB.SellRoutineStartTime = nil
				task.spawn(function()
					task.wait(0.2)
					if HUB.RunAutoBossRoutine then HUB.RunAutoBossRoutine() end
				end)
				return
			end

			returnToOrigin(shouldAbort, function(text)
				if HUB.UI.SellStatusLabel then HUB.UI.SellStatusLabel.Text = text end
			end)
		end)

		if not success and err then
			warn("[Hunting Together Hub] Auto Sell Routine Error: " .. tostring(err))
		end

		_isSellingRoutine = false
		HUB.IsSellingRoutineActive = false
		HUB.SellRoutineStartTime = nil
		if HUB.RefreshSellStatusLabel then
			HUB.RefreshSellStatusLabel()
		end
	end
	HUB.RunAutoSellRoutine = runAutoSellRoutine

	local function refreshSellStatusLabel(customText)
		if not HUB.UI.SellStatusLabel then return end
		if customText then
			HUB.UI.SellStatusLabel.Text = customText
			return
		end
		if HUB.AllItemsProtectedAlert then
			local stats = getBagStats()
			HUB.UI.SellStatusLabel.Text = string.format("สถานะ: กระเป๋า %d%% แต่ทุกชิ้นถูกล็อค/ป้องกัน (ไม่มีของขาย)", stats.pct)
			return
		end
		local stats = getBagStats()
		local thresh = HUB.Config.autoSellThresholdPct or 85
		if HUB.Config.autoSell then
			if HUB.Config.autoSellJunk == false and HUB.Config.autoSellGear == false then
				HUB.UI.SellStatusLabel.Text = string.format("สถานะ: เปิดใช้งาน แต่ปิดทั้งขยะและอุปกรณ์ (เลือกอย่างน้อย 1 อย่าง) [%d%%]", stats.pct)
			else
				local typeStr = "ขยะ+อุปกรณ์"
				if HUB.Config.autoSellJunk ~= false and HUB.Config.autoSellGear == false then
					typeStr = "ขยะ"
				elseif HUB.Config.autoSellJunk == false and HUB.Config.autoSellGear ~= false then
					typeStr = "อุปกรณ์"
				end
				local junk = getJunkStats()
				local junkStr = ""
				if HUB.Config.autoSellJunk ~= false and junk.count > 0 then
					junkStr = string.format(" · ขยะ %s ชิ้น (~%s)", formatComma(junk.count), formatComma(junk.silver))
				end
				HUB.UI.SellStatusLabel.Text = string.format("สถานะ: พร้อมทำงาน%s · ขาย%sเมื่อ >= %d%% (ปัจจุบัน: %d%% [%d/%d])", junkStr, typeStr, thresh, stats.pct, stats.used, stats.max)
			end
		else
			HUB.UI.SellStatusLabel.Text = string.format("สถานะ: ปิดใช้งาน (ความจุกระเป๋า: %d%% [%d/%d])", stats.pct, stats.used, stats.max)
		end
	end
	HUB.RefreshSellStatusLabel = refreshSellStatusLabel

	HUB.IsAutoSellNeeded = function(isTriggerCycle)
		if not HUB.Config.autoSell then return false end
		if HUB.Config.autoSellJunk == false and HUB.Config.autoSellGear == false then return false end

		-- ตรวจสอบก่อนว่ามีไอเทมที่ขายได้จริงหรือไม่
		local canSell = hasSellableItems()
		if not canSell then return false end

		-- หากอยู่ใน Trigger Cycle (เพิ่งย่อย Salvage จากการที่กระเป๋าถึงเกณฑ์มา)
		if isTriggerCycle then
			return true
		end

		local stats = getBagStats()
		local threshold = HUB.Config.autoSellThresholdPct or 85
		return (stats.pct >= threshold or (threshold == 100 and stats.isFull))
	end

	-- Event-driven reactive watcher: ซิงค์ % กระเป๋าและตรวจเช็ค Auto Salvage / Auto Sell ทันทีแบบ Real-time
	local _lastProtectedAlertTime = 0
	local function checkBagAndProcessLoot()
		if not HUB.Alive or EXEC.env.HuntingTogetherHub_Token ~= MY_TOKEN then return end
		HUB.AllItemsProtectedAlert = false -- มีการเปลี่ยนแปลงสล็อตในกระเป๋า รีเซ็ต alert
		if not _isSellingRoutine then
			refreshSellStatusLabel()
		end
		if not _isSalvagingRoutine then
			refreshSalvageStatusLabel()
		end

		local stats = getBagStats()
		local salvageThresh = HUB.Config.autoSalvageThresholdPct or 85
		local sellThresh = HUB.Config.autoSellThresholdPct or 85

		local hitSalvage = HUB.Config.autoSalvage and (stats.pct >= salvageThresh or (salvageThresh == 100 and stats.isFull))
		local hitSell = HUB.Config.autoSell and (stats.pct >= sellThresh or (sellThresh == 100 and stats.isFull))

		-- 1. ลำดับที่ 1: ตรวจสอบและรัน Auto Salvage ก่อน (Location-Independent, ทำงานทันทีในเบื้องหลัง ไม่ขัดจังหวะฟาร์ม)
		if hitSalvage and not _isSalvagingRoutine and not HUB.IsSalvagingRoutineActive then
			task.spawn(function()
				runAutoSalvageRoutine()
				-- หลัง Salvage รันเสร็จ หากถึงเกณฑ์ Auto Sell ด้วย ให้ส่งไม้ต่อให้ Auto Sell ขายขยะ/ของที่เหลือ
				task.wait(0.5)
				if hitSell and HUB.Config.autoSell and not _isSellingRoutine and not HUB.IsSellingRoutineActive and not HUB.IsBossRoutineActive then
					if HUB.IsAutoSellNeeded and HUB.IsAutoSellNeeded(true) then
						task.spawn(function()
							runAutoSellRoutine(true)
						end)
					end
				end
			end)
			return
		end

		-- 2. ลำดับที่ 2: หากไม่ได้เปิด Salvage แต่ถึงเกณฑ์ Auto Sell
		if hitSell and not _isSellingRoutine and not HUB.IsSellingRoutineActive and not HUB.IsBossRoutineActive then
			if HUB.IsAutoSellNeeded and HUB.IsAutoSellNeeded() then
				task.spawn(runAutoSellRoutine)
			end
		end
	end

	HUB:AddConnection(LocalPlayer:GetAttributeChangedSignal("BagSlotsUsed"):Connect(checkBagAndProcessLoot))
	HUB:AddConnection(LocalPlayer:GetAttributeChangedSignal("BagSlotsMax"):Connect(checkBagAndProcessLoot))

	-- Periodic Backup Poller (ตรวจเช็คทุก 2.5 วินาที เพื่อการันตี 100% ว่าไม่พลาดการย่อย/ขายแม้กระเป๋าเต็มจนไม่มีสัญญาณยิง)
	task.spawn(function()
		while HUB.Alive and EXEC.env.HuntingTogetherHub_Token == MY_TOKEN do
			task.wait(2.5)
			if not _isSellingRoutine and not HUB.IsSellingRoutineActive and not _isSalvagingRoutine and not HUB.IsSalvagingRoutineActive then
				if HUB.AllItemsProtectedAlert and (os.clock() - _lastProtectedAlertTime < 45.0) then
					-- ข้ามการสแปมรูทีนถ้าไอเทมทั้งหมดล็อคอยู่แล้ว และยังไม่ถึงรอบตรวจซ้ำ 45s
				else
					checkBagAndProcessLoot()
				end
			end
		end
	end)

	-- Startup Grace Check (ตรวจเช็คหลังจากสคริปต์โหลด 3-4 วินาที)
	if HUB.Config.autoLock then
		task.delay(3.0, function()
			if HUB.Alive and HUB.Config.autoLock and EXEC.env.HuntingTogetherHub_Token == MY_TOKEN then
				runAutoLockCheck()
			end
		end)
	end

	if HUB.Config.autoSalvage or HUB.Config.autoSell then
		task.delay(4.0, function()
			if HUB.Alive and EXEC.env.HuntingTogetherHub_Token == MY_TOKEN then
				checkBagAndProcessLoot()
			end
		end)
	end
end

-- =========================================================================
-- 9.30 Auto Farm Boss Worker (ล่าบอสอัตโนมัติเมื่อเกิด & วาร์ปต่อเนื่อง & กลับจุดฟาร์มเดิม)
-- =========================================================================
do
	local remotes = ReplicatedStorage:WaitForChild("Remotes", 10)
	local _isBossRoutine = false
	local _cancelBossRoutine = false
	local _botModesModule = nil
	local _lastBotModesRetry = 0

	local function getBotModes()
		if _botModesModule then return _botModesModule end
		if tick() - _lastBotModesRetry < 2.5 then return nil end
		_lastBotModesRetry = tick()
		local shared = ReplicatedStorage:FindFirstChild("Shared")
		local bm = shared and shared:FindFirstChild("BotModes")
		if bm then
			local ok, mod = pcall(require, bm)
			if ok and type(mod) == "table" then
				_botModesModule = mod
				return _botModesModule
			end
		end
		return nil
	end

	local function isLootAllowedByBotCfg(lootSkip, dropKind, dropRarity)
		local bm = getBotModes()
		if bm and type(bm.LootAllowed) == "function" then
			local ok, res = pcall(bm.LootAllowed, lootSkip, dropKind, dropRarity)
			if ok then return res == true end
		end
		if type(lootSkip) ~= "table" or type(dropKind) ~= "string" then
			return true
		end
		if lootSkip[dropKind] == true then
			return false
		end
		if dropKind == "gear" then
			local rKey = "r" .. tostring(type(dropRarity) == "number" and dropRarity or 0)
			if lootSkip[rKey] == true then
				return false
			end
		end
		return true
	end

	local function getDesiredBossDrops(rootPos, arenaPos, maxRadius)
		local botCfg = nil
		local rawBotJson = LocalPlayer:GetAttribute("BotJson")
		if type(rawBotJson) == "string" and #rawBotJson > 0 then
			local ok, decoded = pcall(function() return HttpService:JSONDecode(rawBotJson) end)
			if ok and type(decoded) == "table" then
				botCfg = decoded
			end
		end
		if botCfg and botCfg.Loot == false then
			return {}
		end

		local lootSkip = (botCfg and type(botCfg.LootSkip) == "table") and botCfg.LootSkip or {}
		local stats = getBagStats()
		local isBagFull = stats.isFull

		local CS = game:GetService("CollectionService")
		local serverNow = workspace:GetServerTimeNow()
		local myUserId = LocalPlayer.UserId
		local radius = maxRadius or 95.0
		local results = {}

		for _, drop in ipairs(CS:GetTagged("Drop")) do
			if drop and drop.Parent and drop:IsA("BasePart") then
				local owner = tonumber(drop:GetAttribute("OwnerUserId")) or 0
				local freeAt = tonumber(drop:GetAttribute("FreeAt")) or 0
				if owner == 0 or owner == myUserId or freeAt <= serverNow then
					local kind = drop:GetAttribute("DropKind") or "gear"
					local rarity = tonumber(drop:GetAttribute("DropRarity")) or 0
					if (not isBagFull) or kind == "coin" then
						if isLootAllowedByBotCfg(lootSkip, kind, rarity) then
							local dRoot = rootPos and (drop.Position - rootPos).Magnitude or math.huge
							local dArena = arenaPos and (drop.Position - arenaPos).Magnitude or math.huge
							if dRoot <= radius or dArena <= radius then
								table.insert(results, {
									part = drop,
									dist = dRoot,
									kind = kind,
									rarity = rarity,
								})
							end
						end
					end
				end
			end
		end

		table.sort(results, function(a, b)
			return a.dist < b.dist
		end)
		return results
	end
	HUB.GetDesiredBossDrops = getDesiredBossDrops

	local function findLiveBossModel(bDef)
		if not bDef then return nil end
		local CS = game:GetService("CollectionService")
		for _, m in ipairs(CS:GetTagged("Monster")) do
			if m:GetAttribute("MonsterId") == bDef.id and (tonumber(m:GetAttribute("HP")) or 0) > 0 then
				return m
			end
		end
		return nil
	end

	local function isBossAlive(bDef)
		if not bDef then return false end
		local attr = workspace:GetAttribute("BossAlive_" .. bDef.id)
		if type(attr) == "boolean" then
			return attr
		end
		return findLiveBossModel(bDef) ~= nil
	end

	local function getBossCountdown(bDef)
		if not bDef then return 0 end
		local nextT = tonumber(workspace:GetAttribute("BossNext_" .. bDef.id)) or 0
		if nextT > 0 then
			return math.max(0, math.ceil(nextT - workspace:GetServerTimeNow()))
		end
		return 0
	end

	local function getNextCandidateBoss(excludeKey)
		local myLevel = LocalPlayer:GetAttribute("Level") or 1
		local preSpawnSec = HUB.Config.bossPreSpawnThreshold or 15

		-- ลำดับ 1: บอสที่เกิดอยู่แล้ว (Alive Now)
		for _, b in ipairs(BOSS_DEFS) do
			if b.key ~= excludeKey and HUB.Config.farmBossList and HUB.Config.farmBossList[b.key] == true then
				if myLevel >= (b.minLevel or 0) and isBossAlive(b) then
					return b, true, 0
				end
			end
		end

		-- ลำดับ 2: บอสที่กำลังจะเกิดใน <= 15 วินาที (Pre-Spawn Standby)
		local soonestBoss = nil
		local minCd = preSpawnSec + 0.1
		for _, b in ipairs(BOSS_DEFS) do
			if b.key ~= excludeKey and HUB.Config.farmBossList and HUB.Config.farmBossList[b.key] == true then
				if myLevel >= (b.minLevel or 0) then
					local cd = getBossCountdown(b)
					if cd > 0 and cd <= preSpawnSec then
						if cd < minCd then
							minCd = cd
							soonestBoss = b
						end
					end
				end
			end
		end

		if soonestBoss then
			return soonestBoss, false, minCd
		end

		return nil, false, 0
	end
	local getNextAliveSelectedBoss = getNextCandidateBoss
	HUB.GetNextCandidateBoss = getNextCandidateBoss
	HUB.HasAliveSelectedBoss = function()
		local b = getNextCandidateBoss()
		return b ~= nil
	end

	local function runAutoBossRoutine()
		if _isBossRoutine or not HUB.Alive or not HUB.Config.autoFarmBoss or EXEC.env.HuntingTogetherHub_Token ~= MY_TOKEN then return end
		local char = LocalPlayer.Character
		local root = char and char:FindFirstChild("HumanoidRootPart")
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		if not root or not hum or hum.Health <= 0 then return end

		local targetBoss = getNextAliveSelectedBoss()
		if not targetBoss then
			if HUB.UI.BossStatusLabel and HUB.Config.autoFarmBoss then
				HUB.UI.BossStatusLabel.Text = "สถานะ: เปิดใช้งาน · สแตนด์บายรอบอสเกิด..."
			end
			return
		end

		_isBossRoutine = true
		_cancelBossRoutine = false
		HUB.IsBossRoutineActive = true
		HUB.BossRoutineStartTime = os.clock()

		local success, err = pcall(function()
			local function shouldAbort()
				return not HUB.Alive or not HUB.Config.autoFarmBoss or _cancelBossRoutine or EXEC.env.HuntingTogetherHub_Token ~= MY_TOKEN
			end

			-- 1. บันทึกจุดฟาร์มเดิมผ่าน Central Origin Engine (ถ้ายังไม่มี)
			captureOriginIfNeeded()
			local LumiMenuToggle = LocalPlayer:FindFirstChild("LumiMenuToggle")
			local LumiLockTarget = LocalPlayer:FindFirstChild("LumiLockTarget")

			-- ปิด Auto Play ทันทีตั้งแต่เริ่มรูทีนล่าบอส เพื่อไม่ให้ CombatClient แย่งเดินไปตีมอนสเตอร์ระหว่างวิ่งไปเสาวาร์ป (Fix v9.7)
			if HUB.DisableGameAutoPlay then
				HUB.DisableGameAutoPlay()
			end

			while targetBoss and not shouldAbort() do
				if HUB.UI.BossStatusLabel then
					local cd = getBossCountdown(targetBoss)
					if isBossAlive(targetBoss) then
						HUB.UI.BossStatusLabel.Text = string.format("สถานะ: กำลังเดินทางไปล่า %s (%s)...", targetBoss.name, targetBoss.levelText)
					else
						HUB.UI.BossStatusLabel.Text = string.format("สถานะ: บอสจะเกิดใน %d วิ — เดินทางไปรอ %s (%s)...", cd, targetBoss.name, targetBoss.levelText)
					end
				end

				-- ยืนยันปิด Auto Play และปลดล็อกมอนสเตอร์ก่อนออกเดินไปเสาวาร์ปทุกครั้ง
				if HUB.DisableGameAutoPlay then
					HUB.DisableGameAutoPlay()
				end

				char = LocalPlayer.Character
				root = char and char:FindFirstChild("HumanoidRootPart")
				if not root then break end

				-- 2. เดินทางไปยังเสาของ targetBoss
				local warpPillarsFolder = workspace:FindFirstChild("Map") and workspace.Map:FindFirstChild("WarpPillars")
				local currentNearPillar = nil
				local inTown = (root.Position.Z > -200)
				local distToTargetArena = (root.Position - targetBoss.arenaPos).Magnitude

				-- หากตัวละครไม่ได้อยู่ที่ห้องบอสเป้าหมายอยู่แล้ว (ห่างเกิน 120 studs) จึงต้องเดินทางผ่านเสาวาร์ป
				if distToTargetArena > 120.0 then
					-- ค้นหาเสาวาร์ปที่ปลดล็อคแล้วที่อยู่ใกล้ตัวละครที่สุดโดยตรง (Direct Nearest Pillar Walk — Zero HomeWarp)
					local nearestP, minD = getNearestUnlockedPillar(root.Position)
					if nearestP then
						currentNearPillar = nearestP
						local nearPillarName = nearestP:GetAttribute("WarpId") or nearestP.Name
						if HUB.UI.BossStatusLabel then
							HUB.UI.BossStatusLabel.Text = string.format("สถานะ: เดินไปเสาวาร์ปใกล้สุด (%s) เพื่อไปล่า %s...", tostring(nearPillarName), targetBoss.name)
						end
					else
						currentNearPillar = warpPillarsFolder and warpPillarsFolder:FindFirstChild("WarpPillar_Town")
					end

					if shouldAbort() then return end

					-- 3. สั่งวาร์ปไปยังเสาของเป้าหมาย (targetBoss.pillarId) พร้อม Synchronization & Silver Guard
					local warpedToBoss = executePillarWarp(currentNearPillar, targetBoss.pillarId, shouldAbort)

					-- Caller-Level Smart Retry: หากวาร์ปไปหาบอสไม่สำเร็จ ให้ Re-check เสาและลองใหม่อีก 1 รอบ
					if not warpedToBoss and not shouldAbort() then
						task.wait(0.4)
						char = LocalPlayer.Character
						root = char and char:FindFirstChild("HumanoidRootPart")
						if root then
							local rePillar = getNearestUnlockedPillar(root.Position)
							if rePillar then
								if HUB.UI.BossStatusLabel then
									HUB.UI.BossStatusLabel.Text = string.format("สถานะ: วาร์ปไม่สำเร็จ — กำลังลองใหม่รอบที่ 2 ไปยัง %s...", targetBoss.name)
								end
								warpedToBoss = executePillarWarp(rePillar, targetBoss.pillarId, shouldAbort)
							end
						end
					end

					if not warpedToBoss then
						if HUB.UI.BossStatusLabel then
							HUB.UI.BossStatusLabel.Text = "สถานะ: วาร์ปไปหาบอสไม่สำเร็จ · กำลังเดินทางกลับจุดเดิม..."
						end
						break
					end
				end

				char = LocalPlayer.Character
				root = char and char:FindFirstChild("HumanoidRootPart")
				if not root or (root.Position - targetBoss.arenaPos).Magnitude > 500.0 then
					warn("[Hunting Together Hub] Auto Boss: ตัวละครอยู่ห่างจากห้องบอสเกิน 500 studs (วาร์ปไม่ถึง) — ยกเลิกการวิ่งชนกำแพง")
					break
				end

				-- 4. เดินจากเสาบอสเข้าสู่ห้องบอส (รองรับกรณีมีผู้เล่นอื่นกำลังสู้อยู่และบอสเดินออกห่างจุดเกิดหรือกำลังร่ายวงแดง)
				if HUB.UI.BossStatusLabel then
					local cd = getBossCountdown(targetBoss)
					if isBossAlive(targetBoss) then
						HUB.UI.BossStatusLabel.Text = string.format("สถานะ: ถึงโซนแล้ว กำลังเดินเข้าห้องบอส %s...", targetBoss.name)
					else
						HUB.UI.BossStatusLabel.Text = string.format("สถานะ: ถึงโซนแล้ว กำลังเดินไปรอ %s เกิด (อีก %d วิ)...", targetBoss.name, cd)
					end
				end

				local liveBossOnArrive = findLiveBossModel(targetBoss)
				local walkTargetPos = (liveBossOnArrive and liveBossOnArrive.PrimaryPart and liveBossOnArrive.PrimaryPart.Position) or targetBoss.arenaPos

				local preSpawnSec = HUB.Config.bossPreSpawnThreshold or 15
				local bossDiedOnWay = false

				navigatePath(walkTargetPos, {
					stopDistance = 26.0,
					timeout = 16.0,
					sprint = true,
					shouldAbort = shouldAbort,
					customReached = function(rPos)
						-- ตรวจจับว่าบอสถูกคนอื่นฆ่าตายไประหว่างกำลังเดินหรือไม่ (cd > preSpawnSec)
						local cd = getBossCountdown(targetBoss)
						if not isBossAlive(targetBoss) and not findLiveBossModel(targetBoss) and cd > preSpawnSec then
							bossDiedOnWay = true
							return true -- ตัดจบการเดินทันที ไม่ต้องเดินเข้าไปยังห้องว่างเปล่า
						end
						local lb = findLiveBossModel(targetBoss)
						if lb and lb.PrimaryPart then
							local bPos = lb.PrimaryPart.Position
							local dBoss = Vector3.new(bPos.X - rPos.X, 0, bPos.Z - rPos.Z).Magnitude
							if dBoss <= 38.0 then
								return true
							end
						end
						local dArena = Vector3.new(targetBoss.arenaPos.X - rPos.X, 0, targetBoss.arenaPos.Z - rPos.Z).Magnitude
						if dArena <= 32.0 then
							return true
						end
						-- หากเข้าใกล้ห้องบอสแล้ว (<= 75 studs) และเกิดวงแดงจน Smart Dodge ทำงาน ให้ตัดเข้าโหมดต่อสู้ทันทีเพื่อเปิด Auto Play
						if dArena <= 75.0 and HUB.Dodging then
							return true
						end
						return false
					end,
				})

				if shouldAbort() then return end

				local cdOnArrival = getBossCountdown(targetBoss)
				local isDeadOnArrival = bossDiedOnWay or (not isBossAlive(targetBoss) and not findLiveBossModel(targetBoss) and cdOnArrival > preSpawnSec)

				-- 4.5 Pre-Spawn Standby: หากบอสยังไม่เกิด ให้นั่ง/ยืนรอที่ห้องบอส จนกว่าบอสจะเกิดจริง
				if not isDeadOnArrival and not isBossAlive(targetBoss) and not findLiveBossModel(targetBoss) then
					local waitSpawnStart = os.clock()
					local maxWait = math.min(cdOnArrival + 2.5, preSpawnSec + 5.0)
					while not shouldAbort() and (os.clock() - waitSpawnStart < maxWait) do
						if isBossAlive(targetBoss) or findLiveBossModel(targetBoss) then
							break
						end
						local cd = getBossCountdown(targetBoss)
						if cd > preSpawnSec then
							isDeadOnArrival = true
							break
						end
						if HUB.UI.BossStatusLabel then
							HUB.UI.BossStatusLabel.Text = string.format("สถานะ: สแตนด์บายรอ %s เกิดใน %d วิ...", targetBoss.name, cd)
						end
						task.wait(0.3)
					end
				end

				if shouldAbort() then return end

				-- 5. สู้บอส:
				local bossDefeated = false
				local foughtBoss = false

				if isDeadOnArrival then
					pcall(function()
						hum:Move(Vector3.zero, false)
						hum:MoveTo(root.Position)
					end)
					if HUB.UI.BossStatusLabel then
						HUB.UI.BossStatusLabel.Text = string.format("สถานะ: %s ถูกกำจัดไปแล้ว (เกิดใหม่อีก %d วิ) — กำลังสลับเป้าหมาย...", targetBoss.name, cdOnArrival)
					end
					task.wait(0.2)
				else
					-- เปิดใช้งาน Auto Attack ของเกม + ล็อกเป้าหมายบอสผ่าน LumiLockTarget (รองรับกรณีมีคนอื่นตีบอสอยู่แล้ว 100%)
					if HUB.EnsureGameAutoActive then
						HUB.EnsureGameAutoActive(6, 0.25)
					elseif LumiMenuToggle then
						pcall(function() LumiMenuToggle:Fire("autoToggle") end)
					end

					local initialBossModel = findLiveBossModel(targetBoss)
					if initialBossModel then
						foughtBoss = true
						local ct = LocalPlayer:FindFirstChild("CurrentTarget")
						if ct then
							pcall(function() ct.Value = initialBossModel end)
						end
						if LumiLockTarget then
							pcall(function() LumiLockTarget:Fire(initialBossModel) end)
						end
					end

					if HUB.UI.BossStatusLabel then
						HUB.UI.BossStatusLabel.Text = string.format("สถานะ: กำลังต่อสู้กับบอส %s...", targetBoss.name)
					end

					-- วนลูปรอสู้จนบอสตาย พร้อมรักษาล็อกเป้าหมายและ Auto Play ตลอดการต่อสู้
					local fightStart = os.clock()
					while os.clock() - fightStart < 180.0 and not shouldAbort() do
						task.wait(0.5)
						char = LocalPlayer.Character
						root = char and char:FindFirstChild("HumanoidRootPart")
						hum = char and char:FindFirstChildOfClass("Humanoid")
						if not root or not hum or hum.Health <= 0 then break end

						if not isBossAlive(targetBoss) then
							bossDefeated = true
							break
						end

						-- รักษาสถานะ Auto Play ให้เปิดอยู่เสมอระหว่างสู้บอส
						if not HUB.IsGameAutoActive() and HUB.EnsureGameAutoActive then
							HUB.EnsureGameAutoActive(3, 0.2)
						end

						-- ล็อกเป้าบอสผ่าน LumiLockTarget หากยังไม่ได้ล็อกบอส (ป้องกันกรณีมีคนอื่นถือ ThreatUserId แล้วบอทไม่ยอมตี)
						local liveBoss = findLiveBossModel(targetBoss)
						if liveBoss and liveBoss.PrimaryPart then
							foughtBoss = true
							local ct = LocalPlayer:FindFirstChild("CurrentTarget")
							if not ct or ct.Value ~= liveBoss then
								if ct then
									pcall(function() ct.Value = liveBoss end)
								end
								if LumiLockTarget then
									pcall(function() LumiLockTarget:Fire(liveBoss) end)
								end
							end
							-- หากบอสอยู่ห่างเกิน 32 studs และไม่ได้กำลังหลบวงแดง ให้ช่วยเดินเข้าหาบอส
							local bPos = liveBoss.PrimaryPart.Position
							local flatDist = Vector3.new(bPos.X - root.Position.X, 0, bPos.Z - root.Position.Z).Magnitude
							if flatDist > 32.0 and not HUB.Dodging then
								setSprinting(true)
								hum:MoveTo(bPos)
							end
						end
					end
				end

				if bossDefeated and foughtBoss then
					HUB.Stats.bossesDefeated = (HUB.Stats.bossesDefeated or 0) + 1
					local pickupDropRemote = remotes and remotes:FindFirstChild("PickupDrop")
					local currentTargetObj = LocalPlayer:FindFirstChild("CurrentTarget")

					-- 5.1 รอแอนิเมชันบอสตาย (BossSlow 0.85s) และไอเทมดรอปพุ่งกระจายลงพื้น (~1.5s - 2.2s)
					if HUB.UI.BossStatusLabel then
						HUB.UI.BossStatusLabel.Text = string.format("สถานะ: ปราบ %s สำเร็จ! รอของดรอปตกลงพื้น...", targetBoss.name)
					end

					local spawnWaitStart = os.clock()
					while os.clock() - spawnWaitStart < 2.2 and not shouldAbort() do
						task.wait(0.2)
						char = LocalPlayer.Character
						root = char and char:FindFirstChild("HumanoidRootPart")
						if root then
							local initialDrops = getDesiredBossDrops(root.Position, targetBoss.arenaPos, 95.0)
							if #initialDrops > 0 and (os.clock() - spawnWaitStart) >= 1.2 then
								break
							end
						end
					end

					-- 5.2 ลูปรอและช่วยระบบ Auto Play ของเกมเก็บของที่ต้องการจนครบทุกชิ้น (สูงสุด 18 วินาที)
					local lootStart = os.clock()
					local lastPickupFire = 0
					local emptyStreak = 0

					while os.clock() - lootStart < 18.0 and not shouldAbort() do
						char = LocalPlayer.Character
						root = char and char:FindFirstChild("HumanoidRootPart")
						hum = char and char:FindFirstChildOfClass("Humanoid")
						if not root or not hum or hum.Health <= 0 then break end

						local desiredDrops = getDesiredBossDrops(root.Position, targetBoss.arenaPos, 95.0)
						if #desiredDrops == 0 then
							emptyStreak = emptyStreak + 1
							if emptyStreak >= 3 then
								break
							end
							task.wait(0.2)
						else
							emptyStreak = 0
							if HUB.UI.BossStatusLabel then
								HUB.UI.BossStatusLabel.Text = string.format("สถานะ: ปราบ %s สำเร็จ! กำลังเก็บของที่ต้องการ (เหลือ %d ชิ้น)...", targetBoss.name, #desiredDrops)
							end

							-- รักษาสถานะ Auto Play ให้ทำงาน และเคลียร์เป้าหากเผลอล็อกมอนสเตอร์ลูกน้องขณะยังมีของดรอป
							if HUB.EnsureGameAutoActive then
								HUB.EnsureGameAutoActive()
							end
							if currentTargetObj and currentTargetObj.Value ~= nil then
								currentTargetObj.Value = nil
							end

							-- ช่วยพาตัวละครสปรินต์เข้าหาของชิ้นที่ใกล้ที่สุด (รองรับทั้งกรณีเปิดสัตว์เลี้ยงและไม่เปิดสัตว์เลี้ยง)
							local nearestDrop = desiredDrops[1]
							if nearestDrop and nearestDrop.part and nearestDrop.part.Parent then
								local dropPos = nearestDrop.part.Position
								local flatOffset = Vector3.new(dropPos.X - root.Position.X, 0, dropPos.Z - root.Position.Z)
								local flatDist = flatOffset.Magnitude

								if not HUB.Dodging then
									setSprinting(true)
									if flatDist > 2.2 then
										hum:Move(flatOffset.Unit, false)
									else
										hum:Move(Vector3.zero, false)
									end
								end

								-- ยิง PickupDrop:FireServer(true) เมื่ออยู่ในระยะเก็บ (<= 8.0 studs) ตามมาตรฐาน Auto Play ของเกม
								if flatDist <= 8.0 and pickupDropRemote and (os.clock() - lastPickupFire >= 0.35) then
									lastPickupFire = os.clock()
									pcall(function()
										pickupDropRemote:FireServer(true)
									end)
								end
							end

							task.wait(0.15)
						end
					end

					setSprinting(false)
					-- ปิด Auto-Hunt ชั่วคราวเพื่อให้เดินนำทาง/วาร์ปได้โดยไม่ถูกดึงไปตีมอนสเตอร์ข้างทาง
					if HUB.DisableGameAutoPlay then
						HUB.DisableGameAutoPlay()
					elseif LumiMenuToggle and LocalPlayer:GetAttribute("AutoOn") == true then
						pcall(function() LumiMenuToggle:Fire("autoToggle") end)
						task.wait(0.1)
					end
				else
					setSprinting(false)
					if HUB.DisableGameAutoPlay then
						HUB.DisableGameAutoPlay()
					end
				end

				if shouldAbort() then return end

				-- 6. เช็คบอสตัวถัดไป (ไม่ต้องสั่งเดินซ้ำที่นี่ เพราะรอบถัดไป executePillarWarp จะเดินไปหาเสาที่ใกล้ที่สุดและกดวาร์ปให้ทันที)
				local nextBoss = getNextAliveSelectedBoss(targetBoss.key)
				if nextBoss then
					if HUB.UI.BossStatusLabel then
						HUB.UI.BossStatusLabel.Text = string.format("สถานะ: สลับไปล่าบอสตัวถัดไป: %s (%s)...", nextBoss.name, nextBoss.levelText)
					end
					targetBoss = nextBoss
				else
					if HUB.UI.BossStatusLabel then
						HUB.UI.BossStatusLabel.Text = "สถานะ: ไม่มีบอสอื่นที่พร้อมล่า — กำลังเดินทางกลับจุดเดิม..."
					end
					targetBoss = nil
				end
			end

			-- 7. ตรวจสอบการย่อยอุปกรณ์ (Auto Salvage) หรือส่งไม้ต่อให้ Auto Sell (Smart Handoff)
			if HUB.Config.autoSalvage and HUB.RunAutoSalvageRoutine then
				local stats = getBagStats()
				local sThresh = HUB.Config.autoSalvageThresholdPct or 85
				if stats.pct >= sThresh or (sThresh == 100 and stats.isFull) then
					if HUB.UI.BossStatusLabel then
						HUB.UI.BossStatusLabel.Text = "สถานะ: ปราบครบแล้ว · ย่อยอุปกรณ์เบื้องหลัง..."
					end
					HUB.RunAutoSalvageRoutine()
					task.wait(0.3)
				end
			end

			if HUB.IsAutoSellNeeded and HUB.IsAutoSellNeeded() then
				if HUB.UI.BossStatusLabel then
					HUB.UI.BossStatusLabel.Text = "สถานะ: ปราบครบแล้ว · กระเป๋าเต็มเกณฑ์ -> ส่งไม้ต่อให้ Auto Sell"
				end
				_isBossRoutine = false
				HUB.IsBossRoutineActive = false
				task.spawn(function()
					task.wait(0.2)
					if HUB.RunAutoSellRoutine then HUB.RunAutoSellRoutine() end
				end)
				return
			end

			returnToOrigin(shouldAbort, function(text)
				if HUB.UI.BossStatusLabel then HUB.UI.BossStatusLabel.Text = text end
			end)
		end)

		if not success and err then
			warn("[Hunting Together Hub] Auto Boss Routine Error: " .. tostring(err))
		end

		_isBossRoutine = false
		HUB.IsBossRoutineActive = false
		HUB.BossRoutineStartTime = nil
		if HUB.UI.BossStatusLabel then
			if HUB.Config.autoFarmBoss then
				HUB.UI.BossStatusLabel.Text = "สถานะ: พร้อมทำงาน · สแตนด์บายรอบอสเกิด..."
			else
				HUB.UI.BossStatusLabel.Text = "สถานะ: ปิดใช้งาน"
			end
		end
	end

	HUB.RunAutoBossRoutine = runAutoBossRoutine
	HUB.CancelAutoBossRoutine = function()
		_cancelBossRoutine = true
		_isBossRoutine = false
		HUB.IsBossRoutineActive = false
		HUB.BossRoutineStartTime = nil
		if not HUB.Config.autoSell and not HUB.Config.autoFarmBoss then
			clearOrigin()
		end
		pcall(function()
			local char = LocalPlayer.Character
			local root = char and char:FindFirstChild("HumanoidRootPart")
			local hum = char and char:FindFirstChildOfClass("Humanoid")
			if root then root.Anchored = false end
			if hum and root then hum:MoveTo(root.Position) end
		end)
		if HUB.UI.BossStatusLabel and not HUB.Config.autoFarmBoss then
			HUB.UI.BossStatusLabel.Text = "สถานะ: ปิดใช้งาน"
		end
	end
	HUB.IsBossAlive = isBossAlive
	HUB.GetBossCountdown = getBossCountdown
	HUB.CheckAndTriggerAutoBoss = function()
		if not _isBossRoutine and HUB.Config.autoFarmBoss then
			local candidate = getNextAliveSelectedBoss()
			if candidate and not HUB.Navigating and not HUB.Dodging and not HUB.IsSellingRoutineActive then
				task.spawn(runAutoBossRoutine)
			end
		end
	end

	-- Startup Grace Check: หากเปิดใช้งานไว้ตั้งแต่โหลดสคริปต์ ให้รอ 4.5s แล้วเช็คบอส
	if HUB.Config.autoFarmBoss then
		task.delay(4.5, function()
			if HUB.Alive and EXEC.env.HuntingTogetherHub_Token == MY_TOKEN and HUB.Config.autoFarmBoss then
				HUB.CheckAndTriggerAutoBoss()
			end
		end)
	end

	-- Background Watcher: ตรวจจับบอสเกิดหรือกำลังจะเกิดล่วงหน้าเป็นระยะทุก 1 วินาที
	task.spawn(function()
		while HUB.Alive and EXEC.env.HuntingTogetherHub_Token == MY_TOKEN do
			task.wait(1.0)
			if HUB.Config.autoFarmBoss and not _isBossRoutine and not HUB.Navigating and not HUB.Dodging then
				local candidate = getNextAliveSelectedBoss()
				if candidate and not HUB.IsSellingRoutineActive then
					task.spawn(runAutoBossRoutine)
				end
			end
		end
	end)

	-- 9.30 Self-Healing Watchdog (ทุก 5 วินาที): ตรวจจับและปลดล็อค Flag / Routine ที่ค้างเกินเวลาแบบอัตโนมัติ
	task.spawn(function()
		local _stuckBossCount = 0
		while HUB.Alive and EXEC.env.HuntingTogetherHub_Token == MY_TOKEN do
			task.wait(5.0)
			local now = os.clock()

			-- 1. Boss Routine Watchdog: หากรูทีนล่าบอสค้างเกิน 240 วินาที ให้สั่ง Force-Reset ทันที
			if _isBossRoutine or HUB.IsBossRoutineActive then
				if HUB.BossRoutineStartTime and (now - HUB.BossRoutineStartTime > 240.0) then
					warn("[Hunting Together Hub] Watchdog: Auto Boss ค้างเกิน 240s — ปลดล็อคสถานะอัตโนมัติ")
					if HUB.CancelAutoBossRoutine then pcall(HUB.CancelAutoBossRoutine) end
					_isBossRoutine = false
					HUB.IsBossRoutineActive = false
					HUB.Navigating = false
					HUB.BossRoutineStartTime = nil
				end
			else
				HUB.BossRoutineStartTime = nil
			end

			-- 2. Sell Routine Watchdog: หากรูทีนขายของค้างเกิน 90 วินาที ให้สั่ง Force-Reset ทันที
			if HUB.IsSellingRoutineActive then
				if HUB.SellRoutineStartTime and (now - HUB.SellRoutineStartTime > 90.0) then
					warn("[Hunting Together Hub] Watchdog: Auto Sell ค้างเกิน 90s — ปลดล็อคสถานะอัตโนมัติ")
					if HUB.CancelAutoSellRoutine then pcall(HUB.CancelAutoSellRoutine) end
					HUB.IsSellingRoutineActive = false
					HUB.Navigating = false
					HUB.SellRoutineStartTime = nil
				end
			else
				HUB.SellRoutineStartTime = nil
			end

			-- 3. Monster Zone Idle Self-Healing: ยืนนิ่งในทุ่งมอนสเตอร์ (Z <= -300) โดยไม่ได้ติดรูทีนใดๆ แต่ Auto Play ปิดอยู่
			if not _isBossRoutine and not HUB.IsBossRoutineActive and not HUB.IsSellingRoutineActive and not HUB.Navigating and not HUB.Dodging then
				local ch = LocalPlayer.Character
				local rt = ch and ch:FindFirstChild("HumanoidRootPart")
				local hm = ch and ch:FindFirstChildOfClass("Humanoid")
				if rt and hm and hm.Health > 0 and rt.Position.Z <= -300 then
					if not HUB.UserDisabledAuto and not HUB.IsGameAutoActive() and HUB.Config.autoResumeGamePlay ~= false then
						_stuckBossCount = _stuckBossCount + 1
						if _stuckBossCount >= 3 then -- ยืนนิ่งเกิน 15 วินาที
							_stuckBossCount = 0
							if HUB.EnsureGameAutoActive then
								HUB.EnsureGameAutoActive(4, 0.3)
							end
						end
					else
						_stuckBossCount = 0
					end
				else
					_stuckBossCount = 0
				end
			end
		end
	end)
end

-- 9.3 Auto Dodge Controller (สปริ้นต์หลบวงแดงบอส/มินิบอส/ลีดเดอร์ & เข้าโซนเขียวบอสแมพ — Stamina Sprint + Auto-Play Cooperation)
do
	local remotes = ReplicatedStorage:WaitForChild("Remotes", 10)
	local bossFx = remotes and remotes:FindFirstChild("BossFx")
	local activeBossSkills = {}
	local currentEscapePos = nil
	local currentEscapeWaypoints = nil
	local currentEscapeWpIndex = 1

	-- ดึงค่าระยะเผื่อพ้นขอบวงแดง (Buffer) ที่ผู้ใช้ตั้งค่าไว้ในแท็บ Settings แบบ Realtime
	local function getDodgeBuffer()
		local val = tonumber(HUB.Config.dodgeBuffer)
		if val and val >= 2.0 and val <= 15.0 then
			return val
		end
		return 4.0
	end

	local function isPointInsideZone(point, zone, customBuffer)
		if zone.Safe then return false end
		local userBuf = getDodgeBuffer()
		local buffer = customBuffer or (userBuf * 0.75)
		local p2d = Vector3.new(point.X, 0, point.Z)

		if zone.Kind == "room" then
			-- Room สกิลต้องมี CFrame และขอบเขตจริงเท่านั้น ไม่ตีตราว่าทั้งโลกอันตราย
			if zone.CFrame and zone.Width and zone.Length then
				local localPt = zone.CFrame:PointToObjectSpace(point)
				local hw = (zone.Width / 2) + buffer
				local hl = (zone.Length / 2) + buffer
				return math.abs(localPt.X) <= hw and math.abs(localPt.Z) <= hl
			end
			return false
		elseif zone.Kind == "donut" and zone.Center then
			local c2d = Vector3.new(zone.Center.X, 0, zone.Center.Z)
			local d = (p2d - c2d).Magnitude
			local innerSafe = math.max(0, (zone.Inner or 15) - buffer)
			local outerDanger = (zone.Radius or 60) + buffer
			return d >= innerSafe and d <= outerDanger
		elseif zone.Kind == "circle" and zone.Center then
			local c2d = Vector3.new(zone.Center.X, 0, zone.Center.Z)
			return (p2d - c2d).Magnitude <= ((zone.Radius or 12) + buffer)
		elseif zone.Kind == "cone" and zone.Center and zone.Dir then
			local c2d = Vector3.new(zone.Center.X, 0, zone.Center.Z)
			local offset = p2d - c2d
			local dist = offset.Magnitude
			if dist <= ((zone.Radius or 35) + buffer) then
				if dist <= 1.0 then return true end
				local dir2d = (zone.Dir.Magnitude > 0.01) and Vector3.new(zone.Dir.X, 0, zone.Dir.Z).Unit or Vector3.new(0, 0, 1)
				local dot = math.clamp(offset.Unit:Dot(dir2d), -1, 1)
				local angle = math.acos(dot)
				local maxAngle = (zone.Half or 0.6) + 0.12
				return angle <= maxAngle
			end
		elseif (zone.Kind == "box" or zone.CFrame) and zone.CFrame then
			local localPt = zone.CFrame:PointToObjectSpace(point)
			local hw = ((zone.Width or 12) / 2) + buffer
			local hl = ((zone.Length or 35) / 2) + buffer
			return math.abs(localPt.X) <= hw and math.abs(localPt.Z) <= hl
		end
		return false
	end

	local function isCharacterInDanger(charPos, dangerZones)
		for _, z in ipairs(dangerZones) do
			if isPointInsideZone(charPos, z) then
				return true, z
			end
		end
		return false, nil
	end

	-- คำนวณจุดหลบออกจากขอบโซนแดงด้วยระยะทางที่สั้นที่สุดทางเรขาคณิต โดยอิงระยะเผื่อตามที่ผู้ใช้ตั้งไว้ใน Settings
	local function getShortestExitVector(charPos, badZone, customMargin)
		local userBuf = getDodgeBuffer()
		local margin = customMargin or userBuf
		local p2d = Vector3.new(charPos.X, 0, charPos.Z)

		-- 1. รูปทรงวงกลม (Circle)
		if badZone.Kind == "circle" and badZone.Center then
			local c2d = Vector3.new(badZone.Center.X, 0, badZone.Center.Z)
			local diff = p2d - c2d
			local d = diff.Magnitude
			local r = badZone.Radius or 12
			local dir = d > 0.05 and (diff / d) or Vector3.new(0, 0, 1)
			return c2d + dir * (r + margin)

		-- 2. รูปทรงกล่อง / พุ่งชน (Box)
		elseif (badZone.Kind == "box" or badZone.CFrame) and badZone.CFrame then
			local cf = badZone.CFrame
			local localPt = cf:PointToObjectSpace(charPos)
			local hw = (badZone.Width or 12) / 2
			local hl = (badZone.Length or 35) / 2

			local signX = localPt.X >= 0 and 1 or -1
			local signZ = localPt.Z >= 0 and 1 or -1
			local exitX = signX * (hw + margin)
			local exitZ = signZ * (hl + margin)
			local distToExitX = math.abs(exitX - localPt.X)
			local distToExitZ = math.abs(exitZ - localPt.Z)

			if distToExitX < distToExitZ then
				-- ออกด้านข้าง (Lateral) สั้นกว่า
				return cf:PointToWorldSpace(Vector3.new(exitX, 0, localPt.Z))
			else
				-- ออกด้านหน้า/หลัง สั้นกว่า
				return cf:PointToWorldSpace(Vector3.new(localPt.X, 0, exitZ))
			end

		-- 3. รูปทรงกรวย (Cone)
		elseif badZone.Kind == "cone" and badZone.Center and badZone.Dir then
			local c2d = Vector3.new(badZone.Center.X, 0, badZone.Center.Z)
			local dir2d = (badZone.Dir.Magnitude > 0.01) and Vector3.new(badZone.Dir.X, 0, badZone.Dir.Z).Unit or Vector3.new(0, 0, 1)
			local diff = p2d - c2d
			local d = diff.Magnitude
			local halfAngle = badZone.Half or 0.6
			local r = badZone.Radius or 35

			-- ทางเลือก ก: ถอยหลังพ้นโคนกรวย
			local candRear = c2d - dir2d * margin
			local distRear = (p2d - candRear).Magnitude

			-- ทางเลือก ข: ก้าวออกด้านข้างตั้งฉากกับแนวแกนกรวย (Side Step)
			local sideUnit = Vector3.new(-dir2d.Z, 0, dir2d.X).Unit
			local sideDot = diff:Dot(sideUnit)
			local sideSign = sideDot >= 0 and 1 or -1
			local tanHalf = math.tan(halfAngle)
			local forwardDist = math.clamp(diff:Dot(dir2d), 0, r)
			local halfWidthAtDist = forwardDist * tanHalf
			local candSide = c2d + (dir2d * forwardDist) + (sideUnit * sideSign * (halfWidthAtDist + margin))
			local distSide = (p2d - candSide).Magnitude

			-- ทางเลือก ค: พุ่งตรงไปข้างหน้าพ้นปลายกรวย
			local candFront = c2d + (dir2d * (r + margin))
			local distFront = (p2d - candFront).Magnitude

			if distSide <= distRear and distSide <= distFront then
				return candSide
			elseif distRear <= distFront then
				return candRear
			else
				return candFront
			end

		-- 4. รูปทรงโดนัท (Donut)
		elseif badZone.Kind == "donut" and badZone.Center then
			local c2d = Vector3.new(badZone.Center.X, 0, badZone.Center.Z)
			local diff = p2d - c2d
			local d = diff.Magnitude
			local dir = d > 0.05 and (diff / d) or Vector3.new(0, 0, 1)
			local rInner = badZone.Inner or 15
			local rOuter = badZone.Radius or 60
			local distToInner = d - rInner
			local distToOuter = rOuter - d

			if distToInner < distToOuter and distToInner > 0 then
				return c2d + dir * math.max(0, rInner - margin)
			else
				return c2d + dir * (rOuter + margin)
			end
		end

		return nil
	end

	-- ตรวจสอบว่าเส้นทางจาก fromPos ไปยัง toPos โล่งและไม่ติดกำแพงหรือสิ่งกีดขวาง
	local function isPathClear(fromPos, toPos, character)
		local delta = toPos - fromPos
		local dist = delta.Magnitude
		if dist < 0.3 then return true end
		local dir = delta.Unit

		local rp = RaycastParams.new()
		rp.FilterType = Enum.RaycastFilterType.Exclude
		rp.RespectCanCollide = true
		local filter = {}
		if character then table.insert(filter, character) end
		local bossFxFolder = workspace:FindFirstChild("LumiBossFx")
		if bossFxFolder then table.insert(filter, bossFxFolder) end
		rp.FilterDescendantsInstances = filter

		local startPos = fromPos + Vector3.new(0, 1.5, 0)
		local centerHit = workspace:Raycast(startPos, dir * dist, rp)
		if centerHit and centerHit.Instance and centerHit.Instance.CanCollide then
			return false, centerHit
		end

		-- Whisker rays: ตรวจสอบความกว้างของตัวละคร (+/- 1.1 studs ด้านข้าง)
		local perp = Vector3.new(-dir.Z, 0, dir.X)
		if perp.Magnitude > 0.01 then
			perp = perp.Unit * 1.1
			local leftHit = workspace:Raycast(startPos + perp, dir * dist, rp)
			if leftHit and leftHit.Instance and leftHit.Instance.CanCollide then
				return false, leftHit
			end
			local rightHit = workspace:Raycast(startPos - perp, dir * dist, rp)
			if rightHit and rightHit.Instance and rightHit.Instance.CanCollide then
				return false, rightHit
			end
		end

		return true, nil
	end

	-- วัดระยะทางที่เดินได้จริงตามแนว flatDir ก่อนจะชนกำแพงหรือสิ่งกีดขวาง
	local function getClearDistance(fromPos, dir, maxRange, character)
		local flatDir = Vector3.new(dir.X, 0, dir.Z)
		if flatDir.Magnitude < 0.01 then return maxRange, nil end
		flatDir = flatDir.Unit

		local rp = RaycastParams.new()
		rp.FilterType = Enum.RaycastFilterType.Exclude
		rp.RespectCanCollide = true
		local filter = {}
		if character then table.insert(filter, character) end
		local bossFxFolder = workspace:FindFirstChild("LumiBossFx")
		if bossFxFolder then table.insert(filter, bossFxFolder) end
		rp.FilterDescendantsInstances = filter

		local startPos = fromPos + Vector3.new(0, 1.5, 0)
		local hit = workspace:Raycast(startPos, flatDir * maxRange, rp)
		if hit and hit.Instance and hit.Instance.CanCollide then
			local d = (hit.Position - startPos).Magnitude
			return math.max(0, d - 1.2), hit
		end
		return maxRange, nil
	end

	-- ตรวจสอบว่าพิกัดเป้าหมายมีพื้นผิวรองรับที่เดินได้ (ไม่ตกเหวหรือหลุดออกนอกแมพ)
	local function isGroundWalkable(pos, character)
		local rp = RaycastParams.new()
		rp.FilterType = Enum.RaycastFilterType.Exclude
		rp.RespectCanCollide = true
		local filter = {}
		if character then table.insert(filter, character) end
		local bossFxFolder = workspace:FindFirstChild("LumiBossFx")
		if bossFxFolder then table.insert(filter, bossFxFolder) end
		rp.FilterDescendantsInstances = filter

		local hit = workspace:Raycast(pos + Vector3.new(0, 3.5, 0), Vector3.new(0, -12.0, 0), rp)
		if hit and hit.Instance and hit.Instance.CanCollide then
			return true, hit.Position
		end
		return false, nil
	end

	local function findEscapePosition(charPos, dangerZones, safeZones, character)
		-- กรณี 1: มี Safe Zone (Green Show) อยู่ในระยะต่อสู้จริง (<= 85 studs)
		if #safeZones > 0 then
			local bestSafe = nil
			local bestDist = math.huge
			for _, sz in ipairs(safeZones) do
				if sz.Center then
					local d = (charPos - sz.Center).Magnitude
					if d < bestDist and d <= 85 then
						bestDist = d
						bestSafe = sz
					end
				end
			end
			if bestSafe then
				local clear = isPathClear(charPos, bestSafe.Center, character)
				if clear then
					return bestSafe.Center, nil, bestSafe
				else
					local p = PathfindingService:CreatePath({
						AgentRadius = 2.4,
						AgentHeight = 5.0,
						AgentCanJump = true,
					})
					local ok = pcall(function() p:ComputeAsync(charPos, bestSafe.Center) end)
					local pts = (ok and p.Status == Enum.PathStatus.Success) and p:GetWaypoints() or nil
					pcall(p.Destroy, p)
					if pts and #pts > 1 then
						local wps = {}
						for i = 2, #pts do
							table.insert(wps, { Position = pts[i].Position, Action = pts[i].Action })
						end
						return bestSafe.Center, wps, bestSafe
					end
					return bestSafe.Center, nil, bestSafe
				end
			end
		end

		local inDanger, badZone = isCharacterInDanger(charPos, dangerZones)
		if not inDanger or not badZone then return nil, nil, nil end

		local userMargin = getDodgeBuffer()

		-- ตัวเลือกอันดับ 1: ทางออกที่สั้นที่สุดทางเรขาคณิต (Shortest Exit Vector) อิงตาม Settings
		local shortestPos = getShortestExitVector(charPos, badZone, userMargin)
		local primaryHit = nil
		if shortestPos then
			local inOtherDanger = false
			for _, z in ipairs(dangerZones) do
				if z ~= badZone and isPointInsideZone(shortestPos, z, 1.2) then
					inOtherDanger = true
					break
				end
			end

			if not inOtherDanger then
				local clear, hit = isPathClear(charPos, shortestPos, character)
				local groundOk = isGroundWalkable(shortestPos, character)
				if clear and groundOk then
					return shortestPos, nil, badZone
				end
				primaryHit = hit
			end
		end

		-- ตัวเลือกอันดับ 2: ปรับเส้นทางใหม่ด้วย Smart Navigation (Obstacle-Aware Closest Exit Search)
		-- หากเส้นทางหลบเดิมติดกำแพง/สิ่งกีดขวาง ระบบจะสแกนหาเส้นทางใหม่ที่ไม่ติดกำแพง และพ้นโซนแดงในระยะที่สั้นที่สุด
		local bestCandidate = nil
		local bestDist = math.huge

		-- รวบรวมมุมทดสอบ: 24 ทิศทางรอบตัว (ทุก 15 องศา) + ทิศทางตามแนวระนาบกำแพง (Wall Tangent)
		local testAngles = {}
		for deg = 0, 345, 15 do
			table.insert(testAngles, math.rad(deg))
		end

		if primaryHit and primaryHit.Normal then
			local N = primaryHit.Normal
			local t1 = Vector3.new(-N.Z, 0, N.X)
			local t2 = Vector3.new(N.Z, 0, -N.X)
			if t1.Magnitude > 0.01 then
				local steer1 = (t1.Unit * 0.85 + Vector3.new(N.X, 0, N.Z).Unit * 0.25).Unit
				local steer2 = (t2.Unit * 0.85 + Vector3.new(N.X, 0, N.Z).Unit * 0.25).Unit
				table.insert(testAngles, math.atan2(steer1.Z, steer1.X))
				table.insert(testAngles, math.atan2(steer2.Z, steer2.X))
			end
		end

		for _, rad in ipairs(testAngles) do
			local dir = Vector3.new(math.cos(rad), 0, math.sin(rad)).Unit
			local clearDist = getClearDistance(charPos, dir, 50.0, character)

			-- มีระยะทางโล่งอย่างน้อย 2.5 studs (พอให้ตัวละครก้าวได้)
			if clearDist >= 2.5 then
				local minEscapeDist = nil
				local startDist = math.max(2.5, userMargin)
				local stepDist = 2.0
				for d = startDist, clearDist, stepDist do
					local testPt = charPos + dir * d
					local inAny = false
					for _, z in ipairs(dangerZones) do
						if isPointInsideZone(testPt, z, 1.2) then
							inAny = true
							break
						end
					end
					if not inAny then
						minEscapeDist = d
						break
					end
				end

				if minEscapeDist and minEscapeDist < bestDist then
					local candPt = charPos + dir * minEscapeDist
					local groundOk, groundPos = isGroundWalkable(candPt, character)
					if groundOk then
						candPt = Vector3.new(candPt.X, groundPos.Y, candPt.Z)
						local pathClear = isPathClear(charPos, candPt, character)
						if pathClear then
							bestCandidate = candPt
							bestDist = minEscapeDist
						end
					end
				end
			end
		end

		if bestCandidate then
			return bestCandidate, nil, badZone
		end

		-- ตัวเลือกอันดับ 3: Complex Geometry / L-Corner Fallback (PathfindingService)
		-- หากเส้นตรงทุกมุมถูกบล็อก (ติดในมุมอับ/ซอกกำแพง) ใช้ PathfindingService นำทางอ้อมสิ่งกีดขวาง
		if shortestPos then
			local p = PathfindingService:CreatePath({
				AgentRadius = 2.4,
				AgentHeight = 5.0,
				AgentCanJump = true,
			})
			local ok = pcall(function() p:ComputeAsync(charPos, shortestPos) end)
			local pts = (ok and p.Status == Enum.PathStatus.Success) and p:GetWaypoints() or nil
			pcall(p.Destroy, p)
			if pts and #pts > 1 then
				local wps = {}
				for i = 2, #pts do
					table.insert(wps, { Position = pts[i].Position, Action = pts[i].Action })
				end
				return shortestPos, wps, badZone
			end
		end

		return shortestPos or charPos, nil, badZone
	end

	-- ค้นหา Model บอสหรือมอนสเตอร์ที่กำลังสู้อยู่
	local function getTargetBossModel()
		local curTarget = LocalPlayer:FindFirstChild("CurrentTarget")
		local target = curTarget and curTarget.Value
		if target and target.Parent and target:IsA("Model") and target.PrimaryPart then
			local hp = tonumber(target:GetAttribute("HP")) or 0
			if hp > 0 then
				return target
			end
		end
		local char = LocalPlayer.Character
		local root = char and char:FindFirstChild("HumanoidRootPart")
		if root then
			local nearest = nil
			local nearestDist = 45
			for _, m in ipairs(CollectionService:GetTagged("Monster")) do
				if m:IsA("Model") and m.Parent and m.PrimaryPart then
					local hp = tonumber(m:GetAttribute("HP")) or 0
					if hp > 0 then
						local d = (m.PrimaryPart.Position - root.Position).Magnitude
						if d < nearestDist then
							nearestDist = d
							nearest = m
						end
					end
				end
			end
			return nearest
		end
		return nil
	end

	-- ค้นหาจุดตีรอบตัวบอสที่ไม่อยู่ในโซนแดง (Safe Boss Attack Positioning)
	local function findSafeBossAttackPosition(charPos, boss, dangerZones, character)
		if not (boss and boss.PrimaryPart) then return nil end
		local bossPos = boss.PrimaryPart.Position
		local bossRad = tonumber(boss:GetAttribute("Radius")) or 2.5
		local attackDist = math.max(6.0, bossRad + 4.0)

		local bestPos = nil
		local bestDist = math.huge

		-- สแกน 12 ทิศทางรอบตัวบอสในระยะโจมตี
		for angleDeg = 0, 330, 30 do
			local rad = math.rad(angleDeg)
			local cand = bossPos + Vector3.new(math.cos(rad) * attackDist, 0, math.sin(rad) * attackDist)
			local inAnyDanger = false
			for _, z in ipairs(dangerZones) do
				if isPointInsideZone(cand, z, 1.2) then
					inAnyDanger = true
					break
				end
			end
			if not inAnyDanger then
				local pathClear = isPathClear(charPos, cand, character)
				local groundOk = isGroundWalkable(cand, character)
				if pathClear and groundOk then
					local d = (cand - charPos).Magnitude
					if d < bestDist then
						bestDist = d
						bestPos = cand
					end
				end
			end
		end

		return bestPos
	end

	if bossFx then
		HUB:AddConnection(bossFx.OnClientEvent:Connect(function(action, monsterId, skillId, zones, duration)
			if not HUB.Alive or EXEC.env.HuntingTogetherHub_Token ~= MY_TOKEN then return end
			if not HUB.Config.autoDodge then return end

			local key = tostring(monsterId) .. "_" .. tostring(skillId)
			if action == "warn" and type(zones) == "table" then
				local char = LocalPlayer.Character
				local root = char and char:FindFirstChild("HumanoidRootPart")
				if not root then return end
				local charPos = root.Position

				local isRelevant = false
				for _, z in ipairs(zones) do
					local p = z.Center or (z.CFrame and z.CFrame.Position)
					if p and (p - charPos).Magnitude <= 120 then
						isRelevant = true
						break
					end
				end
				if not isRelevant then return end

				local dur = (type(duration) == "number" and duration > 0) and duration or 3.0
				local hasSafe = false
				local safeCenter = nil
				local safeRadius = 10
				for _, z in ipairs(zones) do
					if z.Safe and z.Center then
						hasSafe = true
						safeCenter = z.Center
						safeRadius = z.Radius or 10
						break
					end
				end

				activeBossSkills[key] = {
					zones = zones,
					expiry = os.clock() + dur,
					hasSafe = hasSafe,
					safeCenter = safeCenter,
					safeRadius = safeRadius,
					monsterId = monsterId,
					skillId = skillId
				}
			elseif action == "hit" or action == "cancel" then
				activeBossSkills[key] = nil
				for k, info in pairs(activeBossSkills) do
					if info.monsterId == monsterId or info.skillId == skillId then
						activeBossSkills[k] = nil
					end
				end
			end
		end))
	end

	task.spawn(function()
		local isDodging = false
		local didDodgeCount = false
		local BIND_NAME = "HuntingTogetherHub_DodgeOverride"
		local isBound = false
		local lastMonsterScan = 0
		local cachedMonsters = {}
		local lastDodgeSamplePos = nil
		local lastDodgeSampleTime = os.clock()
		local dodgeStuckAccumTime = 0

		local function ensureOverrideBound()
			if not isBound then
				isBound = true
				pcall(RunService.BindToRenderStep, RunService, BIND_NAME, Enum.RenderPriority.Character.Value + 10, function()
					if HUB.Dodging and currentEscapePos then
						local ch = LocalPlayer.Character
						local r = ch and ch:FindFirstChild("HumanoidRootPart")
						local h = ch and ch:FindFirstChildOfClass("Humanoid")
						if r and h and h.Health > 0 then
							if currentEscapeWaypoints and #currentEscapeWaypoints > 0 then
								local curWp = currentEscapeWaypoints[currentEscapeWpIndex]
								while curWp do
									local distToWp = Vector3.new(curWp.Position.X - r.Position.X, 0, curWp.Position.Z - r.Position.Z).Magnitude
									if distToWp < 2.5 and currentEscapeWpIndex < #currentEscapeWaypoints then
										currentEscapeWpIndex = currentEscapeWpIndex + 1
										curWp = currentEscapeWaypoints[currentEscapeWpIndex]
										if curWp and curWp.Action == Enum.PathWaypointAction.Jump then
											h.Jump = true
										end
									else
										break
									end
								end
								if currentEscapeWaypoints[currentEscapeWpIndex] then
									currentEscapePos = currentEscapeWaypoints[currentEscapeWpIndex].Position
								end
							end

							local toDest = Vector3.new(currentEscapePos.X - r.Position.X, 0, currentEscapePos.Z - r.Position.Z)
							if toDest.Magnitude > 1.0 then
								local moveDir = toDest.Unit
								local whisker = getWhiskerAvoidance(r.Position, moveDir)
								if whisker.Magnitude > 0.1 then
									local steer = (moveDir + whisker * 0.8).Unit
									h:Move(steer, false)
								else
									h:Move(moveDir, false)
								end
							else
								h:Move(Vector3.zero, false)
							end
						end
					end
				end)
			end
		end

		local function cleanupDodge()
			if isDodging or isBound then
				isDodging = false
				HUB.Dodging = false
				didDodgeCount = false
				currentEscapePos = nil
				currentEscapeWaypoints = nil
				currentEscapeWpIndex = 1
				dodgeStuckAccumTime = 0
				lastDodgeSamplePos = nil
				if isBound then
					isBound = false
					pcall(RunService.UnbindFromRenderStep, RunService, BIND_NAME)
				end
				pcall(function()
					LocalPlayer:SetAttribute("BotReviveWalk", nil)
				end)
				local isAuto = isGameAutoActive()
				local autoPlayTargeting = (HUB.Config.targetSprint ~= false) and isAuto and isPlayerInActiveCombat()
				setSprinting(isAuto and autoPlayTargeting)
				if HUB.UI.DodgeStatusLabel and HUB.Config.autoDodge then
					local buf = getDodgeBuffer()
					HUB.UI.DodgeStatusLabel.Text = string.format("สถานะ: เปิดใช้งาน · หลบแล้ว %d ครั้ง (ระยะเผื่อ %.1f studs)", HUB.Stats.dodgesPerformed, buf)
				end
			end
		end

		while HUB.Alive and EXEC.env.HuntingTogetherHub_Token == MY_TOKEN do
			task.wait(0.04)
			if not HUB.Alive or EXEC.env.HuntingTogetherHub_Token ~= MY_TOKEN then break end

			if not HUB.Config.autoDodge then
				cleanupDodge()
				continue
			end

			pcall(function()
				local char = LocalPlayer.Character
				local root = char and char:FindFirstChild("HumanoidRootPart")
				local hum = char and char:FindFirstChildOfClass("Humanoid")
				if not (root and hum and hum.Health > 0) then
					cleanupDodge()
					return
				end

				if isPlayerManualInput() then
					cleanupDodge()
					return
				end

				-- สปริ้นต์อัตโนมัติ: สปริ้นต์ 100% เสมอขณะหลบ หรือเมื่อ Auto Play ต้องการสปริ้นต์เข้าหาเป้าหมาย
				local isAuto = isGameAutoActive()
				local autoPlayTargeting = (HUB.Config.targetSprint ~= false) and isAuto and isPlayerInActiveCombat()
				local shouldSprint = false
				if isDodging then
					shouldSprint = true
				elseif isAuto then
					if HUB.Navigating or autoPlayTargeting then
						shouldSprint = true
					end
				end
				setSprinting(shouldSprint)

				local now = os.clock()
				HUB.DodgeTick = now
				local serverNow = workspace:GetServerTimeNow()
				local allDangerZones = {}
				local allSafeZones = {}

				-- แหล่งที่ 1: BossFx Remote Event Data (Server-Authoritative Skill Zones)
				for k, info in pairs(activeBossSkills) do
					if now > info.expiry then
						activeBossSkills[k] = nil
					else
						for _, z in ipairs(info.zones) do
							if z.Safe and z.Center then
								if (z.Center - root.Position).Magnitude <= 85 then
									table.insert(allSafeZones, {
										Center = z.Center,
										Radius = z.Radius or 9
									})
								end
							else
								if z.Room and z.CFrame then
									table.insert(allDangerZones, {
										Kind = "box",
										CFrame = z.CFrame,
										Width = z.Width or 60,
										Length = z.Length or 60,
										Expiry = info.expiry
									})
								elseif z.Kind == "cone" or (z.Dir and (z.Half or z.Angle)) then
									local halfAngle = z.Half or (z.Angle and math.rad(z.Angle / 2)) or 0.6
									table.insert(allDangerZones, {
										Kind = "cone",
										Center = z.Center,
										Dir = z.Dir.Unit,
										Radius = z.Radius or 35,
										Half = halfAngle,
										Expiry = info.expiry
									})
								elseif (z.Inner and z.Inner > 0) or z.Shape == "donut" then
									table.insert(allDangerZones, {
										Kind = "donut",
										Center = z.Center,
										Radius = z.Radius or 60,
										Inner = z.Inner or 15,
										Expiry = info.expiry
									})
								elseif z.Kind == "circle" or (z.Center and z.Radius and not z.CFrame) then
									table.insert(allDangerZones, {
										Kind = "circle",
										Center = z.Center,
										Radius = z.Radius,
										Expiry = info.expiry
									})
								elseif z.CFrame or z.Length or z.Width or z.Shape == "charge" or z.Shape == "line" then
									table.insert(allDangerZones, {
										Kind = "box",
										CFrame = z.CFrame,
										Width = z.Width or 12,
										Length = z.Length or 35,
										Expiry = info.expiry
									})
								end
							end
						end
					end
				end

				-- แหล่งที่ 2: workspace.LumiBossFx (Parts ที่เกมสร้างขึ้นในฉากจริง)
				local bossFxFolder = workspace:FindFirstChild("LumiBossFx")
				if bossFxFolder then
					for _, part in ipairs(bossFxFolder:GetChildren()) do
						if part:IsA("BasePart") then
							local dist = (part.Position - root.Position).Magnitude
							if dist <= 85 and part.Transparency < 0.85 then
								local c = part.Color
								local maxSize = math.max(part.Size.X, part.Size.Z)
								if maxSize <= 90 then
									-- Green Show (Safe Zone)
									if c.G > 0.6 and c.R < 0.4 then
										local alreadyKnown = false
										for _, sz in ipairs(allSafeZones) do
											if (sz.Center - part.Position).Magnitude < 4.0 then
												alreadyKnown = true
												break
											end
										end
										if not alreadyKnown then
											table.insert(allSafeZones, {
												Center = part.Position,
												Radius = math.max(part.Size.Y, part.Size.Z) / 2
											})
										end
									-- Red Show (Danger Zone)
									elseif (c.R > 0.6 and c.G < 0.5) or (part.Material == Enum.Material.Neon and c.R > 0.7) then
										if not part:IsA("WedgePart") then
											local isCyl = part:IsA("Part") and part.Shape == Enum.PartType.Cylinder
											local alreadyKnown = false
											for _, dz in ipairs(allDangerZones) do
												local pos = dz.Center or (dz.CFrame and dz.CFrame.Position)
												if pos and (pos - part.Position).Magnitude < 4.0 then
													alreadyKnown = true
													break
												end
											end
											if not alreadyKnown then
												if isCyl then
													table.insert(allDangerZones, {
														Kind = "circle",
														Center = part.Position,
														Radius = math.max(part.Size.Y, part.Size.Z) / 2,
														Expiry = now + 1.2
													})
												else
													table.insert(allDangerZones, {
														Kind = "box",
														CFrame = part.CFrame,
														Width = math.min(part.Size.X, part.Size.Z),
														Length = math.max(part.Size.X, part.Size.Z),
														Expiry = now + 1.2
													})
												end
											end
										end
									end
								end
							end
						end
					end
				end

				-- แหล่งที่ 3: Monster Attributes (Spin Attack วงแดงหมุนตัวรอบตัวมอนสเตอร์ — Throttled 0.4s)
				if now - lastMonsterScan > 0.4 then
					lastMonsterScan = now
					cachedMonsters = CollectionService:GetTagged("Monster")
				end
				for _, m in ipairs(cachedMonsters) do
					if m:IsA("Model") and m.Parent then
						local pp = m.PrimaryPart
						if pp and (pp.Position - root.Position).Magnitude <= 45 then
							local spinUntil = tonumber(m:GetAttribute("SpinUntil")) or 0
							if m:GetAttribute("SpinShowZone") == true and serverNow < spinUntil then
								local reach = tonumber(m:GetAttribute("SpinReach")) or 12
								local alreadyKnown = false
								for _, dz in ipairs(allDangerZones) do
									if dz.Center and (dz.Center - pp.Position).Magnitude < 3.0 then
										alreadyKnown = true
										break
									end
								end
								if not alreadyKnown then
									table.insert(allDangerZones, {
										Kind = "circle",
										Center = pp.Position,
										Radius = reach,
										Expiry = now + math.max(0.5, spinUntil - serverNow)
									})
								end
							end
						end
					end
				end

				HUB.LastDangerCount = #allDangerZones
				HUB.LastSafeCount = #allSafeZones
				HUB.IsDodgingInternal = isDodging

				-- =========================================================================
				-- การควบคุมและหลบหลีก (Shortest Exit & Safe Boss Attack State Machine)
				-- =========================================================================

				local inDanger, badZone = isCharacterInDanger(root.Position, allDangerZones)

				-- Real-time Stuck Detection: ตรวจจับหากตัวละครติดกำแพง/สิ่งกีดขวางขณะหลบ
				if isDodging and currentEscapePos then
					local nowDodgeTime = os.clock()
					local dtStuck = nowDodgeTime - (lastDodgeSampleTime or nowDodgeTime)
					if dtStuck >= 0.15 then
						local movedDist = lastDodgeSamplePos and Vector3.new(root.Position.X - lastDodgeSamplePos.X, 0, root.Position.Z - lastDodgeSamplePos.Z).Magnitude or 10
						local distToGoal = Vector3.new(currentEscapePos.X - root.Position.X, 0, currentEscapePos.Z - root.Position.Z).Magnitude
						if distToGoal > 2.0 and movedDist < 0.6 then
							dodgeStuckAccumTime = dodgeStuckAccumTime + dtStuck
							if dodgeStuckAccumTime >= 0.20 then
								hum.Jump = true
								if inDanger and badZone then
									local newEscPos, newEscWps = findEscapePosition(root.Position, allDangerZones, allSafeZones, char)
									if newEscPos then
										currentEscapePos = newEscPos
										currentEscapeWaypoints = newEscWps
										currentEscapeWpIndex = 1
									end
								end
								dodgeStuckAccumTime = 0
							end
						else
							dodgeStuckAccumTime = 0
						end
						lastDodgeSamplePos = root.Position
						lastDodgeSampleTime = nowDodgeTime
					end
				else
					lastDodgeSamplePos = root.Position
					lastDodgeSampleTime = os.clock()
					dodgeStuckAccumTime = 0
				end

				-- กรณี 1: มี Safe Zone (Green Show) อยู่ใกล้ตัว (<= 85 studs)
				if (HUB.Config.dodgeGreenZones ~= false) and #allSafeZones > 0 then
					local bestSafe = nil
					local bestDist = math.huge
					for _, sz in ipairs(allSafeZones) do
						if sz.Center then
							local d = (root.Position - sz.Center).Magnitude
							if d < bestDist and d <= 85 then
								bestDist = d
								bestSafe = sz
							end
						end
					end

					if bestSafe then
						local distToSafe = (Vector3.new(root.Position.X, 0, root.Position.Z) - Vector3.new(bestSafe.Center.X, 0, bestSafe.Center.Z)).Magnitude
						local safeRad = bestSafe.Radius or 9

						if distToSafe > (safeRad * 0.7) then
							isDodging = true
							HUB.Dodging = true
							currentEscapePos = bestSafe.Center
							if not didDodgeCount then
								HUB.Stats.dodgesPerformed = HUB.Stats.dodgesPerformed + 1
								didDodgeCount = true
							end

							setSprinting(true)
							hum:MoveTo(bestSafe.Center)
							local diff = Vector3.new(bestSafe.Center.X - root.Position.X, 0, bestSafe.Center.Z - root.Position.Z)
							if diff.Magnitude > 1.2 then
								hum:Move(diff.Unit, false)
							end
							LocalPlayer:SetAttribute("BotReviveWalk", bestSafe.Center)
							ensureOverrideBound()

							if HUB.UI.DodgeStatusLabel then
								HUB.UI.DodgeStatusLabel.Text = string.format("สถานะ: กำลังสปริ้นต์เข้า green show! (ระยะ %.1fm)", distToSafe)
							end
						else
							-- เข้ามาใน Safe Zone แล้ว: หากสกิล Room ยังระเบิดไม่เสร็จ ให้ปักหลักอยู่ข้างใน ไม่เดินออกไปหาบอส
							if isDodging then
								if #allDangerZones > 0 then
									hum:Move(Vector3.zero, false)
									LocalPlayer:SetAttribute("BotReviveWalk", bestSafe.Center)
									ensureOverrideBound()
									if HUB.UI.DodgeStatusLabel then
										HUB.UI.DodgeStatusLabel.Text = "สถานะ: อยู่ใน green show ปลอดภัยแล้ว (รอสกิลระเบิด...)"
									end
								else
									cleanupDodge()
								end
							end
						end
					else
						if isDodging and not inDanger then
							cleanupDodge()
						end
					end

				-- กรณี 2: ตัวเราอยู่ในโซนแดง (Red Show) จริง ๆ -> วิ่งออกจากโซนแดงในระยะทางที่สั้นที่สุดเสมอตาม Settings!
				elseif (HUB.Config.dodgeRedZones ~= false) and inDanger and badZone then
					local escapePos, escapeWps = findEscapePosition(root.Position, allDangerZones, allSafeZones, char)
					if escapePos then
						isDodging = true
						HUB.Dodging = true
						currentEscapePos = escapePos
						currentEscapeWaypoints = escapeWps
						currentEscapeWpIndex = 1
						if not didDodgeCount then
							HUB.Stats.dodgesPerformed = HUB.Stats.dodgesPerformed + 1
							didDodgeCount = true
						end

						setSprinting(true)
						local targetMovePos = (escapeWps and escapeWps[1] and escapeWps[1].Position) or escapePos
						hum:MoveTo(targetMovePos)
						local diff = Vector3.new(targetMovePos.X - root.Position.X, 0, targetMovePos.Z - root.Position.Z)
						if diff.Magnitude > 1.0 then
							hum:Move(diff.Unit, false)
						end
						LocalPlayer:SetAttribute("BotReviveWalk", targetMovePos)
						ensureOverrideBound()

						local exitDist = (escapePos - root.Position).Magnitude
						local userBuf = getDodgeBuffer()
						if HUB.UI.DodgeStatusLabel then
							if escapeWps and #escapeWps > 0 then
								HUB.UI.DodgeStatusLabel.Text = string.format("สถานะ: นำทางอ้อมสิ่งกีดขวางพ้นโซนแดง (%d waypoints)!", #escapeWps)
							else
								HUB.UI.DodgeStatusLabel.Text = string.format("สถานะ: สปริ้นต์หลบเลี่ยงสิ่งกีดขวางระยะสั้นสุด %.1f studs (เผื่อ %.1f studs)!", exitDist, userBuf)
							end
						end
					end

				-- กรณี 3: ตัวเราอยู่นอกโซนแดงแล้ว แต่สกิลบอสยังคงแสดงผลอยู่ในฉาก (Anti-Suicide & Safe Flank Attack)
				elseif isDodging and (#allDangerZones > 0) then
					local boss = getTargetBossModel()
					if boss then
						local safeAttackPos = findSafeBossAttackPosition(root.Position, boss, allDangerZones, char)
						if safeAttackPos then
							-- พบบริเวณรอบตัวบอสที่ปลอดภัยจากโซนแดง: เคลื่อนที่ไปยืนตีจากมุมปลอดภัยนั้น!
							currentEscapePos = safeAttackPos
							currentEscapeWaypoints = nil
							currentEscapeWpIndex = 1
							setSprinting(isAuto)
							hum:MoveTo(safeAttackPos)
							local diff = Vector3.new(safeAttackPos.X - root.Position.X, 0, safeAttackPos.Z - root.Position.Z)
							if diff.Magnitude > 1.2 then
								hum:Move(diff.Unit, false)
								LocalPlayer:SetAttribute("BotReviveWalk", safeAttackPos)
								ensureOverrideBound()
								if HUB.UI.DodgeStatusLabel then
									HUB.UI.DodgeStatusLabel.Text = "สถานะ: กำลังอ้อมเข้าตีบอสจากมุมปลอดภัย (Flank Attack)..."
								end
							else
								-- ถึงจุดตีปลอดภัยแล้ว: ปลด BotReviveWalk เพื่อให้ CombatClient ตีบอสต่อเนื่อง
								LocalPlayer:SetAttribute("BotReviveWalk", nil)
								hum:Move(Vector3.zero, false)
								if HUB.UI.DodgeStatusLabel then
									HUB.UI.DodgeStatusLabel.Text = "สถานะ: กำลังโจมตีบอสจากมุมปลอดภัยที่ไม่มีโซนแดง!"
								end
							end
						else
							-- สกิลบอสคลุมรอบตัว 360 องศา (ไม่มีจุดตีปลอดภัย): ปักหลักอยู่นอกโซนแดงจนกว่าจะระเบิดเสร็จ!
							if currentEscapePos then
								hum:Move(Vector3.zero, false)
								LocalPlayer:SetAttribute("BotReviveWalk", currentEscapePos)
								ensureOverrideBound()
							end

							if HUB.UI.DodgeStatusLabel then
								HUB.UI.DodgeStatusLabel.Text = "สถานะ: ปักหลักรอนอกโซนแดงอย่างปลอดภัย (รอสกิลระเบิดเสร็จ...)"
							end
						end
					else
						-- ไม่พบบอสในระยะสู้: ปักหลักรอ
						if currentEscapePos then
							hum:Move(Vector3.zero, false)
							LocalPlayer:SetAttribute("BotReviveWalk", currentEscapePos)
							ensureOverrideBound()
						end
					end

				else
					-- โซนแดงทั้งหมดระเบิดเสร็จสิ้นหรือไม่มีอันตรายแล้ว -> ปลดล็อคและคืนการควบคุมให้ Auto Play ตีบอสตามปกติ!
					if isDodging then
						cleanupDodge()
					end
				end
			end)
		end

		cleanupDodge()
	end)
end

-- ===== 9.5 Auto Resume Game Play Worker (Startup & Rejoin Auto-Execute Resilience & Respawn Lifecycle) =====
do
	-- ป้องกัน CombatClient สั่งปิด Auto Play ตอนตัวละครเกิดใหม่ (RespawnKeepBot)
	pcall(function()
		LocalPlayer:SetAttribute("RespawnKeepBot", true)
	end)

	local function onCharacterDied()
		HUB.CharacterDying = true
		-- ยกเลิกลูปรูทีนที่กำลังทำงานอยู่ทันที ป้องกันไม่ให้เธรดค้างบนร่างที่ตาย
		if HUB.CancelAutoBossRoutine then pcall(HUB.CancelAutoBossRoutine) end
		if HUB.CancelAutoSellRoutine then pcall(HUB.CancelAutoSellRoutine) end
		HUB.IsSalvagingRoutineActive = false
		HUB.Navigating = false
		HUB.Dodging = false
	end

	local function hookHumanoid(char)
		if not char then return end
		local hum = char:FindFirstChildOfClass("Humanoid")
		if hum then
			HUB:AddConnection(hum.Died:Connect(onCharacterDied))
		end
	end

	if LocalPlayer.Character then
		hookHumanoid(LocalPlayer.Character)
	end

	-- User Shutoff Guard: หาก Hub เคยเปิด Auto Play ให้ แล้วผู้ใช้กดปิดด้วยตนเอง จะไม่เปิดอัตโนมัติซ้ำอีก
	-- แต่ถ้าปิดเพราะตัวละครตาย หรือเลือดหมด จะไม่นับว่าผู้ใช้สั่งปิดเองเด็ดขาด 100%
	HUB:AddConnection(LocalPlayer:GetAttributeChangedSignal("AutoOn"):Connect(function()
		if LocalPlayer:GetAttribute("AutoOn") ~= true then
			if HUB.CharacterDying then return end
			local ch = LocalPlayer.Character
			local h = ch and ch:FindFirstChildOfClass("Humanoid")
			if not h or h.Health <= 0 then return end

			if HUB.BotTurnedOnAuto and not HUB.BotPausingAuto and not HUB.IsBossRoutineActive and not HUB.IsSellingRoutineActive and not HUB.Navigating then
				HUB.UserDisabledAuto = true
				print("[Hunting Together Hub] ผู้ใช้กดปิด Auto Play ด้วยตนเอง — งดการเปิดอัตโนมัติซ้ำจนกว่าจะกดเปิดในเมนู Hub หรือ execute ใหม่")
				if HUB.UI.AutoResumeStatusLabel then
					HUB.UI.AutoResumeStatusLabel.Text = "สถานะ: ผู้ใช้กดปิด Auto Play (งดเปิดซ้ำ)"
				end
			end
		end
	end))

	-- ตรวจสอบและกดเปิด Auto Play อัตโนมัติเมื่อเพิ่ง Execute / Rejoin เข้ามาช่วงแรก (เฉพาะเมื่อพบมอนในระยะ 30 studs)
	task.spawn(function()
		-- ขั้นที่ 1: ตรวจสอบและข้ามหน้าจอ Press to Start / Intro Loading ก่อน
		if HUB.Config.autoStartGame ~= false then
			HUB.BypassStartScreen(45)
		end

		local pgui = LocalPlayer:WaitForChild("PlayerGui", 25)
		if pgui then
			pcall(function() pgui:WaitForChild("LumiAuto", 20) end)
		end

		-- Grace period ให้ระบบของตัวเกม (CombatClient / BotJson) โหลดและตั้งค่าเริ่มต้นให้เสร็จ
		task.wait(2.0)

		-- Checkpoints ในช่วง 15 วินาทีแรก (t = 2s, 5s, 9s, 14s)
		local intervals = { 0, 3, 4, 5 }
		for _, delaySec in ipairs(intervals) do
			if not HUB.Alive or EXEC.env.HuntingTogetherHub_Token ~= MY_TOKEN then break end
			if delaySec > 0 then task.wait(delaySec) end

			if HUB.UserDisabledAuto then break end

			if HUB.Config.autoResumeGamePlay ~= false then
				if not HUB.IsGameAutoActive() then
					-- ตรวจสอบเงื่อนไขระยะมอนสเตอร์: ต้องมีมอนสเตอร์อยู่ในระยะ 30 studs เท่านั้น
					if isMonsterWithinRadius(30) then
						local ok = HUB.EnsureGameAutoActive(4, 0.3)
						if ok then
							HUB.BotTurnedOnAuto = true
							print("[Hunting Together Hub] พบมอนสเตอร์ในระยะ 30 studs — สั่งเปิด Auto Play ต่อเนื่องเรียบร้อย")
							if HUB.UI.AutoResumeStatusLabel then
								HUB.UI.AutoResumeStatusLabel.Text = "สถานะ: เปิด Auto Play อัตโนมัติ (พบมอนในระยะ 30s) ⚔️"
							end
						end
					else
						if HUB.UI.AutoResumeStatusLabel and not HUB.BotTurnedOnAuto then
							HUB.UI.AutoResumeStatusLabel.Text = "สถานะ: ไม่มีมอนในระยะ 30 studs (ยังไม่เปิด Auto Play)"
						end
					end
				end
			end
		end
	end)

	-- เมื่อตัวละครเกิดใหม่ (Respawn): Lifecycle Self-Healing Engine กู้คืนสถานะทั้งหมด
	HUB:AddConnection(LocalPlayer.CharacterAdded:Connect(function(newChar)
		HUB.CharacterDying = false
		HUB.UserDisabledAuto = false -- ปลดล็อค False UserDisabledAuto จากจังหวะตาย 100%
		HUB.Navigating = false
		HUB.Dodging = false
		HUB.IsSalvagingRoutineActive = false
		if HUB.CancelAutoBossRoutine then pcall(HUB.CancelAutoBossRoutine) end
		if HUB.CancelAutoSellRoutine then pcall(HUB.CancelAutoSellRoutine) end

		pcall(function()
			LocalPlayer:SetAttribute("RespawnKeepBot", true)
			local root = newChar:WaitForChild("HumanoidRootPart", 5)
			if root then root.Anchored = false end
		end)
		hookHumanoid(newChar)

		if not HUB.Alive or HUB.Config.autoResumeGamePlay == false then return end

		task.delay(2.5, function()
			if not HUB.Alive or EXEC.env.HuntingTogetherHub_Token ~= MY_TOKEN then return end
			local ch = LocalPlayer.Character
			local root = ch and ch:FindFirstChild("HumanoidRootPart")
			if not root then return end

			-- กรณีเกิดในเมือง (Z > -200) แต่มี Origin จุดฟาร์มมอนสเตอร์เดิมที่ยังค้างอยู่ (Z <= -300)
			if root.Position.Z > -200 and HUB.OriginCFrame and HUB.OriginCFrame.Position.Z <= -300 then
				task.spawn(function()
					if HUB.ReturnToOrigin then
						HUB.ReturnToOrigin(nil, function(txt)
							if HUB.UI.AutoResumeStatusLabel then
								HUB.UI.AutoResumeStatusLabel.Text = txt
							end
						end)
					end
				end)
				return
			end

			-- ถ้ามีมอนสเตอร์ใกล้ตัว หรืออยู่ในโซนมอนสเตอร์ ให้เปิด Auto Play ทันที
			if isMonsterWithinRadius(30) or root.Position.Z <= -300 then
				local ok = HUB.EnsureGameAutoActive(5, 0.3)
				if ok then
					HUB.BotTurnedOnAuto = true
					print("[Hunting Together Hub] ตัวละครเกิดใหม่ — สั่งเปิดใช้งาน Auto Play ต่อเนื่องเรียบร้อย")
					if HUB.UI.AutoResumeStatusLabel then
						HUB.UI.AutoResumeStatusLabel.Text = "สถานะ: เปิด Auto Play หลังเกิดใหม่สำเร็จ ⚔️"
					end
				end
			else
				if HUB.UI.AutoResumeStatusLabel and not HUB.BotTurnedOnAuto then
					HUB.UI.AutoResumeStatusLabel.Text = "สถานะ: เกิดใหม่ที่เมือง (รอคำสั่งหรือเดินทางไปจุดฟาร์ม)"
				end
			end
		end)
	end))
end

-- ===== 10. Anti-AFK Background Worker (Hardware-Level VIM Pulse & Triple Protection) =====
do
	local UserInputService = game:GetService("UserInputService")
	local _cachedAfkFn = nil
	local _afkGcScanned = false

	-- 1. ฟังก์ชันส่ง Real Hardware-Level Input Pulse ผ่าน VirtualInputManager
	-- ขยับเม้าส์ระดับพิกัดปลอดภัย (1,1 -> 0,0) เท่านั้น โดยไม่ส่ง Key Event ใดๆ:
	-- ปลอดภัย 100%: ไม่ส่ง SendKeyEvent เพื่อป้องกันการชนกับ Toggle Key (RightControl/Insert) ของ Hub GUI
	-- ซึ่งจะทำให้หน้าต่างที่ยุบอยู่เด้งเปิดขึ้นมาเอง (Zero Ghost GUI Pop-up)
	-- รีเซ็ตทั้งตัวนับ Idle ของ Roblox C++ Engine และกระตุ้น UserInputService เพื่ออัปเดต u38 ของเกมจริง 100%
	-- สำคัญ: ไม่เรียก VirtualUser:CaptureController() เพื่อป้องกันการดึงหน้าต่างที่ยุบอยู่ขึ้นมา (Zero Window Steal)
	local function triggerHardwareAntiAfkPulse()
		local okPulse = false
		if VIM then
			pcall(function()
				VIM:SendMouseMoveEvent(1, 1, game)
				VIM:SendMouseMoveEvent(0, 0, game)
				okPulse = true
			end)
		end
		return okPulse
	end

	-- 2. ค้นหาฟังก์ชัน touched ของ AfkRejoinClient เพื่ออ่านและรีเซ็ต Upvalues ในระดับหน่วยความจำ (สแกนเฉพาะฟังก์ชันครั้งเดียว ไม่กวาดตารางทั้ง Heap)
	local function getAfkClientFunction()
		if _cachedAfkFn or _afkGcScanned then return _cachedAfkFn end
		_afkGcScanned = true
		if type(EXEC.getgc) == "function" and type(EXEC.getinfo) == "function" then
			pcall(function()
				for _, obj in ipairs(EXEC.getgc(false)) do
					if type(obj) == "function" and not (isexecutorclosure and isexecutorclosure(obj)) then
						local inf = EXEC.getinfo(obj)
						if inf and inf.source and inf.source:find("AfkRejoinClient") and inf.linedefined == 22 then
							_cachedAfkFn = obj
							break
						end
					end
				end
			end)
		end
		return _cachedAfkFn
	end

	-- 3. อ่านระยะเวลา Idle ที่แท้จริงจาก AfkRejoinClient เพื่อแสดงผลบน UI ให้ผู้ใช้ตรวจสอบได้สดๆ
	function HUB.GetGroundTruthIdleSeconds()
		local fn = getAfkClientFunction()
		if fn and type(EXEC.getupvalues) == "function" then
			local ok, uvs = pcall(EXEC.getupvalues, fn)
			if ok and type(uvs) == "table" and type(uvs[1]) == "number" then
				return math.max(0, os.clock() - uvs[1])
			end
		end
		return math.max(0, tick() - (HUB.Stats.lastAfkTime or tick()))
	end

	local function onIdledEvent()
		if not HUB.Alive or not HUB.Config.antiAfk then return end
		if type(HUB.TriggerAfkReset) == "function" then
			HUB.TriggerAfkReset(true)
		end
	end

	-- 4. ปิดการทำงานของ Connection อื่นใน LocalPlayer.Idled (CoreScript & AfkRejoinClient)
	-- เพื่อป้องกันไม่ให้เกมหรือ Roblox ยิงสัญญาณเตือน Idle เตะผู้เล่น
	local function disableExternalIdledConnections()
		if type(EXEC.getconnections) == "function" then
			pcall(function()
				for _, conn in ipairs(EXEC.getconnections(LocalPlayer.Idled)) do
					if conn.Function ~= onIdledEvent then
						if type(conn.Disable) == "function" then
							conn:Disable()
						elseif type(conn.Disconnect) == "function" then
							conn:Disconnect()
						end
					end
				end
			end)
		end
	end

	-- 5. สั่งรีเซ็ต Idle ครบวงจร (VIM Pulse + Memory Sync + Connection Lock)
	local function executeAfkReset(fromIdledSignal)
		triggerHardwareAntiAfkPulse()

		local fn = getAfkClientFunction()
		if fn and type(EXEC.setupvalue) == "function" then
			pcall(EXEC.setupvalue, fn, 1, os.clock())
			pcall(EXEC.setupvalue, fn, 2, false)
		end

		if fromIdledSignal then
			disableExternalIdledConnections()
		end

		HUB.Stats.afkCount = HUB.Stats.afkCount + 1
		HUB.Stats.lastAfkTime = tick()

		local idleSec = HUB.GetGroundTruthIdleSeconds()
		if HUB.UI.AfkStatusLabel then
			HUB.UI.AfkStatusLabel.Text = string.format("สถานะ: เปิดใช้งาน · รีเซ็ตแล้ว %d ครั้ง (Idle: %.1fs)", HUB.Stats.afkCount, idleSec)
		end
		if HUB.UI.StatAfkCount then
			HUB.UI.StatAfkCount.Text = tostring(HUB.Stats.afkCount) .. " ครั้ง"
		end
	end
	HUB.TriggerAfkReset = executeAfkReset

	-- ลูป Background รันทุก 45 วินาที (สม่ำเสมอ ต่ำกว่าขีดจำกัด 1080s/1140s/1200s มาก)
	task.spawn(function()
		while HUB.Alive and EXEC.env.HuntingTogetherHub_Token == MY_TOKEN do
			task.wait(45)
			if not HUB.Alive or EXEC.env.HuntingTogetherHub_Token ~= MY_TOKEN then break end
			if HUB.Config.antiAfk then
				executeAfkReset()
			end
		end
	end)

	-- ดักฟังสัญญาณ Idled เพิ่มเติม หากเผลอถูกเรียก ให้รีเซ็ตทันที
	HUB:AddConnection(LocalPlayer.Idled:Connect(onIdledEvent))

	-- ปิด Connection อื่นทันทีตั้งแต่ตอนเริ่ม
	task.defer(disableExternalIdledConnections)
end

-- ===== 11. Auto Rejoin Worker (GuiService Error Monitoring) =====
do
	local isRejoining = false
	HUB:AddConnection(GuiService.ErrorMessageChanged:Connect(function(msg)
		if not HUB.Alive or not HUB.Config.autoRejoin or isRejoining then return end
		if not msg or msg == "" then return end

		local errCodeName = ""
		pcall(function()
			errCodeName = GuiService:GetErrorCode().Name
		end)

		if errCodeName == "DisconnectDuplicatePlayer" or errCodeName == "DisconnectDuplicateTicket" then
			warn("[Hunting Together Hub] ตรวจพบบัญชีซ้ำซ้อน — งดการ Rejoin อัตโนมัติ")
			return
		end

		isRejoining = true
		HUB.Stats.rejoinAttempts = HUB.Stats.rejoinAttempts + 1
		warn(string.format("[Hunting Together Hub] ตรวจพบการตัดการเชื่อมต่อ (%s: %s) — เตรียมเชื่อมต่อใหม่ใน 3 วินาที...", errCodeName, tostring(msg)))

		task.wait(3)
		local ok, err = pcall(function()
			TeleportService:Teleport(game.PlaceId, LocalPlayer)
		end)
		if not ok then
			task.wait(8)
			isRejoining = false
			pcall(function()
				TeleportService:Teleport(game.PlaceId, LocalPlayer)
			end)
		end
	end))
end

-- ===== 12. Periodic Auto-Save & Clean Maintenance Engine =====
task.spawn(function()
	while HUB.Alive and EXEC.env.HuntingTogetherHub_Token == MY_TOKEN do
		task.wait(30)
		if not HUB.Alive or EXEC.env.HuntingTogetherHub_Token ~= MY_TOKEN then break end
		if HUB.Config.autoSave then
			saveConfig()
		end
		-- Background Clean Maintenance: กวาดล้าง Dead Connections และคืนหน่วยความจำอัตโนมัติ (เงียบสนิท ไม่แสดงใน UI)
		if HUB.PruneConnections then
			pcall(function()
				HUB:PruneConnections()
			end)
		end
	end
end)

print(string.format("[Hunting Together Hub] v%s โหลดสำเร็จเรียบร้อย — Ground-Truth Farm Automation", VERSION))
return HUB
