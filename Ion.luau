--!strict
--!native
--!optimize 2

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local EncodingService = game:GetService("EncodingService")

-- Localize Buffer Library for speed
local BufferWriteU8 = buffer.writeu8
local BufferWriteU16 = buffer.writeu16
local BufferWriteU32 = buffer.writeu32
local BufferWriteI8 = buffer.writei8
local BufferWriteI16 = buffer.writei16
local BufferWriteI32 = buffer.writei32
local BufferWriteF32 = buffer.writef32
local BufferWriteF64 = buffer.writef64
local BufferWriteString = buffer.writestring
local BufferCopy = buffer.copy
local BufferCreate = buffer.create
local BufferLen = buffer.len
local BufferReadU8 = buffer.readu8
local BufferReadU16 = buffer.readu16
local BufferReadU32 = buffer.readu32
local BufferReadI8 = buffer.readi8
local BufferReadI16 = buffer.readi16
local BufferReadI32 = buffer.readi32
local BufferReadF32 = buffer.readf32
local BufferReadF64 = buffer.readf64
local BufferReadString = buffer.readstring

-- Localize Bit32 Library
local Bit32LShift = bit32.lshift
local Bit32RShift = bit32.rshift
local Bit32Band = bit32.band
local Bit32BTest = bit32.btest
local Bit32Xor = bit32.bxor
local Bit32Or = bit32.bor

-- Localize Math Library
local MathFrexp = math.frexp
local MathLdexp = math.ldexp
local MathFloor = math.floor
local MathRound = math.round
local MathClamp = math.clamp
local MathAbs = math.abs

-- Configuration
local IonVersion : number = 1
local MaxPacketSize : number = 900
local MaxCollectionSize : number = 16777215 -- 2^24-1
local CompressionThreshold : number = 128 -- Bytes
local PoolCapacity : number = 64
local PoolBufferSize : number = 4096
local MaxSafeInteger : number = 9007199254740992 -- 2^53

-- Buffer Pool State
local BufferPool : { buffer } = {}

export type IonPacket<T...> = {
	Server : {
		SendTo : (Recipient : Player, T...) -> (boolean),
		SendToAll : (T...) -> (boolean),
		SendToList : (Recipients : { Player }, T...) -> ({ Player }),
		Listen : (Callback : (Player, T...) -> ()) -> ()
	},
	Client : {
		Send : (T...) -> (boolean),
		Listen : (Callback : (T...) -> ()) -> ()
	},
	Destroy : () -> ()
}

export type Int64Struct = { Upper : number, Lower : number }

-- Initialize Pool
for PoolIndex : number = 1, PoolCapacity do
	table.insert(BufferPool, BufferCreate(PoolBufferSize))
end

local function AcquireBuffer(MinimumSize : number) : buffer
	if MinimumSize > PoolBufferSize then
		return BufferCreate(MinimumSize)
	end
	return table.remove(BufferPool) or BufferCreate(PoolBufferSize)
end

local function ReleaseBuffer(BufferToRelease : buffer)
	if BufferLen(BufferToRelease) >= PoolBufferSize and #BufferPool < PoolCapacity then
		table.insert(BufferPool, BufferToRelease)
	end
end

local function EnsureCapacity(TargetBuffer : buffer, CursorPosition : number, Size : number) : buffer
	local CurrentLength : number = BufferLen(TargetBuffer)
	if CursorPosition + Size > CurrentLength then
		local NewLength : number = math.max(CurrentLength * 2, CursorPosition + Size)
		local NewBuffer : buffer = BufferCreate(NewLength)
		BufferCopy(NewBuffer, 0, TargetBuffer, 0, CurrentLength)
		return NewBuffer
	end
	return TargetBuffer
end

local function CheckBounds(TargetBuffer : buffer, CursorPosition : number, Size : number)
	if CursorPosition + Size > BufferLen(TargetBuffer) then
		error("Ion: Malformed packet (Buffer overflow)")
	end
end

local function FNV1a(StringValue : string) : number
	local Hash : number = 2166136261
	for Index : number = 1, #StringValue do
		Hash = Bit32Band((Hash * 16777619), 4294967295)
		Hash = Bit32Band(Bit32Xor(Hash, string.byte(StringValue, Index)), 4294967295)
	end
	return Hash
end

-- IEEE 754 Binary16 Encoder (Bias 15)
local function WriteFloat16(TargetBuffer : buffer, CursorPosition : number, Value : number)
	local Sign : number = if Value < 0 then 0x8000 else 0
	Value = MathAbs(Value)

	local Encoded : number = 0
	
	if Value >= 65504 then -- Infinity / Overflow
		Encoded = Sign + 0x7C00
	elseif Value ~= 0 then
		local Mantissa : number, Exponent : number = MathFrexp(Value)
		Exponent += 14 -- Correct Bias 15 adjustment for frexp range [0.5, 1)

		if Exponent <= 0 then
			if Exponent < -10 then Encoded = Sign
			else
				Mantissa = MathLdexp(Mantissa, Exponent + 10)
				Encoded = Sign + MathFloor(Mantissa + 0.5)
			end
		elseif Exponent >= 31 then Encoded = Sign + 0x7C00
		else
			Encoded = Sign + Bit32LShift(Exponent, 10) + MathFloor((Mantissa * 2 - 1) * 1024 + 0.5)
		end
	else Encoded = Sign end
	BufferWriteU16(TargetBuffer, CursorPosition, Encoded)
end

local function ReadFloat16(SourceBuffer : buffer, CursorPosition : number) : number
	local Encoded : number = BufferReadU16(SourceBuffer, CursorPosition)
	local Sign : number = Bit32BTest(Encoded, 0x8000) and -1 or 1
	local Exponent : number = Bit32RShift(Bit32Band(Encoded, 0x7C00), 10)
	local Mantissa : number = Bit32Band(Encoded, 0x03FF)
	if Exponent == 0 then
		if Mantissa == 0 then return 0 * Sign end
		return Sign * MathLdexp(Mantissa, -24)
	elseif Exponent == 31 then
		if Mantissa == 0 then return Sign * math.huge end
		return 0/0
	end
	return Sign * MathLdexp(Mantissa + 1024, Exponent - 25)
end

export type TypeSerializer<T> = {
	Write : (buffer, number, T, { Instance }, { [Instance] : number }) -> (buffer, number),
	Read : (buffer, number, { Instance }) -> (T, number),
	GetByteSize : (T) -> number,
	IsDynamic : boolean,
	ContainsInstances : boolean,
	IsUnbounded : boolean?
}

local DataTypes = {}

DataTypes.UInt8 = {
	IsDynamic = false, ContainsInstances = false,
	GetByteSize = function(_ : number) : number return 1 end,
	Write = function(TargetBuffer, CursorPosition, Value)
		TargetBuffer = EnsureCapacity(TargetBuffer, CursorPosition, 1)
		BufferWriteU8(TargetBuffer, CursorPosition, Value or 0)
		return TargetBuffer, CursorPosition + 1
	end,
	Read = function(TargetBuffer, CursorPosition)
		CheckBounds(TargetBuffer, CursorPosition, 1)
		return BufferReadU8(TargetBuffer, CursorPosition), CursorPosition + 1
	end
} :: TypeSerializer<number>

DataTypes.UInt16 = {
	IsDynamic = false, ContainsInstances = false,
	GetByteSize = function(_ : number) : number return 2 end,
	Write = function(TargetBuffer, CursorPosition, Value)
		TargetBuffer = EnsureCapacity(TargetBuffer, CursorPosition, 2)
		BufferWriteU16(TargetBuffer, CursorPosition, Value or 0)
		return TargetBuffer, CursorPosition + 2
	end,
	Read = function(TargetBuffer, CursorPosition)
		CheckBounds(TargetBuffer, CursorPosition, 2)
		return BufferReadU16(TargetBuffer, CursorPosition), CursorPosition + 2
	end
} :: TypeSerializer<number>

DataTypes.UInt32 = {
	IsDynamic = false, ContainsInstances = false,
	GetByteSize = function(_ : number) : number return 4 end,
	Write = function(TargetBuffer, CursorPosition, Value)
		TargetBuffer = EnsureCapacity(TargetBuffer, CursorPosition, 4)
		BufferWriteU32(TargetBuffer, CursorPosition, Value or 0)
		return TargetBuffer, CursorPosition + 4
	end,
	Read = function(TargetBuffer, CursorPosition)
		CheckBounds(TargetBuffer, CursorPosition, 4)
		return BufferReadU32(TargetBuffer, CursorPosition), CursorPosition + 4
	end
} :: TypeSerializer<number>

DataTypes.Float16 = {
	IsDynamic = false, ContainsInstances = false,
	GetByteSize = function(_ : number) : number return 2 end,
	Write = function(TargetBuffer, CursorPosition, Value)
		TargetBuffer = EnsureCapacity(TargetBuffer, CursorPosition, 2)
		WriteFloat16(TargetBuffer, CursorPosition, Value or 0)
		return TargetBuffer, CursorPosition + 2
	end,
	Read = function(TargetBuffer, CursorPosition)
		CheckBounds(TargetBuffer, CursorPosition, 2)
		return ReadFloat16(TargetBuffer, CursorPosition), CursorPosition + 2
	end
} :: TypeSerializer<number>

DataTypes.Float32 = {
	IsDynamic = false, ContainsInstances = false,
	GetByteSize = function(_ : number) : number return 4 end,
	Write = function(TargetBuffer, CursorPosition, Value)
		TargetBuffer = EnsureCapacity(TargetBuffer, CursorPosition, 4)
		BufferWriteF32(TargetBuffer, CursorPosition, Value or 0)
		return TargetBuffer, CursorPosition + 4
	end,
	Read = function(TargetBuffer, CursorPosition)
		CheckBounds(TargetBuffer, CursorPosition, 4)
		return BufferReadF32(TargetBuffer, CursorPosition), CursorPosition + 4
	end
} :: TypeSerializer<number>

DataTypes.Float64 = {
	IsDynamic = false, ContainsInstances = false,
	GetByteSize = function(_ : number) : number return 8 end,
	Write = function(TargetBuffer, CursorPosition, Value)
		TargetBuffer = EnsureCapacity(TargetBuffer, CursorPosition, 8)
		BufferWriteF64(TargetBuffer, CursorPosition, Value or 0)
		return TargetBuffer, CursorPosition + 8
	end,
	Read = function(TargetBuffer, CursorPosition)
		CheckBounds(TargetBuffer, CursorPosition, 8)
		return BufferReadF64(TargetBuffer, CursorPosition), CursorPosition + 8
	end
} :: TypeSerializer<number>

DataTypes.Boolean = {
	IsDynamic = false, ContainsInstances = false,
	GetByteSize = function(_ : boolean) : number return 1 end,
	Write = function(TargetBuffer, CursorPosition, Value)
		TargetBuffer = EnsureCapacity(TargetBuffer, CursorPosition, 1)
		BufferWriteU8(TargetBuffer, CursorPosition, Value and 1 or 0)
		return TargetBuffer, CursorPosition + 1
	end,
	Read = function(TargetBuffer, CursorPosition)
		CheckBounds(TargetBuffer, CursorPosition, 1)
		return BufferReadU8(TargetBuffer, CursorPosition) == 1, CursorPosition + 1
	end
} :: TypeSerializer<boolean>

DataTypes.String = {
	IsDynamic = true, ContainsInstances = false,
	GetByteSize = function(Value : string) : number return 4 + #Value end,
	Write = function(TargetBuffer, CursorPosition, Value)
		local Length : number = #Value
		TargetBuffer = EnsureCapacity(TargetBuffer, CursorPosition, 4 + Length)
		BufferWriteU32(TargetBuffer, CursorPosition, Length)
		BufferWriteString(TargetBuffer, CursorPosition + 4, Value)
		return TargetBuffer, CursorPosition + 4 + Length
	end,
	Read = function(TargetBuffer, CursorPosition)
		CheckBounds(TargetBuffer, CursorPosition, 4)
		local Length : number = BufferReadU32(TargetBuffer, CursorPosition)
		if Length > 1000000 then error("Ion: String too large") end
		CheckBounds(TargetBuffer, CursorPosition + 4, Length)
		return BufferReadString(TargetBuffer, CursorPosition + 4, Length), CursorPosition + 4 + Length
	end
} :: TypeSerializer<string>

DataTypes.RestOfString = {
	IsDynamic = true, ContainsInstances = false, IsUnbounded = true,
	GetByteSize = function(Value : string) : number return #Value end,
	Write = function(TargetBuffer, CursorPosition, Value)
		local Length : number = #Value
		TargetBuffer = EnsureCapacity(TargetBuffer, CursorPosition, Length)
		BufferWriteString(TargetBuffer, CursorPosition, Value)
		return TargetBuffer, CursorPosition + Length
	end,
	Read = function(TargetBuffer, CursorPosition)
		local Remaining : number = BufferLen(TargetBuffer) - CursorPosition
		if Remaining < 0 then error("Ion: Buffer underflow reading RestOfString") end
		return BufferReadString(TargetBuffer, CursorPosition, Remaining), CursorPosition + Remaining
	end
} :: TypeSerializer<string>

DataTypes.Instance = {
	IsDynamic = false, ContainsInstances = true,
	GetByteSize = function(_ : Instance?) : number return 2 end,
	Write = function(TargetBuffer : buffer, CursorPosition : number, Value : Instance?, InstanceAccumulator : { Instance }, InstanceLookup : { [Instance] : number })
		TargetBuffer = EnsureCapacity(TargetBuffer, CursorPosition, 2)
		if Value and typeof(Value) == "Instance" and Value:IsDescendantOf(game) then
			local Index : number? = InstanceLookup[Value]
			if Index then
				BufferWriteU16(TargetBuffer, CursorPosition, Index)
			else
				local NewIndex : number = #InstanceAccumulator + 1
				if NewIndex > 65535 then error("Ion: Instance count overflow (>65535)") end
				InstanceAccumulator[NewIndex] = Value
				InstanceLookup[Value] = NewIndex
				BufferWriteU16(TargetBuffer, CursorPosition, NewIndex)
			end
		else
			BufferWriteU16(TargetBuffer, CursorPosition, 0)
		end
		return TargetBuffer, CursorPosition + 2
	end,
	Read = function(TargetBuffer : buffer, CursorPosition : number, InstanceSource : { Instance }) : (Instance?, number)
		CheckBounds(TargetBuffer, CursorPosition, 2)
		local Index : number = BufferReadU16(TargetBuffer, CursorPosition)
		return InstanceSource[Index], CursorPosition + 2
	end
} :: TypeSerializer<Instance?>

function DataTypes.UseEnum(EnumType : any) : TypeSerializer<EnumItem>
	local EnumMap : { [number] : EnumItem } = {}
	local Items = EnumType:GetEnumItems()
	local DefaultItem = Items[1]
	for _, Item in ipairs(Items) do EnumMap[Item.Value] = Item end

	return {
		IsDynamic = false, ContainsInstances = false,
		GetByteSize = function(_ : EnumItem) : number return 2 end,
		Write = function(TargetBuffer : buffer, CursorPosition : number, Value : EnumItem)
			TargetBuffer = EnsureCapacity(TargetBuffer, CursorPosition, 2)
			BufferWriteU16(TargetBuffer, CursorPosition, Value.Value)
			return TargetBuffer, CursorPosition + 2
		end,
		Read = function(TargetBuffer : buffer, CursorPosition : number, _InstanceSource : {Instance}) : (EnumItem, number)
			CheckBounds(TargetBuffer, CursorPosition, 2)
			local Value : number = BufferReadU16(TargetBuffer, CursorPosition)
			local Item = EnumMap[Value]
			if Item then return Item, CursorPosition + 2 end
			warn("Ion: Invalid Enum value ".. tostring(Value))
			return DefaultItem, CursorPosition + 2
		end
	}
end

DataTypes.Vector3 = {
	IsDynamic = false, ContainsInstances = false,
	GetByteSize = function(_ : Vector3) : number return 12 end,
	Write = function(TargetBuffer, CursorPosition, Value)
		TargetBuffer = EnsureCapacity(TargetBuffer, CursorPosition, 12)
		BufferWriteF32(TargetBuffer, CursorPosition, Value.X)
		BufferWriteF32(TargetBuffer, CursorPosition + 4, Value.Y)
		BufferWriteF32(TargetBuffer, CursorPosition + 8, Value.Z)
		return TargetBuffer, CursorPosition + 12
	end,
	Read = function(TargetBuffer, CursorPosition)
		CheckBounds(TargetBuffer, CursorPosition, 12)
		return Vector3.new(BufferReadF32(TargetBuffer, CursorPosition), BufferReadF32(TargetBuffer, CursorPosition + 4), BufferReadF32(TargetBuffer, CursorPosition + 8)), CursorPosition + 12
	end
} :: TypeSerializer<Vector3>

DataTypes.CFrame = {
	IsDynamic = false, ContainsInstances = false,
	GetByteSize = function(_ : CFrame) : number return 24 end,
	Write = function(TargetBuffer, CursorPosition, Value)
		TargetBuffer = EnsureCapacity(TargetBuffer, CursorPosition, 24)
		local PositionX : number = Value.X
		local PositionY : number = Value.Y
		local PositionZ : number = Value.Z
		local Axis : Vector3, Angle : number = Value:ToAxisAngle()
		local RotationVector : Vector3 = Axis * Angle
		if Angle ~= Angle then RotationVector = Vector3.zero end
		BufferWriteF32(TargetBuffer, CursorPosition, PositionX)
		BufferWriteF32(TargetBuffer, CursorPosition + 4, PositionY)
		BufferWriteF32(TargetBuffer, CursorPosition + 8, PositionZ)
		BufferWriteF32(TargetBuffer, CursorPosition + 12, RotationVector.X)
		BufferWriteF32(TargetBuffer, CursorPosition + 16, RotationVector.Y)
		BufferWriteF32(TargetBuffer, CursorPosition + 20, RotationVector.Z)
		return TargetBuffer, CursorPosition + 24
	end,
	Read = function(TargetBuffer, CursorPosition)
		CheckBounds(TargetBuffer, CursorPosition, 24)
		local PositionX : number = BufferReadF32(TargetBuffer, CursorPosition)
		local PositionY : number = BufferReadF32(TargetBuffer, CursorPosition + 4)
		local PositionZ : number = BufferReadF32(TargetBuffer, CursorPosition + 8)
		local RotationX : number = BufferReadF32(TargetBuffer, CursorPosition + 12)
		local RotationY : number = BufferReadF32(TargetBuffer, CursorPosition + 16)
		local RotationZ : number = BufferReadF32(TargetBuffer, CursorPosition + 20)
		local PositionVector : Vector3 = Vector3.new(PositionX, PositionY, PositionZ)
		local RotationVector : Vector3 = Vector3.new(RotationX, RotationY, RotationZ)
		local Angle : number = RotationVector.Magnitude
		if Angle < 0.001 then return CFrame.new(PositionVector), CursorPosition + 24 end
		return CFrame.fromAxisAngle(RotationVector / Angle, Angle) + PositionVector, CursorPosition + 24
	end
} :: TypeSerializer<CFrame>

function DataTypes.Struct(StructureDefinition : { [string] : TypeSerializer<any> }) : TypeSerializer<{ [string] : any }>
	local SortedKeys : { string } = {}
	local HasInstances : boolean = false
	local IsDynamic : boolean = false
	for DefinitionKey : string, Serializer : TypeSerializer<any> in pairs(StructureDefinition) do
		if Serializer.IsUnbounded then error("Ion: RestOfString cannot be used inside Struct") end
		table.insert(SortedKeys, DefinitionKey)
		if Serializer.ContainsInstances then HasInstances = true end
		if Serializer.IsDynamic then IsDynamic = true end
	end
	table.sort(SortedKeys)
	local FieldWriters, FieldReaders = {}, {}
	for Index : number, Key : string in ipairs(SortedKeys) do
		local Serializer = StructureDefinition[Key]
		FieldWriters[Index] = Serializer.Write
		FieldReaders[Index] = Serializer.Read
	end
	return {
		IsDynamic = IsDynamic, ContainsInstances = HasInstances,
		GetByteSize = function(_) return 0 end,
		Write = function(TargetBuffer, CursorPosition, Value, InstanceAccumulator, InstanceLookup)
			for Index : number, Key : string in ipairs(SortedKeys) do
				TargetBuffer, CursorPosition = FieldWriters[Index](TargetBuffer, CursorPosition, Value[Key], InstanceAccumulator, InstanceLookup)
			end
			return TargetBuffer, CursorPosition
		end,
		Read = function(TargetBuffer, CursorPosition, InstanceSource)
			local Result : { [string] : any } = {}
			for Index : number, Key : string in ipairs(SortedKeys) do
				Result[Key], CursorPosition = FieldReaders[Index](TargetBuffer, CursorPosition, InstanceSource)
			end
			return Result, CursorPosition
		end
	}
end

local Definitions : { [number] : { TypeSerializer<any> } } = {}
local Listeners : { [number] : (...any) -> () } = {}
local RemoteCache : { [number] : RemoteEvent | UnreliableRemoteEvent } = {}
local Ion = {}
Ion.Types = DataTypes

function Ion.Define(Namespace : string, Schema : { TypeSerializer<any> }, Options : { Unreliable : boolean?, Compress : boolean?, Middleware : any?, SchemaVersion : number? }?)
	local Hash : number = FNV1a(Namespace)
	if Definitions[Hash] then error("Ion: Namespace collision for '".. Namespace.. "'") end
	Definitions[Hash] = Schema
	local IsUnreliable = Options and Options.Unreliable or false
	local UseCompression = Options and Options.Compress or false
	local Hooks = Options and Options.Middleware
	local SchemaVersion = Options and Options.SchemaVersion or 1
	local RemoteName = "Ion_".. Hash

	local function OnEvent(Player : Player | buffer, Data : buffer | {Instance}?, Instances : {Instance}?)
		local SourceBuffer = if RunService:IsServer() then Data :: buffer else Player :: buffer
		local SourceInstances = if RunService:IsServer() then Instances :: {Instance} else Data :: {Instance}
		local CursorPosition : number = 0
		CheckBounds(SourceBuffer, CursorPosition, 7)
		local Version = BufferReadU8(SourceBuffer, CursorPosition)
		local PacketId = BufferReadU32(SourceBuffer, CursorPosition + 1)
		local Flags = BufferReadU8(SourceBuffer, CursorPosition + 5)
		local InSchemaVersion = BufferReadU8(SourceBuffer, CursorPosition + 6)
		CursorPosition += 7
		if Version ~= IonVersion or PacketId ~= Hash or InSchemaVersion ~= SchemaVersion then return end
		if Bit32BTest(Flags, 1) then -- Bit 0 set (Value 1)
			SourceBuffer = EncodingService:DecompressBuffer(SourceBuffer, Enum.CompressionAlgorithm.Zstd)
			CursorPosition = 0
		end
		local Callback = Listeners[Hash]
		if Callback then
			local Args : { any } = {}
			for _, Serializer in ipairs(Schema) do
				local Value, NextPos = Serializer.Read(SourceBuffer, CursorPosition, SourceInstances)
				table.insert(Args, Value)
				CursorPosition = NextPos
			end
			if RunService:IsServer() then
				if Hooks and Hooks.OnAfterReceived then Hooks.OnAfterReceived(Player, table.unpack(Args)) end
				Callback(Player, table.unpack(Args))
			else
				if Hooks and Hooks.OnAfterReceived then Hooks.OnAfterReceived(table.unpack(Args)) end
				Callback(table.unpack(Args))
			end
		end
	end

	if RunService:IsServer() then
		local Remote = if IsUnreliable then Instance.new("UnreliableRemoteEvent") else Instance.new("RemoteEvent")
		Remote.Name, Remote.Parent = RemoteName, ReplicatedStorage
		RemoteCache[Hash] = Remote :: any
		(Remote :: any).OnServerEvent:Connect(OnEvent)
	else
		local Remote = ReplicatedStorage:WaitForChild(RemoteName, 10)
		if not Remote then error("Ion: Remote '"..RemoteName.."' not found") end
		RemoteCache[Hash] = Remote :: any
		(Remote :: any).OnClientEvent:Connect(OnEvent)
	end

	local PacketObject = {}
	function PacketObject.Send(Target : Player?,... : any) : boolean
		if Hooks and Hooks.OnBeforeSend and not Hooks.OnBeforeSend(...) then return false end
		local Args = {...}
		local PayloadBuffer = AcquireBuffer(1024)
		local Success, ResultCursor, ResultInst = pcall(function()
			local Cursor, InstAcc, InstLook = 0, {}, {}
			for Index, Serializer in ipairs(Schema) do
				PayloadBuffer, Cursor = Serializer.Write(PayloadBuffer, Cursor, Args[Index], InstAcc, InstLook)
			end
			return Cursor, InstAcc
		end)
		if not Success then warn("Ion: Serialization failed - ".. tostring(ResultCursor)) ReleaseBuffer(PayloadBuffer) return false end
		
		local CursorPosition = ResultCursor :: number
		if IsUnreliable and (CursorPosition + 7) > MaxPacketSize then warn("Ion: Unreliable packet dropped") ReleaseBuffer(PayloadBuffer) return false end
		
		local FinalPayload = BufferCreate(CursorPosition)
		BufferCopy(FinalPayload, 0, PayloadBuffer, 0, CursorPosition)
		ReleaseBuffer(PayloadBuffer)

		local IsCompressed = false
		if UseCompression and CursorPosition > CompressionThreshold then
			FinalPayload = EncodingService:DecompressBuffer(FinalPayload, Enum.CompressionAlgorithm.Zstd)
			IsCompressed = true
		end
		
		local PacketBuffer = BufferCreate(7 + BufferLen(FinalPayload))
		BufferWriteU8(PacketBuffer, 0, IonVersion)
		BufferWriteU32(PacketBuffer, 1, Hash)
		BufferWriteU8(PacketBuffer, 5, IsCompressed and 1 or 0)
		BufferWriteU8(PacketBuffer, 6, SchemaVersion)
		BufferCopy(PacketBuffer, 7, FinalPayload, 0, BufferLen(FinalPayload))

		local Remote : any = RemoteCache[Hash]
		if RunService:IsServer() then
			if Target then Remote:FireClient(Target, PacketBuffer, ResultInst) else Remote:FireAllClients(PacketBuffer, ResultInst) end
		else Remote:FireServer(PacketBuffer, ResultInst) end
		return true
	end

	function PacketObject.Listen(Callback) Listeners[Hash] = Callback end
	function PacketObject.Destroy()
		Listeners[Hash] = nil
		if RemoteCache[Hash] then RemoteCache[Hash]:Destroy() RemoteCache[Hash] = nil end
		Definitions[Hash] = nil
	end

	return {
		Server = { SendTo = function(P,...) return PacketObject.Send(P,...) end, SendToAll = function(...) return PacketObject.Send(nil,...) end, Listen = PacketObject.Listen },
		Client = { Send = function(...) return PacketObject.Send(nil,...) end, Listen = PacketObject.Listen },
		Destroy = PacketObject.Destroy
	} :: IonPacket<any>
end

return Ion