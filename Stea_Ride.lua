local Players = game:GetService("Players")
local TeleportService = game:GetService("TeleportService")
local HttpService = game:GetService("HttpService")

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

-- ==========================================
-- CẤU HÌNH PATH36, PRIMORDIALCAGE & HOP NHANH
-- ==========================================
local TARGET_PATH = "Path36"
local TARGET_CAGE = "PrimordialCage"

local SCAN_WAIT_SECONDS = 1.5 -- Chờ load lồng nhanh hơn
local HOP_RETRY_DELAY = 0.5   -- Nghỉ ngắn giữa các lần hop

local RAW_SCRIPT_URL = "https://raw.githubusercontent.com/sthfun369/Steal-And-Ride/refs/heads/main/Stea_Ride.lua"
local AUTO_START_HOP_ON_TELEPORT = true

local TP_LOCATIONS = {
	{ name = "Back", pos = Vector3.new(11989, 4, -495), color = Color3.fromRGB(120, 145, 215) },
	{ name = "NewZone", pos = Vector3.new(11945, 4, -11458), color = Color3.fromRGB(70, 165, 195) },
}

local shouldAutoStart = (getgenv and getgenv().AUTO_HOP_BOOT == true) and true or false
if getgenv then
	getgenv().AUTO_HOP_BOOT = nil
end

local HopState = {
	Enabled = shouldAutoStart,
	Status = shouldAutoStart and ("Chờ " .. SCAN_WAIT_SECONDS .. "s quét Path36...") or "Sẵn sàng",
}

local visitedServers = {
	[game.JobId] = true,
}

local function cleanStr(str)
	return string.lower(tostring(str or "")):gsub("%s+", "")
end

local function teleportTo(targetPos)
	local char = LocalPlayer.Character
	if not char then return end

	local root = char:FindFirstChild("HumanoidRootPart")
	local safePos = targetPos + Vector3.new(0, 3, 0)

	if root then
		root.AssemblyLinearVelocity = Vector3.zero
		root.AssemblyAngularVelocity = Vector3.zero
		root.CFrame = CFrame.new(safePos)
	elseif char.PrimaryPart then
		char:PivotTo(CFrame.new(safePos))
	end
end

local function scanPath36()
	local countsByType = {}
	local totalInRegion = 0

	local pathsFolder = workspace:FindFirstChild("Paths")
	if not pathsFolder then
		return false, 0, countsByType, "Thiếu Paths"
	end

	local pathObj = pathsFolder:FindFirstChild(TARGET_PATH)
	if not pathObj then
		return false, 0, countsByType, "Thiếu " .. TARGET_PATH
	end

	local cagesFolder = pathObj:FindFirstChild("Cages")
	local scanRoot = cagesFolder or pathObj
	local counted = {}

	for _, obj in ipairs(scanRoot:GetDescendants()) do
		if not counted[obj] and (obj:IsA("Model") or obj:IsA("Folder")) then
			if string.find(cleanStr(obj.Name), "cage", 1, true) then
				counted[obj] = true
				totalInRegion += 1
				countsByType[obj.Name] = (countsByType[obj.Name] or 0) + 1
			end
		end
	end

	return true, totalInRegion, countsByType, nil
end

local function formatCountsText(foundPath, totalInRegion, countsByType, errMsg)
	if not foundPath then
		return errMsg or "Không tìm thấy Path36"
	end
	if totalInRegion == 0 then
		return "Trống (0 Cage)"
	end

	local names = {}
	for cageName in pairs(countsByType) do
		table.insert(names, cageName)
	end
	table.sort(names)

	local lines = {}
	for _, cageName in ipairs(names) do
		table.insert(lines, string.format("• %s: %d", cageName, countsByType[cageName]))
	end

	return table.concat(lines, "\n")
end

local function hasPrimordialCage()
	local foundPath, _, countsByType = scanPath36()
	if not foundPath then
		return false, 0
	end

	for cageName, count in pairs(countsByType) do
		if count > 0 and cleanStr(cageName) == cleanStr(TARGET_CAGE) then
			return true, count
		end
	end

	return false, 0
end

local function queueSelfOnTeleport()
	if RAW_SCRIPT_URL == "" then
		return
	end
	local queueFn = (syn and syn.queue_on_teleport) or queue_on_teleport or (fluxus and fluxus.queue_on_teleport)
	if not queueFn then
		return
	end

	local payload = string.format([[
		task.wait(0.8)
		if getgenv then
			getgenv().AUTO_HOP_BOOT = %s
		end
		loadstring(game:HttpGet(%q))()
	]], tostring(AUTO_START_HOP_ON_TELEPORT), RAW_SCRIPT_URL)

	pcall(function()
		queueFn(payload)
	end)
end

local function hopToOtherServer()
	HopState.Status = "Hop nhanh..."
	local cursor = ""
	local servers = {}

	for _ = 1, 2 do
		local url = string.format(
			"https://games.roblox.com/v1/games/%d/servers/Public?sortOrder=Asc&limit=100%s",
			game.PlaceId,
			cursor ~= "" and ("&cursor=" .. HttpService:UrlEncode(cursor)) or ""
		)

		local ok, raw = pcall(function()
			return game:HttpGet(url)
		end)
		if not ok or not raw then
			break
		end

		local decodedOk, body = pcall(function()
			return HttpService:JSONDecode(raw)
		end)
		if not decodedOk or type(body) ~= "table" or type(body.data) ~= "table" then
			break
		end

		for _, srv in ipairs(body.data) do
			local jobId = tostring(srv.id or "")
			local playing = tonumber(srv.playing) or 0
			local maxPlayers = tonumber(srv.maxPlayers) or 0
			if jobId ~= "" and not visitedServers[jobId] and maxPlayers > 0 and playing < maxPlayers then
				table.insert(servers, jobId)
			end
		end

		if #servers >= 25 then
			break
		end

		if body.nextPageCursor and tostring(body.nextPageCursor) ~= "" then
			cursor = tostring(body.nextPageCursor)
		else
			break
		end
	end

	if #servers == 0 then
		HopState.Status = "Hết server mới, thử lại..."
		return
	end

	local nextJobId = servers[math.random(1, #servers)]
	visitedServers[nextJobId] = true
	HopState.Status = "Đang hop..."
	queueSelfOnTeleport()

	pcall(function()
		TeleportService:TeleportToPlaceInstance(game.PlaceId, nextJobId, LocalPlayer)
	end)
end

-- ==========================================
-- GIAO DIỆN TP BACK / NEWZONE & PATH36 HOP
-- ==========================================
if PlayerGui:FindFirstChild("Path36PrimordialGui") then
	PlayerGui.Path36PrimordialGui:Destroy()
end

local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name = "Path36PrimordialGui"
ScreenGui.ResetOnSpawn = false
ScreenGui.Parent = PlayerGui

local FULL_WIDTH = 310
local FULL_HEIGHT = 252
local HEADER_HEIGHT = 32

local MainFrame = Instance.new("Frame")
MainFrame.Size = UDim2.new(0, FULL_WIDTH, 0, FULL_HEIGHT)
MainFrame.Position = UDim2.new(0.04, 0, 0.2, 0)
MainFrame.BackgroundColor3 = Color3.fromRGB(20, 22, 28)
MainFrame.BorderSizePixel = 0
MainFrame.Active = true
MainFrame.Draggable = true
MainFrame.Parent = ScreenGui
Instance.new("UICorner", MainFrame).CornerRadius = UDim.new(0, 10)

local Header = Instance.new("Frame")
Header.Size = UDim2.new(1, 0, 0, HEADER_HEIGHT)
Header.BackgroundColor3 = Color3.fromRGB(30, 33, 42)
Header.BorderSizePixel = 0
Header.Parent = MainFrame
Instance.new("UICorner", Header).CornerRadius = UDim.new(0, 10)

local TitleLabel = Instance.new("TextLabel")
TitleLabel.Size = UDim2.new(1, -64, 1, 0)
TitleLabel.Position = UDim2.new(0, 10, 0, 0)
TitleLabel.BackgroundTransparency = 1
TitleLabel.Text = "PATH36 • PRIMORDIALCAGE"
TitleLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
TitleLabel.Font = Enum.Font.GothamBold
TitleLabel.TextSize = 11
TitleLabel.TextXAlignment = Enum.TextXAlignment.Left
TitleLabel.Parent = Header

local isMinimized = false
local MinBtn = Instance.new("TextButton")
MinBtn.Size = UDim2.new(0, 22, 0, 22)
MinBtn.Position = UDim2.new(1, -52, 0.5, -11)
MinBtn.BackgroundColor3 = Color3.fromRGB(50, 55, 70)
MinBtn.Text = "-"
MinBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
MinBtn.Font = Enum.Font.GothamBold
MinBtn.TextSize = 14
MinBtn.Parent = Header
Instance.new("UICorner", MinBtn).CornerRadius = UDim.new(0, 6)

local CloseBtn = Instance.new("TextButton")
CloseBtn.Size = UDim2.new(0, 22, 0, 22)
CloseBtn.Position = UDim2.new(1, -26, 0.5, -11)
CloseBtn.BackgroundColor3 = Color3.fromRGB(190, 55, 55)
CloseBtn.Text = "X"
CloseBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
CloseBtn.Font = Enum.Font.GothamBold
CloseBtn.TextSize = 11
CloseBtn.Parent = Header
Instance.new("UICorner", CloseBtn).CornerRadius = UDim.new(0, 6)

local BodyFrame = Instance.new("Frame")
BodyFrame.Size = UDim2.new(1, -16, 1, -40)
BodyFrame.Position = UDim2.new(0, 8, 0, 36)
BodyFrame.BackgroundTransparency = 1
BodyFrame.Parent = MainFrame

local TpRow = Instance.new("Frame")
TpRow.Size = UDim2.new(1, 0, 0, 28)
TpRow.BackgroundTransparency = 1
TpRow.Parent = BodyFrame

for i, loc in ipairs(TP_LOCATIONS) do
	local tpBtn = Instance.new("TextButton")
	tpBtn.Size = UDim2.new(0.485, 0, 1, 0)
	tpBtn.Position = UDim2.new((i - 1) * 0.515, 0, 0, 0)
	tpBtn.BackgroundColor3 = loc.color
	tpBtn.Text = "TP: " .. loc.name
	tpBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
	tpBtn.Font = Enum.Font.GothamBold
	tpBtn.TextSize = 10
	tpBtn.Parent = TpRow
	Instance.new("UICorner", tpBtn).CornerRadius = UDim.new(0, 6)

	tpBtn.MouseButton1Click:Connect(function()
		teleportTo(loc.pos)
	end)
end

local HopBtn = Instance.new("TextButton")
HopBtn.Size = UDim2.new(1, 0, 0, 30)
HopBtn.Position = UDim2.new(0, 0, 0, 34)
HopBtn.BackgroundColor3 = HopState.Enabled and Color3.fromRGB(38, 155, 105) or Color3.fromRGB(55, 65, 85)
HopBtn.Text = HopState.Enabled and "Auto Hop PrimordialCage: BẬT" or "Auto Hop PrimordialCage: TẮT"
HopBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
HopBtn.Font = Enum.Font.GothamBold
HopBtn.TextSize = 11
HopBtn.Parent = BodyFrame
Instance.new("UICorner", HopBtn).CornerRadius = UDim.new(0, 6)

local StatusLabel = Instance.new("TextLabel")
StatusLabel.Size = UDim2.new(1, 0, 0, 18)
StatusLabel.Position = UDim2.new(0, 2, 0, 68)
StatusLabel.BackgroundTransparency = 1
StatusLabel.Text = "Trạng thái: " .. HopState.Status
StatusLabel.TextColor3 = Color3.fromRGB(130, 215, 255)
StatusLabel.Font = Enum.Font.GothamBold
StatusLabel.TextSize = 10
StatusLabel.TextTruncate = Enum.TextTruncate.AtEnd
StatusLabel.TextXAlignment = Enum.TextXAlignment.Left
StatusLabel.Parent = BodyFrame

local ScanCard = Instance.new("Frame")
ScanCard.Size = UDim2.new(1, 0, 0, 114)
ScanCard.Position = UDim2.new(0, 0, 0, 90)
ScanCard.BackgroundColor3 = Color3.fromRGB(28, 31, 40)
ScanCard.BorderSizePixel = 0
ScanCard.Parent = BodyFrame
Instance.new("UICorner", ScanCard).CornerRadius = UDim.new(0, 8)

local ScanTitle = Instance.new("TextLabel")
ScanTitle.Size = UDim2.new(1, -16, 0, 20)
ScanTitle.Position = UDim2.new(0, 8, 0, 6)
ScanTitle.BackgroundTransparency = 1
ScanTitle.Text = "Path36 - Tổng: 0"
ScanTitle.TextColor3 = Color3.fromRGB(255, 195, 95)
ScanTitle.Font = Enum.Font.GothamBold
ScanTitle.TextSize = 12
ScanTitle.TextXAlignment = Enum.TextXAlignment.Left
ScanTitle.Parent = ScanCard

local ScanDetail = Instance.new("TextLabel")
ScanDetail.Size = UDim2.new(1, -16, 0, 80)
ScanDetail.Position = UDim2.new(0, 8, 0, 28)
ScanDetail.BackgroundTransparency = 1
ScanDetail.Text = "Đang quét..."
ScanDetail.TextColor3 = Color3.fromRGB(215, 222, 235)
ScanDetail.Font = Enum.Font.GothamSemibold
ScanDetail.TextSize = 11
ScanDetail.TextWrapped = true
ScanDetail.TextXAlignment = Enum.TextXAlignment.Left
ScanDetail.TextYAlignment = Enum.TextYAlignment.Top
ScanDetail.Parent = ScanCard
local function refreshUI()
	local foundPath, totalInRegion, countsByType, errMsg = scanPath36()
	ScanTitle.Text = string.format("%s - Tổng: %d", TARGET_PATH, totalInRegion)
	ScanDetail.Text = formatCountsText(foundPath, totalInRegion, countsByType, errMsg)
	StatusLabel.Text = "Trạng thái: " .. HopState.Status
end

HopBtn.MouseButton1Click:Connect(function()
	HopState.Enabled = not HopState.Enabled
	HopBtn.Text = HopState.Enabled and "Auto Hop PrimordialCage: BẬT" or "Auto Hop PrimordialCage: TẮT"
	HopBtn.BackgroundColor3 = HopState.Enabled and Color3.fromRGB(38, 155, 105) or Color3.fromRGB(55, 65, 85)
	HopState.Status = HopState.Enabled and ("Chờ " .. SCAN_WAIT_SECONDS .. "s quét Path36...") or "Đã tắt"
	refreshUI()
end)

MinBtn.MouseButton1Click:Connect(function()
	isMinimized = not isMinimized
	BodyFrame.Visible = not isMinimized
	MinBtn.Text = isMinimized and "+" or "-"
	MainFrame.Size = isMinimized and UDim2.new(0, FULL_WIDTH, 0, HEADER_HEIGHT) or UDim2.new(0, FULL_WIDTH, 0, FULL_HEIGHT)
end)

CloseBtn.MouseButton1Click:Connect(function()
	HopState.Enabled = false
	ScreenGui:Destroy()
end)

refreshUI()

task.spawn(function()
	while ScreenGui.Parent do
		task.wait(0.5)
		refreshUI()
	end
end)

task.spawn(function()
	local enterTime = os.clock()
	while ScreenGui.Parent do
		task.wait(0.4)
		if HopState.Enabled then
			local elapsed = os.clock() - enterTime
			if elapsed < SCAN_WAIT_SECONDS then
				HopState.Status = string.format("Chờ load: %.1fs", SCAN_WAIT_SECONDS - elapsed)
			else
				local found, count = hasPrimordialCage()
				if found then
					HopState.Enabled = false
					HopBtn.Text = "Auto Hop PrimordialCage: TẮT"
					HopBtn.BackgroundColor3 = Color3.fromRGB(55, 65, 85)
					HopState.Status = string.format("Đã dừng! Có %s (%d)", TARGET_CAGE, count)
					refreshUI()
				else
					HopState.Status = "Không có PrimordialCage, hop..."
					refreshUI()
					task.wait(HOP_RETRY_DELAY)
					if HopState.Enabled and ScreenGui.Parent then
						hopToOtherServer()
						enterTime = os.clock()
					end
				end
			end
		end
	end
end)
