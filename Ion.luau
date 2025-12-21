--!strict
--!native
--!optimize 2

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local EncodingService = game:GetService("EncodingService")

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
local MathCeil = math.ceil
local MathLog = math.log

local IonVersion : number = 1
local MaxPacketSize : number = 900
local MaxBufferSize : number = 100 * 1024 * 1024
local MaxBufferBlobSize : number = 10 * 1024 * 1024
local BufferGrowthFactor : number = 1.5
local MaxCollectionSize : number = 100000
local MaxStringSize : number = 1000000
local CompressionThreshold : number = 128
local CompressionRatioEstimate : number = 0.7
local PoolCapacity : number = 64
local PoolBufferSize : number = 4096
local MaxSafeInteger : number = 9007199254740991
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
	TIMEOUT = "E017",
	RATE_LIMITED = "E018"
}

export type IonPacket<Arguments...> = {
	Server : {
		SendTo : (Recipient : Player, Arguments...) -> (boolean),
		SendToAll : (Arguments...) -> (boolean),
		SendToAllExcept : (Excluded : Player | { Player }, Arguments...) -> (boolean),
		SendToList : (Recipients : { Player }, Arguments...) -> ({ Player }),
		Listen : (Callback : (Player, Arguments...) -> ()) -> ({ Disconnect: () -> () }) 
	},
	Client : {
		Send : (Arguments...) -> (boolean),
		Listen : (Callback : (Arguments...) -> ()) -> ({ Disconnect: () -> () })
	},
	Destroy : () -> ()
}

export type Int64Struct = { Upper : number, Lower : number }

export type TypeSerializer<Type> = {
	Write : (buffer, number, Type, { Instance }, { [Instance] : number }) -> (buffer, number),
	Read : (buffer, number, { Instance }) -> (Type, number),
	GetByteSize : (Type) -> number,
	IsDynamic : boolean,
	ContainsInstances : boolean,
	IsUnbounded : boolean?
}

export type IonDefinitionOptions = {
	Unreliable : boolean?,
	Compress : boolean?,
	CompressionThreshold : number?,
	SchemaVersion : number?,
	RemoteTimeout : number?,
	RateLimit : { MaxRequests : number, Window : number }?,
	Middleware : {
		OnBeforeSend : ((...any) -> (boolean | {any} | nil))?,
		OnAfterReceived : ((...any) -> ())?
	}?
}

local BufferPool : { buffer } = {}
local BufferPoolInitialized : boolean = false

local EnumSerializerCache : { [any] : any } = {}
local EnumSerializerCacheOrder : { any } = {}
local AnyEnumCache : { [any] : { [number] : EnumItem } } = {}
local AnyEnumCacheOrder : { any } = {}

type RateLimitState = {
	History : { number },
	WindowStart : number
}

type PacketMetadata = {
	Namespace : string,
	Created : number,
	IsDestroyed : boolean,
	Generation : number,
	ClientRateLimitState : RateLimitState?,
	ServerRateLimitState : { [number] : RateLimitState }?
}

local Definitions : { [number] : any } = {}
local Listeners : { [number] : (...any) -> () } = {}
local RemoteCache : { [number] : RemoteEvent | UnreliableRemoteEvent } = {}
local RemoteConnections : { [number] : RBXScriptConnection } = {}
local ActivePackets : { [number] : PacketMetadata } = {}

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

local function InitializeBufferPool()
	if BufferPoolInitialized then return end
	for PoolIndex = 1, PoolCapacity do
		table.insert(BufferPool, BufferCreate(PoolBufferSize))
	end
	BufferPoolInitialized = true
end

local function ReleaseBuffer(BufferToRelease : buffer)
	local CurrentLength = BufferLen(BufferToRelease)
	if CurrentLength == PoolBufferSize and #BufferPool < PoolCapacity then
		BufferFill(BufferToRelease, 0, 0, PoolBufferSize)
		table.insert(BufferPool, BufferToRelease)
	end
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
	if RequiredSize <= CurrentLength then return TargetBuffer end

	local NewLength = CurrentLength
	if NewLength == 0 then NewLength = 1 end
	while NewLength < RequiredSize do
		NewLength = NewLength * 2
		if NewLength >= MaxBufferSize then
			NewLength = MaxBufferSize
			break
		end
	end

	if NewLength < RequiredSize then
		error(string.format("[%s] Ion: Buffer overflow - Required %d > Max %d", IonErrorCodes.BUFFER_OVERFLOW, RequiredSize, MaxBufferSize))
	end

	local NewBuffer = BufferCreate(NewLength)
	BufferCopy(NewBuffer, 0, TargetBuffer, 0, CurrentLength)
	ReleaseBuffer(TargetBuffer)
	return NewBuffer
end


local function CheckBounds(TargetBuffer : buffer, CursorPosition : number, Size : number)
	if CursorPosition + Size > BufferLen(TargetBuffer) then
		error(string.format("[%s] Ion: Malformed packet (Buffer overflow)", IonErrorCodes.BUFFER_OVERFLOW))
	end
end

local function FNV1a(StringValue : string) : number
	local Hash : number = 2166136261
	local Prime : number = 16777619
	for Index = 1, #StringValue do
		Hash = Bit32Xor(Hash, string.byte(StringValue, Index))
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
	elseif Value > 65504 then
		Encoded = Sign + 0x7C00
	elseif Value ~= Value then
		Encoded = 0x7FFF
	else
		local Mantissa : number, Exponent : number = MathFrexp(Value)
		Exponent += 14

		if Exponent <= 0 then
			if Exponent < -10 then
				Encoded = Sign
			else
				Mantissa = MathLdexp(Mantissa, Exponent + 10)
				local MantissaBits = MathClamp(MathFloor(Mantissa + 0.5), 0, 1023)
				Encoded = Sign + MantissaBits
			end
		elseif Exponent >= 31 then
			Encoded = Sign + 0x7C00
		else
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

local function ZigZagEncode(n : number) : number
    if n >= 0 then
        return n * 2
    else
        return (-n) * 2 - 1
    end
end

local function ZigZagDecode(z : number) : number
    if z % 2 == 0 then
        return z // 2
    else
        return -((z + 1) // 2)
    end
end

local function ReadAnyNumberFast(Source, CursorPosition, Count)
    local Result = table.create(Count)
    local Out = 1

    while Out <= Count do
        local Mask = BufferReadU32(Source, CursorPosition)
        CursorPosition += 4

        for Index = 0, 15 do
            if Out > Count then break end
            local Shift = Index * 2
            local Tag = bit32.band(bit32.rshift(Mask, Shift), 3)

            if Tag == 0 then
                local v = BufferReadU8(Source, CursorPosition); CursorPosition += 1
                Result[Out] = ZigZagDecode(v)
            elseif Tag == 1 then
                local v = BufferReadU16(Source, CursorPosition); CursorPosition += 2
                Result[Out] = ZigZagDecode(v)
            elseif Tag == 2 then
                local v = BufferReadU32(Source, CursorPosition); CursorPosition += 4
                Result[Out] = ZigZagDecode(v)
            else
                Result[Out] = BufferReadF64(Source, CursorPosition); CursorPosition += 8
            end

            Out += 1
        end
    end

    return Result, CursorPosition
end

local DataTypes = {}

local function CreatePrimitive(Size: number, WriteFunc: (buffer, number, number) -> (), ReadFunc: (buffer, number) -> number, ClampMin: number?, ClampMax: number?) : TypeSerializer<number>
	return {
		IsDynamic = false, ContainsInstances = false,
		GetByteSize = function(_ : any) return Size end,
		Write = function(TargetBuffer, CursorPosition, Value)
			TargetBuffer = EnsureCapacity(TargetBuffer, CursorPosition, Size)
			local SafeValue = Value or 0
			if ClampMin and ClampMax then SafeValue = MathClamp(SafeValue, ClampMin, ClampMax) end
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
		local Byte1 = BufferReadU8(TargetBuffer, CursorPosition)
		local Byte2 = BufferReadU8(TargetBuffer, CursorPosition + 1)
		local Byte3 = BufferReadU8(TargetBuffer, CursorPosition + 2)
		return Byte1 + Bit32LShift(Byte2, 8) + Bit32LShift(Byte3, 16), CursorPosition + 3 
	end
} :: TypeSerializer<number>

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
} :: TypeSerializer<number>

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
} :: TypeSerializer<boolean>

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
} :: TypeSerializer<Int64Struct | number | string>

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
} :: TypeSerializer<Int64Struct | number | string>

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
} :: TypeSerializer<string>

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
} :: TypeSerializer<string>

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
} :: TypeSerializer<string>

DataTypes.FixedString = function(Length : number, ErrorOnTruncate : boolean?) : TypeSerializer<string>
	if Length > MaxStringSize then error(string.format("[%s] FixedString too large", IonErrorCodes.SIZE_LIMIT_EXCEEDED)) end
	return {
		IsDynamic = false, ContainsInstances = false,
		GetByteSize = function(_) return Length end,
		Write = function(TargetBuffer, CursorPosition, Value)
			local StrLen = MathMin(#Value, Length)
			if ErrorOnTruncate and #Value > Length then
				error(string.format("[%s] String exceeds FixedString length %d", IonErrorCodes.SIZE_LIMIT_EXCEEDED, Length))
			end

			TargetBuffer = EnsureCapacity(TargetBuffer, CursorPosition, Length)
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
	if EnumSerializerCache[EnumType] then return EnumSerializerCache[EnumType] :: TypeSerializer<EnumItem> end

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
	return Serializer :: TypeSerializer<EnumItem>
end

DataTypes.Vector3 = {
	IsDynamic = false, ContainsInstances = false,
	GetByteSize = function(_) return 12 end,
	Write = function(TargetBuffer, CursorPosition, Value : Vector3)
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

DataTypes.Vector3Int16 = {
	IsDynamic = false, ContainsInstances = false,
	GetByteSize = function(_) return 6 end,
	Write = function(TargetBuffer, CursorPosition, Value : Vector3)
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
} :: TypeSerializer<Vector3>

DataTypes.Vector2 = {
	IsDynamic = false, ContainsInstances = false,
	GetByteSize = function(_) return 8 end,
	Write = function(TargetBuffer, CursorPosition, Value : Vector2)
		TargetBuffer = EnsureCapacity(TargetBuffer, CursorPosition, 8)
		BufferWriteF32(TargetBuffer, CursorPosition, Value.X)
		BufferWriteF32(TargetBuffer, CursorPosition + 4, Value.Y)
		return TargetBuffer, CursorPosition + 8
	end,
	Read = function(TargetBuffer, CursorPosition)
		CheckBounds(TargetBuffer, CursorPosition, 8)
		return Vector2.new(BufferReadF32(TargetBuffer, CursorPosition), BufferReadF32(TargetBuffer, CursorPosition + 4)), CursorPosition + 8
	end
} :: TypeSerializer<Vector2>

DataTypes.CFrameFloat16 = {
	IsDynamic = false, ContainsInstances = false,
	GetByteSize = function(_) return 12 end,
	Write = function(TargetBuffer, CursorPosition, Value : CFrame)
		TargetBuffer = EnsureCapacity(TargetBuffer, CursorPosition, 12)
		WriteFloat16(TargetBuffer, CursorPosition, Value.X)
		WriteFloat16(TargetBuffer, CursorPosition + 2, Value.Y)
		WriteFloat16(TargetBuffer, CursorPosition + 4, Value.Z)
		local EulerX, EulerY, EulerZ = Value:ToEulerAnglesXYZ()
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
} :: TypeSerializer<CFrame>

DataTypes.CFrame = {
	IsDynamic = false, ContainsInstances = false,
	GetByteSize = function(_) return 24 end,
	Write = function(TargetBuffer, CursorPosition, Value : CFrame)
		TargetBuffer = EnsureCapacity(TargetBuffer, CursorPosition, 24)
		local Axis, Angle = Value:ToAxisAngle()
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
} :: TypeSerializer<CFrame>

DataTypes.Color3 = {
	IsDynamic = false, ContainsInstances = false,
	GetByteSize = function(_) return 3 end,
	Write = function(TargetBuffer, CursorPosition, Value : Color3)
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
} :: TypeSerializer<Color3>

DataTypes.UDim2 = {
	IsDynamic = false, ContainsInstances = false,
	GetByteSize = function(_) return 16 end,
	Write = function(TargetBuffer, CursorPosition, Value : UDim2)
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
} :: TypeSerializer<UDim2>

DataTypes.DateTime = {
	IsDynamic = false, ContainsInstances = false,
	GetByteSize = function(_) return 8 end,
	Write = function(TargetBuffer, CursorPosition, Value : DateTime)
		TargetBuffer = EnsureCapacity(TargetBuffer, CursorPosition, 8)
		local High, Low = DecomposeInt64(Value.UnixTimestampMillis)
		BufferWriteU32(TargetBuffer, CursorPosition, High)ZigZagEncode
		BufferWriteU32(TargetBuffer, CursorPosition + 4, Low)
		return TargetBuffer, CursorPosition + 8
	end,
	Read = function(TargetBuffer, CursorPosition)
		CheckBounds(TargetBuffer, CursorPosition, 8)
		local High, Low = BufferReadU32(TargetBuffer, CursorPosition), BufferReadU32(TargetBuffer, CursorPosition + 4)
		return DateTime.fromUnixTimestampMillis(High * 4294967296 + Low), CursorPosition + 8
	end
} :: TypeSerializer<DateTime>

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
} :: TypeSerializer<buffer>

DataTypes.Any = {
	IsDynamic = true,
	ContainsInstances = true,

	GetByteSize = function(Value : any) : number
		local Type = typeof(Value)

		if Type == "number" then
			return 1 + 8
		elseif Type == "boolean" then
			return 1 + 1
		elseif Type == "string" then
			return 1 + 4 + #Value
		elseif Type == "Instance" then
			return 1 + 3
		elseif Type == "Vector3" then
			return 1 + 12
		elseif Type == "Vector2" then
			return 1 + 8
		elseif Type == "CFrame" then
			return 1 + 24
		elseif Type == "Color3" then
			return 1 + 3
		elseif Type == "UDim2" then
			return 1 + 16
		elseif Type == "DateTime" then
			return 1 + 8
		elseif Type == "buffer" then
			return 1 + 4 + BufferLen(Value)
		elseif Type == "EnumItem" then
			return 1 + 7 + #tostring(Value.EnumType)
		end

		return 1
	end,

	Write = function(
		TargetBuffer : buffer,
		CursorPosition : number,
		Value : any,
		InstanceAccumulator : { Instance },
		InstanceLookUp : { [Instance] : number }
	)
		TargetBuffer = EnsureCapacity(TargetBuffer, CursorPosition, 1)

		if Value == nil then
			BufferWriteU8(TargetBuffer, CursorPosition, 0)
			return TargetBuffer, CursorPosition + 1
		end

		local Type = typeof(Value)

		if Type == "number" then
			BufferWriteU8(TargetBuffer, CursorPosition, 1)
			TargetBuffer = EnsureCapacity(TargetBuffer, CursorPosition + 1, 8)
			BufferWriteF64(TargetBuffer, CursorPosition + 1, Value)
			return TargetBuffer, CursorPosition + 9

		elseif Type == "boolean" then
			BufferWriteU8(TargetBuffer, CursorPosition, 2)
			TargetBuffer = EnsureCapacity(TargetBuffer, CursorPosition + 1, 1)
			BufferWriteU8(TargetBuffer, CursorPosition + 1, Value and 1 or 0)
			return TargetBuffer, CursorPosition + 2

		elseif Type == "string" then
			BufferWriteU8(TargetBuffer, CursorPosition, 3)
			return DataTypes.String.Write(
				TargetBuffer,
				CursorPosition + 1,
				Value,
				InstanceAccumulator,
				InstanceLookUp
			)

		elseif Type == "Instance" then
			BufferWriteU8(TargetBuffer, CursorPosition, 4)
			return DataTypes.Instance.Write(
				TargetBuffer,
				CursorPosition + 1,
				Value,
				InstanceAccumulator,
				InstanceLookUp
			)

		elseif Type == "Vector3" then
			BufferWriteU8(TargetBuffer, CursorPosition, 5)
			return DataTypes.Vector3.Write(TargetBuffer, CursorPosition + 1, Value, InstanceAccumulator, InstanceLookUp)

		elseif Type == "Vector2" then
			BufferWriteU8(TargetBuffer, CursorPosition, 6)
			return DataTypes.Vector2.Write(TargetBuffer, CursorPosition + 1, Value, InstanceAccumulator, InstanceLookUp)

		elseif Type == "CFrame" then
			BufferWriteU8(TargetBuffer, CursorPosition, 7)
			return DataTypes.CFrame.Write(TargetBuffer, CursorPosition + 1, Value, InstanceAccumulator, InstanceLookUp)

		elseif Type == "Color3" then
			BufferWriteU8(TargetBuffer, CursorPosition, 8)
			return DataTypes.Color3.Write(TargetBuffer, CursorPosition + 1, Value, InstanceAccumulator, InstanceLookUp)

		elseif Type == "UDim2" then
			BufferWriteU8(TargetBuffer, CursorPosition, 9)
			return DataTypes.UDim2.Write(TargetBuffer, CursorPosition + 1, Value, InstanceAccumulator, InstanceLookUp)

		elseif Type == "DateTime" then
			BufferWriteU8(TargetBuffer, CursorPosition, 10)
			return DataTypes.DateTime.Write(TargetBuffer, CursorPosition + 1, Value, InstanceAccumulator, InstanceLookUp)

		elseif Type == "buffer" then
			BufferWriteU8(TargetBuffer, CursorPosition, 11)
			return DataTypes.Buffer.Write(TargetBuffer, CursorPosition + 1, Value, InstanceAccumulator, InstanceLookUp)

		elseif Type == "EnumItem" then
			BufferWriteU8(TargetBuffer, CursorPosition, 12)
			return DataTypes.EnumItem.Write(TargetBuffer, CursorPosition + 1, Value, InstanceAccumulator, InstanceLookUp)
		end

		BufferWriteU8(TargetBuffer, CursorPosition, 255)
		return TargetBuffer, CursorPosition + 1
	end,
} :: TypeSerializer<any>

DataTypes.AnyNumberFast = {
	IsDynamic = true,
	ContainsInstances = false,

	GetByteSize = function()
		return nil
	end,

	Write = function(
		TargetBuffer : buffer,
		CursorPosition : number,
		Value : any,
		InstanceAccumulator,
		InstanceLookUp
	)
		if typeof(Value) ~= "table" then
			return DataTypes.Any.Write(
				TargetBuffer,
				CursorPosition,
				Value,
				InstanceAccumulator,
				InstanceLookUp
			)
		end

		local Count = #Value

		for Index = 1, Count do
			if type(Value[Index]) ~= "number" then
				return DataTypes.Any.Write(
					TargetBuffer,
					CursorPosition,
					Value,
					InstanceAccumulator,
					InstanceLookUp
				)
			end
		end

		TargetBuffer = EnsureCapacity(TargetBuffer, CursorPosition, 2)
		BufferWriteU16(TargetBuffer, CursorPosition, Count)
		CursorPosition += 2

		local Index = 1

		while Index <= Count do
			TargetBuffer = EnsureCapacity(TargetBuffer, CursorPosition, 4)
			local MaskPos = CursorPosition
			CursorPosition += 4

			local Mask = 0
			local Shift = 0

			for _ = 1, 16 do
				if Index > Count then break end

				local V = Value[Index]
				Index += 1

				if V % 1 == 0 then
					local ZZ = ZigZagEncode(V)

					if ZZ <= 0xFF then
						TargetBuffer = EnsureCapacity(TargetBuffer, CursorPosition, 1)
						BufferWriteU8(TargetBuffer, CursorPosition, ZZ)
						CursorPosition += 1

					elseif ZZ <= 0xFFFF then
						Mask = bit32.bor(Mask, bit32.lshift(1, Shift))
						TargetBuffer = EnsureCapacity(TargetBuffer, CursorPosition, 2)
						BufferWriteU16(TargetBuffer, CursorPosition, ZZ)
						CursorPosition += 2

					elseif ZZ <= 0xFFFFFFFF then
						Mask = bit32.bor(Mask, bit32.lshift(2, Shift))
						TargetBuffer = EnsureCapacity(TargetBuffer, CursorPosition, 4)
						BufferWriteU32(TargetBuffer, CursorPosition, ZZ)
						CursorPosition += 4

					else
						Mask = bit32.bor(Mask, bit32.lshift(3, Shift))
						TargetBuffer = EnsureCapacity(TargetBuffer, CursorPosition, 8)
						BufferWriteF64(TargetBuffer, CursorPosition, V)
						CursorPosition += 8
					end
				else
					Mask = bit32.bor(Mask, bit32.lshift(3, Shift))
					TargetBuffer = EnsureCapacity(TargetBuffer, CursorPosition, 8)
					BufferWriteF64(TargetBuffer, CursorPosition, V)
					CursorPosition += 8
				end

				Shift += 2
			end

			BufferWriteU32(TargetBuffer, MaskPos, Mask)
		end

		return TargetBuffer, CursorPosition
	end,

	Read = function(Source, CursorPosition)
		local Count = BufferReadU16(Source, CursorPosition)
		CursorPosition += 2
		return ReadAnyNumberFast(Source, CursorPosition, Count)
	end,
} :: TypeSerializer<any>


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

function DataTypes.Struct(StructureDefinition : { [string]: TypeSerializer<any> }): TypeSerializer<{ [string]: any }>
	local SortedKeys = {}
	local HasInstances, IsDynamic = false, false
	for Key, Serializer in pairs(StructureDefinition) do 
		if Serializer.IsUnbounded then error("Ion: RestOfString cannot be used inside Struct") end
		table.insert(SortedKeys, Key)
		if Serializer.ContainsInstances then HasInstances = true end
		if Serializer.IsDynamic then IsDynamic = true end
	end
	table.sort(SortedKeys)
	local Writers: {(buffer, number, any, {Instance}, {[Instance]: number}) -> (buffer, number)} = {}
	local Readers: {(buffer, number, {Instance}) -> (any, number)} = {}

	for Index, Key in ipairs(SortedKeys) do
		Writers[Index] = StructureDefinition[Key].Write
		Readers[Index] = StructureDefinition[Key].Read
	end

	return {
		IsDynamic = IsDynamic, ContainsInstances = HasInstances,
		GetByteSize = function(Value) 
			local Size = 0 
			for _, Key in ipairs(SortedKeys) do 
				local Val = Value[Key]
				if Val == nil and not IsDynamic then
					warn(string.format("Ion: Struct field '%s' is nil - will use default value", Key))
				end
				Size += StructureDefinition[Key].GetByteSize(if IsDynamic then Val else nil) 
			end 
			return Size 
		end,
		Write = function(TargetBuffer: buffer, CursorPosition: number, Value: { [string]: any }, InstanceAccumulator: {Instance}, InstanceLookup: {[Instance]: number}): (buffer, number)
			for Index = 1, #SortedKeys do 
				TargetBuffer, CursorPosition = Writers[Index](TargetBuffer, CursorPosition, Value[SortedKeys[Index]], InstanceAccumulator, InstanceLookup) 
			end
			return TargetBuffer, CursorPosition
		end,
		Read = function(TargetBuffer: buffer, CursorPosition: number, InstanceSource: {Instance}): ({ [string]: any }, number)
			local Result: { [string]: any } = {}
			for Index = 1, #SortedKeys do 
				Result[SortedKeys[Index]], CursorPosition = Readers[Index](TargetBuffer, CursorPosition, InstanceSource) 
			end
			return Result, CursorPosition
		end
	}
end

local Ion = {}
Ion.Types = DataTypes

local function PreparePacket(
	Schema : { TypeSerializer<any> },
	Args : { any },
	Hash : number,
	SchemaVersion : number,
	UseCompression : boolean,
	CompressThreshold : number
): (buffer?, { Instance }?, string?)

	local SchemaLenght = #Schema
	local StaticPossible = true
	local EstimatedSize = 0

	for Index = 1, SchemaLenght do
		local Serializer = Schema[Index]

		if Serializer.IsDynamic then
			StaticPossible = false
			break
		end

		local Passed, Size = pcall(Serializer.GetByteSize, Serializer, Args[Index])
		if not Passed then
			StaticPossible = false
			break
		end

		EstimatedSize += Size
	end

	if StaticPossible then
		local FinalPayload = BufferCreate(EstimatedSize)
		local CursorPosition = 0

		local InstanceAccumulator = table.create(4)
		local InstanceLookUp = {}

		for Index = 1, SchemaLenght do
			local Serializer = Schema[Index]
			FinalPayload, CursorPosition =
				Serializer.Write(FinalPayload, CursorPosition, Args[Index], InstanceAccumulator, InstanceLookUp)
		end

		local IsCompressed = false

		if UseCompression and CursorPosition > CompressThreshold then
			local Passed, Compressed = pcall(function()
				return EncodingService:CompressBuffer(FinalPayload, Enum.CompressionAlgorithm.Zstd)
			end)

			if Passed and BufferLen(Compressed) < CursorPosition then
				local UncompressedSize = BufferLen(FinalPayload)
				FinalPayload = Compressed
				IsCompressed = true
				PerformanceStats.CompressionSavings += (UncompressedSize - BufferLen(Compressed))
			end
		end

		local PayloadLength = BufferLen(FinalPayload)
		local Header = BufferCreate(7 + PayloadLength)
		BufferWriteU8(Header, 0, IonVersion)
		BufferWriteU32(Header, 1, Hash)
		BufferWriteU8(Header, 5, IsCompressed and 1 or 0)
		BufferWriteU8(Header, 6, SchemaVersion)
		BufferCopy(Header, 7, FinalPayload, 0, PayloadLength)

		return Header, InstanceAccumulator, nil
	end

	local PayloadBuffer = AcquireBuffer(1024)
	local CursorPosition = 0

	local InstanceAccumulator = table.create(4)
	local InstanceLookUp = {}

	local Passed, ErrorMessage = pcall(function()
		for Index = 1, SchemaLenght do
			local Serializer = Schema[Index]
			PayloadBuffer, CursorPosition =
				Serializer.Write(PayloadBuffer, CursorPosition, Args[Index], InstanceAccumulator, InstanceLookUp)
		end
	end)

	if not Passed then
		ReleaseBuffer(PayloadBuffer)
		return nil, nil, tostring(ErrorMessage)
	end

	local FinalPayload = BufferCreate(CursorPosition)
	BufferCopy(FinalPayload, 0, PayloadBuffer, 0, CursorPosition)
	ReleaseBuffer(PayloadBuffer)

	local IsCompressed = false

	if UseCompression and CursorPosition > CompressThreshold then
		local Passed, Compressed = pcall(function()
			return EncodingService:CompressBuffer(FinalPayload, Enum.CompressionAlgorithm.Zstd)
		end)

		if Passed and BufferLen(Compressed) < CursorPosition then
			local UncompressedSize = BufferLen(FinalPayload)
			FinalPayload = Compressed
			IsCompressed = true
			PerformanceStats.CompressionSavings += (UncompressedSize - BufferLen(Compressed))
		end
	end

	local PayloadLength = BufferLen(FinalPayload)
	local Header = BufferCreate(7 + PayloadLength)
	BufferWriteU8(Header, 0, IonVersion)
	BufferWriteU32(Header, 1, Hash)
	BufferWriteU8(Header, 5, IsCompressed and 1 or 0)
	BufferWriteU8(Header, 6, SchemaVersion)
	BufferCopy(Header, 7, FinalPayload, 0, PayloadLength)

	return Header, InstanceAccumulator, nil
end


local function GetStubPacket()
	return {
		Server = {
			SendTo = function(...) return false end,
			SendToAll = function(...) return false end,
			SendToAllExcept = function(...) return false end,
			SendToList = function(R: { Player }, ...: any): { Player } return R end,
			Listen = function(...) return { Disconnect = function() end } end
		},
		Client = {
			Send = function(...) return false end,
			Listen = function(...) return { Disconnect = function() end } end
		},
		Destroy = function() end
	}
end

function Ion.Define(Namespace : string, Schema : { TypeSerializer<any> }, Options : IonDefinitionOptions?): IonPacket<...any>
	local Success, Result = pcall(function()
		if (Namespace :: any) == nil or Namespace == "" or #Namespace == 0 then
			error(string.format("[%s] Namespace cannot be empty", IonErrorCodes.INVALID_CONFIG))
		end

		local TrimmedNamespace = Namespace:match("^%s*(.-)%s*$")
		if TrimmedNamespace and Namespace ~= TrimmedNamespace then
			warn("Ion: Namespace has leading/trailing whitespace - trimming")
			Namespace = TrimmedNamespace or ""
		end
		if (Namespace :: any) == "" then
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
		if type(SchemaVersion) ~= "number" or SchemaVersion ~= math.floor(SchemaVersion) then
			error(string.format("[%s] SchemaVersion must be an integer", IonErrorCodes.INVALID_CONFIG))
		end
		if SchemaVersion < 0 or SchemaVersion > 255 then
			error(string.format("[%s] SchemaVersion must be 0-255", IonErrorCodes.INVALID_CONFIG))
		end

		local RemoteTimeout = Options and Options.RemoteTimeout or 10
		local RateLimitConfig = Options and Options.RateLimit
		local RateLimitState = if RateLimitConfig then {
			History = {},
			WindowStart = 0
		} else nil

		Definitions[Hash] = Schema
		ActivePackets[Hash] = { 
			Namespace = Namespace, 
			Created = os.time(), 
			IsDestroyed = false,
			Generation = 1,
			ClientRateLimitState = RateLimitState,
			ServerRateLimitState = {}
		}

		local IsUnreliable = Options and Options.Unreliable or false
		local UseCompression = Options and Options.Compress or false
		local CompressThreshold = Options and Options.CompressionThreshold or CompressionThreshold
		local Hooks = Options and Options.Middleware
		local RemoteName = "Ion_".. Hash

		local function OnEvent(Player : Player | buffer, Data : buffer | {Instance}?, Instances : {Instance}?)
			local PacketData = ActivePackets[Hash]
			if not PacketData or PacketData.IsDestroyed then return end

			local SourceBuffer = if RunService:IsServer() then Data :: buffer else Player :: buffer
			local SourceInstances = if RunService:IsServer() then Instances :: {Instance} else Data :: {Instance}
			local CursorPosition = 0
			local StartTime = os.clock()

			if RunService:IsServer() and RateLimitConfig then
				local Sender = Player :: Player
				local UserId = Sender.UserId

				if not PacketData.ServerRateLimitState then PacketData.ServerRateLimitState = {} end
				local ServerState = PacketData.ServerRateLimitState
				if not ServerState then return end

				local PlayerState = ServerState[UserId]

				if not PlayerState then
					PlayerState = { History = {}, WindowStart = 0 }
					ServerState[UserId] = PlayerState
				end

				local Now = os.clock()
				if Now - PlayerState.WindowStart > RateLimitConfig.Window then
					PlayerState.History = {}
					PlayerState.WindowStart = Now
				end

				local Cutoff = Now - RateLimitConfig.Window
				for Index = #PlayerState.History, 1, -1 do
					if PlayerState.History[Index] < Cutoff then
						table.remove(PlayerState.History, Index)
					end
				end

				if #PlayerState.History >= RateLimitConfig.MaxRequests then
					warn(string.format("[%s] Rate limit exceeded from player %d", IonErrorCodes.RATE_LIMITED, UserId))
					return
				end

				table.insert(PlayerState.History, Now)
			end

			local Success, ErrorOrMessage = pcall(function()
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

					local DecompSuccess, DecompResult = pcall(function() return EncodingService:DecompressBuffer(CompPayload, Enum.CompressionAlgorithm.Zstd) end)
					if not DecompSuccess then error(string.format("[%s] Decompression failed: %s", IonErrorCodes.DECOMPRESSION_FAILED, tostring(DecompResult))) end

					SourceBuffer = DecompResult :: buffer
					CursorPosition = 0
					if BufferLen(SourceBuffer) > MaxBufferSize then error(string.format("[%s] Decompressed payload too large", IonErrorCodes.SIZE_LIMIT_EXCEEDED)) end
				end
				return true
			end)

			if not Success then 
				warn("Ion Packet Error: " .. tostring(ErrorOrMessage)) 
				return 
			end

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
					return true
				end)

				if not ReadSuccess then warn("Ion Read Error: "..tostring(ReadErr)) return end

				RecordPerformance("deserialize", os.clock() - StartTime, BufferLen(SourceBuffer))

				if Hooks and Hooks.OnAfterReceived then
					local OnAfterReceived = Hooks.OnAfterReceived
					local MiddlewareSuccess, MiddlewareErr = pcall(function()
						if RunService:IsServer() then
							OnAfterReceived(Player, table.unpack(Args))
						else
							OnAfterReceived(table.unpack(Args))
						end
						return true
					end)
					if not MiddlewareSuccess then warn("Ion Middleware Error: " .. tostring(MiddlewareErr)) end
				end

				if ActivePackets[Hash].IsDestroyed then return end

				if RunService:IsServer() then Callback(Player, table.unpack(Args)) else Callback(table.unpack(Args)) end
			end
		end

		if RunService:IsServer() then
			local Remote = if IsUnreliable then Instance.new("UnreliableRemoteEvent") else Instance.new("RemoteEvent")
			Remote.Name, Remote.Parent = RemoteName, ReplicatedStorage
			RemoteCache[Hash] = Remote :: any
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
			if not Remote then 
				warn(string.format("[%s] Remote missing for %s - packet will be non-functional", IonErrorCodes.REMOTE_MISSING, Namespace))
				return GetStubPacket()
			end
			RemoteCache[Hash] = Remote :: any
			RemoteConnections[Hash] = (Remote :: any).OnClientEvent:Connect(OnEvent)
		end

		local PacketObject = {}
		
		function PacketObject.SendToAllExcept(Excluded: Player | { Player }, ... : any) : boolean
			local PacketData = ActivePackets[Hash]
			if not PacketData or PacketData.IsDestroyed then return false end

			local Remote : any = RemoteCache[Hash]
			if not Remote or not Remote.Parent then return false end

			local ExcludedMap = {}
			if typeof(Excluded) == "Instance" then
				ExcludedMap[Excluded] = true
			elseif type(Excluded) == "table" then
				for _, p in ipairs(Excluded) do
					ExcludedMap[p] = true
				end
			end

			local Args = table.pack(...)

			if Hooks and Hooks.OnBeforeSend then
				local MiddlewareSuccess, MiddlewareResult = pcall(Hooks.OnBeforeSend, ...)
				if not MiddlewareSuccess then return false end
				if MiddlewareResult == false then return false end
				if type(MiddlewareResult) == "table" then Args = MiddlewareResult end
			end

			local StartTime = os.clock()
			local PacketBuffer, PacketInsts, Err = PreparePacket(Schema, Args, Hash, SchemaVersion, UseCompression, CompressThreshold)
			if not PacketBuffer then return false end

			if IsUnreliable and BufferLen(PacketBuffer) > MaxPacketSize then return false end
			RecordPerformance("serialize", os.clock() - StartTime, BufferLen(PacketBuffer))

			for _, Player in (Players:GetPlayers()) do
				if not ExcludedMap[Player] then
					Remote:FireClient(Player, PacketBuffer, PacketInsts)
				end
			end

			return true
		end

		function PacketObject.Send(Target : Player?, ... : any) : boolean
			local PacketData = ActivePackets[Hash]
			if not PacketData or PacketData.IsDestroyed then return false end

			if not Definitions[Hash] then return false end
			local Remote : any = RemoteCache[Hash]
			if not Remote or not Remote.Parent then return false end

			local Args = table.pack(...)
			if Hooks and Hooks.OnBeforeSend then
				local MiddlewareSuccess, MiddlewareResult = pcall(Hooks.OnBeforeSend, ...)
				if not MiddlewareSuccess then 
					warn("Ion Middleware Error: " .. tostring(MiddlewareResult)) 
					return false 
				end

				if MiddlewareResult == false then 
					return false 
				elseif type(MiddlewareResult) == "table" then 
					Args = MiddlewareResult 
				elseif MiddlewareResult ~= nil and MiddlewareResult ~= true then
					warn(string.format("Ion: OnBeforeSend returned unexpected type '%s' - ignoring", type(MiddlewareResult)))
				end
			end

			if RateLimitConfig and PacketData.ClientRateLimitState then
				local Now = os.clock()
				local State = PacketData.ClientRateLimitState

				if Now - State.WindowStart > RateLimitConfig.Window then
					State.History = {}
					State.WindowStart = Now
				end

				local Cutoff = Now - RateLimitConfig.Window
				for Index = #State.History, 1, -1 do
					if State.History[Index] < Cutoff then
						table.remove(State.History, Index)
					end
				end

				if #State.History >= RateLimitConfig.MaxRequests then
					warn(string.format("[%s] Rate limit exceeded for %s", IonErrorCodes.RATE_LIMITED, Namespace))
					return false
				end

				table.insert(State.History, Now)
			end

			if IsUnreliable then
				local EstSize = 7
				local InstanceCount = 0
				local SizeCheckSuccess = pcall(function() 
					for Index, Serializer in ipairs(Schema) do 
						EstSize += Serializer.GetByteSize(Args[Index])
						if Serializer.ContainsInstances then
							InstanceCount += 1
						end
					end 
					EstSize += InstanceCount * 10
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

		function PacketObject.SendToList(Recipients: { Player }, ...: any): { Player }
			if type(Recipients) ~= "table" then
				warn("Ion: SendToList recipients must be a table")
				return {}
			end
			if #Recipients == 0 then return {} end

			local Args = table.pack(...)
			if Hooks and Hooks.OnBeforeSend then
				local MiddlewareSuccess, MiddlewareResult = pcall(Hooks.OnBeforeSend, ...)
				if not MiddlewareSuccess then 
					warn("Ion Middleware Error: " .. tostring(MiddlewareResult)) 
					return Recipients 
				end

				if MiddlewareResult == false then 
					return Recipients 
				elseif type(MiddlewareResult) == "table" then 
					Args = MiddlewareResult 
				end
			end

			local PacketBuffer, PacketInsts, Err = PreparePacket(Schema, Args, Hash, SchemaVersion, UseCompression, CompressThreshold)
			if not PacketBuffer then warn(Err) return Recipients end

			if IsUnreliable and BufferLen(PacketBuffer) > MaxPacketSize then return Recipients end

			local Failed: { Player } = {}
			local Remote : any = RemoteCache[Hash]
			for _, Player in ipairs(Recipients) do
				if Player and Player.Parent then 
					local SendSuccess = pcall(function()
						Remote:FireClient(Player, PacketBuffer, PacketInsts) 
					end)
					if not SendSuccess then
						DebugLog("SendToList failed for player: " .. tostring(Player), "WARN")
						table.insert(Failed, Player)
					end
				else 
					table.insert(Failed, Player :: Player) 
				end
			end
			return Failed
		end

		function PacketObject.Listen(Callback) 
			Listeners[Hash] = Callback 

			return {
				Disconnect = function()
					if Listeners[Hash] == Callback then
						Listeners[Hash] = nil
					end
				end
			}
		end

		function PacketObject.Destroy()
			local PacketData = ActivePackets[Hash]
			if not PacketData or PacketData.IsDestroyed then return end

			DebugLog("Destroying Packet "..Namespace, "INFO")
			PacketData.IsDestroyed = true

			Listeners[Hash] = nil
			local Connection = RemoteConnections[Hash]
			if Connection then Connection:Disconnect() end
			RemoteConnections[Hash] = nil

			local Remote = RemoteCache[Hash]
			if Remote and typeof(Remote) == "Instance" and Remote.Parent then Remote:Destroy() end

			RemoteCache[Hash] = nil
			Definitions[Hash] = nil
			ActivePackets[Hash] = nil
		end

		return {
			Server = { 
				SendTo = function(Player,...) return PacketObject.Send(Player,...) end, 
				SendToAll = function(...) return PacketObject.Send(nil,...) end, 
				SendToAllExcept = PacketObject.SendToAllExcept,
				SendToList = PacketObject.SendToList, 
				Listen = PacketObject.Listen 
			},
			Client = { 
				Send = function(...) return PacketObject.Send(nil,...) end, 
				Listen = PacketObject.Listen
			},
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