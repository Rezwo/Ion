--!strict
--!native
--!optimize 2

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local EncodingService = game:GetService("EncodingService")

-- Buffer optimizations
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

-- Bitwise optimizations
local Bit32LShift = bit32.lshift
local Bit32RShift = bit32.rshift
local Bit32Band = bit32.band
local Bit32BTest = bit32.btest
local Bit32Xor = bit32.bxor
local Bit32Or = bit32.bor

-- Math optimizations
local MathFrexp = math.frexp
local MathLdexp = math.ldexp
local MathFloor = math.floor
local MathRound = math.round
local MathClamp = math.clamp
local MathAbs = math.abs
local MathMax = math.max

-- Constants
local IonVersion : number = 1
local MaxPacketSize : number = 900
local MaxCollectionSize : number = 100000 -- Limit collection size to prevent DoS
local MaxStringSize : number = 1000000 -- 1MB Limit
local CompressionThreshold : number = 128 -- Bytes
local CompressionRatioEstimate : number = 0.7 -- Estimated ratio for size checks
local PoolCapacity : number = 64
local PoolBufferSize : number = 4096
local MaxSafeInteger : number = 9007199254740992 -- 2^53
local EulerScalingFactor : number = 10430.2191955 -- Scaling for CFrameFloat16
local MaxEnumCacheSize : number = 100

local BufferPool : { buffer } = {}
local BufferPoolInitialized : boolean = false
local EnumSerializerCache : { [any] : any } = {} -- Cache for UseEnum serializers

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

local function InitializeBufferPool()
	if BufferPoolInitialized then return end
	for PoolIndex : number = 1, PoolCapacity do
		table.insert(BufferPool, BufferCreate(PoolBufferSize))
	end
	BufferPoolInitialized = true
end

local function AcquireBuffer(MinimumSize : number) : buffer
	InitializeBufferPool()
	if MinimumSize > PoolBufferSize then
		return BufferCreate(MinimumSize)
	end
	return table.remove(BufferPool) or BufferCreate(PoolBufferSize)
end

local function ReleaseBuffer(BufferToRelease : buffer)
	if BufferLen(BufferToRelease) >= PoolBufferSize and #BufferPool < PoolCapacity then
		-- Clear entire buffer data to prevent info leaks
		BufferFill(BufferToRelease, 0, 0, BufferLen(BufferToRelease))
		table.insert(BufferPool, BufferToRelease)
	end
end

local function EnsureCapacity(TargetBuffer : buffer, CursorPosition : number, Size : number) : buffer
	local CurrentLength : number = BufferLen(TargetBuffer)
	if CursorPosition + Size > CurrentLength then
		local NewLength : number = MathMax(CurrentLength * 2, CursorPosition + Size)
		local NewBuffer : buffer = BufferCreate(NewLength)
		BufferCopy(NewBuffer, 0, TargetBuffer, 0, CurrentLength)
		
		-- CRITICAL FIX: Always release the old buffer. 
		-- ReleaseBuffer handles validation internally.
		ReleaseBuffer(TargetBuffer)
		
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

local function WriteFloat16(TargetBuffer : buffer, CursorPosition : number, Value : number)
	local Sign : number = if Value < 0 then 0x8000 else 0
	Value = MathAbs(Value)
	local Encoded : number = 0
	
	if Value >= 65504 then
		Encoded = Sign + 0x7C00
	elseif Value ~= 0 then
		local Mantissa : number, Exponent : number = MathFrexp(Value)
		Exponent += 14

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
		local Clamped = MathClamp(Value or 0, 0, 255)
		BufferWriteU8(TargetBuffer, CursorPosition, Clamped)
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
		local Clamped = MathClamp(Value or 0, 0, 65535)
		BufferWriteU16(TargetBuffer, CursorPosition, Clamped)
		return TargetBuffer, CursorPosition + 2
	end,
	Read = function(TargetBuffer, CursorPosition)
		CheckBounds(TargetBuffer, CursorPosition, 2)
		return BufferReadU16(TargetBuffer, CursorPosition), CursorPosition + 2
	end
} :: TypeSerializer<number>

DataTypes.UInt24 = {
	IsDynamic = false, ContainsInstances = false,
	GetByteSize = function(_ : number) : number return 3 end,
	Write = function(TargetBuffer, CursorPosition, Value) 
		TargetBuffer = EnsureCapacity(TargetBuffer, CursorPosition, 3)
		local Clamped : number = MathClamp(Value or 0, 0, 16777215)
		BufferWriteU8(TargetBuffer, CursorPosition, Bit32Band(Clamped, 0xFF))
		BufferWriteU8(TargetBuffer, CursorPosition + 1, Bit32Band(Bit32RShift(Clamped, 8), 0xFF))
		BufferWriteU8(TargetBuffer, CursorPosition + 2, Bit32Band(Bit32RShift(Clamped, 16), 0xFF))
		return TargetBuffer, CursorPosition + 3 
	end,
	Read = function(TargetBuffer, CursorPosition) 
		CheckBounds(TargetBuffer, CursorPosition, 3)
		local Byte1 : number = BufferReadU8(TargetBuffer, CursorPosition)
		local Byte2 : number = BufferReadU8(TargetBuffer, CursorPosition + 1)
		local Byte3 : number = BufferReadU8(TargetBuffer, CursorPosition + 2)
		return Byte1 + Bit32LShift(Byte2, 8) + Bit32LShift(Byte3, 16), CursorPosition + 3 
	end
} :: TypeSerializer<number>

DataTypes.UInt32 = {
	IsDynamic = false, ContainsInstances = false,
	GetByteSize = function(_ : number) : number return 4 end,
	Write = function(TargetBuffer, CursorPosition, Value)
		TargetBuffer = EnsureCapacity(TargetBuffer, CursorPosition, 4)
		local Clamped = MathClamp(Value or 0, 0, 4294967295)
		BufferWriteU32(TargetBuffer, CursorPosition, Clamped)
		return TargetBuffer, CursorPosition + 4
	end,
	Read = function(TargetBuffer, CursorPosition)
		CheckBounds(TargetBuffer, CursorPosition, 4)
		return BufferReadU32(TargetBuffer, CursorPosition), CursorPosition + 4
	end
} :: TypeSerializer<number>

DataTypes.UInt64 = {
	IsDynamic = false, ContainsInstances = false,
	GetByteSize = function(_ : any) : number return 8 end,
	Write = function(TargetBuffer, CursorPosition, Value)
		TargetBuffer = EnsureCapacity(TargetBuffer, CursorPosition, 8)
		local Upper : number
		local Lower : number

		if type(Value) == "table" then
			Upper = Value.Upper or 0
			Lower = Value.Lower or 0
		elseif type(Value) == "string" then
			local NumberValue : number = tonumber(Value) or 0
			if NumberValue > MaxSafeInteger then 
				error("Ion: UInt64 string-to-number precision loss detected for value: "..Value) 
			end
			Upper = MathFloor(NumberValue / 4294967296)
			Lower = NumberValue % 4294967296
		else
			local NumberValue : number = tonumber(Value) or 0
			if NumberValue > MaxSafeInteger then
				error("Ion: Precision loss for UInt64 number ("..tostring(NumberValue).."). Use String or Int64Struct.")
			end
			Upper = MathFloor(NumberValue / 4294967296)
			Lower = NumberValue % 4294967296
		end

		BufferWriteU32(TargetBuffer, CursorPosition, Upper)
		BufferWriteU32(TargetBuffer, CursorPosition + 4, Lower)
		return TargetBuffer, CursorPosition + 8
	end,
	Read = function(TargetBuffer, CursorPosition)
		CheckBounds(TargetBuffer, CursorPosition, 8)
		local Upper : number = BufferReadU32(TargetBuffer, CursorPosition)
		local Lower : number = BufferReadU32(TargetBuffer, CursorPosition + 4)
		return { Upper = Upper, Lower = Lower }, CursorPosition + 8
	end
} :: TypeSerializer<Int64Struct | number | string>

DataTypes.Int8 = {
	IsDynamic = false, ContainsInstances = false,
	GetByteSize = function(_ : number) : number return 1 end,
	Write = function(TargetBuffer, CursorPosition, Value) 
		TargetBuffer = EnsureCapacity(TargetBuffer, CursorPosition, 1)
		BufferWriteI8(TargetBuffer, CursorPosition, Value or 0)
		return TargetBuffer, CursorPosition + 1 
	end,
	Read = function(TargetBuffer, CursorPosition) 
		CheckBounds(TargetBuffer, CursorPosition, 1)
		return BufferReadI8(TargetBuffer, CursorPosition), CursorPosition + 1 
	end
} :: TypeSerializer<number>

DataTypes.Int16 = {
	IsDynamic = false, ContainsInstances = false,
	GetByteSize = function(_ : number) : number return 2 end,
	Write = function(TargetBuffer, CursorPosition, Value) 
		TargetBuffer = EnsureCapacity(TargetBuffer, CursorPosition, 2)
		BufferWriteI16(TargetBuffer, CursorPosition, Value or 0)
		return TargetBuffer, CursorPosition + 2 
	end,
	Read = function(TargetBuffer, CursorPosition) 
		CheckBounds(TargetBuffer, CursorPosition, 2)
		return BufferReadI16(TargetBuffer, CursorPosition), CursorPosition + 2 
	end
} :: TypeSerializer<number>

DataTypes.Int32 = {
	IsDynamic = false, ContainsInstances = false,
	GetByteSize = function(_ : number) : number return 4 end,
	Write = function(TargetBuffer, CursorPosition, Value) 
		TargetBuffer = EnsureCapacity(TargetBuffer, CursorPosition, 4)
		BufferWriteI32(TargetBuffer, CursorPosition, Value or 0)
		return TargetBuffer, CursorPosition + 4 
	end,
	Read = function(TargetBuffer, CursorPosition) 
		CheckBounds(TargetBuffer, CursorPosition, 4)
		return BufferReadI32(TargetBuffer, CursorPosition), CursorPosition + 4 
	end
} :: TypeSerializer<number>

DataTypes.Int64 = {
	IsDynamic = false, ContainsInstances = false,
	GetByteSize = function(_ : any) : number return 8 end,
	Write = function(TargetBuffer, CursorPosition, Value)
		TargetBuffer = EnsureCapacity(TargetBuffer, CursorPosition, 8)
		local High : number
		local Low : number

		if type(Value) == "table" then
			High = Value.Upper or 0
			Low = Value.Lower or 0
		elseif type(Value) == "string" then
			-- Improved: Explicit string handling for consistency
			local NumberValue : number = tonumber(Value) or 0
			if MathAbs(NumberValue) > MaxSafeInteger then 
				error("Ion: Int64 string-to-number precision loss detected for value: "..Value) 
			end
			High = MathFloor(NumberValue / 4294967296)
			Low = NumberValue % 4294967296
		else
			local NumberValue : number = tonumber(Value) or 0
			if MathAbs(NumberValue) > MaxSafeInteger then
				error("Ion: Precision loss for Int64 number ("..tostring(NumberValue).."). Use String or Int64Struct.")
			end
			High = MathFloor(NumberValue / 4294967296)
			Low = NumberValue % 4294967296
		end

		BufferWriteI32(TargetBuffer, CursorPosition, High)
		BufferWriteU32(TargetBuffer, CursorPosition + 4, Low)
		return TargetBuffer, CursorPosition + 8
	end,
	Read = function(TargetBuffer, CursorPosition)
		CheckBounds(TargetBuffer, CursorPosition, 8)
		local High : number = BufferReadI32(TargetBuffer, CursorPosition)
		local Low : number = BufferReadU32(TargetBuffer, CursorPosition + 4)
		return { Upper = High, Lower = Low }, CursorPosition + 8
	end
} :: TypeSerializer<Int64Struct | number | string>

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
		if Length > MaxStringSize then error("Ion: String too large") end
		TargetBuffer = EnsureCapacity(TargetBuffer, CursorPosition, 4 + Length)
		BufferWriteU32(TargetBuffer, CursorPosition, Length)
		BufferWriteString(TargetBuffer, CursorPosition + 4, Value)
		return TargetBuffer, CursorPosition + 4 + Length
	end,
	Read = function(TargetBuffer, CursorPosition)
		CheckBounds(TargetBuffer, CursorPosition, 4)
		local Length : number = BufferReadU32(TargetBuffer, CursorPosition)
		if Length > MaxStringSize then error("Ion: String too large") end
		CheckBounds(TargetBuffer, CursorPosition + 4, Length)
		return BufferReadString(TargetBuffer, CursorPosition + 4, Length), CursorPosition + 4 + Length
	end
} :: TypeSerializer<string>

DataTypes.ShortString = {
	IsDynamic = true, ContainsInstances = false,
	GetByteSize = function(Value : string) : number return 1 + #Value end,
	Write = function(TargetBuffer, CursorPosition, Value)
		local Length : number = #Value
		if Length > 255 then error("Ion: ShortString exceeds 255 bytes") end
		TargetBuffer = EnsureCapacity(TargetBuffer, CursorPosition, 1 + Length)
		BufferWriteU8(TargetBuffer, CursorPosition, Length)
		BufferWriteString(TargetBuffer, CursorPosition + 1, Value)
		return TargetBuffer, CursorPosition + 1 + Length
	end,
	Read = function(TargetBuffer, CursorPosition)
		CheckBounds(TargetBuffer, CursorPosition, 1)
		local Length : number = BufferReadU8(TargetBuffer, CursorPosition)
		CheckBounds(TargetBuffer, CursorPosition + 1, Length)
		return BufferReadString(TargetBuffer, CursorPosition + 1, Length), CursorPosition + 1 + Length
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

DataTypes.FixedString = function(Length : number) : TypeSerializer<string>
	return {
		IsDynamic = false, ContainsInstances = false,
		GetByteSize = function(_ : string) : number return Length end,
		Write = function(TargetBuffer, CursorPosition, Value)
			TargetBuffer = EnsureCapacity(TargetBuffer, CursorPosition, Length)
			local StringLength : number = #Value
			if StringLength > Length then
				warn("Ion: FixedString truncated from "..StringLength.." to "..Length.." bytes")
			end
			if StringLength >= Length then
				BufferWriteString(TargetBuffer, CursorPosition, Value, Length)
			else
				BufferWriteString(TargetBuffer, CursorPosition, Value)
				for Offset : number = StringLength, Length - 1 do
					BufferWriteU8(TargetBuffer, CursorPosition + Offset, 0)
				end
			end
			return TargetBuffer, CursorPosition + Length
		end,
		Read = function(TargetBuffer, CursorPosition)
			CheckBounds(TargetBuffer, CursorPosition, Length)
			local RawString : string = BufferReadString(TargetBuffer, CursorPosition, Length)
			local NullPos = string.find(RawString, "\0")
			if NullPos then
				return string.sub(RawString, 1, NullPos - 1), CursorPosition + Length
			end
			return RawString, CursorPosition + Length
		end
	}
end

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
	if EnumSerializerCache[EnumType] then return EnumSerializerCache[EnumType] end
	
	local EnumMap : { [number] : EnumItem } = {}
	local Items = EnumType:GetEnumItems()
	local DefaultItem = Items[1]
	for _, Item in ipairs(Items) do EnumMap[Item.Value] = Item end

	local Serializer = {
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
	EnumSerializerCache[EnumType] = Serializer
	return Serializer
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

DataTypes.Vector3Int16 = {
	IsDynamic = false, ContainsInstances = false,
	GetByteSize = function(_ : Vector3) : number return 6 end,
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

DataTypes.CFrameFloat16 = {
	IsDynamic = false, ContainsInstances = false,
	GetByteSize = function(_ : CFrame) : number return 12 end,
	Write = function(TargetBuffer, CursorPosition, Value)
		TargetBuffer = EnsureCapacity(TargetBuffer, CursorPosition, 12)
		WriteFloat16(TargetBuffer, CursorPosition, Value.X)
		WriteFloat16(TargetBuffer, CursorPosition + 2, Value.Y)
		WriteFloat16(TargetBuffer, CursorPosition + 4, Value.Z)

		local EulerX : number, EulerY : number, EulerZ : number = Value:ToEulerAnglesXYZ()
		BufferWriteI16(TargetBuffer, CursorPosition + 6, MathClamp(MathRound(EulerX * EulerScalingFactor), -32768, 32767))
		BufferWriteI16(TargetBuffer, CursorPosition + 8, MathClamp(MathRound(EulerY * EulerScalingFactor), -32768, 32767))
		BufferWriteI16(TargetBuffer, CursorPosition + 10, MathClamp(MathRound(EulerZ * EulerScalingFactor), -32768, 32767))
		return TargetBuffer, CursorPosition + 12
	end,
	Read = function(TargetBuffer, CursorPosition)
		CheckBounds(TargetBuffer, CursorPosition, 12)
		local PositionX : number = ReadFloat16(TargetBuffer, CursorPosition)
		local PositionY : number = ReadFloat16(TargetBuffer, CursorPosition + 2)
		local PositionZ : number = ReadFloat16(TargetBuffer, CursorPosition + 4)
		local EulerX : number = BufferReadI16(TargetBuffer, CursorPosition + 6) / EulerScalingFactor
		local EulerY : number = BufferReadI16(TargetBuffer, CursorPosition + 8) / EulerScalingFactor
		local EulerZ : number = BufferReadI16(TargetBuffer, CursorPosition + 10) / EulerScalingFactor

		return CFrame.fromEulerAnglesXYZ(EulerX, EulerY, EulerZ) + Vector3.new(PositionX, PositionY, PositionZ), CursorPosition + 12
	end
} :: TypeSerializer<CFrame>

DataTypes.Vector2 = {
	IsDynamic = false, ContainsInstances = false,
	GetByteSize = function(_ : Vector2) : number return 8 end,
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
} :: TypeSerializer<Vector2>

DataTypes.Color3 = {
	IsDynamic = false, ContainsInstances = false,
	GetByteSize = function(_ : Color3) : number return 3 end,
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
	GetByteSize = function(_ : UDim2) : number return 16 end,
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
} :: TypeSerializer<UDim2>

DataTypes.DateTime = {
	IsDynamic = false, ContainsInstances = false,
	GetByteSize = function(_ : DateTime) : number return 8 end,
	Write = function(TargetBuffer, CursorPosition, Value)
		TargetBuffer = EnsureCapacity(TargetBuffer, CursorPosition, 8)
		local NumberValue : number = Value.UnixTimestampMillis
		local Upper : number = MathFloor(NumberValue / 4294967296)
		local Lower : number = NumberValue % 4294967296
		BufferWriteU32(TargetBuffer, CursorPosition, Upper)
		BufferWriteU32(TargetBuffer, CursorPosition + 4, Lower)
		return TargetBuffer, CursorPosition + 8
	end,
	Read = function(TargetBuffer, CursorPosition)
		CheckBounds(TargetBuffer, CursorPosition, 8)
		local Upper : number = BufferReadU32(TargetBuffer, CursorPosition)
		local Lower : number = BufferReadU32(TargetBuffer, CursorPosition + 4)
		return DateTime.fromUnixTimestampMillis(Upper * 4294967296 + Lower), CursorPosition + 8
	end
} :: TypeSerializer<DateTime>

DataTypes.Buffer = {
	IsDynamic = true, ContainsInstances = false,
	GetByteSize = function(Value : buffer) : number return 4 + BufferLen(Value) end,
	Write = function(TargetBuffer, CursorPosition, Value)
		local Length : number = BufferLen(Value)
		TargetBuffer = EnsureCapacity(TargetBuffer, CursorPosition, 4 + Length)
		BufferWriteU32(TargetBuffer, CursorPosition, Length)
		BufferCopy(TargetBuffer, CursorPosition + 4, Value, 0, Length)
		return TargetBuffer, CursorPosition + 4 + Length
	end,
	Read = function(TargetBuffer, CursorPosition)
		CheckBounds(TargetBuffer, CursorPosition, 4)
		local Length : number = BufferReadU32(TargetBuffer, CursorPosition)
		if Length > 10485760 then error("Ion: Buffer too large") end
		CheckBounds(TargetBuffer, CursorPosition + 4, Length)
		local NewBuffer : buffer = BufferCreate(Length)
		BufferCopy(NewBuffer, 0, TargetBuffer, CursorPosition + 4, Length)
		return NewBuffer, CursorPosition + 4 + Length
	end
} :: TypeSerializer<buffer>

function DataTypes.Array<T>(Inner : TypeSerializer<T>) : TypeSerializer<{ T }>
	if Inner.IsUnbounded then error("Ion: RestOfString cannot be used inside Array") end
	return {
		IsDynamic = true, ContainsInstances = Inner.ContainsInstances,
		GetByteSize = function(Value : { T }) : number
			if not Inner.IsDynamic then
				return 4 + (#Value * Inner.GetByteSize(nil :: any))
			end
			local Size : number = 4
			for _, Item : T in ipairs(Value) do Size += Inner.GetByteSize(Item) end
			return Size
		end,
		Write = function(TargetBuffer, CursorPosition, Value, InstanceAccumulator, InstanceLookup)
			local Count : number = #Value
			TargetBuffer = EnsureCapacity(TargetBuffer, CursorPosition, 4)
			BufferWriteU32(TargetBuffer, CursorPosition, Count)
			CursorPosition += 4
			for Index : number = 1, Count do 
				TargetBuffer, CursorPosition = Inner.Write(TargetBuffer, CursorPosition, Value[Index], InstanceAccumulator, InstanceLookup) 
			end
			return TargetBuffer, CursorPosition
		end,
		Read = function(TargetBuffer, CursorPosition, InstanceSource)
			CheckBounds(TargetBuffer, CursorPosition, 4)
			local Count : number = BufferReadU32(TargetBuffer, CursorPosition)
			if Count > MaxCollectionSize then error("Ion: Array too large ("..Count.." > "..MaxCollectionSize..")") end
			CursorPosition += 4
			local Result : { T } = table.create(Count)
			for Index : number = 1, Count do 
				local Item : T
				Item, CursorPosition = Inner.Read(TargetBuffer, CursorPosition, InstanceSource)
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
		GetByteSize = function(Value : { [K] : V }) : number
			local Size : number = 4
			for Key : K, Val : V in pairs(Value) do Size += KeyType.GetByteSize(Key) + ValType.GetByteSize(Val) end
			return Size
		end,
		Write = function(TargetBuffer, CursorPosition, Value, InstanceAccumulator, InstanceLookup)
			local Count : number = 0
			for _ in pairs(Value) do Count += 1 end
			
			if Count > MaxCollectionSize then 
				error("Ion: Map too large ("..Count.." > "..MaxCollectionSize..")") 
			end
			
			TargetBuffer = EnsureCapacity(TargetBuffer, CursorPosition, 4)
			BufferWriteU32(TargetBuffer, CursorPosition, Count)
			CursorPosition += 4
			for Key : K, Val : V in pairs(Value) do 
				TargetBuffer, CursorPosition = KeyType.Write(TargetBuffer, CursorPosition, Key, InstanceAccumulator, InstanceLookup)
				TargetBuffer, CursorPosition = ValType.Write(TargetBuffer, CursorPosition, Val, InstanceAccumulator, InstanceLookup) 
			end
			return TargetBuffer, CursorPosition
		end,
		Read = function(TargetBuffer, CursorPosition, InstanceSource)
			CheckBounds(TargetBuffer, CursorPosition, 4)
			local Count : number = BufferReadU32(TargetBuffer, CursorPosition)
			if Count > MaxCollectionSize then error("Ion: Map too large ("..Count.." > "..MaxCollectionSize..")") end
			CursorPosition += 4
			local Result : { [K] : V } = {}
			for Index : number = 1, Count do 
				local Key : K, Val : V
				Key, CursorPosition = KeyType.Read(TargetBuffer, CursorPosition, InstanceSource)
				Val, CursorPosition = ValType.Read(TargetBuffer, CursorPosition, InstanceSource)
				Result[Key] = Val 
			end
			return Result, CursorPosition
		end
	}
end

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
		GetByteSize = function(Value : { [string] : any }) : number
			if not IsDynamic then
				local Size = 0
				for _, Key in ipairs(SortedKeys) do
					Size += StructureDefinition[Key].GetByteSize(nil :: any)
				end
				return Size
			else
				local Size = 0
				for _, Key in ipairs(SortedKeys) do
					Size += StructureDefinition[Key].GetByteSize(Value[Key])
				end
				return Size
			end
		end,
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

local AnyEnumCache : { [any] : { [number] : EnumItem } } = {}
local EnumCacheOrder : { any } = {}

DataTypes.Any = {
	IsDynamic = true, ContainsInstances = true,
	GetByteSize = function(Value : any) : number
		local T = typeof(Value)
		if T == "number" then return 9
		elseif T == "string" then return 5 + #Value
		elseif T == "boolean" then return 2
		elseif T == "Instance" then return 3
		elseif T == "Vector3" then return 13
		elseif T == "CFrame" then return 25
		elseif T == "Vector2" then return 9
		elseif T == "Color3" then return 4
		elseif T == "UDim2" then return 17
		elseif T == "DateTime" then return 9
		elseif T == "buffer" then return 5 + BufferLen(Value)
		elseif T == "EnumItem" then return 7 + #(tostring(Value.EnumType))
		else return 1 end
	end,
	Write = function(TargetBuffer, CursorPosition, Val, InstAcc, InstLook)
		local T = typeof(Val)
		TargetBuffer = EnsureCapacity(TargetBuffer, CursorPosition, 1)
		if Val == nil then BufferWriteU8(TargetBuffer, CursorPosition, 0) return TargetBuffer, CursorPosition + 1
		elseif T == "boolean" then BufferWriteU8(TargetBuffer, CursorPosition, 1) return DataTypes.Boolean.Write(TargetBuffer, CursorPosition + 1, Val)
		elseif T == "number" then BufferWriteU8(TargetBuffer, CursorPosition, 2) return DataTypes.Float64.Write(TargetBuffer, CursorPosition + 1, Val)
		elseif T == "string" then BufferWriteU8(TargetBuffer, CursorPosition, 3) return DataTypes.String.Write(TargetBuffer, CursorPosition + 1, Val)
		elseif T == "Instance" then BufferWriteU8(TargetBuffer, CursorPosition, 4) return DataTypes.Instance.Write(TargetBuffer, CursorPosition + 1, Val, InstAcc, InstLook)
		elseif T == "Vector3" then BufferWriteU8(TargetBuffer, CursorPosition, 5) return DataTypes.Vector3.Write(TargetBuffer, CursorPosition + 1, Val)
		elseif T == "CFrame" then BufferWriteU8(TargetBuffer, CursorPosition, 7) return DataTypes.CFrame.Write(TargetBuffer, CursorPosition + 1, Val)
		elseif T == "Vector2" then BufferWriteU8(TargetBuffer, CursorPosition, 8) return DataTypes.Vector2.Write(TargetBuffer, CursorPosition + 1, Val)
		elseif T == "Color3" then BufferWriteU8(TargetBuffer, CursorPosition, 9) return DataTypes.Color3.Write(TargetBuffer, CursorPosition + 1, Val)
		elseif T == "UDim2" then BufferWriteU8(TargetBuffer, CursorPosition, 10) return DataTypes.UDim2.Write(TargetBuffer, CursorPosition + 1, Val)
		elseif T == "DateTime" then BufferWriteU8(TargetBuffer, CursorPosition, 11) return DataTypes.DateTime.Write(TargetBuffer, CursorPosition + 1, Val)
		elseif T == "buffer" then BufferWriteU8(TargetBuffer, CursorPosition, 12) return DataTypes.Buffer.Write(TargetBuffer, CursorPosition + 1, Val)
		elseif T == "EnumItem" then
			BufferWriteU8(TargetBuffer, CursorPosition, 6)
			TargetBuffer, CursorPosition = DataTypes.String.Write(TargetBuffer, CursorPosition + 1, tostring(Val.EnumType))
			BufferWriteU16(TargetBuffer, CursorPosition, Val.Value)
			return TargetBuffer, CursorPosition + 2
		else
			error("Ion: Unsupported Any type " .. T)
		end
	end,
	Read = function(TargetBuffer, CursorPosition, InstSrc)
		-- Type IDs: 0=nil, 1=boolean, 2=number, 3=string, 4=Instance, 5=Vector3, 
		--           6=EnumItem, 7=CFrame, 8=Vector2, 9=Color3, 10=UDim2, 
		--           11=DateTime, 12=buffer
		CheckBounds(TargetBuffer, CursorPosition, 1)
		local ID = BufferReadU8(TargetBuffer, CursorPosition)
		CursorPosition += 1
		if ID == 0 then return nil, CursorPosition
		elseif ID == 1 then return DataTypes.Boolean.Read(TargetBuffer, CursorPosition, InstSrc)
		elseif ID == 2 then return DataTypes.Float64.Read(TargetBuffer, CursorPosition, InstSrc)
		elseif ID == 3 then return DataTypes.String.Read(TargetBuffer, CursorPosition, InstSrc)
		elseif ID == 4 then return DataTypes.Instance.Read(TargetBuffer, CursorPosition, InstSrc)
		elseif ID == 5 then return DataTypes.Vector3.Read(TargetBuffer, CursorPosition, InstSrc)
		elseif ID == 7 then return DataTypes.CFrame.Read(TargetBuffer, CursorPosition, InstSrc)
		elseif ID == 8 then return DataTypes.Vector2.Read(TargetBuffer, CursorPosition, InstSrc)
		elseif ID == 9 then return DataTypes.Color3.Read(TargetBuffer, CursorPosition, InstSrc)
		elseif ID == 10 then return DataTypes.UDim2.Read(TargetBuffer, CursorPosition, InstSrc)
		elseif ID == 11 then return DataTypes.DateTime.Read(TargetBuffer, CursorPosition, InstSrc)
		elseif ID == 12 then return DataTypes.Buffer.Read(TargetBuffer, CursorPosition, InstSrc)
		elseif ID == 6 then
			local EName, NextPos = DataTypes.String.Read(TargetBuffer, CursorPosition, InstSrc)
			CheckBounds(TargetBuffer, NextPos, 2)
			local Val = BufferReadU16(TargetBuffer, NextPos)
			local EType = (Enum :: any)[EName]
			if EType then
				local Cache = AnyEnumCache[EType]
				if not Cache then
					if #EnumCacheOrder >= MaxEnumCacheSize then
						local OldestKey = table.remove(EnumCacheOrder, 1)
						AnyEnumCache[OldestKey] = nil
					end
					
					Cache = {}
					for _, Item in ipairs(EType:GetEnumItems()) do Cache[Item.Value] = Item end
					AnyEnumCache[EType] = Cache
					table.insert(EnumCacheOrder, EType)
				end
				return Cache[Val], NextPos + 2
			end
			return nil, NextPos + 2
		else
			error("Ion: Corrupt Any type (ID: " .. ID .. ")")
		end
	end
} :: TypeSerializer<any>

local Definitions : { [number] : { TypeSerializer<any> } } = {}
local Listeners : { [number] : (...any) -> () } = {}
local RemoteCache : { [number] : RemoteEvent | UnreliableRemoteEvent } = {}
local Ion = {}
Ion.Types = DataTypes

function Ion.Define(
	Namespace : string, 
	Schema : { TypeSerializer<any> }, 
	Options : { 
		Unreliable : boolean?, 
		Compress : boolean?, 
		CompressionThreshold : number?,
		Middleware : any?, 
		SchemaVersion : number? 
	}?
)
	local Hash : number = FNV1a(Namespace)
	if Definitions[Hash] then error("Ion: Namespace collision for '".. Namespace.. "'") end
	Definitions[Hash] = Schema
	local IsUnreliable = Options and Options.Unreliable or false
	local UseCompression = Options and Options.Compress or false
	local CompressThreshold = Options and Options.CompressionThreshold or CompressionThreshold
	local Hooks = Options and Options.Middleware
	local SchemaVersion = Options and Options.SchemaVersion or 1
	local RemoteName = "Ion_".. Hash

	local function OnEvent(Player : Player | buffer, Data : buffer | {Instance}?, Instances : {Instance}?)
		local SourceBuffer = if RunService:IsServer() then Data :: buffer else Player :: buffer
		local SourceInstances = if RunService:IsServer() then Instances :: {Instance} else Data :: {Instance}
		local CursorPosition : number = 0
		
		local DeserializeSuccess, ErrorOrResult = pcall(function()
			CheckBounds(SourceBuffer, CursorPosition, 7)
			local Version = BufferReadU8(SourceBuffer, CursorPosition)
			local PacketId = BufferReadU32(SourceBuffer, CursorPosition + 1)
			local Flags = BufferReadU8(SourceBuffer, CursorPosition + 5)
			local InSchemaVersion = BufferReadU8(SourceBuffer, CursorPosition + 6)
			CursorPosition += 7
			
			if Version ~= IonVersion then
				warn("Ion: Version mismatch - Expected "..IonVersion..", got "..Version)
				return false
			elseif PacketId ~= Hash then
				warn("Ion: Packet ID mismatch - Expected "..Hash..", got "..PacketId)
				return false
			elseif InSchemaVersion ~= SchemaVersion then
				warn("Ion: Schema version mismatch for namespace - Expected "..SchemaVersion..", got "..InSchemaVersion)
				return false
			end
			
			if Bit32Band(Flags, 1) == 1 then
				local PayloadSize = BufferLen(SourceBuffer) - 7
				local CompressedPayload = BufferCreate(PayloadSize)
				BufferCopy(CompressedPayload, 0, SourceBuffer, 7, PayloadSize)
				SourceBuffer = EncodingService:DecompressBuffer(CompressedPayload, Enum.CompressionAlgorithm.Zstd)
				CursorPosition = 0
			end
			return true
		end)

		if not DeserializeSuccess then
			warn("Ion: Packet header error - " .. tostring(ErrorOrResult))
			return
		end
		
		if ErrorOrResult == false then return end

		local Callback = Listeners[Hash]
		if Callback then
			local Args : { any } = {}
			local ReadSuccess, ReadError = pcall(function()
				for _, Serializer in ipairs(Schema) do
					local Value, NextPos = Serializer.Read(SourceBuffer, CursorPosition, SourceInstances)
					table.insert(Args, Value)
					CursorPosition = NextPos
				end
			end)
			
			if not ReadSuccess then
				warn("Ion: Deserialization error - " .. tostring(ReadError))
				return
			end
			
			if RunService:IsServer() then
				if Hooks and Hooks.OnAfterReceived then
					local success, err = pcall(Hooks.OnAfterReceived, Player, table.unpack(Args))
					if not success then warn("Ion: Middleware OnAfterReceived error - "..tostring(err)) end
				end
				Callback(Player, table.unpack(Args))
			else
				if Hooks and Hooks.OnAfterReceived then
					local success, err = pcall(Hooks.OnAfterReceived, table.unpack(Args))
					if not success then warn("Ion: Middleware OnAfterReceived error - "..tostring(err)) end
				end
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
		local RetryCount = 0
		local MaxRetries = 5
		
		while not Remote and RetryCount < MaxRetries do
			RetryCount += 1
			warn("Ion: Remote '"..RemoteName.."' not found, retrying... ("..RetryCount.."/"..MaxRetries..")")
			task.wait(2)
			Remote = ReplicatedStorage:FindFirstChild(RemoteName)
		end
		
		if not Remote then 
			error("Ion: Remote '"..RemoteName.."' not found after "..MaxRetries.." retries") 
		end
		
		RemoteCache[Hash] = Remote :: any
		(Remote :: any).OnClientEvent:Connect(OnEvent)
	end

	local PacketObject = {}
	function PacketObject.Send(Target : Player?,... : any) : boolean
		if Hooks and Hooks.OnBeforeSend then
			local success, result = pcall(Hooks.OnBeforeSend, ...)
			if not success then
				warn("Ion: Middleware OnBeforeSend error - "..tostring(result))
				return false
			end
			if not result then return false end
		end
		
		local Args = table.pack(...)
		
		if IsUnreliable then
			local EstimatedSize = 7 -- Header size
			local EstimateSuccess = pcall(function()
				for Index, Serializer in ipairs(Schema) do
					if Serializer.IsDynamic then
						EstimatedSize += Serializer.GetByteSize(Args[Index])
					else
						EstimatedSize += Serializer.GetByteSize(nil :: any)
					end
				end
			end)
			
			if EstimateSuccess then
				if UseCompression and EstimatedSize > CompressThreshold then
					EstimatedSize = math.ceil(EstimatedSize * CompressionRatioEstimate)
				end
				
				if EstimatedSize > MaxPacketSize then
					warn("Ion: Unreliable packet likely too large (estimated "..EstimatedSize.." > "..MaxPacketSize.." bytes)")
				end
			end
		end
		
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
		local FinalPayload = BufferCreate(CursorPosition)
		BufferCopy(FinalPayload, 0, PayloadBuffer, 0, CursorPosition)
		ReleaseBuffer(PayloadBuffer)

		local IsCompressed = false
		if UseCompression and CursorPosition > CompressThreshold then
			FinalPayload = EncodingService:CompressBuffer(FinalPayload, Enum.CompressionAlgorithm.Zstd)
			IsCompressed = true
		end
		
		local PacketBuffer = BufferCreate(7 + BufferLen(FinalPayload))
		BufferWriteU8(PacketBuffer, 0, IonVersion)
		BufferWriteU32(PacketBuffer, 1, Hash)
		BufferWriteU8(PacketBuffer, 5, IsCompressed and 1 or 0)
		BufferWriteU8(PacketBuffer, 6, SchemaVersion)
		BufferCopy(PacketBuffer, 7, FinalPayload, 0, BufferLen(FinalPayload))

		if IsUnreliable and BufferLen(PacketBuffer) > MaxPacketSize then
			warn("Ion: Unreliable packet too large ("..BufferLen(PacketBuffer).." > "..MaxPacketSize.." bytes)")
			return false
		end

		local Remote : any = RemoteCache[Hash]
		if RunService:IsServer() then
			if Target then Remote:FireClient(Target, PacketBuffer, ResultInst) else Remote:FireAllClients(PacketBuffer, ResultInst) end
		else Remote:FireServer(PacketBuffer, ResultInst) end
		return true
	end

	function PacketObject.SendToList(Recipients : { Player }, ... : any) : { Player }
		local Args = table.pack(...)
		local Failed : { Player } = {}
		for _, Player in ipairs(Recipients) do
			if not PacketObject.Send(Player, table.unpack(Args, 1, Args.n)) then
				table.insert(Failed, Player)
			end
		end
		return Failed
	end

	function PacketObject.Listen(Callback) Listeners[Hash] = Callback end
	function PacketObject.Destroy()
		Listeners[Hash] = nil
		if RemoteCache[Hash] then RemoteCache[Hash]:Destroy() RemoteCache[Hash] = nil end
		Definitions[Hash] = nil
	end

	return {
		Server = { 
			SendTo = function(P,...) return PacketObject.Send(P,...) end, 
			SendToAll = function(...) return PacketObject.Send(nil,...) end,
			SendToList = PacketObject.SendToList,
			Listen = PacketObject.Listen 
		},
		Client = { 
			Send = function(...) return PacketObject.Send(nil,...) end, 
			Listen = PacketObject.Listen 
		},
		Destroy = PacketObject.Destroy
	} :: IonPacket<any>
end

return Ion