--!strict
--[[
MapLayout: the map contract between code and builder (T-016). Owned by world-programmer.
This is the ONLY code that reads CollectionService tags or builder attributes on map parts
(docs/architecture.md section 1f). Every other module asks MapLayout. Shared: server and client.

=== TAG CONTRACT FOR BUILDER ======================================================================
Tag every item below with CollectionService (Tag Editor) and set its attributes exactly.
Map items live under Workspace (any folder; code never uses paths). Copies in ReplicatedStorage or
ServerStorage are ignored, so templates may carry tags too.

  Tag          Instance                      Attributes (type)                      Notes
  -----------  ----------------------------  -------------------------------------  ---------------------------
  BossStage    Model (PrimaryPart = stage    BossId (string), WorldId (number)      ModelStreamingMode = Atomic.
               anchor) or the anchor Part                                           BossId from BOSS_IDS below.
  Pod          Part, CanCollide off,         PodIndex (number 1..7), WorldId        Box that covers the chair;
               Transparency 1 (zone box)                                            presence = inside the box.
  EggStand     Part or Model                 EggId (string), WorldId                Holds the ProximityPrompt.
  ShopStand    Part or Model                 Shop ("Tools" | "Robux"), WorldId      Holds the ProximityPrompt.
                                                                                    Not on the spawn->Sid path.
  MogRing      Model, Atomic; children       RingIndex (number 1..2), WorldId       Side1/Side2 face each other;
               Parts "Side1", "Side2", "Pit"                                        Pit = foam pit centre.
  Portal       Part (touch box)              ToWorldId (number)                     W1 -> W2 and W2 -> W1.
  Spawn        SpawnLocation (or Part)       WorldId (number)                       Front face (LookVector)
                                                                                    points at the first boss.
  Leaderboard  Part (SurfaceGui face)        Board ("LifetimeMp" | "Rebirths" |     One per board per hub.
                                             "DuelWinsWeek" | "Donors")
  Podium       Part (top surface)            Place (number 1..3)                    Glow Town hub only.

Lean v1 (D-034, T-038), World 1 only. Builder must create in Glow Town (WorldId 1):
  - 7 BossStage (BOSS_IDS[1]), 5 Pod (PodIndex 1..5), 1 Spawn, ShopStand Tools + Robux,
  - EggStand "BasicEgg", "ShinyEgg", "StarEgg" and "GalaxyEgg" (W1_EGG_IDS),
  - EggStand named "GalaxyEggStand": EggId = "GalaxyEgg", WorldId = 1, at (-90, 0, -15)
    (D-057: Galaxy Egg moved from Neon Runway to Glow Town),
  - 1 Portal with ToWorldId = 2. Touching it only shows "World 2 coming Saturday!" (no teleport
    until T-092). Make it a Part touch box (CanCollide off, CanTouch on) in front of the arch.
  Pod boxes: make the box cover the whole chair area and at least 8 studs tall from the floor, so
  a standing or seated character's HumanoidRootPart is inside it.

Mog Rings (T-059, sprint 3), World 1 only in v1. Builder must create in Glow Town:
  - 2 Models tagged "MogRing": RingIndex = 1 and RingIndex = 2, both WorldId = 1, each with
    ModelStreamingMode = Atomic and these direct children (names exact, all BaseParts, Anchored):
      "Side1"  floor pad where duelist 1 stands (top surface = floor; code adds 3 studs height).
      "Side2"  floor pad where duelist 2 stands, about 16 studs from Side1, facing it.
      "Pit"    the foam pit (cartoon foam, CanCollide on so the loser lands in it). Put it beside
               the ring, ~16 studs from the ring centre, NOT between Side1 and Side2.
  - Everything else (ropes, posts, floor, foam cubes) goes inside the same Model, so the Model's
    bounding box covers the ring floor AND the pit: that box (+4 studs) is the ring area the server
    uses for membership. Keep each ring + pit inside a 40 x 40 stud footprint, no roof.
  - Rings sit at WORLDS[1].rings (60, 0, 70) and (110, 0, 70); 50 studs apart so both run at once.
  Without the map the code uses those centres with Side1/Side2 at -/+ 8 X and the pit at +16 Z.

=== LOOK AND FIT TEMPLATES FOR BUILDER (server only) ==============================================
  ServerStorage > Assets (Folder) > Looks (Folder) > <one Folder or Model per id below>
  Each template holds ONLY Accessory instances (each with a Part named "Handle" and an Attachment
  matching an avatar attachment, e.g. HatAttachment, FaceFrontAttachment, BodyFrontAttachment,
  WaistCenterAttachment). Auras, trails and beams go INSIDE an accessory's Handle.
  Anything else (Shirt, Pants, BodyColors, scale values, CharacterMesh, scripts) is ignored:
  looks are cartoon accessories layered on the avatar and never edit the body (GDD 7, 11).
  Keep each rank look to at most 3 accessories and each fit to 1. At most 6 are worn in total.
  Rank looks (LOOK_IDS, = EconomyConfig.RANKS[i].lookId):
    FreshSpawn, CombRookie, GlowStarter, DripApprentice, StyleScout, MainCharacter,
    Trendsetter, AuraFarmer, Icon, SpotlightLegend, StarMogger, SupremeMogger
  Fits (FIT_IDS): StarterFit (first boss win), RookieShades (Starter Pack), GoldenGlowFit,
    NeonIconFit (exclusive cosmetics), VipSparkleAura (VIP),
    WeekStreakAura (Day-7 daily reward: a cartoon aura accessory, Handle only, at
    ServerStorage.Assets.Looks.WeekStreakAura)
===================================================================================================

WorldId: 1 = Glow Town, 2 = Neon Runway. Positions: follow WORLDS below (studs, Y = ground level).
They are a guide, except that the spawn must face Sleepy Sid at 15 studs (GDD 9) and boss stages
sit 50 studs apart along the stage row (T-019). If you move something, update this file in a
request to world-programmer so the fallbacks stay right. Code reads real positions from the parts.
===================================================================================================

Streaming: StreamingEnabled is on. On the client any tagged item may be missing or stream out at
any time, so every getter returns nil (or an empty list) when nothing is there. Use `observe` to
react to items streaming in/out, and `waitFor` (with a timeout) only outside Init.
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types =
	require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Contracts"):WaitForChild("Types"))

local Tag = Types.Tag
local Attr = Types.MapAttr

local MapLayout = {}

export type ShopKind = "Tools" | "Robux"

export type WorldLayout = {
	name: string,
	origin: Vector3,
	spawn: CFrame, -- fallback when no Spawn part exists (or it streamed out)
	bossIds: { string }, -- stage row order, weakest first
	stages: { Vector3 }, -- same order as bossIds
	pods: { [number]: Vector3 }, -- PodIndex -> position
	eggStands: { [string]: Vector3 }, -- EggId -> position
	shopStands: { [string]: Vector3 }, -- Shop -> position
	rings: { Vector3 }, -- RingIndex -> ring centre
	portal: Vector3,
	leaderboards: { [string]: Vector3 },
	podium: { Vector3 }?, -- Place -> position (Glow Town only)
}

-- Boss ids builder writes into `BossId`. Gameplay's EconomyConfig.BOSSES must use the same keys.
MapLayout.BOSS_IDS = table.freeze({
	[1] = table.freeze({
		"SleepySid",
		"BedheadBenny",
		"SweatbandSal",
		"CaptainCardio",
		"DukeOfDrip",
		"GlowQueen",
		"AuraTitan",
	}),
	[2] = table.freeze({
		"LaserLarry",
		"DjDazzle",
		"ChromeChamp",
		"RunwayRex",
		"DivaSupreme",
		"KingShine",
	}),
})

-- Egg stands builder places in World 1 for the lean v1 (D-034). Galaxy Egg moved to World 1 (D-057).
MapLayout.W1_EGG_IDS = table.freeze({ "BasicEgg", "ShinyEgg", "StarEgg", "GalaxyEgg" })

-- Rank look template names, rank order. Must equal EconomyConfig.RANKS[i].lookId (qa checks).
MapLayout.LOOK_IDS = table.freeze({
	"FreshSpawn",
	"CombRookie",
	"GlowStarter",
	"DripApprentice",
	"StyleScout",
	"MainCharacter",
	"Trendsetter",
	"AuraFarmer",
	"Icon",
	"SpotlightLegend",
	"StarMogger",
	"SupremeMogger",
})

-- Fit template names, in wear priority (paid first, so a bought fit is never cut by the cap).
MapLayout.FIT_IDS = table.freeze({
	"GoldenGlowFit",
	"NeonIconFit",
	"VipSparkleAura",
	"RookieShades",
	"WeekStreakAura",
	"StarterFit",
})

MapLayout.LOOK_ASSETS_FOLDER = "Assets" -- ServerStorage.Assets
MapLayout.LOOK_TEMPLATES_FOLDER = "Looks" -- ServerStorage.Assets.Looks
MapLayout.MAX_LOOK_ACCESSORIES = 6

MapLayout.SPAWN_TO_FIRST_STAGE = 15 -- studs (GDD 9: Sleepy Sid 15 studs from spawn)
MapLayout.STAGE_SPACING = 50 -- studs between boss stages (T-019)
MapLayout.SPAWN_HEIGHT = 3 -- studs above the spawn surface for character placement

local function buildWorld(
	name: string,
	origin: Vector3,
	bossIds: { string },
	pods: { [number]: Vector3 },
	eggs: { [string]: Vector3 },
	podium: { Vector3 }?
): WorldLayout
	-- Hub axes: the player spawns at the origin looking down -Z. The first stage is straight ahead;
	-- the stage row runs along +X from there. Pods sit behind spawn, rings and portal further back.
	local firstStage = origin + Vector3.new(0, 0, -MapLayout.SPAWN_TO_FIRST_STAGE)
	local stages = {}
	for i = 1, #bossIds do
		stages[i] = firstStage + Vector3.new(MapLayout.STAGE_SPACING * (i - 1), 0, 0)
	end
	local spawnPos = origin + Vector3.new(0, MapLayout.SPAWN_HEIGHT, 0)
	local shiftedPods: { [number]: Vector3 } = {}
	for index, offset in pods do
		shiftedPods[index] = origin + offset
	end
	local shiftedEggs: { [string]: Vector3 } = {}
	for eggId, offset in eggs do
		shiftedEggs[eggId] = origin + offset
	end
	local shiftedPodium: { Vector3 }? = nil
	if podium then
		local list = {}
		for i, offset in podium do
			list[i] = origin + offset
		end
		shiftedPodium = list
	end
	return {
		name = name,
		origin = origin,
		spawn = CFrame.lookAt(spawnPos, spawnPos + Vector3.new(0, 0, -1)),
		bossIds = bossIds,
		stages = stages,
		pods = shiftedPods,
		eggStands = shiftedEggs,
		shopStands = {
			Tools = origin + Vector3.new(-30, 0, 10),
			Robux = origin + Vector3.new(-30, 0, 30),
		},
		rings = { origin + Vector3.new(60, 0, 70), origin + Vector3.new(110, 0, 70) },
		portal = origin + Vector3.new(0, 0, 100),
		leaderboards = {
			LifetimeMp = origin + Vector3.new(-60, 0, -40),
			Rebirths = origin + Vector3.new(-40, 0, -40),
			DuelWinsWeek = origin + Vector3.new(-20, 0, -40),
			Donors = origin + Vector3.new(-80, 0, -40),
		},
		podium = shiftedPodium,
	}
end

-- World hubs are 4,000 studs apart so the far hub never streams in on mobile.
MapLayout.WORLDS = table.freeze({
	[1] = buildWorld("Glow Town", Vector3.new(0, 0, 0), MapLayout.BOSS_IDS[1], {
		[1] = Vector3.new(-40, 0, 45),
		[2] = Vector3.new(-20, 0, 45),
		[3] = Vector3.new(0, 0, 45),
		[4] = Vector3.new(20, 0, 45),
		[5] = Vector3.new(40, 0, 45),
	}, {
		BasicEgg = Vector3.new(-30, 0, -15),
		ShinyEgg = Vector3.new(-50, 0, -15),
		StarEgg = Vector3.new(-70, 0, -15),
		GalaxyEgg = Vector3.new(-90, 0, -15), -- moved from World 2 (D-057)
	}, { Vector3.new(-60, 0, 70), Vector3.new(-70, 0, 70), Vector3.new(-50, 0, 70) }),
	[2] = buildWorld("Neon Runway", Vector3.new(4000, 0, 0), MapLayout.BOSS_IDS[2], {
		[6] = Vector3.new(-20, 0, 45),
		[7] = Vector3.new(20, 0, 45),
	}, {
		NeonEgg = Vector3.new(-30, 0, -15),
		RunwayEgg = Vector3.new(-50, 0, -15),
	}, nil),
})

MapLayout.WORLD_COUNT = 2

-- Generic helpers --------------------------------------------------------------------------------

local function inWorkspace(inst: Instance): boolean
	return inst:IsDescendantOf(workspace)
end

local function numberAttr(inst: Instance, name: string): number?
	local value = inst:GetAttribute(name)
	if typeof(value) == "number" and value == value then
		return value
	end
	return nil
end

local function stringAttr(inst: Instance, name: string): string?
	local value = inst:GetAttribute(name)
	if typeof(value) == "string" then
		return value
	end
	return nil
end

-- Every tagged instance currently in Workspace (streamed-in only, on the client).
local function tagged(tag: string): { Instance }
	local out = {}
	for _, inst in CollectionService:GetTagged(tag) do
		if inWorkspace(inst) then
			table.insert(out, inst)
		end
	end
	return out
end

local function findTagged(tag: string, match: (Instance) -> boolean): Instance?
	for _, inst in CollectionService:GetTagged(tag) do
		if inWorkspace(inst) and match(inst) then
			return inst
		end
	end
	return nil
end

-- World position of a map item: a BasePart's position, a Model's pivot, an Attachment's world
-- position. nil for anything else, or for a Model with nothing streamed in yet.
function MapLayout.positionOf(inst: Instance?): Vector3?
	if inst == nil then
		return nil
	end
	if inst:IsA("BasePart") then
		return inst.Position
	elseif inst:IsA("Model") then
		if inst.PrimaryPart == nil and inst:FindFirstChildWhichIsA("BasePart", true) == nil then
			return nil
		end
		return inst:GetPivot().Position
	elseif inst:IsA("Attachment") then
		return inst.WorldPosition
	end
	return nil
end

function MapLayout.cframeOf(inst: Instance?): CFrame?
	if inst == nil then
		return nil
	end
	if inst:IsA("BasePart") then
		return inst.CFrame
	elseif inst:IsA("Model") then
		if inst.PrimaryPart == nil and inst:FindFirstChildWhichIsA("BasePart", true) == nil then
			return nil
		end
		return inst:GetPivot()
	end
	return nil
end

-- Oriented box of a map item (Part: its CFrame and Size; Model: its bounding box). nil otherwise
-- or when a Model has nothing streamed in.
function MapLayout.boxOf(inst: Instance?): (CFrame?, Vector3?)
	if inst == nil then
		return nil, nil
	end
	if inst:IsA("BasePart") then
		return inst.CFrame, inst.Size
	elseif inst:IsA("Model") then
		if inst:FindFirstChildWhichIsA("BasePart", true) == nil then
			return nil, nil
		end
		local cf, size = inst:GetBoundingBox()
		return cf, size
	end
	return nil, nil
end

-- True when `point` is inside the item's box, grown by `pad` studs on every side.
function MapLayout.isInsideBox(inst: Instance?, point: Vector3, pad: number?): boolean
	local cf, size = MapLayout.boxOf(inst)
	if cf == nil or size == nil then
		return false
	end
	local localPoint = cf:PointToObjectSpace(point)
	local half = size / 2 + Vector3.one * (pad or 0)
	return math.abs(localPoint.X) <= half.X
		and math.abs(localPoint.Y) <= half.Y
		and math.abs(localPoint.Z) <= half.Z
end

function MapLayout.getWorldIdOf(inst: Instance): number?
	return numberAttr(inst, Attr.WorldId)
end

function MapLayout.isValidWorld(worldId: any): boolean
	return typeof(worldId) == "number" and MapLayout.WORLDS[worldId] ~= nil
end

-- Boss stages -----------------------------------------------------------------------------------

function MapLayout.getBossStage(bossId: string): Instance?
	return findTagged(Tag.BossStage, function(inst)
		return stringAttr(inst, Attr.BossId) == bossId
	end)
end

function MapLayout.getBossIdOf(inst: Instance): string?
	return stringAttr(inst, Attr.BossId)
end

-- World of a boss from the layout table (does not need the map; safe before streaming).
function MapLayout.getBossWorld(bossId: string): number?
	for worldId, ids in MapLayout.BOSS_IDS do
		if table.find(ids, bossId) then
			return worldId
		end
	end
	return nil
end

-- Stage position: the real part when present, else the layout fallback.
function MapLayout.getBossStagePosition(bossId: string): Vector3?
	local pos = MapLayout.positionOf(MapLayout.getBossStage(bossId))
	if pos then
		return pos
	end
	local worldId = MapLayout.getBossWorld(bossId)
	if worldId == nil then
		return nil
	end
	local world = MapLayout.WORLDS[worldId]
	local index = table.find(world.bossIds, bossId)
	return if index then world.stages[index] else nil
end

-- Pods ------------------------------------------------------------------------------------------

function MapLayout.getPods(worldId: number?): { Instance }
	local out = {}
	for _, inst in tagged(Tag.Pod) do
		if worldId == nil or MapLayout.getWorldIdOf(inst) == worldId then
			table.insert(out, inst)
		end
	end
	return out
end

function MapLayout.getPod(podIndex: number): Instance?
	return findTagged(Tag.Pod, function(inst)
		return numberAttr(inst, Attr.PodIndex) == podIndex
	end)
end

function MapLayout.getPodIndexOf(inst: Instance): number?
	return numberAttr(inst, Attr.PodIndex)
end

-- Egg and shop stands ---------------------------------------------------------------------------

function MapLayout.getEggStand(eggId: string): Instance?
	return findTagged(Tag.EggStand, function(inst)
		return stringAttr(inst, Attr.EggId) == eggId
	end)
end

function MapLayout.getEggIdOf(inst: Instance): string?
	return stringAttr(inst, Attr.EggId)
end

-- World of an egg from the layout table (nil for an unknown id). Safe before streaming.
function MapLayout.getEggWorld(eggId: string): number?
	for worldId, world in MapLayout.WORLDS do
		if world.eggStands[eggId] ~= nil then
			return worldId
		end
	end
	return nil
end

function MapLayout.getEggStandPosition(eggId: string): Vector3?
	local pos = MapLayout.positionOf(MapLayout.getEggStand(eggId))
	if pos then
		return pos
	end
	for _, world in MapLayout.WORLDS do
		local fallback = world.eggStands[eggId]
		if fallback then
			return fallback
		end
	end
	return nil
end

function MapLayout.getShopStand(worldId: number, shop: ShopKind): Instance?
	return findTagged(Tag.ShopStand, function(inst)
		return stringAttr(inst, Attr.Shop) == shop and MapLayout.getWorldIdOf(inst) == worldId
	end)
end

function MapLayout.getShopKindOf(inst: Instance): ShopKind?
	local shop = stringAttr(inst, Attr.Shop)
	if shop == "Tools" or shop == "Robux" then
		return shop
	end
	return nil
end

function MapLayout.getShopStandPosition(worldId: number, shop: ShopKind): Vector3?
	local pos = MapLayout.positionOf(MapLayout.getShopStand(worldId, shop))
	if pos then
		return pos
	end
	local world = MapLayout.WORLDS[worldId]
	return if world then world.shopStands[shop] else nil
end

-- Mog rings -------------------------------------------------------------------------------------

MapLayout.RING_COUNT = 2 -- rings per world hub (GDD 6)
MapLayout.RING_SIDE1_NAME = "Side1"
MapLayout.RING_SIDE2_NAME = "Side2"
MapLayout.RING_PIT_NAME = "Pit"
MapLayout.RING_SIDE_OFFSET = 8 -- fallback: Side1/Side2 at centre -/+ 8 studs on X
MapLayout.RING_PIT_OFFSET = Vector3.new(0, 0, 16) -- fallback: foam pit beside the ring
MapLayout.RING_AREA_PAD = 4 -- studs added around the ring Model's box for membership
MapLayout.RING_AREA_VERTICAL_PAD = 20 -- jumps and the knockback arc stay "in the ring"
MapLayout.RING_FALLBACK_RADIUS = 28 -- XZ radius of the ring area when the Model is missing

export type RingParts = { model: Instance, side1: BasePart?, side2: BasePart?, pit: BasePart? }

local DEFAULT_KNOCKBACK = Vector3.new(0, 0, 1)

function MapLayout.getRing(worldId: number, ringIndex: number): RingParts?
	local model = findTagged(Tag.MogRing, function(inst)
		return numberAttr(inst, Attr.RingIndex) == ringIndex and MapLayout.getWorldIdOf(inst) == worldId
	end)
	if model == nil then
		return nil
	end
	local function part(name: string): BasePart?
		local child = model:FindFirstChild(name)
		return if child and child:IsA("BasePart") then child else nil
	end
	return {
		model = model,
		side1 = part(MapLayout.RING_SIDE1_NAME),
		side2 = part(MapLayout.RING_SIDE2_NAME),
		pit = part(MapLayout.RING_PIT_NAME),
	}
end

function MapLayout.isValidRing(worldId: any, ringIndex: any): boolean
	return MapLayout.isValidWorld(worldId)
		and typeof(ringIndex) == "number"
		and ringIndex == math.floor(ringIndex)
		and ringIndex >= 1
		and ringIndex <= MapLayout.RING_COUNT
		and MapLayout.WORLDS[worldId].rings[ringIndex] ~= nil
end

-- Layout fallback centre (nil for an unknown world/ring). Safe before the map exists.
local function fallbackRingCentre(worldId: number, ringIndex: number): Vector3?
	if not MapLayout.isValidRing(worldId, ringIndex) then
		return nil
	end
	return MapLayout.WORLDS[worldId].rings[ringIndex]
end

-- Ring centre: midpoint of Side1/Side2, else the Model pivot, else the layout fallback.
function MapLayout.getRingCentre(worldId: number, ringIndex: number): Vector3?
	local fallback = fallbackRingCentre(worldId, ringIndex)
	if fallback == nil then
		return nil
	end
	local ring = MapLayout.getRing(worldId, ringIndex)
	if ring then
		if ring.side1 and ring.side2 then
			return (ring.side1.Position + ring.side2.Position) / 2
		end
		local pos = MapLayout.positionOf(ring.model)
		if pos then
			return pos
		end
	end
	return fallback
end

-- Floor position of a duelist pad (side 1 or 2): the Side part, else the layout fallback.
local function sidePosition(worldId: number, ringIndex: number, side: number): Vector3?
	local fallback = fallbackRingCentre(worldId, ringIndex)
	if fallback == nil or (side ~= 1 and side ~= 2) then
		return nil
	end
	local ring = MapLayout.getRing(worldId, ringIndex)
	local part = ring and (if side == 1 then ring.side1 else ring.side2)
	if part then
		return part.Position
	end
	local sign = if side == 1 then -1 else 1
	return fallback + Vector3.new(sign * MapLayout.RING_SIDE_OFFSET, 0, 0)
end

-- Where to put duelist `side` (1 or 2): on its pad, raised by SPAWN_HEIGHT, facing the other pad.
function MapLayout.getRingSideCFrame(worldId: number, ringIndex: number, side: number): CFrame?
	local own = sidePosition(worldId, ringIndex, side)
	local other = sidePosition(worldId, ringIndex, if side == 1 then 2 else 1)
	if own == nil or other == nil then
		return nil
	end
	local pos = own + Vector3.new(0, MapLayout.SPAWN_HEIGHT, 0)
	local look = Vector3.new(other.X - own.X, 0, other.Z - own.Z)
	if look.Magnitude < 1e-3 then
		look = Vector3.new(0, 0, -1)
	end
	return CFrame.lookAt(pos, pos + look.Unit)
end

-- Foam pit centre: the Pit part, else the layout fallback.
function MapLayout.getRingPitPosition(worldId: number, ringIndex: number): Vector3?
	local fallback = fallbackRingCentre(worldId, ringIndex)
	if fallback == nil then
		return nil
	end
	local ring = MapLayout.getRing(worldId, ringIndex)
	if ring and ring.pit then
		return ring.pit.Position
	end
	local centre = MapLayout.getRingCentre(worldId, ringIndex) or fallback
	return centre + MapLayout.RING_PIT_OFFSET
end

-- Flat (XZ) unit vector from the ring centre to its foam pit. Never nil: +Z for bad input.
function MapLayout.getRingKnockback(worldId: number, ringIndex: number): Vector3
	local centre = MapLayout.getRingCentre(worldId, ringIndex)
	local pit = MapLayout.getRingPitPosition(worldId, ringIndex)
	if centre == nil or pit == nil then
		return DEFAULT_KNOCKBACK
	end
	local dir = Vector3.new(pit.X - centre.X, 0, pit.Z - centre.Z)
	if dir.Magnitude < 1e-3 then
		return DEFAULT_KNOCKBACK
	end
	return dir.Unit
end

-- Geometry only: true when `point` is inside the ring area (ring Model box incl. pit, padded; or
-- the fallback radius when the Model is missing). The server decides membership (ZoneService).
function MapLayout.isInRingArea(worldId: number, ringIndex: number, point: Vector3): boolean
	if not MapLayout.isValidRing(worldId, ringIndex) or typeof(point) ~= "Vector3" then
		return false
	end
	local ring = MapLayout.getRing(worldId, ringIndex)
	local cf, size = MapLayout.boxOf(if ring then ring.model else nil)
	if cf and size then
		local localPoint = cf:PointToObjectSpace(point)
		local half = size / 2
		return math.abs(localPoint.X) <= half.X + MapLayout.RING_AREA_PAD
			and math.abs(localPoint.Z) <= half.Z + MapLayout.RING_AREA_PAD
			and math.abs(localPoint.Y) <= half.Y + MapLayout.RING_AREA_VERTICAL_PAD
	end
	local centre = MapLayout.getRingCentre(worldId, ringIndex)
	if centre == nil then
		return false
	end
	local flat = Vector3.new(point.X - centre.X, 0, point.Z - centre.Z)
	return flat.Magnitude <= MapLayout.RING_FALLBACK_RADIUS
		and math.abs(point.Y - centre.Y) <= MapLayout.RING_AREA_VERTICAL_PAD
end

-- Portals, spawns, leaderboards, podium ---------------------------------------------------------

function MapLayout.getPortals(): { Instance }
	return tagged(Tag.Portal)
end

function MapLayout.getPortalTarget(inst: Instance): number?
	return numberAttr(inst, Attr.ToWorldId)
end

function MapLayout.getSpawn(worldId: number): Instance?
	return findTagged(Tag.Spawn, function(inst)
		return MapLayout.getWorldIdOf(inst) == worldId
	end)
end

-- Where to put a character for this world: the Spawn part's CFrame (raised by SPAWN_HEIGHT), else
-- the layout fallback. Never nil for a valid world.
function MapLayout.getSpawnCFrame(worldId: number): CFrame?
	local cf = MapLayout.cframeOf(MapLayout.getSpawn(worldId))
	if cf then
		local pos = cf.Position + Vector3.new(0, MapLayout.SPAWN_HEIGHT, 0)
		local look = Vector3.new(cf.LookVector.X, 0, cf.LookVector.Z)
		if look.Magnitude < 1e-3 then
			look = Vector3.new(0, 0, -1)
		end
		return CFrame.lookAt(pos, pos + look.Unit)
	end
	local world = MapLayout.WORLDS[worldId]
	return if world then world.spawn else nil
end

function MapLayout.getLeaderboard(worldId: number, board: Types.LeaderboardId): Instance?
	return findTagged(Tag.Leaderboard, function(inst)
		return stringAttr(inst, Attr.Board) == board
			and (MapLayout.getWorldIdOf(inst) == nil or MapLayout.getWorldIdOf(inst) == worldId)
	end)
end

function MapLayout.getLeaderboards(): { Instance }
	return tagged(Tag.Leaderboard)
end

function MapLayout.getBoardOf(inst: Instance): string?
	return stringAttr(inst, Attr.Board)
end

function MapLayout.getPodium(place: number): Instance?
	return findTagged(Tag.Podium, function(inst)
		return numberAttr(inst, Attr.Place) == place
	end)
end

-- Streaming helpers -----------------------------------------------------------------------------

export type MapTag =
	"BossStage"
	| "Pod"
	| "EggStand"
	| "ShopStand"
	| "MogRing"
	| "Portal"
	| "Spawn"
	| "Leaderboard"
	| "Podium"

-- Calls `added` for every tagged item in Workspace now and as it streams in, and `removed` as it
-- streams out or is destroyed. Returns a function that disconnects both. Never yields.
function MapLayout.observe(
	tag: MapTag,
	added: (inst: Instance) -> (),
	removed: ((inst: Instance) -> ())?
): () -> ()
	local tagName = (Tag :: any)[tag] :: string
	assert(tagName, `MapLayout.observe: unknown tag "{tag}"`)
	local seen: { [Instance]: boolean } = {}
	local function onAdded(inst: Instance)
		if seen[inst] or not inWorkspace(inst) then
			return
		end
		seen[inst] = true
		task.spawn(added, inst)
	end
	local function onRemoved(inst: Instance)
		if not seen[inst] then
			return
		end
		seen[inst] = nil
		if removed then
			task.spawn(removed, inst)
		end
	end
	local addConn = CollectionService:GetInstanceAddedSignal(tagName):Connect(onAdded)
	local removeConn = CollectionService:GetInstanceRemovedSignal(tagName):Connect(onRemoved)
	for _, inst in CollectionService:GetTagged(tagName) do
		onAdded(inst)
	end
	return function()
		addConn:Disconnect()
		removeConn:Disconnect()
		table.clear(seen)
	end
end

-- Yields until a tagged item matching `match` is in Workspace, or `timeoutSec` passes (default 10).
-- Returns nil on timeout. Never call from Init.
function MapLayout.waitFor(tag: MapTag, match: (inst: Instance) -> boolean, timeoutSec: number?): Instance?
	local tagName = (Tag :: any)[tag] :: string
	assert(tagName, `MapLayout.waitFor: unknown tag "{tag}"`)
	local found = findTagged(tagName, match)
	if found then
		return found
	end
	local thread = coroutine.running()
	local done = false
	local conn: RBXScriptConnection? = nil
	local function finish(result: Instance?)
		if done then
			return
		end
		done = true
		if conn then
			conn:Disconnect()
		end
		task.spawn(thread, result)
	end
	conn = CollectionService:GetInstanceAddedSignal(tagName):Connect(function(inst)
		if inWorkspace(inst) and match(inst) then
			finish(inst)
		end
	end)
	task.delay(timeoutSec or 10, finish, nil)
	return coroutine.yield()
end

return table.freeze(MapLayout)
