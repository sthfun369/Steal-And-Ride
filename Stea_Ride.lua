local Players = game:GetService("Players")
local TeleportService = game:GetService("TeleportService")
local HttpService = game:GetService("HttpService")

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

-- ==========================================
-- CẤU HÌNH VÙNG, TỌA ĐỘ & AUTO SERVER HOP
-- ==========================================
local REGIONS = {
	{ pathName = "Path35", regionName = "Yomi River", accent = Color3.fromRGB(255, 110, 110) },
	{ pathName = "Path34", regionName = "Golden Throne", accent = Color3.fromRGB(255, 215, 95) },
	{ pathName = "Path33", regionName = "Cloud Palace", accent = Color3.fromRGB(125, 210, 255) },
}

-- Điều kiện lồng dừng Server Hop theo từng vùng
local HOP_TARGET_RULES = {
	Path35 = { "AscendedCage" },        -- Yomi River
	Path34 = { "Singularity+Cage" },   -- Golden Throne
	Path33 = { "SingularityCage" },    -- Cloud Palace
}

local REQUIRE_ALL_REGIONS = false -- false = chỉ cần 1 trong 3 vùng đạt là dừng; true = cả 3 vùng đều phải có
local SCAN_WAIT_SECONDS = 4     -- Thời gian chờ map/lồng load sau khi vào server
local HOP_RETRY_DELAY = 3       -- Thời gian chờ giữa các lần hop

-- Sau khi lấy link Raw GitHub, dán vào đây để tự chạy lại khi hop server
local RAW_SCRIPT_URL = ""
local AUTO_START_HOP_ON_TELEPORT = true

-- Danh sách các tọa độ Teleport
local TP_LOCATIONS = {
	{ name = "Back", pos = Vector3.new(12004, 4, -475), color = Color3.fromRGB(120, 145, 215) },
	{ name = "Cloud Palace", pos = Vector3.new(11948, 4, -13392), color = Color3.fromRGB(70, 155, 225) },
	{ name = "Golden Throne", pos = Vector3.new(12055, 4, -16343), color = Color3.fromRGB(210, 165, 55) },
	{ name = "Yomi River", pos = Vector3.new(11947, 4, -19702), color = Color3.fromRGB(205, 80, 95) },
}

local shouldAutoStart = (getgenv and getgenv().AUTO_HOP_BOOT == true) and true or false
if getgenv then
	getgenv().AUTO_HOP_BOOT = nil
end

local HopState = {
	Enabled = shouldAutoStart,
	Status = shouldAutoStart and ("Chờ " .. SCAN_WAIT_SECONDS .. "s để quét lồng...") or "Sẵn sàng",
}

local visitedServers = {
	[game.JobId] = true,
}

local function cleanStr(str)
	return string.lower(tostring(str or "")):gsub("%s+", "")
end

-- Hàm dịch chuyển nhân vật tới tọa độ
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

-- Quét số lượng từng loại Cage trong một Path cụ thể
local function scanRegionCages(pathName)
	local countsByType = {}
	local totalInRegion = 0
	local foundPath = false

	local pathsFolder = workspace:FindFirstChild("Paths")
	if not pathsFolder then
		return false, 0, countsByType, "Thiếu Paths"
	end

	local pathObj = pathsFolder:FindFirstChild(pathName)
	if not pathObj then
		return false, 0, countsByType, "Thiếu " .. pathName
	end
	foundPath = true

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

	return foundPath, totalInRegion, countsByType, nil
end

local function formatCountsText(foundPath, totalInRegion, countsByType, errMsg)
	if not foundPath then
		return errMsg or "Không tìm thấy vùng"
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

-- Kiểm tra xem server hiện tại có lồng khớp điều kiện từng vùng hay không
local function checkHopConditionMet()
	local matchedSummary = {}
	local allRegionsMatched = true

	for _, cfg in ipairs(REGIONS) do
		local rules = HOP_TARGET_RULES[cfg.pathName]
		if rules and #rules > 0 then
			local foundPath, _, countsByType = scanRegionCages(cfg.pathName)
			local regionHit = false

			if foundPath then
				for cageName, count in pairs(countsByType) do
					if count > 0 then
						for _, targetName in ipairs(rules) do
							if cleanStr(cageName) == cleanStr(targetName) then
								regionHit = true
								table.insert(matchedSummary, string.format("%s: %s (%d)", cfg.regionName, cageName, count))
								break
							end
						end
					end
					if regionHit then
						break
					end
				end
			end

			if not regionHit then
				allRegionsMatched = false
			end
		end
	end

	if REQUIRE_ALL_REGIONS then
		return allRegionsMatched, table.concat(matchedSummary, " | ")
	else
		return #matchedSummary > 0, table.concat(matchedSummary, " | ")
	end
end

-- Đăng ký tự chạy lại sau khi đổi server qua link Raw
local function queueSelfOnTeleport()
	if RAW_SCRIPT_URL == "" then
		return
	end
	local queueFn = (syn and syn.queue_on_teleport) or queue_on_teleport or (fluxus and fluxus.queue_on_teleport)
	if not queueFn then
		return
	end

	local payload = string.format([[
		task.wait(2)
		if getgenv then
			getgenv().AUTO_HOP_BOOT = %s
		end
		loadstring(game:HttpGet(%q))()
	]], tostring(AUTO_START_HOP_ON_TELEPORT), RAW_SCRIPT_URL)

	pcall(function()
		queueFn(payload)
	end)
end

-- Chuyển sang server khác
local function hopToOtherServer()
	HopState.Status = "Đang tìm server..."
	local cursor = ""
	local servers = {}

	for _ = 1, 5 do
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

		if body.nextPageCursor and tostring(body.nextPageCursor) ~= "" then
			cursor = tostring(body.nextPageCursor)
		else
			break
		end
	end

	if #servers == 0 then
		HopState.Status = "Không còn server trống mới, thử lại..."
		return
	end

	local nextJobId = servers[math.random(1, #servers)]
	visitedServers[nextJobId] = true
	HopState.Status = "Đang tele sang server mới..."
	queueSelfOnTeleport()

	pcall(function()
		TeleportService:TeleportToPlaceInstance(game.PlaceId, nextJobId, LocalPlayer)
	end)
end

-- ==========================================
-- 1. TẠO GIAO DIỆN MENU & NÚT TELEPORT
-- ==========================================
if PlayerGui:FindFirstChild("RegionCageScannerGui") then
	PlayerGui.RegionCageScannerGui:Destroy()
end

local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name = "RegionCageScannerGui"
ScreenGui.ResetOnSpawn = false
ScreenGui.Parent = PlayerGui

local FULL_WIDTH = 340
local FULL_HEIGHT = 480
local HEADER_HEIGHT = 34

local MainFrame = Instance.new("Frame")
MainFrame.Name = "MainFrame"
MainFrame.Size = UDim2.new(0, FULL_WIDTH, 0, FULL_HEIGHT)
MainFrame.Position = UDim2.new(0.03, 0, 0.18, 0)
MainFrame.BackgroundColor3 = Color3.fromRGB(20, 22, 28)
MainFrame.BorderSizePixel = 0
MainFrame.Active = true
MainFrame.Draggable = true
MainFrame.Parent = ScreenGui
Instance.new("UICorner", MainFrame).CornerRadius = UDim.new(0, 10)

local MainStroke = Instance.new("UIStroke")
MainStroke.Color = Color3.fromRGB(70, 75, 95)
MainStroke.Thickness = 1.2
MainStroke.Parent = MainFrame

-- Thanh tiêu đề
local Header = Instance.new("Frame")
Header.Size = UDim2.new(1, 0, 0, HEADER_HEIGHT)
Header.BackgroundColor3 = Color3.fromRGB(30, 33, 42)
Header.BorderSizePixel = 0
Header.Parent = MainFrame
Instance.new("UICorner", Header).CornerRadius = UDim.new(0, 10)

local TitleLabel = Instance.new("TextLabel")
TitleLabel.Size = UDim2.new(1, -70, 1, 0)
TitleLabel.Position = UDim2.new(0, 10, 0, 0)
TitleLabel.BackgroundTransparency = 1
TitleLabel.Text = "CAGE SCANNER & TELEPORT"
TitleLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
TitleLabel.Font = Enum.Font.GothamBold
TitleLabel.TextSize = 12
TitleLabel.TextXAlignment = Enum.TextXAlignment.Left
TitleLabel.Parent = Header

local isMinimized = false
local MinBtn = Instance.new("TextButton")
MinBtn.Size = UDim2.new(0, 24, 0, 24)
MinBtn.Position = UDim2.new(1, -56, 0.5, -12)
MinBtn.BackgroundColor3 = Color3.fromRGB(50, 55, 70)
MinBtn.Text = "-"
MinBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
MinBtn.Font = Enum.Font.GothamBold
MinBtn.TextSize = 14
MinBtn.Parent = Header
Instance.new("UICorner", MinBtn).CornerRadius = UDim.new(0, 6)

local CloseBtn = Instance.new("TextButton")
CloseBtn.Size = UDim2.new(0, 24, 0, 24)
CloseBtn.Position = UDim2.new(1, -28, 0.5, -12)
CloseBtn.BackgroundColor3 = Color3.fromRGB(190, 55, 55)
CloseBtn.Text = "X"
CloseBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
CloseBtn.Font = Enum.Font.GothamBold
CloseBtn.TextSize = 12
CloseBtn.Parent = Header
Instance.new("UICorner", CloseBtn).CornerRadius = UDim.new(0, 6)

-- Khung cuộn chính
local ScrollFrame = Instance.new("ScrollingFrame")
ScrollFrame.Size = UDim2.new(1, -16, 1, -44)
ScrollFrame.Position = UDim2.new(0, 8, 0, 38)
ScrollFrame.BackgroundTransparency = 1
ScrollFrame.BorderSizePixel = 0
ScrollFrame.ScrollBarThickness = 4
ScrollFrame.CanvasSize = UDim2.new(0, 0, 0, 0)
ScrollFrame.AutomaticCanvasSize = Enum.AutomaticSize.Y
ScrollFrame.Parent = MainFrame

local ListLayout = Instance.new("UIListLayout")
ListLayout.Padding = UDim.new(0, 8)
ListLayout.SortOrder = Enum.SortOrder.LayoutOrder
ListLayout.Parent = ScrollFrame

-- Thẻ Server Hop tìm lồng theo điều kiện từng vùng (LayoutOrder = -1)
local HopCard = Instance.new("Frame")
HopCard.Name = "ServerHopCard"
HopCard.Size = UDim2.new(1, -4, 0, 82)
HopCard.BackgroundColor3 = Color3.fromRGB(28, 31, 40)
HopCard.BorderSizePixel = 0
HopCard.LayoutOrder = -1
HopCard.Parent = ScrollFrame
Instance.new("UICorner", HopCard).CornerRadius = UDim.new(0, 8)

local HopStroke = Instance.new("UIStroke")
HopStroke.Color = Color3.fromRGB(52, 57, 74)
HopStroke.Thickness = 1
HopStroke.Parent = HopCard

local HopBtn = Instance.new("TextButton")
HopBtn.Size = UDim2.new(1, -16, 0, 28)
HopBtn.Position = UDim2.new(0, 8, 0, 7)
HopBtn.BackgroundColor3 = HopState.Enabled and Color3.fromRGB(38, 155, 105) or Color3.fromRGB(55, 65, 85)
HopBtn.Text = HopState.Enabled and "Server Hop Tìm Lồng: BẬT" or "Server Hop Tìm Lồng: TẮT"
HopBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
HopBtn.Font = Enum.Font.GothamBold
HopBtn.TextSize = 11
HopBtn.Parent = HopCard
Instance.new("UICorner", HopBtn).CornerRadius = UDim.new(0, 6)

local HopRuleLabel = Instance.new("TextLabel")
HopRuleLabel.Size = UDim2.new(1, -16, 0, 16)
HopRuleLabel.Position = UDim2.new(0, 10, 0, 38)
HopRuleLabel.BackgroundTransparency = 1
HopRuleLabel.Text = "Dừng khi: Yomi=AscendedCage | Throne=Singularity+Cage | Cloud=SingularityCage"
HopRuleLabel.TextColor3 = Color3.fromRGB(165, 175, 195)
HopRuleLabel.Font = Enum.Font.GothamSemibold
HopRuleLabel.TextSize = 9
HopRuleLabel.TextTruncate = Enum.TextTruncate.AtEnd
HopRuleLabel.TextXAlignment = Enum.TextXAlignment.Left
HopRuleLabel.Parent = HopCard

local HopStatusLabel = Instance.new("TextLabel")
HopStatusLabel.Size = UDim2.new(1, -16, 0, 18)
HopStatusLabel.Position = UDim2.new(0, 10, 0, 56)
HopStatusLabel.BackgroundTransparency = 1
HopStatusLabel.Text = "Trạng thái: " .. HopState.Status
HopStatusLabel.TextColor3 = Color3.fromRGB(130, 215, 255)
HopStatusLabel.Font = Enum.Font.GothamBold
HopStatusLabel.TextSize = 10
HopStatusLabel.TextTruncate = Enum.TextTruncate.AtEnd
HopStatusLabel.TextXAlignment = Enum.TextXAlignment.Left
HopStatusLabel.Parent = HopCard

-- Khung chứa các nút Teleport (LayoutOrder = 0 để nằm trên cùng)
local TpCard = Instance.new("Frame")
TpCard.Name = "TeleportCard"
TpCard.Size = UDim2.new(1, -4, 0, 86)
TpCard.BackgroundColor3 = Color3.fromRGB(28, 31, 40)
TpCard.BorderSizePixel = 0
TpCard.LayoutOrder = 0
TpCard.Parent = ScrollFrame
Instance.new("UICorner", TpCard).CornerRadius = UDim.new(0, 8)

local TpStroke = Instance.new("UIStroke")
TpStroke.Color = Color3.fromRGB(52, 57, 74)
TpStroke.Thickness = 1
TpStroke.Parent = TpCard

local TpTitle = Instance.new("TextLabel")
TpTitle.Size = UDim2.new(1, -16, 0, 18)
TpTitle.Position = UDim2.new(0, 10, 0, 6)
TpTitle.BackgroundTransparency = 1
TpTitle.Text = "TELEPORT VỊ TRÍ"
TpTitle.TextColor3 = Color3.fromRGB(140, 235, 185)
TpTitle.Font = Enum.Font.GothamBold
TpTitle.TextSize = 11
TpTitle.TextXAlignment = Enum.TextXAlignment.Left
TpTitle.Parent = TpCard

local TpGrid = Instance.new("Frame")
TpGrid.Size = UDim2.new(1, -16, 0, 54)
TpGrid.Position = UDim2.new(0, 8, 0, 26)
TpGrid.BackgroundTransparency = 1
TpGrid.Parent = TpCard

local GridLayout = Instance.new("UIGridLayout")
GridLayout.CellSize = UDim2.new(0.485, 0, 0, 24)
GridLayout.CellPadding = UDim2.new(0.03, 0, 0, 5)
GridLayout.SortOrder = Enum.SortOrder.LayoutOrder
GridLayout.Parent = TpGrid

for i, loc in ipairs(TP_LOCATIONS) do
	local btn = Instance.new("TextButton")
	btn.Name = "TP_" .. loc.name
	btn.Text = "TP: " .. loc.name
	btn.BackgroundColor3 = loc.color
	btn.TextColor3 = Color3.fromRGB(255, 255, 255)
	btn.Font = Enum.Font.GothamBold
	btn.TextSize = 10
	btn.LayoutOrder = i
	btn.Parent = TpGrid
	Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 6)

	btn.MouseButton1Click:Connect(function()
		teleportTo(loc.pos)
	end)
end

-- Tạo thẻ hiển thị cho từng vùng
local regionCards = {}

for idx, cfg in ipairs(REGIONS) do
	local Card = Instance.new("Frame")
	Card.Name = cfg.pathName .. "_Card"
	Card.Size = UDim2.new(1, -4, 0, 92)
	Card.AutomaticSize = Enum.AutomaticSize.Y
	Card.BackgroundColor3 = Color3.fromRGB(28, 31, 40)
	Card.BorderSizePixel = 0
	Card.LayoutOrder = idx
	Card.Parent = ScrollFrame
	Instance.new("UICorner", Card).CornerRadius = UDim.new(0, 8)

	local CardStroke = Instance.new("UIStroke")
	CardStroke.Color = Color3.fromRGB(52, 57, 74)
	CardStroke.Thickness = 1
	CardStroke.Parent = Card

	local Pad = Instance.new("UIPadding")
	Pad.PaddingTop = UDim.new(0, 8)
	Pad.PaddingBottom = UDim.new(0, 8)
	Pad.PaddingLeft = UDim.new(0, 10)
	Pad.PaddingRight = UDim.new(0, 10)
	Pad.Parent = Card

	local CardLayout = Instance.new("UIListLayout")
	CardLayout.Padding = UDim.new(0, 4)
	CardLayout.SortOrder = Enum.SortOrder.LayoutOrder
	CardLayout.Parent = Card

	local RegionTitle = Instance.new("TextLabel")
	RegionTitle.Size = UDim2.new(1, 0, 0, 18)
	RegionTitle.BackgroundTransparency = 1
	RegionTitle.Text = string.format("%s (%s) - Tổng: 0", cfg.regionName, cfg.pathName)
	RegionTitle.TextColor3 = cfg.accent
	RegionTitle.Font = Enum.Font.GothamBold
	RegionTitle.TextSize = 12
	RegionTitle.TextXAlignment = Enum.TextXAlignment.Left
	RegionTitle.LayoutOrder = 1
	RegionTitle.Parent = Card

	local DetailLabel = Instance.new("TextLabel")
	DetailLabel.Size = UDim2.new(1, 0, 0, 16)
	DetailLabel.AutomaticSize = Enum.AutomaticSize.Y
	DetailLabel.BackgroundTransparency = 1
	DetailLabel.Text = "Đang quét..."
	DetailLabel.TextColor3 = Color3.fromRGB(215, 222, 235)
	DetailLabel.Font = Enum.Font.GothamSemibold
	DetailLabel.TextSize = 11
	DetailLabel.TextWrapped = true
	DetailLabel.TextXAlignment = Enum.TextXAlignment.Left
	DetailLabel.TextYAlignment = Enum.TextYAlignment.Top
	DetailLabel.LayoutOrder = 2
	DetailLabel.Parent = Card

	regionCards[cfg.pathName] = {
		cfg = cfg,
		titleLabel = RegionTitle,
		detailLabel = DetailLabel,
	}
end

-- ==========================================
-- 2. CẬP NHẬT DỮ LIỆU, HOP LOOP & SỰ KIỆN NÚT
-- ==========================================
local function refreshAllRegions()
	for _, entry in pairs(regionCards) do
		local foundPath, totalInRegion, countsByType, errMsg = scanRegionCages(entry.cfg.pathName)
		entry.titleLabel.Text = string.format(
			"%s (%s) - Tổng: %d",
			entry.cfg.regionName,
			entry.cfg.pathName,
			totalInRegion
		)
		entry.detailLabel.Text = formatCountsText(foundPath, totalInRegion, countsByType, errMsg)
	end
	HopStatusLabel.Text = "Trạng thái: " .. HopState.Status
end

HopBtn.MouseButton1Click:Connect(function()
	HopState.Enabled = not HopState.Enabled
	HopBtn.Text = HopState.Enabled and "Server Hop Tìm Lồng: BẬT" or "Server Hop Tìm Lồng: TẮT"
	HopBtn.BackgroundColor3 = HopState.Enabled and Color3.fromRGB(38, 155, 105) or Color3.fromRGB(55, 65, 85)
	HopState.Status = HopState.Enabled and ("Chờ " .. SCAN_WAIT_SECONDS .. "s để quét lồng...") or "Đã tắt"
	refreshAllRegions()
end)

MinBtn.MouseButton1Click:Connect(function()
	isMinimized = not isMinimized
	ScrollFrame.Visible = not isMinimized
	MinBtn.Text = isMinimized and "+" or "-"
	MainFrame.Size = isMinimized and UDim2.new(0, FULL_WIDTH, 0, HEADER_HEIGHT) or UDim2.new(0, FULL_WIDTH, 0, FULL_HEIGHT)
end)

CloseBtn.MouseButton1Click:Connect(function()
	HopState.Enabled = false
	ScreenGui:Destroy()
end)

refreshAllRegions()

task.spawn(function()
	while ScreenGui.Parent do
		task.wait(1)
		refreshAllRegions()
	end
end)

task.spawn(function()
	local enterTime = os.clock()
	while ScreenGui.Parent do
		task.wait(1)
		if HopState.Enabled then
			local elapsed = os.clock() - enterTime
			if elapsed < SCAN_WAIT_SECONDS then
				HopState.Status = string.format("Chờ lồng load: %.0fs", SCAN_WAIT_SECONDS - elapsed)
			else
				local met, summary = checkHopConditionMet()
				if met then
					HopState.Enabled = false
					HopBtn.Text = "Server Hop Tìm Lồng: TẮT"
					HopBtn.BackgroundColor3 = Color3.fromRGB(55, 65, 85)
					HopState.Status = "Đã dừng! Có: " .. summary
					refreshAllRegions()
				else
					HopState.Status = "Chưa có lồng mục tiêu, đang hop..."
					refreshAllRegions()
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
