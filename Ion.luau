--!strict
--!native
--!optimize 2

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local EncodingService = game:GetService("EncodingService")

--------------------------------------------------------------------------------
-- OPTIMIZATIONS & LOCALS
--------------------------------------------------------------------------------

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
local BufferFill = buffer.fill

local Bit32LShift = bit32.lshift
local Bit32RShift = bit32.rshift
local Bit32Band = bit32.band
local Bit32BTest = bit32.btest
local Bit32Xor = bit32.bxor
local Bit32Or = bit32.bor

local MathFrexp = math.frexp
local MathLdexp = math.ldexp
local MathFloor = math.floor
local MathRound = math.round
local MathClamp = math.clamp
local MathAbs = math.abs
local MathMax = math.max
local MathMin = math.min

--------------------------------------------------------------------------------
-- CONFIGURATION & CONSTANTS
--------------------------------------------------------------------------------

local IonVersion : number = 1
local MaxPacketSize : number = 900
local MaxBufferSize : number = 100 * 1024 * 1024 -- 100MB Hard Limit
local MaxBufferBlobSize : number = 10 * 1024 * 1024 -- 10MB Limit for single Blob/String
local BufferGrowthFactor : number = 1.5
local MaxCollectionSize : number = 100000 -- 100k items limit
local MaxStringSize : number = 1000000 -- 1MB string limit
local CompressionThreshold : number = 128 -- Bytes
local CompressionRatioEstimate : number = 0.7
local PoolCapacity : number = 64
local PoolBufferSize : number = 4096
local MaxSafeInteger : number = 9007199254740991 -- 2^53 - 1
-- 10430.0 keeps PI * Factor < 32767 to fit in Int16
local EulerScalingFactor : number = 10430.0 
local MaxEnumCacheSize : number = 500

local IonErrorCodes = {
	BUFFER_OVERFLOW = "E001",
	BUFFER_UNDERFLOW = "E002",
	VERSION_MISMATCH = "E003",
	PACKET_ID_MISMATCH = "E004",
	SCHEMA_MISMATCH = "E005",
	COMPRESSION_FAILED = "E006",
	DECOMPRESSION_FAILED = "E007",
	SERIALIZATION_FAILED = "E008",
	DESERIALIZATION_FAILED = "E009",
	SIZE_LIMIT_EXCEEDED = "E010",
	INVALID_INSTANCE = "E011",
	MIDDLEWARE_ERROR = "E012",
	PACKET_DESTROYED = "E013",
	NOT_SUPPORTED = "E014",
	INVALID_CONFIG = "E015",
	REMOTE_MISSING = "E016",
	TIMEOUT = "E017"
}

--------------------------------------------------------------------------------
-- PUBLIC TYPE EXPORTS
--------------------------------------------------------------------------------

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

export type TypeSerializer<T> = {
	Write : (buffer, number, T, { Instance }, { [Instance] : number }) -> (buffer, number),
	Read : (buffer, number, { Instance }) -> (T, number),
	GetByteSize : (T) -> number,
	IsDynamic : boolean,
	ContainsInstances : boolean,
	IsUnbounded : boolean?
}

--------------------------------------------------------------------------------
-- STATE & DIAGNOSTICS
--------------------------------------------------------------------------------

local BufferPool : { buffer } = {}
local BufferPoolInitialized : boolean = false

-- Caches
local EnumSerializerCache : { [any] : any } = {}
local EnumSerializerCacheOrder : { any } = {}
local AnyEnumCache : { [any] : { [number] : EnumItem } } = {}
local AnyEnumCacheOrder : { any } = {}

-- Packet Tracking
local Definitions : { [number] : any } = {}
local Listeners : { [number] : (...any) -> () } = {}
local RemoteCache : { [number] : RemoteEvent | UnreliableRemoteEvent } = {}
local RemoteConnections : { [number] : RBXScriptConnection } = {}
local ActivePackets : { [number] : { Namespace: string, Created: number, IsDestroyed: boolean } } = {}

local DebugMode = false
local DebugLogger : ((message: string, level: string) -> ())? = nil

local PerformanceStats = {
	PacketsSent = 0,
	PacketsReceived = 0,
	BytesSent = 0,
	BytesReceived = 0,
	AverageSerializationTime = 0,
	AverageDeserializationTime = 0,
	BufferPoolHits = 0,
	BufferPoolMisses = 0,
	CompressionSavings = 0
}

local function DebugLog(Message : string, Level : string?)
	if not DebugMode then return end
	Level = Level or "INFO"
	local FormattedMessage = string.format("[Ion-%s] %s", Level, Message)
	if DebugLogger then 
		pcall(DebugLogger, FormattedMessage, Level) 
	else 
		print(FormattedMessage) 
	end
end

local function RecordPerformance(Operation : string, Duration : number, Bytes : number?)
	if Operation == "serialize" then
		local Count = PerformanceStats.PacketsSent
		PerformanceStats.AverageSerializationTime = (PerformanceStats.AverageSerializationTime * Count + Duration) / (Count + 1)
		PerformanceStats.PacketsSent += 1
		if Bytes then PerformanceStats.BytesSent += Bytes end
	elseif Operation == "deserialize" then
		local Count = PerformanceStats.PacketsReceived
		PerformanceStats.AverageDeserializationTime = (PerformanceStats.AverageDeserializationTime * Count + Duration) / (Count + 1)
		PerformanceStats.PacketsReceived += 1
		if Bytes then PerformanceStats.BytesReceived += Bytes end
	end
end

--------------------------------------------------------------------------------
-- BUFFER MANAGEMENT
--------------------------------------------------------------------------------

local function InitializeBufferPool()
	if BufferPoolInitialized then return end
	for PoolIndex = 1, PoolCapacity do
		table.insert(BufferPool, BufferCreate(PoolBufferSize))
	end
	BufferPoolInitialized = true
end

local function ReleaseBuffer(BufferToRelease : buffer)
	local CurrentLength = BufferLen(BufferToRelease)
	-- Only pool exact matches to standard size to prevent memory fragmentation
	if CurrentLength == PoolBufferSize and #BufferPool < PoolCapacity then
		-- Security: Wipe data before pooling to prevent info leaks
		BufferFill(BufferToRelease, 0, 0, PoolBufferSize)
		table.insert(BufferPool, BufferToRelease)
	end
	-- Oversized/Undersized buffers are left to GC
end

local function AcquireBuffer(MinimumSize : number) : buffer
	InitializeBufferPool()
	if MinimumSize > PoolBufferSize then
		PerformanceStats.BufferPoolMisses += 1
		return BufferCreate(MinimumSize)
	end
	local PooledBuffer = table.remove(BufferPool)
	if PooledBuffer then
		PerformanceStats.BufferPoolHits += 1
		return PooledBuffer
	end
	PerformanceStats.BufferPoolMisses += 1
	return BufferCreate(PoolBufferSize)
end

local function EnsureCapacity(TargetBuffer : buffer, CursorPosition : number, Size : number) : buffer
	local CurrentLength = BufferLen(TargetBuffer)
	local RequiredSize = CursorPosition + Size
	
	if RequiredSize <= CurrentLength then
		return TargetBuffer
	end
	
	-- Growth logic with hard limit
	local NewLength = MathMax(math.ceil(CurrentLength * BufferGrowthFactor), RequiredSize)
	
	if NewLength > MaxBufferSize then
		if RequiredSize > MaxBufferSize then
			error(string.format("[%s] Ion: Buffer overflow - Required %d > Max %d", IonErrorCodes.BUFFER_OVERFLOW, RequiredSize, MaxBufferSize))
		end
		NewLength = MaxBufferSize
	end
	
	local NewBuffer = BufferCreate(NewLength)
	BufferCopy(NewBuffer, 0, TargetBuffer, 0, CurrentLength)
	
	-- Always release the old buffer (ReleaseBuffer handles validation)
	ReleaseBuffer(TargetBuffer)
	
	return NewBuffer
end

local function CheckBounds(TargetBuffer : buffer, CursorPosition : number, Size : number)
	if CursorPosition + Size > BufferLen(TargetBuffer) then
		error(string.format("[%s] Ion: Malformed packet (Buffer overflow)", IonErrorCodes.BUFFER_OVERFLOW))
	end
end

--------------------------------------------------------------------------------
-- UTILITIES
--------------------------------------------------------------------------------

local function FNV1a(StringValue : string) : number
	local Hash : number = 2166136261
	local Prime : number = 16777619
	for Index = 1, #StringValue do
		Hash = Bit32Xor(Hash, string.byte(StringValue, Index))
		-- FIX: Ensure 32-bit clamping before multiplication to minimize overflow
		Hash = Bit32Band(Hash, 4294967295) 
		Hash = Bit32Band(Hash * Prime, 4294967295)
	end
	return Hash
end

local function WriteFloat16(TargetBuffer : buffer, CursorPosition : number, Value : number)
	local Sign : number = if Value < 0 then 0x8000 else 0
	Value = MathAbs(Value)
	local Encoded : number = 0
	
	if Value == 0 then
		Encoded = Sign
	elseif Value > 65504 then -- FIX: Corrected from >= to > for true overflow
		Encoded = Sign + 0x7C00
	elseif Value ~= Value then -- NaN
		Encoded = 0x7FFF
	else
		local Mantissa : number, Exponent : number = MathFrexp(Value)
		Exponent += 14

		if Exponent <= 0 then -- Denormalized
			if Exponent < -10 then
				Encoded = Sign
			else
				Mantissa = MathLdexp(Mantissa, Exponent + 10)
				local MantissaBits = MathClamp(MathFloor(Mantissa + 0.5), 0, 1023)
				Encoded = Sign + MantissaBits
			end
		elseif Exponent >= 31 then -- Overflow
			Encoded = Sign + 0x7C00
		else -- Normalized
			local MantissaValue = (Mantissa * 2 - 1) * 1024
			local MantissaBits = MathClamp(MathFloor(MantissaValue + 0.5), 0, 1023)
			Encoded = Sign + Bit32LShift(Exponent, 10) + MantissaBits
		end
	end
	BufferWriteU16(TargetBuffer, CursorPosition, Encoded)
end

local function ReadFloat16(SourceBuffer : buffer, CursorPosition : number) : number
	local Encoded = BufferReadU16(SourceBuffer, CursorPosition)
	local Sign = Bit32BTest(Encoded, 0x8000) and -1 or 1
	local Exponent = Bit32RShift(Bit32Band(Encoded, 0x7C00), 10)
	local Mantissa = Bit32Band(Encoded, 0x03FF)
	if Exponent == 0 then
		if Mantissa == 0 then return 0 * Sign end
		return Sign * MathLdexp(Mantissa, -24)
	elseif Exponent == 31 then
		if Mantissa == 0 then return Sign * math.huge end
		return 0/0
	end
	return Sign * MathLdexp(Mantissa + 1024, Exponent - 25)
end

local function DecomposeInt64(Value : number) : (number, number)
	if MathAbs(Value) > MaxSafeInteger then
		error(string.format("[%s] Ion: Precision loss for Int64 number.", IonErrorCodes.NOT_SUPPORTED))
	end
	local High = MathFloor(Value / 4294967296)
	local Low = Value - (High * 4294967296)
	if Low < 0 then
		High -= 1
		Low += 4294967296
	end
	return High, Low
end

--------------------------------------------------------------------------------
-- SERIALIZERS
--------------------------------------------------------------------------------

local DataTypes = {}

-- Primitives
local function CreatePrimitive(Size, WriteFunc, ReadFunc, ClampMin, ClampMax)
	return {
		IsDynamic = false, ContainsInstances = false,
		GetByteSize = function(_ : any) return Size end,
		Write = function(TargetBuffer, CursorPosition, Value)
			TargetBuffer = EnsureCapacity(TargetBuffer, CursorPosition, Size)
			local SafeValue = Value or 0
			if ClampMin then SafeValue = MathClamp(SafeValue, ClampMin, ClampMax) end
			WriteFunc(TargetBuffer, CursorPosition, SafeValue)
			return TargetBuffer, CursorPosition + Size
		end,
		Read = function(TargetBuffer, CursorPosition)
			CheckBounds(TargetBuffer, CursorPosition, Size)
			return ReadFunc(TargetBuffer, CursorPosition), CursorPosition + Size
		end
	}
end

DataTypes.UInt8 = CreatePrimitive(1, BufferWriteU8, BufferReadU8, 0, 255)
DataTypes.UInt16 = CreatePrimitive(2, BufferWriteU16, BufferReadU16, 0, 65535)
DataTypes.UInt32 = CreatePrimitive(4, BufferWriteU32, BufferReadU32, 0, 4294967295)
DataTypes.Int8 = CreatePrimitive(1, BufferWriteI8, BufferReadI8, nil, nil)
DataTypes.Int16 = CreatePrimitive(2, BufferWriteI16, BufferReadI16, nil, nil)
DataTypes.Int32 = CreatePrimitive(4, BufferWriteI32, BufferReadI32, nil, nil)
DataTypes.Float32 = CreatePrimitive(4, BufferWriteF32, BufferReadF32, nil, nil)
DataTypes.Float64 = CreatePrimitive(8, BufferWriteF64, BufferReadF64, nil, nil)

DataTypes.UInt24 = {
	IsDynamic = false, ContainsInstances = false,
	GetByteSize = function(_) return 3 end,
	Write = function(TargetBuffer, CursorPosition, Value) 
		TargetBuffer = EnsureCapacity(TargetBuffer, CursorPosition, 3)
		local Clamped = MathClamp(Value or 0, 0, 16777215)
		BufferWriteU8(TargetBuffer, CursorPosition, Bit32Band(Clamped, 0xFF))
		BufferWriteU8(TargetBuffer, CursorPosition + 1, Bit32Band(Bit32RShift(Clamped, 8), 0xFF))
		BufferWriteU8(TargetBuffer, CursorPosition + 2, Bit32Band(Bit32RShift(Clamped, 16), 0xFF))
		return TargetBuffer, CursorPosition + 3 
	end,
	Read = function(TargetBuffer, CursorPosition) 
		CheckBounds(TargetBuffer, CursorPosition, 3)
		local B1 = BufferReadU8(TargetBuffer, CursorPosition)
		local B2 = BufferReadU8(TargetBuffer, CursorPosition + 1)
		local B3 = BufferReadU8(TargetBuffer, CursorPosition + 2)
		return B1 + Bit32LShift(B2, 8) + Bit32LShift(B3, 16), CursorPosition + 3 
	end
}

DataTypes.Float16 = {
	IsDynamic = false, ContainsInstances = false,
	GetByteSize = function(_) return 2 end,
	Write = function(TargetBuffer, CursorPosition, Value)
		TargetBuffer = EnsureCapacity(TargetBuffer, CursorPosition, 2)
		WriteFloat16(TargetBuffer, CursorPosition, Value or 0)
		return TargetBuffer, CursorPosition + 2
	end,
	Read = function(TargetBuffer, CursorPosition)
		CheckBounds(TargetBuffer, CursorPosition, 2)
		return ReadFloat16(TargetBuffer, CursorPosition), CursorPosition + 2
	end
}

DataTypes.Boolean = {
	IsDynamic = false, ContainsInstances = false,
	GetByteSize = function(_) return 1 end,
	Write = function(TargetBuffer, CursorPosition, Value)
		TargetBuffer = EnsureCapacity(TargetBuffer, CursorPosition, 1)
		BufferWriteU8(TargetBuffer, CursorPosition, Value and 1 or 0)
		return TargetBuffer, CursorPosition + 1
	end,
	Read = function(TargetBuffer, CursorPosition)
		CheckBounds(TargetBuffer, CursorPosition, 1)
		return BufferReadU8(TargetBuffer, CursorPosition) == 1, CursorPosition + 1
	end
}

DataTypes.UInt64 = {
	IsDynamic = false, ContainsInstances = false,
	GetByteSize = function(_) return 8 end,
	Write = function(TargetBuffer, CursorPosition, Value)
		TargetBuffer = EnsureCapacity(TargetBuffer, CursorPosition, 8)
		local Upper, Lower
		if type(Value) == "table" then
			Upper, Lower = Value.Upper or 0, Value.Lower or 0
			if Upper < 0 or Lower < 0 then
				error(string.format("[%s] UInt64 requires non-negative values", IonErrorCodes.SERIALIZATION_FAILED))
			end
		else
			local NumberValue = tonumber(Value) or 0
			if NumberValue < 0 then
				error(string.format("[%s] UInt64 requires non-negative value", IonErrorCodes.SERIALIZATION_FAILED))
			end
			Upper, Lower = DecomposeInt64(NumberValue)
		end
		BufferWriteU32(TargetBuffer, CursorPosition, Upper)
		BufferWriteU32(TargetBuffer, CursorPosition + 4, Lower)
		return TargetBuffer, CursorPosition + 8
	end,
	Read = function(TargetBuffer, CursorPosition)
		CheckBounds(TargetBuffer, CursorPosition, 8)
		return { Upper = BufferReadU32(TargetBuffer, CursorPosition), Lower = BufferReadU32(TargetBuffer, CursorPosition + 4) }, CursorPosition + 8
	end
}

DataTypes.Int64 = {
	IsDynamic = false, ContainsInstances = false,
	GetByteSize = function(_) return 8 end,
	Write = function(TargetBuffer, CursorPosition, Value)
		TargetBuffer = EnsureCapacity(TargetBuffer, CursorPosition, 8)
		local High, Low
		if type(Value) == "table" then
			High, Low = Value.Upper or 0, Value.Lower or 0
		else
			local NumberValue = tonumber(Value) or 0
			High, Low = DecomposeInt64(NumberValue)
		end
		BufferWriteI32(TargetBuffer, CursorPosition, High)
		BufferWriteU32(TargetBuffer, CursorPosition + 4, Low)
		return TargetBuffer, CursorPosition + 8
	end,
	Read = function(TargetBuffer, CursorPosition)
		CheckBounds(TargetBuffer, CursorPosition, 8)
		return { Upper = BufferReadI32(TargetBuffer, CursorPosition), Lower = BufferReadU32(TargetBuffer, CursorPosition + 4) }, CursorPosition + 8
	end
}

DataTypes.String = {
	IsDynamic = true, ContainsInstances = false,
	GetByteSize = function(Value : string) return 4 + #Value end,
	Write = function(TargetBuffer, CursorPosition, Value)
		local Length = #Value
		if Length > MaxStringSize then error(string.format("[%s] String too large", IonErrorCodes.SIZE_LIMIT_EXCEEDED)) end
		TargetBuffer = EnsureCapacity(TargetBuffer, CursorPosition, 4 + Length)
		BufferWriteU32(TargetBuffer, CursorPosition, Length)
		if Length > 0 then BufferWriteString(TargetBuffer, CursorPosition + 4, Value) end
		return TargetBuffer, CursorPosition + 4 + Length
	end,
	Read = function(TargetBuffer, CursorPosition)
		CheckBounds(TargetBuffer, CursorPosition, 4)
		local Length = BufferReadU32(TargetBuffer, CursorPosition)
		if Length > MaxStringSize then error(string.format("[%s] String too large", IonErrorCodes.SIZE_LIMIT_EXCEEDED)) end
		CheckBounds(TargetBuffer, CursorPosition + 4, Length)
		if Length == 0 then return "", CursorPosition + 4 end
		return BufferReadString(TargetBuffer, CursorPosition + 4, Length), CursorPosition + 4 + Length
	end
}

DataTypes.ShortString = {
	IsDynamic = true, ContainsInstances = false,
	GetByteSize = function(Value : string) return 1 + #Value end,
	Write = function(TargetBuffer, CursorPosition, Value)
		local Length = #Value
		if Length > 255 then error(string.format("[%s] ShortString too large", IonErrorCodes.SIZE_LIMIT_EXCEEDED)) end
		TargetBuffer = EnsureCapacity(TargetBuffer, CursorPosition, 1 + Length)
		BufferWriteU8(TargetBuffer, CursorPosition, Length)
		if Length > 0 then BufferWriteString(TargetBuffer, CursorPosition + 1, Value) end
		return TargetBuffer, CursorPosition + 1 + Length
	end,
	Read = function(TargetBuffer, CursorPosition)
		CheckBounds(TargetBuffer, CursorPosition, 1)
		local Length = BufferReadU8(TargetBuffer, CursorPosition)
		CheckBounds(TargetBuffer, CursorPosition + 1, Length)
		return BufferReadString(TargetBuffer, CursorPosition + 1, Length), CursorPosition + 1 + Length
	end
}

DataTypes.RestOfString = {
	IsDynamic = true, ContainsInstances = false, IsUnbounded = true,
	GetByteSize = function(Value : string) return #Value end,
	Write = function(TargetBuffer, CursorPosition, Value)
		local Length = #Value
		if Length > MaxStringSize then error(string.format("[%s] RestOfString too large", IonErrorCodes.SIZE_LIMIT_EXCEEDED)) end
		TargetBuffer = EnsureCapacity(TargetBuffer, CursorPosition, Length)
		if Length > 0 then BufferWriteString(TargetBuffer, CursorPosition, Value) end
		return TargetBuffer, CursorPosition + Length
	end,
	Read = function(TargetBuffer, CursorPosition)
		if CursorPosition > BufferLen(TargetBuffer) then error(string.format("[%s] Buffer underflow", IonErrorCodes.BUFFER_UNDERFLOW)) end
		local Remaining = BufferLen(TargetBuffer) - CursorPosition
		if Remaining > MaxStringSize then error(string.format("[%s] RestOfString too large", IonErrorCodes.SIZE_LIMIT_EXCEEDED)) end
		if Remaining <= 0 then return "", CursorPosition end
		return BufferReadString(TargetBuffer, CursorPosition, Remaining), CursorPosition + Remaining
	end
}

DataTypes.FixedString = function(Length : number) : TypeSerializer<string>
	if Length > MaxStringSize then error(string.format("[%s] FixedString too large", IonErrorCodes.SIZE_LIMIT_EXCEEDED)) end
	return {
		IsDynamic = false, ContainsInstances = false,
		GetByteSize = function(_) return Length end,
		Write = function(TargetBuffer, CursorPosition, Value)
			TargetBuffer = EnsureCapacity(TargetBuffer, CursorPosition, Length)
			local StrLen = MathMin(#Value, Length)
			if StrLen > 0 then BufferWriteString(TargetBuffer, CursorPosition, string.sub(Value, 1, StrLen)) end
			if StrLen < Length then BufferFill(TargetBuffer, CursorPosition + StrLen, 0, Length - StrLen) end
			return TargetBuffer, CursorPosition + Length
		end,
		Read = function(TargetBuffer, CursorPosition)
			CheckBounds(TargetBuffer, CursorPosition, Length)
			local Raw = BufferReadString(TargetBuffer, CursorPosition, Length)
			local NullPos = string.find(Raw, "\0", 1, true)
			local Result = if NullPos then string.sub(Raw, 1, NullPos - 1) else Raw
			return Result, CursorPosition + Length
		end
	}
end

function DataTypes.Optional<T>(Inner : TypeSerializer<T>) : TypeSerializer<T?>
	return {
		IsDynamic = true, ContainsInstances = Inner.ContainsInstances,
		GetByteSize = function(Value)
			if Value == nil then return 1 end
			return 1 + Inner.GetByteSize(if Inner.IsDynamic then Value else nil :: any)
		end,
		Write = function(TargetBuffer, CursorPosition, Value, InstanceAccumulator, InstanceLookup)
			TargetBuffer = EnsureCapacity(TargetBuffer, CursorPosition, 1)
			if Value == nil then
				BufferWriteU8(TargetBuffer, CursorPosition, 0)
				return TargetBuffer, CursorPosition + 1
			else
				BufferWriteU8(TargetBuffer, CursorPosition, 1)
				return Inner.Write(TargetBuffer, CursorPosition + 1, Value, InstanceAccumulator, InstanceLookup)
			end
		end,
		Read = function(TargetBuffer, CursorPosition, InstanceSource)
			CheckBounds(TargetBuffer, CursorPosition, 1)
			local Exists = BufferReadU8(TargetBuffer, CursorPosition) == 1
			if not Exists then return nil, CursorPosition + 1 end
			return Inner.Read(TargetBuffer, CursorPosition + 1, InstanceSource)
		end
	}
end

DataTypes.Instance = {
	IsDynamic = false, ContainsInstances = true,
	GetByteSize = function(_) return 2 end,
	Write = function(TargetBuffer, CursorPosition, Value, InstanceAccumulator, InstanceLookup)
		TargetBuffer = EnsureCapacity(TargetBuffer, CursorPosition, 2)
		local IsValid = false
		if Value and typeof(Value) == "Instance" then
			local Success, Result = pcall(function() return Value:IsDescendantOf(game) end)
			IsValid = Success and Result
		end
		
		if IsValid then
			local Index = InstanceLookup[Value]
			if Index then
				BufferWriteU16(TargetBuffer, CursorPosition, Index)
			else
				local Count = #InstanceAccumulator
				if Count >= 65535 then error(string.format("[%s] Instance limit exceeded", IonErrorCodes.SIZE_LIMIT_EXCEEDED)) end
				local NewIdx = Count + 1
				InstanceAccumulator[NewIdx] = Value
				InstanceLookup[Value] = NewIdx
				BufferWriteU16(TargetBuffer, CursorPosition, NewIdx)
			end
		else
			BufferWriteU16(TargetBuffer, CursorPosition, 0)
		end
		return TargetBuffer, CursorPosition + 2
	end,
	Read = function(TargetBuffer, CursorPosition, InstanceSource)
		CheckBounds(TargetBuffer, CursorPosition, 2)
		local Index = BufferReadU16(TargetBuffer, CursorPosition)
		return InstanceSource[Index], CursorPosition + 2
	end
} :: TypeSerializer<Instance?>

function DataTypes.UseEnum(EnumType : any) : TypeSerializer<EnumItem>
	if EnumSerializerCache[EnumType] then return EnumSerializerCache[EnumType] end
	
	if #EnumSerializerCacheOrder >= MaxEnumCacheSize then
		local Oldest = table.remove(EnumSerializerCacheOrder, 1)
		EnumSerializerCache[Oldest] = nil
	end
	table.insert(EnumSerializerCacheOrder, EnumType)

	local EnumMap = {}
	local Items = EnumType:GetEnumItems()
	local Default = Items[1]
	for _, Item in ipairs(Items) do EnumMap[Item.Value] = Item end

	local Serializer = {
		IsDynamic = false, ContainsInstances = false,
		GetByteSize = function(_) return 2 end,
		Write = function(TargetBuffer, CursorPosition, Value)
			TargetBuffer = EnsureCapacity(TargetBuffer, CursorPosition, 2)
			BufferWriteU16(TargetBuffer, CursorPosition, Value.Value)
			return TargetBuffer, CursorPosition + 2
		end,
		Read = function(TargetBuffer, CursorPosition)
			CheckBounds(TargetBuffer, CursorPosition, 2)
			local Val = BufferReadU16(TargetBuffer, CursorPosition)
			local Item = EnumMap[Val]
			if not Item then
				warn(string.format("Ion: Invalid Enum value %d", Val))
				local FallbackItems = EnumType:GetEnumItems()
				if #FallbackItems == 0 then return nil, CursorPosition + 2 end
				return FallbackItems[1], CursorPosition + 2 
			end
			return Item, CursorPosition + 2
		end
	}
	EnumSerializerCache[EnumType] = Serializer
	return Serializer
end

DataTypes.Vector3 = {
	IsDynamic = false, ContainsInstances = false,
	GetByteSize = function(_) return 12 end,
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
}

DataTypes.Vector3Int16 = {
	IsDynamic = false, ContainsInstances = false,
	GetByteSize = function(_) return 6 end,
	Write = function(TargetBuffer, CursorPosition, Value)
		TargetBuffer = EnsureCapacity(TargetBuffer, CursorPosition, 6)
		BufferWriteI16(TargetBuffer, CursorPosition, MathClamp(MathRound(Value.X), -32768, 32767))
		BufferWriteI16(TargetBuffer, CursorPosition + 2, MathClamp(MathRound(Value.Y), -32768, 32767))
		BufferWriteI16(TargetBuffer, CursorPosition + 4, MathClamp(MathRound(Value.Z), -32768, 32767))
		return TargetBuffer, CursorPosition + 6
	end,
	Read = function(TargetBuffer, CursorPosition)
		CheckBounds(TargetBuffer, CursorPosition, 6)
		return Vector3.new(BufferReadI16(TargetBuffer, CursorPosition), BufferReadI16(TargetBuffer, CursorPosition + 2), BufferReadI16(TargetBuffer, CursorPosition + 4)), CursorPosition + 6
	end
}

DataTypes.Vector2 = {
	IsDynamic = false, ContainsInstances = false,
	GetByteSize = function(_) return 8 end,
	Write = function(TargetBuffer, CursorPosition, Value)
		TargetBuffer = EnsureCapacity(TargetBuffer, CursorPosition, 8)
		BufferWriteF32(TargetBuffer, CursorPosition, Value.X)
		BufferWriteF32(TargetBuffer, CursorPosition + 4, Value.Y)
		return TargetBuffer, CursorPosition + 8
	end,
	Read = function(TargetBuffer, CursorPosition)
		CheckBounds(TargetBuffer, CursorPosition, 8)
		return Vector2.new(BufferReadF32(TargetBuffer, CursorPosition), BufferReadF32(TargetBuffer, CursorPosition + 4)), CursorPosition + 8
	end
}

DataTypes.CFrameFloat16 = {
	IsDynamic = false, ContainsInstances = false,
	GetByteSize = function(_) return 12 end,
	Write = function(TargetBuffer, CursorPosition, Value)
		TargetBuffer = EnsureCapacity(TargetBuffer, CursorPosition, 12)
		WriteFloat16(TargetBuffer, CursorPosition, Value.X)
		WriteFloat16(TargetBuffer, CursorPosition + 2, Value.Y)
		WriteFloat16(TargetBuffer, CursorPosition + 4, Value.Z)
		local EulerX, EulerY, EulerZ = Value:ToEulerAnglesXYZ()
		-- Sanitize Euler angles before scaling
		local SafeEX = if EulerX == EulerX then EulerX else 0
		local SafeEY = if EulerY == EulerY then EulerY else 0
		local SafeEZ = if EulerZ == EulerZ then EulerZ else 0
		BufferWriteI16(TargetBuffer, CursorPosition + 6, MathClamp(MathRound(SafeEX * EulerScalingFactor), -32767, 32767))
		BufferWriteI16(TargetBuffer, CursorPosition + 8, MathClamp(MathRound(SafeEY * EulerScalingFactor), -32767, 32767))
		BufferWriteI16(TargetBuffer, CursorPosition + 10, MathClamp(MathRound(SafeEZ * EulerScalingFactor), -32767, 32767))
		return TargetBuffer, CursorPosition + 12
	end,
	Read = function(TargetBuffer, CursorPosition)
		CheckBounds(TargetBuffer, CursorPosition, 12)
		local PosX, PosY, PosZ = ReadFloat16(TargetBuffer, CursorPosition), ReadFloat16(TargetBuffer, CursorPosition + 2), ReadFloat16(TargetBuffer, CursorPosition + 4)
		local EX = BufferReadI16(TargetBuffer, CursorPosition + 6) / EulerScalingFactor
		local EY = BufferReadI16(TargetBuffer, CursorPosition + 8) / EulerScalingFactor
		local EZ = BufferReadI16(TargetBuffer, CursorPosition + 10) / EulerScalingFactor
		return CFrame.fromEulerAnglesXYZ(EX, EY, EZ) + Vector3.new(PosX, PosY, PosZ), CursorPosition + 12
	end
}

DataTypes.CFrame = {
	IsDynamic = false, ContainsInstances = false,
	GetByteSize = function(_) return 24 end,
	Write = function(TargetBuffer, CursorPosition, Value)
		TargetBuffer = EnsureCapacity(TargetBuffer, CursorPosition, 24)
		local Axis, Angle = Value:ToAxisAngle()
		-- Check ALL components for NaN
		local HasNaN = Angle ~= Angle or Axis.X ~= Axis.X or Axis.Y ~= Axis.Y or Axis.Z ~= Axis.Z
		local Rot = if HasNaN then Vector3.zero else Axis * Angle
		BufferWriteF32(TargetBuffer, CursorPosition, Value.X)
		BufferWriteF32(TargetBuffer, CursorPosition + 4, Value.Y)
		BufferWriteF32(TargetBuffer, CursorPosition + 8, Value.Z)
		BufferWriteF32(TargetBuffer, CursorPosition + 12, Rot.X)
		BufferWriteF32(TargetBuffer, CursorPosition + 16, Rot.Y)
		BufferWriteF32(TargetBuffer, CursorPosition + 20, Rot.Z)
		return TargetBuffer, CursorPosition + 24
	end,
	Read = function(TargetBuffer, CursorPosition)
		CheckBounds(TargetBuffer, CursorPosition, 24)
		local Pos = Vector3.new(BufferReadF32(TargetBuffer, CursorPosition), BufferReadF32(TargetBuffer, CursorPosition + 4), BufferReadF32(TargetBuffer, CursorPosition + 8))
		local Rot = Vector3.new(BufferReadF32(TargetBuffer, CursorPosition + 12), BufferReadF32(TargetBuffer, CursorPosition + 16), BufferReadF32(TargetBuffer, CursorPosition + 20))
		local Angle = Rot.Magnitude
		if Angle < 1e-6 then return CFrame.new(Pos), CursorPosition + 24 end
		return CFrame.fromAxisAngle(Rot / Angle, Angle) + Pos, CursorPosition + 24
	end
}

DataTypes.Color3 = {
	IsDynamic = false, ContainsInstances = false,
	GetByteSize = function(_) return 3 end,
	Write = function(TargetBuffer, CursorPosition, Value)
		TargetBuffer = EnsureCapacity(TargetBuffer, CursorPosition, 3)
		BufferWriteU8(TargetBuffer, CursorPosition, MathClamp(MathRound(Value.R * 255), 0, 255))
		BufferWriteU8(TargetBuffer, CursorPosition + 1, MathClamp(MathRound(Value.G * 255), 0, 255))
		BufferWriteU8(TargetBuffer, CursorPosition + 2, MathClamp(MathRound(Value.B * 255), 0, 255))
		return TargetBuffer, CursorPosition + 3
	end,
	Read = function(TargetBuffer, CursorPosition)
		CheckBounds(TargetBuffer, CursorPosition, 3)
		return Color3.fromRGB(BufferReadU8(TargetBuffer, CursorPosition), BufferReadU8(TargetBuffer, CursorPosition + 1), BufferReadU8(TargetBuffer, CursorPosition + 2)), CursorPosition + 3
	end
}

DataTypes.UDim2 = {
	IsDynamic = false, ContainsInstances = false,
	GetByteSize = function(_) return 16 end,
	Write = function(TargetBuffer, CursorPosition, Value)
		TargetBuffer = EnsureCapacity(TargetBuffer, CursorPosition, 16)
		BufferWriteF32(TargetBuffer, CursorPosition, Value.X.Scale)
		BufferWriteI32(TargetBuffer, CursorPosition + 4, Value.X.Offset)
		BufferWriteF32(TargetBuffer, CursorPosition + 8, Value.Y.Scale)
		BufferWriteI32(TargetBuffer, CursorPosition + 12, Value.Y.Offset)
		return TargetBuffer, CursorPosition + 16
	end,
	Read = function(TargetBuffer, CursorPosition)
		CheckBounds(TargetBuffer, CursorPosition, 16)
		return UDim2.new(BufferReadF32(TargetBuffer, CursorPosition), BufferReadI32(TargetBuffer, CursorPosition + 4), BufferReadF32(TargetBuffer, CursorPosition + 8), BufferReadI32(TargetBuffer, CursorPosition + 12)), CursorPosition + 16
	end
}

DataTypes.DateTime = {
	IsDynamic = false, ContainsInstances = false,
	GetByteSize = function(_) return 8 end,
	Write = function(TargetBuffer, CursorPosition, Value)
		TargetBuffer = EnsureCapacity(TargetBuffer, CursorPosition, 8)
		local High, Low = DecomposeInt64(Value.UnixTimestampMillis)
		BufferWriteU32(TargetBuffer, CursorPosition, High)
		BufferWriteU32(TargetBuffer, CursorPosition + 4, Low)
		return TargetBuffer, CursorPosition + 8
	end,
	Read = function(TargetBuffer, CursorPosition)
		CheckBounds(TargetBuffer, CursorPosition, 8)
		local High, Low = BufferReadU32(TargetBuffer, CursorPosition), BufferReadU32(TargetBuffer, CursorPosition + 4)
		return DateTime.fromUnixTimestampMillis(High * 4294967296 + Low), CursorPosition + 8
	end
}

DataTypes.Buffer = {
	IsDynamic = true, ContainsInstances = false,
	GetByteSize = function(Value) return 4 + BufferLen(Value) end,
	Write = function(TargetBuffer, CursorPosition, Value)
		local Length = BufferLen(Value)
		TargetBuffer = EnsureCapacity(TargetBuffer, CursorPosition, 4 + Length)
		BufferWriteU32(TargetBuffer, CursorPosition, Length)
		BufferCopy(TargetBuffer, CursorPosition + 4, Value, 0, Length)
		return TargetBuffer, CursorPosition + 4 + Length
	end,
	Read = function(TargetBuffer, CursorPosition)
		CheckBounds(TargetBuffer, CursorPosition, 4)
		local Length = BufferReadU32(TargetBuffer, CursorPosition)
		if Length > MaxBufferBlobSize then error(string.format("[%s] Buffer too large", IonErrorCodes.SIZE_LIMIT_EXCEEDED)) end
		CheckBounds(TargetBuffer, CursorPosition + 4, Length)
		local NewBuffer = BufferCreate(Length)
		BufferCopy(NewBuffer, 0, TargetBuffer, CursorPosition + 4, Length)
		return NewBuffer, CursorPosition + 4 + Length
	end
}

DataTypes.Any = {
	IsDynamic = true, ContainsInstances = true,
	GetByteSize = function(Value : any) : number
		local T = typeof(Value)
		if T == "number" then return 9
		elseif T == "string" then return 5 + #Value
		elseif T == "boolean" then return 2
		elseif T == "Instance" then return 3
		elseif T == "EnumItem" then return 7 + #(tostring(Value.EnumType))
		elseif T == "Vector3" then return 13
		elseif T == "Vector2" then return 9
		elseif T == "CFrame" then return 25
		elseif T == "Color3" then return 4
		elseif T == "UDim2" then return 17
		elseif T == "DateTime" then return 9
		elseif T == "buffer" then return 5 + BufferLen(Value)
		else return 1 end -- Nil
	end,
	Write = function(TargetBuffer, CursorPosition, Value, InstanceAccumulator, InstanceLookup)
		local T = typeof(Value)
		TargetBuffer = EnsureCapacity(TargetBuffer, CursorPosition, 1)
		
		if Value == nil then BufferWriteU8(TargetBuffer, CursorPosition, 0) return TargetBuffer, CursorPosition + 1
		elseif T == "boolean" then BufferWriteU8(TargetBuffer, CursorPosition, 1) return DataTypes.Boolean.Write(TargetBuffer, CursorPosition + 1, Value)
		elseif T == "number" then BufferWriteU8(TargetBuffer, CursorPosition, 2) return DataTypes.Float64.Write(TargetBuffer, CursorPosition + 1, Value)
		elseif T == "string" then BufferWriteU8(TargetBuffer, CursorPosition, 3) return DataTypes.String.Write(TargetBuffer, CursorPosition + 1, Value)
		elseif T == "Instance" then BufferWriteU8(TargetBuffer, CursorPosition, 4) return DataTypes.Instance.Write(TargetBuffer, CursorPosition + 1, Value, InstanceAccumulator, InstanceLookup)
		elseif T == "Vector3" then BufferWriteU8(TargetBuffer, CursorPosition, 5) return DataTypes.Vector3.Write(TargetBuffer, CursorPosition + 1, Value)
		elseif T == "EnumItem" then
			BufferWriteU8(TargetBuffer, CursorPosition, 6)
			TargetBuffer, CursorPosition = DataTypes.String.Write(TargetBuffer, CursorPosition + 1, tostring(Value.EnumType))
			TargetBuffer = EnsureCapacity(TargetBuffer, CursorPosition, 2)
			BufferWriteU16(TargetBuffer, CursorPosition, Value.Value)
			return TargetBuffer, CursorPosition + 2
		elseif T == "CFrame" then BufferWriteU8(TargetBuffer, CursorPosition, 7) return DataTypes.CFrame.Write(TargetBuffer, CursorPosition + 1, Value)
		elseif T == "Vector2" then BufferWriteU8(TargetBuffer, CursorPosition, 8) return DataTypes.Vector2.Write(TargetBuffer, CursorPosition + 1, Value)
		elseif T == "Color3" then BufferWriteU8(TargetBuffer, CursorPosition, 9) return DataTypes.Color3.Write(TargetBuffer, CursorPosition + 1, Value)
		elseif T == "UDim2" then BufferWriteU8(TargetBuffer, CursorPosition, 10) return DataTypes.UDim2.Write(TargetBuffer, CursorPosition + 1, Value)
		elseif T == "DateTime" then BufferWriteU8(TargetBuffer, CursorPosition, 11) return DataTypes.DateTime.Write(TargetBuffer, CursorPosition + 1, Value)
		elseif T == "buffer" then BufferWriteU8(TargetBuffer, CursorPosition, 12) return DataTypes.Buffer.Write(TargetBuffer, CursorPosition + 1, Value)
		else error(string.format("[%s] Unsupported Any type: %s", IonErrorCodes.NOT_SUPPORTED, T)) end
	end,
	Read = function(TargetBuffer, CursorPosition, InstanceSource)
		CheckBounds(TargetBuffer, CursorPosition, 1)
		local Id = BufferReadU8(TargetBuffer, CursorPosition)
		CursorPosition += 1
		if Id == 0 then return nil, CursorPosition
		elseif Id == 1 then return DataTypes.Boolean.Read(TargetBuffer, CursorPosition, InstanceSource)
		elseif Id == 2 then return DataTypes.Float64.Read(TargetBuffer, CursorPosition, InstanceSource)
		elseif Id == 3 then return DataTypes.String.Read(TargetBuffer, CursorPosition, InstanceSource)
		elseif Id == 4 then return DataTypes.Instance.Read(TargetBuffer, CursorPosition, InstanceSource)
		elseif Id == 5 then return DataTypes.Vector3.Read(TargetBuffer, CursorPosition, InstanceSource)
		elseif Id == 6 then
			local EnumName, NextPos = DataTypes.String.Read(TargetBuffer, CursorPosition, InstanceSource)
			CheckBounds(TargetBuffer, NextPos, 2)
			local Val = BufferReadU16(TargetBuffer, NextPos)
			local EnumType = (Enum :: any)[EnumName]
			if EnumType then
				local Cache = AnyEnumCache[EnumType]
				if not Cache then
					if #AnyEnumCacheOrder >= MaxEnumCacheSize then
						local Oldest = table.remove(AnyEnumCacheOrder, 1)
						AnyEnumCache[Oldest] = nil
					end
					Cache = {}
					for _, Item in ipairs(EnumType:GetEnumItems()) do Cache[Item.Value] = Item end
					AnyEnumCache[EnumType] = Cache
					table.insert(AnyEnumCacheOrder, EnumType)
				end
				local Item = Cache[Val]
				if not Item then
					warn(string.format("Ion: Invalid Enum value %d for %s", Val, EnumName))
					local Items = EnumType:GetEnumItems()
					if #Items == 0 then return nil, NextPos + 2 end
					return Items[1], NextPos + 2
				end
				return Item, NextPos + 2
			end
			return nil, NextPos + 2
		elseif Id == 7 then return DataTypes.CFrame.Read(TargetBuffer, CursorPosition, InstanceSource)
		elseif Id == 8 then return DataTypes.Vector2.Read(TargetBuffer, CursorPosition, InstanceSource)
		elseif Id == 9 then return DataTypes.Color3.Read(TargetBuffer, CursorPosition, InstanceSource)
		elseif Id == 10 then return DataTypes.UDim2.Read(TargetBuffer, CursorPosition, InstanceSource)
		elseif Id == 11 then return DataTypes.DateTime.Read(TargetBuffer, CursorPosition, InstanceSource)
		elseif Id == 12 then return DataTypes.Buffer.Read(TargetBuffer, CursorPosition, InstanceSource)
		else error(string.format("[%s] Unknown Any Type ID: %d", IonErrorCodes.SERIALIZATION_FAILED, Id)) end
	end
}

function DataTypes.Array<T>(Inner : TypeSerializer<T>) : TypeSerializer<{ T }>
	if Inner.IsUnbounded then error("Ion: RestOfString cannot be used inside Array") end
	return {
		IsDynamic = true, ContainsInstances = Inner.ContainsInstances,
		GetByteSize = function(Value) 
			local Count = #Value
			if Count > MaxCollectionSize then 
				error(string.format("[%s] Array size %d exceeds limit", IonErrorCodes.SIZE_LIMIT_EXCEEDED, Count))
			end
			
			if not Inner.IsDynamic then return 4 + (Count * Inner.GetByteSize(nil :: any)) end
			local Size = 4
			for _, Item in ipairs(Value) do 
				Size += Inner.GetByteSize(Item)
				if Size > MaxBufferSize then error(string.format("[%s] Array byte size exceeds limit", IonErrorCodes.SIZE_LIMIT_EXCEEDED)) end
			end
			return Size
		end,
		Write = function(TargetBuffer, CursorPosition, Value, InstanceAccumulator, InstanceLookup)
			local Count = #Value
			-- FIX #4: Check size BEFORE iteration
			if Count > MaxCollectionSize then error(string.format("[%s] Array size %d exceeds limit", IonErrorCodes.SIZE_LIMIT_EXCEEDED, Count)) end
			
			TargetBuffer = EnsureCapacity(TargetBuffer, CursorPosition, 4)
			BufferWriteU32(TargetBuffer, CursorPosition, Count)
			CursorPosition += 4
			for Index = 1, Count do 
				TargetBuffer, CursorPosition = Inner.Write(TargetBuffer, CursorPosition, Value[Index], InstanceAccumulator, InstanceLookup)
			end
			return TargetBuffer, CursorPosition
		end,
		Read = function(TargetBuffer, CursorPosition, InstanceSource)
			CheckBounds(TargetBuffer, CursorPosition, 4)
			local Count = BufferReadU32(TargetBuffer, CursorPosition)
			if Count > MaxCollectionSize then error(string.format("[%s] Array too large", IonErrorCodes.SIZE_LIMIT_EXCEEDED)) end
			CursorPosition += 4
			local Result = table.create(Count)
			for Index = 1, Count do
				local Item; Item, CursorPosition = Inner.Read(TargetBuffer, CursorPosition, InstanceSource)
				Result[Index] = Item
			end
			return Result, CursorPosition
		end
	}
end

function DataTypes.Map<K, V>(KeyType : TypeSerializer<K>, ValType : TypeSerializer<V>) : TypeSerializer<{ [K] : V }>
	if KeyType.IsUnbounded or ValType.IsUnbounded then error("Ion: RestOfString cannot be used inside Map") end
	return {
		IsDynamic = true, ContainsInstances = KeyType.ContainsInstances or ValType.ContainsInstances,
		GetByteSize = function(Value)
			local Size = 4
			local Count = 0
			for Key, Val in pairs(Value) do 
				Count += 1
				if Count > MaxCollectionSize then error(string.format("[%s] Map size exceeds limit", IonErrorCodes.SIZE_LIMIT_EXCEEDED)) end
				Size += KeyType.GetByteSize(Key) + ValType.GetByteSize(Val)
				if Size > MaxBufferSize then error(string.format("[%s] Map byte size exceeds limit", IonErrorCodes.SIZE_LIMIT_EXCEEDED)) end
			end
			return Size
		end,
		Write = function(TargetBuffer, CursorPosition, Value, InstanceAccumulator, InstanceLookup)
			local Count = 0
			for _ in pairs(Value) do Count += 1 end
			-- FIX #4: Check size BEFORE iteration
			if Count > MaxCollectionSize then error(string.format("[%s] Map size %d exceeds limit", IonErrorCodes.SIZE_LIMIT_EXCEEDED, Count)) end
			
			TargetBuffer = EnsureCapacity(TargetBuffer, CursorPosition, 4)
			BufferWriteU32(TargetBuffer, CursorPosition, Count)
			CursorPosition += 4
			for Key, Val in pairs(Value) do
				TargetBuffer, CursorPosition = KeyType.Write(TargetBuffer, CursorPosition, Key, InstanceAccumulator, InstanceLookup)
				TargetBuffer, CursorPosition = ValType.Write(TargetBuffer, CursorPosition, Val, InstanceAccumulator, InstanceLookup)
			end
			return TargetBuffer, CursorPosition
		end,
		Read = function(TargetBuffer, CursorPosition, InstanceSource)
			CheckBounds(TargetBuffer, CursorPosition, 4)
			local Count = BufferReadU32(TargetBuffer, CursorPosition)
			if Count > MaxCollectionSize then error(string.format("[%s] Map too large", IonErrorCodes.SIZE_LIMIT_EXCEEDED)) end
			CursorPosition += 4
			local Result = {}
			for _ = 1, Count do
				local Key, Val
				Key, CursorPosition = KeyType.Read(TargetBuffer, CursorPosition, InstanceSource)
				Val, CursorPosition = ValType.Read(TargetBuffer, CursorPosition, InstanceSource)
				Result[Key] = Val
			end
			return Result, CursorPosition
		end
	}
end

function DataTypes.Struct(StructureDefinition)
	local SortedKeys = {}
	local HasInstances, IsDynamic = false, false
	for Key, Serializer in pairs(StructureDefinition) do 
		if Serializer.IsUnbounded then error("Ion: RestOfString cannot be used inside Struct") end
		table.insert(SortedKeys, Key)
		if Serializer.ContainsInstances then HasInstances = true end
		if Serializer.IsDynamic then IsDynamic = true end
	end
	table.sort(SortedKeys)
	local Writers, Readers = {}, {}
	for Index, Key in ipairs(SortedKeys) do
		Writers[Index] = StructureDefinition[Key].Write
		Readers[Index] = StructureDefinition[Key].Read
	end
	
	return {
		IsDynamic = IsDynamic, ContainsInstances = HasInstances,
		GetByteSize = function(Value) 
			local Size = 0 
			for _, Key in ipairs(SortedKeys) do 
				-- FIX #5: Check for nil values in Struct keys to prevent silent errors
				local Val = Value[Key]
				if Val == nil and not IsDynamic then
					warn(string.format("Ion: Struct field '%s' is nil - will use default value", Key))
				end
				Size += StructureDefinition[Key].GetByteSize(if IsDynamic then Val else nil) 
			end 
			return Size 
		end,
		Write = function(TargetBuffer, CursorPosition, Value, InstanceAccumulator, InstanceLookup)
			for Index = 1, #SortedKeys do 
				TargetBuffer, CursorPosition = Writers[Index](TargetBuffer, CursorPosition, Value[SortedKeys[Index]], InstanceAccumulator, InstanceLookup) 
			end
			return TargetBuffer, CursorPosition
		end,
		Read = function(TargetBuffer, CursorPosition, InstanceSource)
			local Result = {}
			for Index = 1, #SortedKeys do 
				Result[SortedKeys[Index]], CursorPosition = Readers[Index](TargetBuffer, CursorPosition, InstanceSource) 
			end
			return Result, CursorPosition
		end
	}
end

--------------------------------------------------------------------------------
-- CORE LOGIC (Shared)
--------------------------------------------------------------------------------

local Ion = {}
Ion.Types = DataTypes

local function PreparePacket(Schema, Args, Hash, SchemaVersion, UseCompression, CompressThreshold)
	local PayloadBuf = AcquireBuffer(1024)
	
	local SerSuccess, SerRes = pcall(function()
		local Cursor, Acc, Look = 0, {}, {}
		for Index, Serializer in ipairs(Schema) do 
			PayloadBuf, Cursor = Serializer.Write(PayloadBuf, Cursor, Args[Index], Acc, Look) 
		end
		
		local FinalSize = Cursor
		local FinalPayload = BufferCreate(FinalSize)
		BufferCopy(FinalPayload, 0, PayloadBuf, 0, FinalSize)
		
		local IsCompressed = false
		if UseCompression and FinalSize > CompressThreshold then
			local CompData = EncodingService:CompressBuffer(FinalPayload, Enum.CompressionAlgorithm.Zstd)
			if BufferLen(CompData) < FinalSize then
				FinalPayload = CompData
				IsCompressed = true
				PerformanceStats.CompressionSavings += (FinalSize - BufferLen(CompData))
			end
		end
		
		return { Payload = FinalPayload, Compressed = IsCompressed, Inst = Acc }
	end)

	ReleaseBuffer(PayloadBuf) -- FIX #7: Always release the temp buffer

	if not SerSuccess then 
		return nil, nil, "Serialization Failed: " .. tostring(SerRes)
	end
	
	local PacketData = SerRes
	local Header = BufferCreate(7 + BufferLen(PacketData.Payload))
	BufferWriteU8(Header, 0, IonVersion)
	BufferWriteU32(Header, 1, Hash)
	BufferWriteU8(Header, 5, PacketData.Compressed and 1 or 0)
	BufferWriteU8(Header, 6, SchemaVersion)
	BufferCopy(Header, 7, PacketData.Payload, 0, BufferLen(PacketData.Payload))
	
	return Header, PacketData.Inst, nil
end

function Ion.Define(Namespace : string, Schema : { TypeSerializer<any> }, Options)
	local Success, Result = pcall(function()
		if Namespace == nil or Namespace == "" or #Namespace == 0 then
			error(string.format("[%s] Namespace cannot be empty", IonErrorCodes.INVALID_CONFIG))
		end
		-- FIX #14: Handle empty namespace after trim
		local TrimmedNamespace = Namespace:match("^%s*(.-)%s*$")
		if Namespace ~= TrimmedNamespace then
			warn("Ion: Namespace has leading/trailing whitespace - trimming")
			Namespace = TrimmedNamespace or ""
		end
		if Namespace == "" then
			error(string.format("[%s] Namespace cannot be empty after trimming", IonErrorCodes.INVALID_CONFIG))
		end

		local Hash = FNV1a(Namespace)
		
		if Definitions[Hash] then
			local Existing = ActivePackets[Hash]
			if Existing and Existing.Namespace == Namespace then
				error(string.format("Ion: Packet '%s' already defined", Namespace))
			else
				error(string.format(
					"Ion: Hash collision! Namespace '%s' collides with '%s' (Hash: %d). Please rename one.",
					Namespace,
					Existing and Existing.Namespace or "unknown",
					Hash
				))
			end
		end
		
		for Index = 1, #Schema - 1 do
			if Schema[Index].IsUnbounded then
				error("Ion: RestOfString can only be the last field in schema")
			end
		end
		
		local SchemaVersion = Options and Options.SchemaVersion or 1
		if SchemaVersion < 0 or SchemaVersion > 255 then
			error(string.format("[%s] SchemaVersion must be 0-255", IonErrorCodes.INVALID_CONFIG))
		end
		
		local RemoteTimeout = Options and Options.RemoteTimeout or 10
		
		Definitions[Hash] = Schema
		ActivePackets[Hash] = { Namespace = Namespace, Created = os.time(), IsDestroyed = false }
		
		local IsUnreliable = Options and Options.Unreliable or false
		local UseCompression = Options and Options.Compress or false
		local CompressThreshold = Options and Options.CompressionThreshold or CompressionThreshold
		local Hooks = Options and Options.Middleware
		local RemoteName = "Ion_".. Hash

		local function OnEvent(Player : Player | buffer, Data : buffer | {Instance}?, Instances : {Instance}?)
			-- FIX A: Initial destroyed check
			local PacketData = ActivePackets[Hash]
			if not PacketData or PacketData.IsDestroyed then return end
			
			local SourceBuffer = if RunService:IsServer() then Data :: buffer else Player :: buffer
			local SourceInstances = if RunService:IsServer() then Instances :: {Instance} else Data :: {Instance}
			local CursorPosition = 0
			local StartTime = os.clock()
			
			local ProcessingSuccess, Error = pcall(function()
				CheckBounds(SourceBuffer, CursorPosition, 7)
				local Ver = BufferReadU8(SourceBuffer, CursorPosition)
				local PId = BufferReadU32(SourceBuffer, CursorPosition + 1)
				local Flg = BufferReadU8(SourceBuffer, CursorPosition + 5)
				local SVer = BufferReadU8(SourceBuffer, CursorPosition + 6)
				CursorPosition += 7
				
				if Ver ~= IonVersion then error(string.format("[%s] Version mismatch", IonErrorCodes.VERSION_MISMATCH)) end
				if PId ~= Hash then error(string.format("[%s] Packet ID mismatch", IonErrorCodes.PACKET_ID_MISMATCH)) end
				if SVer ~= SchemaVersion then error(string.format("[%s] Schema mismatch", IonErrorCodes.SCHEMA_MISMATCH)) end
				
				if Bit32Band(Flg, 1) == 1 then
					local CompSize = BufferLen(SourceBuffer) - 7
					if CompSize > MaxBufferSize then error(string.format("[%s] Compressed payload too large", IonErrorCodes.SIZE_LIMIT_EXCEEDED)) end
					local CompPayload = BufferCreate(CompSize)
					BufferCopy(CompPayload, 0, SourceBuffer, 7, CompSize)
					
					local DecompData = EncodingService:DecompressBuffer(CompPayload, Enum.CompressionAlgorithm.Zstd)
					SourceBuffer = DecompData
					CursorPosition = 0
					if BufferLen(SourceBuffer) > MaxBufferSize then error(string.format("[%s] Decompressed payload too large", IonErrorCodes.SIZE_LIMIT_EXCEEDED)) end
				end
			end)

			if not ProcessingSuccess then 
				warn("Ion Packet Error: " .. tostring(Error)) 
				return 
			end

			-- FIX A: Final race condition check before callback
			if ActivePackets[Hash].IsDestroyed then return end

			local Callback = Listeners[Hash]
			if Callback then
				local Args = {}
				local ReadSuccess, ReadErr = pcall(function()
					for _, Ser in ipairs(Schema) do
						local Val, Next = Ser.Read(SourceBuffer, CursorPosition, SourceInstances)
						table.insert(Args, Val)
						CursorPosition = Next
					end
				end)
				
				if not ReadSuccess then warn("Ion Read Error: "..tostring(ReadErr)) return end
				
				RecordPerformance("deserialize", os.clock() - StartTime, BufferLen(SourceBuffer))
				
				-- FIX A: One more check before middleware/callback execution
				if ActivePackets[Hash].IsDestroyed then return end

				if Hooks and Hooks.OnAfterReceived then
					if RunService:IsServer() then
						pcall(Hooks.OnAfterReceived, Player, table.unpack(Args))
					else
						pcall(Hooks.OnAfterReceived, table.unpack(Args))
					end
				end
				
				if RunService:IsServer() then Callback(Player, table.unpack(Args)) else Callback(table.unpack(Args)) end
			end
		end

		if RunService:IsServer() then
			local Remote = if IsUnreliable then Instance.new("UnreliableRemoteEvent") else Instance.new("RemoteEvent")
			Remote.Name, Remote.Parent = RemoteName, ReplicatedStorage
			RemoteCache[Hash] = Remote
			RemoteConnections[Hash] = (Remote :: any).OnServerEvent:Connect(OnEvent)
		else
			local Remote = ReplicatedStorage:WaitForChild(RemoteName, RemoteTimeout)
			if not Remote then
				local Retries = 0
				while not Remote and Retries < 5 do
					Retries += 1
					Remote = ReplicatedStorage:WaitForChild(RemoteName, 2)
				end
			end
			if not Remote then error(string.format("[%s] Remote missing for %s", IonErrorCodes.REMOTE_MISSING, Namespace)) end
			RemoteCache[Hash] = Remote
			RemoteConnections[Hash] = (Remote :: any).OnClientEvent:Connect(OnEvent)
		end

		local PacketObject = {}
		
		function PacketObject.Send(Target : Player?, ... : any) : boolean
			local PacketData = ActivePackets[Hash]
			if not PacketData or PacketData.IsDestroyed then return false end
			
			if not Definitions[Hash] then return false end
			local Remote : any = RemoteCache[Hash]
			if not Remote or not Remote.Parent then return false end

			local Args = table.pack(...)
			if Hooks and Hooks.OnBeforeSend then
				local MiddlewareSuccess, MiddlewareResult = pcall(Hooks.OnBeforeSend, ...)
				if not MiddlewareSuccess then warn("Ion Middleware Error") return false end
				if MiddlewareResult == false then return false end
				if type(MiddlewareResult) == "table" then Args = MiddlewareResult end
			end

			if IsUnreliable then
				local EstSize = 7
				local SizeCheckSuccess = pcall(function() 
					for Index, Serializer in ipairs(Schema) do EstSize += Serializer.GetByteSize(Args[Index]) end 
				end)
				
				if not SizeCheckSuccess then 
					warn("Ion: Size check failed - aborting send") 
					return false 
				end
				
				if UseCompression and EstSize > CompressThreshold then 
					EstSize = math.ceil(EstSize * CompressionRatioEstimate) 
				end
				
				if EstSize > MaxPacketSize then 
					warn(string.format("[%s] Packet likely too large (%d bytes)", IonErrorCodes.SIZE_LIMIT_EXCEEDED, EstSize))
					return false 
				end
			end
			
			local StartTime = os.clock()
			local PacketBuffer, PacketInsts, Err = PreparePacket(Schema, Args, Hash, SchemaVersion, UseCompression, CompressThreshold)
			if not PacketBuffer then warn(Err) return false end
			
			if IsUnreliable and BufferLen(PacketBuffer) > MaxPacketSize then 
				warn(string.format("[%s] Packet too large (%d bytes)", IonErrorCodes.SIZE_LIMIT_EXCEEDED, BufferLen(PacketBuffer)))
				return false 
			end
			
			RecordPerformance("serialize", os.clock() - StartTime, BufferLen(PacketBuffer))
			
			DebugLog("Sent Packet "..Namespace, "DEBUG")
			
			if RunService:IsServer() then
				if Target then Remote:FireClient(Target, PacketBuffer, PacketInsts) else Remote:FireAllClients(PacketBuffer, PacketInsts) end
			else
				Remote:FireServer(PacketBuffer, PacketInsts)
			end
			return true
		end

		function PacketObject.SendToList(Recipients, ...)
			if #Recipients == 0 then return {} end
			
			local Args = table.pack(...)
			if Hooks and Hooks.OnBeforeSend then
				local MiddlewareSuccess, MiddlewareResult = pcall(Hooks.OnBeforeSend, ...)
				if not MiddlewareSuccess or MiddlewareResult == false then return Recipients end
				if type(MiddlewareResult) == "table" then Args = MiddlewareResult end
			end
			
			local PacketBuffer, PacketInsts, Err = PreparePacket(Schema, Args, Hash, SchemaVersion, UseCompression, CompressThreshold)
			if not PacketBuffer then warn(Err) return Recipients end
			
			if IsUnreliable and BufferLen(PacketBuffer) > MaxPacketSize then return Recipients end
			
			local Failed = {}
			local Remote : any = RemoteCache[Hash]
			for _, Plr in ipairs(Recipients) do
				-- FIX #5: Wrap FireClient in pcall
				if Plr and Plr.Parent then 
					local SendSuccess = pcall(function()
						Remote:FireClient(Plr, PacketBuffer, PacketInsts) 
					end)
					if not SendSuccess then
						DebugLog("SendToList failed for player: " .. tostring(Plr), "WARN")
						table.insert(Failed, Plr)
					end
				else 
					table.insert(Failed, Plr) 
				end
			end
			return Failed
		end

		function PacketObject.Listen(Callback) Listeners[Hash] = Callback end
		
		function PacketObject.Destroy()
			local PacketData = ActivePackets[Hash]
			if not PacketData or PacketData.IsDestroyed then return end
			
			DebugLog("Destroying Packet "..Namespace, "INFO")
			PacketData.IsDestroyed = true
			
			Listeners[Hash] = nil
			local Conn = RemoteConnections[Hash]
			if Conn then Conn:Disconnect() end
			RemoteConnections[Hash] = nil
			
			local Remote = RemoteCache[Hash]
			if Remote and typeof(Remote) == "Instance" and Remote.Parent then Remote:Destroy() end
			
			RemoteCache[Hash] = nil
			Definitions[Hash] = nil
			ActivePackets[Hash] = nil
		end

		return {
			Server = { SendTo = function(p,...) return PacketObject.Send(p,...) end, SendToAll = function(...) return PacketObject.Send(nil,...) end, SendToList = PacketObject.SendToList, Listen = PacketObject.Listen },
			Client = { Send = function(...) return PacketObject.Send(nil,...) end, Listen = PacketObject.Listen },
			Destroy = PacketObject.Destroy
		}
	end)

	if not Success then
		local CleanupSuccess, Hash = pcall(FNV1a, Namespace)
		if CleanupSuccess then
			if RemoteConnections[Hash] then RemoteConnections[Hash]:Disconnect() end
			local Remote = RemoteCache[Hash]
			if Remote and typeof(Remote) == "Instance" then Remote:Destroy() end
			RemoteCache[Hash] = nil
			Definitions[Hash] = nil
			ActivePackets[Hash] = nil
		end
		error(Result)
	end

	return Result
end

function Ion.GetStats() return PerformanceStats end
function Ion.SetDebugMode(Enabled, Logger) DebugMode = Enabled DebugLogger = Logger end

return Ion