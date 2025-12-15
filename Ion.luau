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

local IonVersion : number = 1
local MaxPacketSize : number = 900
local MaxCollectionSize : number = 16777215 -- 2^24-1
local CompressionThreshold : number = 128 -- Bytes
local BufferPool : { buffer } = {}
local PoolCapacity : number = 64
local PoolBufferSize : number = 4096

export type IonPacket<T...> = {
	Server : {
		SendTo : (Recipient : Player, T...) -> (),
		SendToAll : (T...) -> (),
		SendToList : (Recipients : { Player }, T...) -> ({ Player }),
		Listen : (Callback : (Player, T...) -> ()) -> ()
	},
	Client : {
		Send : (T...) -> (),
		Listen : (Callback : (T...) -> ()) -> ()
	},
	Destroy : () -> ()
}

export type Int64Struct = { Upper : number, Lower : number }

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
	if BufferLen(BufferToRelease) == PoolBufferSize and #BufferPool < PoolCapacity then
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

local function WriteFloat16(TargetBuffer : buffer, CursorPosition : number, Value : number)
	local Sign : number = if Value < 0 then 0x8000 else 0
	if Value < 0 then Value = -Value end
	
	local Encoded : number = 0
	if Value ~= 0 then
		local Mantissa : number, Exponent : number = MathFrexp(Value)
		Exponent += 14
		
		if Exponent <= 0 then
			if Exponent < -10 then
				Encoded = Sign
			else
				Mantissa = MathLdexp(Mantissa, Exponent + 10)
				Encoded = Sign + MathFloor(Mantissa + 0.5)
			end
		elseif Exponent >= 32 then
			Encoded = Sign + 0x7C00
		else
			local Fractional : number = Mantissa * 2 - 1
			Encoded = Sign + Bit32LShift(Exponent, 10) + MathFloor(Fractional * 1024 + 0.5)
		end
	end
	BufferWriteU16(TargetBuffer, CursorPosition, Encoded)
end

local function ReadFloat16(SourceBuffer : buffer, CursorPosition : number) : number
	local Encoded : number = BufferReadU16(SourceBuffer, CursorPosition)
	local Sign : boolean = Bit32BTest(Encoded, 0x8000)
	local Exponent : number = Bit32RShift(Bit32Band(Encoded, 0x7C00), 10)
	local Mantissa : number = Bit32Band(Encoded, 0x03FF)
	
	if Exponent == 0 then
		if Mantissa == 0 then return 0 end
		local Result : number = MathLdexp(Mantissa, -24) 
		return if Sign then -Result else Result
	elseif Exponent == 31 then
		if Mantissa == 0 then
			return if Sign then -math.huge else math.huge
		else
			return 0/0
		end
	end
	
	local Result : number = MathLdexp(Mantissa + 1024, Exponent - 25)
	return if Sign then -Result else Result
end

export type TypeSerializer<T> = {
	Write : (buffer, number, T, { Instance }, { [Instance] : number }) -> (buffer, number),
	Read : (buffer, number, { Instance }) -> (T, number),
	GetByteSize : (T) -> number,
	IsDynamic : boolean,
	ContainsInstances : boolean
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
		BufferWriteU32(TargetBuffer, CursorPosition, Value or 0)
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
			Upper = MathFloor(NumberValue / 4294967296)
			Lower = NumberValue % 4294967296
		else
			local NumberValue : number = tonumber(Value) or 0
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
		else
			local NumberValue : number = tonumber(Value) or 0
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
	IsDynamic = true, ContainsInstances = false,
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
			return RawString:gsub("%z+$", ""), CursorPosition + Length
		end
	}
end

DataTypes.Instance = {
	IsDynamic = false, ContainsInstances = true,
	GetByteSize = function(_ : Instance) : number return 2 end,
	Write = function(TargetBuffer, CursorPosition, Value, InstanceAccumulator, InstanceLookup)
		TargetBuffer = EnsureCapacity(TargetBuffer, CursorPosition, 2)
		if Value and typeof(Value) == "Instance" and Value:IsDescendantOf(game) then
			local Index : number? = InstanceLookup[Value]
			if Index then 
				BufferWriteU16(TargetBuffer, CursorPosition, Index)
			else
				local NewIndex : number = #InstanceAccumulator + 1
				InstanceAccumulator[NewIndex] = Value
				InstanceLookup[Value] = NewIndex
				BufferWriteU16(TargetBuffer, CursorPosition, NewIndex)
			end
		else 
			BufferWriteU16(TargetBuffer, CursorPosition, 0) 
		end
		return TargetBuffer, CursorPosition + 2
	end,
	Read = function(TargetBuffer, CursorPosition, InstanceSource)
		CheckBounds(TargetBuffer, CursorPosition, 2)
		local Index : number = BufferReadU16(TargetBuffer, CursorPosition)
		local InstanceObject : Instance? = InstanceSource[Index]
		if Index ~= 0 and not InstanceObject then
			warn("Ion: Instance reference " .. Index .. " not found in replication")
			return nil, CursorPosition + 2
		end
		return InstanceObject, CursorPosition + 2
	end
} :: TypeSerializer<Instance>

function DataTypes.UseEnum(EnumType : any) : TypeSerializer<EnumItem>
	return {
		IsDynamic = false, ContainsInstances = false,
		GetByteSize = function(_ : EnumItem) : number return 2 end,
		Write = function(TargetBuffer, CursorPosition, Value) 
			TargetBuffer = EnsureCapacity(TargetBuffer, CursorPosition, 2)
			BufferWriteU16(TargetBuffer, CursorPosition, Value.Value)
			return TargetBuffer, CursorPosition + 2 
		end,
		Read = function(TargetBuffer, CursorPosition) 
			CheckBounds(TargetBuffer, CursorPosition, 2)
			local Value : number = BufferReadU16(TargetBuffer, CursorPosition)
			local EnumItems = EnumType:GetEnumItems()
			for _, Item : EnumItem in ipairs(EnumItems) do
				if Item.Value == Value then return Item, CursorPosition + 2 end
			end
			warn("Ion: Invalid Enum value " .. tostring(Value))
			return EnumItems[1], CursorPosition + 2 
		end
	}
end

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
		local Axis : Vector3 = RotationVector / Angle
		return CFrame.fromAxisAngle(Axis, Angle) + PositionVector, CursorPosition + 24
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
		local ScalingFactor : number = 10430.2191955
		BufferWriteI16(TargetBuffer, CursorPosition + 6, MathClamp(MathRound(EulerX * ScalingFactor), -32768, 32767))
		BufferWriteI16(TargetBuffer, CursorPosition + 8, MathClamp(MathRound(EulerY * ScalingFactor), -32768, 32767))
		BufferWriteI16(TargetBuffer, CursorPosition + 10, MathClamp(MathRound(EulerZ * ScalingFactor), -32768, 32767))
		return TargetBuffer, CursorPosition + 12
	end,
	Read = function(TargetBuffer, CursorPosition)
		CheckBounds(TargetBuffer, CursorPosition, 12)
		local PositionX : number = ReadFloat16(TargetBuffer, CursorPosition)
		local PositionY : number = ReadFloat16(TargetBuffer, CursorPosition + 2)
		local PositionZ : number = ReadFloat16(TargetBuffer, CursorPosition + 4)
		local ScalingFactor : number = 10430.2191955
		local EulerX : number = BufferReadI16(TargetBuffer, CursorPosition + 6) / ScalingFactor
		local EulerY : number = BufferReadI16(TargetBuffer, CursorPosition + 8) / ScalingFactor
		local EulerZ : number = BufferReadI16(TargetBuffer, CursorPosition + 10) / ScalingFactor

		return CFrame.fromEulerAnglesXYZ(EulerX, EulerY, EulerZ) + Vector3.new(PositionX, PositionY, PositionZ), CursorPosition + 12
	end
} :: TypeSerializer<CFrame>

DataTypes.Color3 = {
	IsDynamic = false, ContainsInstances = false,
	GetByteSize = function(_ : Color3) : number return 3 end,
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
			if Count > MaxCollectionSize then error("Ion: Array too large") end
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
			if Count > MaxCollectionSize then error("Ion: Map too large") end
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
		table.insert(SortedKeys, DefinitionKey)
		if Serializer.ContainsInstances then HasInstances = true end
		if Serializer.IsDynamic then IsDynamic = true end
	end
	table.sort(SortedKeys)

	local FieldWriters : { any } = {}
	local FieldReaders : { any } = {}
	local FieldSizers : { any } = {}

	for Index : number, Key : string in ipairs(SortedKeys) do
		local Serializer : TypeSerializer<any> = StructureDefinition[Key]
		FieldWriters[Index] = Serializer.Write
		FieldReaders[Index] = Serializer.Read
		FieldSizers[Index] = Serializer.GetByteSize
	end

	return {
		IsDynamic = IsDynamic, ContainsInstances = HasInstances,
		GetByteSize = function(Value : { [string] : any }) : number
			local TotalSize : number = 0
			for Index : number, Key : string in ipairs(SortedKeys) do
				TotalSize += FieldSizers[Index](Value[Key])
			end
			return TotalSize
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

local AnyTypeHandler : TypeSerializer<any>
do
	local function GetAnySize(Value : any) : number
		local TypeName : string = typeof(Value)
		if TypeName == "string" then return 5 + #Value
		elseif TypeName == "number" then return 9
		elseif TypeName == "boolean" then return 2
		elseif TypeName == "Instance" then return 3
		elseif TypeName == "Vector3" then return 13
		elseif TypeName == "CFrame" then return 25
		elseif TypeName == "EnumItem" then return 3
		elseif TypeName == "Vector2" then return 9
		elseif TypeName == "Color3" then return 4
		elseif TypeName == "UDim2" then return 17
		elseif TypeName == "DateTime" then return 9
		elseif TypeName == "buffer" then return 5 + BufferLen(Value)
		else return 1 end
	end

	local function WriteAny(TargetBuffer, CursorPosition, Value, InstanceAccumulator, InstanceLookup)
		local TypeName : string = typeof(Value)
		TargetBuffer = EnsureCapacity(TargetBuffer, CursorPosition, 1)

		if Value == nil then 
			BufferWriteU8(TargetBuffer, CursorPosition, 0)
			return TargetBuffer, CursorPosition + 1
		elseif TypeName == "string" then 
			BufferWriteU8(TargetBuffer, CursorPosition, 3)
			return DataTypes.String.Write(TargetBuffer, CursorPosition + 1, Value, InstanceAccumulator, InstanceLookup)
		elseif TypeName == "number" then 
			BufferWriteU8(TargetBuffer, CursorPosition, 2)
			return DataTypes.Float64.Write(TargetBuffer, CursorPosition + 1, Value, InstanceAccumulator, InstanceLookup)
		elseif TypeName == "boolean" then 
			BufferWriteU8(TargetBuffer, CursorPosition, 1)
			return DataTypes.Boolean.Write(TargetBuffer, CursorPosition + 1, Value, InstanceAccumulator, InstanceLookup)
		elseif TypeName == "Instance" then 
			BufferWriteU8(TargetBuffer, CursorPosition, 4)
			return DataTypes.Instance.Write(TargetBuffer, CursorPosition + 1, Value, InstanceAccumulator, InstanceLookup)
		elseif TypeName == "Vector3" then 
			BufferWriteU8(TargetBuffer, CursorPosition, 5)
			return DataTypes.Vector3.Write(TargetBuffer, CursorPosition + 1, Value, InstanceAccumulator, InstanceLookup)
		elseif TypeName == "CFrame" then 
			BufferWriteU8(TargetBuffer, CursorPosition, 7)
			return DataTypes.CFrame.Write(TargetBuffer, CursorPosition + 1, Value, InstanceAccumulator, InstanceLookup)
		elseif TypeName == "EnumItem" then 
			BufferWriteU8(TargetBuffer, CursorPosition, 6)
			return DataTypes.UInt16.Write(TargetBuffer, CursorPosition + 1, Value.Value, InstanceAccumulator, InstanceLookup)
		elseif TypeName == "Vector2" then
			BufferWriteU8(TargetBuffer, CursorPosition, 8)
			return DataTypes.Vector2.Write(TargetBuffer, CursorPosition + 1, Value, InstanceAccumulator, InstanceLookup)
		elseif TypeName == "Color3" then
			BufferWriteU8(TargetBuffer, CursorPosition, 9)
			return DataTypes.Color3.Write(TargetBuffer, CursorPosition + 1, Value, InstanceAccumulator, InstanceLookup)
		elseif TypeName == "UDim2" then
			BufferWriteU8(TargetBuffer, CursorPosition, 10)
			return DataTypes.UDim2.Write(TargetBuffer, CursorPosition + 1, Value, InstanceAccumulator, InstanceLookup)
		elseif TypeName == "DateTime" then
			BufferWriteU8(TargetBuffer, CursorPosition, 11)
			return DataTypes.DateTime.Write(TargetBuffer, CursorPosition + 1, Value, InstanceAccumulator, InstanceLookup)
		elseif TypeName == "buffer" then
			BufferWriteU8(TargetBuffer, CursorPosition, 12)
			return DataTypes.Buffer.Write(TargetBuffer, CursorPosition + 1, Value, InstanceAccumulator, InstanceLookup)
		else 
			error("Ion: Unsupported Any type " .. TypeName) 
		end
	end

	local function ReadAny(TargetBuffer, CursorPosition, InstanceSource)
		CheckBounds(TargetBuffer, CursorPosition, 1)
		local TypeId : number = BufferReadU8(TargetBuffer, CursorPosition)
		CursorPosition += 1
		if TypeId == 0 then return nil, CursorPosition
		elseif TypeId == 3 then return DataTypes.String.Read(TargetBuffer, CursorPosition, InstanceSource)
		elseif TypeId == 2 then return DataTypes.Float64.Read(TargetBuffer, CursorPosition, InstanceSource)
		elseif TypeId == 1 then return DataTypes.Boolean.Read(TargetBuffer, CursorPosition, InstanceSource)
		elseif TypeId == 4 then return DataTypes.Instance.Read(TargetBuffer, CursorPosition, InstanceSource)
		elseif TypeId == 5 then return DataTypes.Vector3.Read(TargetBuffer, CursorPosition, InstanceSource)
		elseif TypeId == 7 then return DataTypes.CFrame.Read(TargetBuffer, CursorPosition, InstanceSource)
		elseif TypeId == 6 then return DataTypes.UInt16.Read(TargetBuffer, CursorPosition, InstanceSource)
		elseif TypeId == 8 then return DataTypes.Vector2.Read(TargetBuffer, CursorPosition, InstanceSource)
		elseif TypeId == 9 then return DataTypes.Color3.Read(TargetBuffer, CursorPosition, InstanceSource)
		elseif TypeId == 10 then return DataTypes.UDim2.Read(TargetBuffer, CursorPosition, InstanceSource)
		elseif TypeId == 11 then return DataTypes.DateTime.Read(TargetBuffer, CursorPosition, InstanceSource)
		elseif TypeId == 12 then return DataTypes.Buffer.Read(TargetBuffer, CursorPosition, InstanceSource)
		else error("Ion: Corrupt Any type") end
	end
	
	AnyTypeHandler = { IsDynamic = true, ContainsInstances = true, GetByteSize = GetAnySize, Write = WriteAny, Read = ReadAny }
end
DataTypes.Any = AnyTypeHandler

local Definitions : { [number] : { TypeSerializer<any> } } = {}
local Listeners : { [number] : (...any) -> () } = {}
local RemoteCache : { [number] : RemoteEvent | UnreliableRemoteEvent } = {}

type RateLimit = { Tokens : number, LastUpdate : number, RefillRate : number, Capacity : number }
local RateLimiters : { [number] : { [Player] : RateLimit } } = {}
local GlobalRateLimitPerPlayer : { [Player] : RateLimit } = {}
local GlobalLimitSettings : number? = nil

type Stats = { TotalBytesSent : number, TotalBytesReceived : number, PacketsSent : number, PacketsReceived : number }
local GlobalStats : Stats = { TotalBytesSent = 0, TotalBytesReceived = 0, PacketsSent = 0, PacketsReceived = 0 }

local function IncrementStats(Bytes : number, Packets : number)
	GlobalStats.TotalBytesSent += Bytes
	GlobalStats.PacketsSent += Packets
end

local function IncrementReceivedStats(Bytes : number, Packets : number)
	GlobalStats.TotalBytesReceived += Bytes
	GlobalStats.PacketsReceived += Packets
end

type Middleware = {
	OnBeforeSend : ((...any) -> boolean)?,
	OnAfterReceived : ((...any) -> ())?
}

local function GetRateLimiter(PacketId : number, Player : Player, Rate : number) : RateLimit
	local PacketCache = RateLimiters[PacketId]
	if not PacketCache then 
		PacketCache = {}
		RateLimiters[PacketId] = PacketCache 
	end
	local Limiter : RateLimit = PacketCache[Player]
	if not Limiter then
		Limiter = { Tokens = Rate, LastUpdate = os.clock(), RefillRate = Rate, Capacity = Rate * 2 }
		PacketCache[Player] = Limiter
	end
	return Limiter
end

local function CheckGlobalRateLimit(Player : Player) : boolean
	if not GlobalLimitSettings then return true end
	local Limiter : RateLimit = GlobalRateLimitPerPlayer[Player]
	if not Limiter then
		Limiter = { Tokens = GlobalLimitSettings, LastUpdate = os.clock(), RefillRate = GlobalLimitSettings, Capacity = GlobalLimitSettings * 1.5 }
		GlobalRateLimitPerPlayer[Player] = Limiter
	end

	local Now : number = os.clock()
	local Delta : number = Now - Limiter.LastUpdate
	Limiter.LastUpdate = Now
	Limiter.Tokens = math.min(Limiter.Capacity, Limiter.Tokens + (Delta * Limiter.RefillRate))

	if Limiter.Tokens >= 1 then
		Limiter.Tokens -= 1
		return true
	end
	return false
end

Players.PlayerRemoving:Connect(function(Player : Player)
	for _, Cache in pairs(RateLimiters) do 
		Cache[Player] = nil 
	end
	GlobalRateLimitPerPlayer[Player] = nil
end)

local Ion = {}
Ion.Types = DataTypes

function Ion.GetStats() : Stats 
	return GlobalStats 
end

function Ion.SetGlobalRateLimit(LimitPerSecond : number)
	GlobalLimitSettings = LimitPerSecond
end

function Ion.Define(Namespace : string, Schema : { TypeSerializer<any> }, Options : { Unreliable : boolean?, RateLimit : number?, Compress : boolean?, Middleware : Middleware?, SchemaVersion : number? }?)
	local FullHash : number = FNV1a(Namespace)
	local Hash : number = Bit32Band(FullHash, 0xFFFF) 

	if Definitions[Hash] then 
		error("Ion: Namespace collision for '" .. Namespace .. "'") 
	end
	Definitions[Hash] = Schema

	local IsUnreliable : boolean = Options and Options.Unreliable or false
	local Rate : number? = Options and Options.RateLimit
	local UseCompression : boolean = Options and Options.Compress or false
	local Hooks : Middleware? = Options and Options.Middleware
	local SchemaVersion : number = Options and Options.SchemaVersion or 1

	local RemoteName : string = "Ion_" .. Hash

	if RunService:IsServer() then
		local Remote : Instance
		if IsUnreliable then 
			Remote = Instance.new("UnreliableRemoteEvent") 
		else 
			Remote = Instance.new("RemoteEvent") 
		end
		Remote.Name = RemoteName
		Remote.Parent = ReplicatedStorage
		RemoteCache[Hash] = Remote :: any

		local function OnServerEvent(Player : Player, Data : buffer, Instances : { Instance })
			if not CheckGlobalRateLimit(Player) then return end

			if Rate then
				local Limiter : RateLimit = GetRateLimiter(Hash, Player, Rate)
				local Now : number = os.clock()
				local Delta : number = Now - Limiter.LastUpdate
				Limiter.LastUpdate = Now
				Limiter.Tokens = math.min(Limiter.Capacity, Limiter.Tokens + (Delta * Limiter.RefillRate))
				if Limiter.Tokens >= 1 then 
					Limiter.Tokens -= 1 
				else 
					return 
				end
			end

			local Length : number = BufferLen(Data)
			IncrementReceivedStats(Length, 1)

			local CursorPosition : number = 0
			CheckBounds(Data, CursorPosition, 5)
			local Version : number = BufferReadU8(Data, CursorPosition)
			local PacketId : number = BufferReadU16(Data, CursorPosition + 1)
			local Flags : number = BufferReadU8(Data, CursorPosition + 3)
			local IncomingSchemaVersion : number = BufferReadU8(Data, CursorPosition + 4)
			CursorPosition += 5

			if Version ~= IonVersion or PacketId ~= Hash then return end
			if IncomingSchemaVersion ~= SchemaVersion then
				warn("Ion: Schema version mismatch for " .. Namespace .. " (Client: " .. IncomingSchemaVersion .. ", Server: " .. SchemaVersion .. ")")
				return
			end

			if Bit32BTest(Flags, 1) then
				Data = EncodingService:DecompressBuffer(Data, Enum.CompressionAlgorithm.Zstd)
				CursorPosition = 0
			end

			local Callback = Listeners[Hash]
			if Callback then
				local Args : { any } = {}
				for Index, Serializer : TypeSerializer<any> in ipairs(Schema) do
					local Value : any
					Value, CursorPosition = Serializer.Read(Data, CursorPosition, Instances)
					table.insert(Args, Value)
				end

				if Hooks and Hooks.OnAfterReceived then 
					Hooks.OnAfterReceived(Player, table.unpack(Args)) 
				end
				Callback(Player, table.unpack(Args))
			end
		end

		if IsUnreliable then 
			(Remote :: UnreliableRemoteEvent).OnServerEvent:Connect(OnServerEvent)
		else 
			(Remote :: RemoteEvent).OnServerEvent:Connect(OnServerEvent) 
		end
	else
		local Remote : Instance? = ReplicatedStorage:WaitForChild(RemoteName, 10)
		if not Remote then 
			error("Ion: Remote '"..RemoteName.."' not found") 
		end
		RemoteCache[Hash] = Remote :: any

		local function OnClientEvent(Data : buffer, Instances : { Instance })
			local Length : number = BufferLen(Data)
			IncrementReceivedStats(Length, 1)

			local CursorPosition : number = 0
			CheckBounds(Data, CursorPosition, 5)
			local Version : number = BufferReadU8(Data, CursorPosition)
			local PacketId : number = BufferReadU16(Data, CursorPosition + 1)
			local Flags : number = BufferReadU8(Data, CursorPosition + 3)
			local IncomingSchemaVersion : number = BufferReadU8(Data, CursorPosition + 4)
			CursorPosition += 5

			if Version ~= IonVersion or PacketId ~= Hash then return end
			if IncomingSchemaVersion ~= SchemaVersion then
				warn("Ion: Schema version mismatch for " .. Namespace .. " (Server: " .. IncomingSchemaVersion .. ", Client: " .. SchemaVersion .. ")")
				return
			end

			if Bit32BTest(Flags, 1) then
				Data = EncodingService:DecompressBuffer(Data, Enum.CompressionAlgorithm.Zstd)
				CursorPosition = 0
			end

			local Callback = Listeners[Hash]
			if Callback then
				local Args : { any } = {}
				for Index, Serializer : TypeSerializer<any> in ipairs(Schema) do
					local Value : any
					Value, CursorPosition = Serializer.Read(Data, CursorPosition, Instances)
					table.insert(Args, Value)
				end

				if Hooks and Hooks.OnAfterReceived then 
					Hooks.OnAfterReceived(table.unpack(Args)) 
				end
				Callback(table.unpack(Args))
			end
		end

		if IsUnreliable then 
			(Remote :: UnreliableRemoteEvent).OnClientEvent:Connect(OnClientEvent)
		else 
			(Remote :: RemoteEvent).OnClientEvent:Connect(OnClientEvent) 
		end
	end

	local PacketObject = {}

	function PacketObject.Send(Target : Player?, ... : any)
		if Hooks and Hooks.OnBeforeSend then
			if not Hooks.OnBeforeSend(...) then 
				warn("Ion: Packet cancelled by OnBeforeSend middleware")
				return 
			end
		end

		local Args : { any } = { ... }
		local PayloadBuffer : buffer = AcquireBuffer(1024)
		local CursorPosition : number = 0
		local InstanceAccumulator : { Instance } = {}
		local InstanceLookup : { [Instance] : number } = {}

		for Index, Serializer : TypeSerializer<any> in ipairs(Schema) do
			PayloadBuffer, CursorPosition = Serializer.Write(PayloadBuffer, CursorPosition, Args[Index], InstanceAccumulator, InstanceLookup)
		end

		local FinalPayload : buffer = BufferCreate(CursorPosition)
		BufferCopy(FinalPayload, 0, PayloadBuffer, 0, CursorPosition)
		ReleaseBuffer(PayloadBuffer)

		local IsCompressed : boolean = false
		if UseCompression and CursorPosition > CompressionThreshold then
			FinalPayload = EncodingService:CompressBuffer(FinalPayload, Enum.CompressionAlgorithm.Zstd)
			IsCompressed = true
		end

		local PayloadSize : number = BufferLen(FinalPayload)
		if IsUnreliable and (PayloadSize + 5) > MaxPacketSize then 
			warn("Ion: Unreliable packet dropped (Too large " .. PayloadSize .. "b)") 
			return 
		end

		-- Header: [Version:u8] [Hash:u16] [Flags:u8] [SchemaVersion:u8]
		local PacketBuffer : buffer = BufferCreate(5 + PayloadSize)
		BufferWriteU8(PacketBuffer, 0, IonVersion)
		BufferWriteU16(PacketBuffer, 1, Hash)
		BufferWriteU8(PacketBuffer, 3, IsCompressed and 2 or 0)
		BufferWriteU8(PacketBuffer, 4, SchemaVersion)
		BufferCopy(PacketBuffer, 5, FinalPayload, 0, PayloadSize)

		local TotalSize : number = BufferLen(PacketBuffer)
		IncrementStats(TotalSize, 1)

		local Remote : any = RemoteCache[Hash]
		if RunService:IsServer() then
			if Target then 
				Remote:FireClient(Target, PacketBuffer, InstanceAccumulator)
			else 
				Remote:FireAllClients(PacketBuffer, InstanceAccumulator) 
			end
		else
			Remote:FireServer(PacketBuffer, InstanceAccumulator)
		end
	end

	function PacketObject.Listen(Callback : (...any) -> ())
		Listeners[Hash] = Callback
	end

	function PacketObject.Destroy()
		Listeners[Hash] = nil
		local Remote : any = RemoteCache[Hash]
		if Remote then
			Remote:Destroy()
			RemoteCache[Hash] = nil
		end
		Definitions[Hash] = nil
	end

	local ServerInterface = {}
	local ClientInterface = {}

	function ServerInterface.SendTo(Recipient : Player, ... : any) PacketObject.Send(Recipient, ...) end
	function ServerInterface.SendToAll(... : any) PacketObject.Send(nil, ...) end
	function ServerInterface.SendToList(Recipients : { Player }, ... : any) 
		local FailedPlayers : { Player } = {}
		for _, Recipient in ipairs(Recipients) do 
			if Recipient.Parent then 
				PacketObject.Send(Recipient, ...) 
			else
				warn("Ion: Failed to send to disconnected player")
				table.insert(FailedPlayers, Recipient)
			end
		end 
		return FailedPlayers
	end
	function ServerInterface.Listen(Callback : (Player, ...any) -> ()) PacketObject.Listen(Callback) end

	function ClientInterface.Send(... : any) PacketObject.Send(nil, ...) end
	function ClientInterface.Listen(Callback : (...any) -> ()) PacketObject.Listen(Callback) end

	return {
		Server = ServerInterface,
		Client = ClientInterface,
		Destroy = PacketObject.Destroy
	} :: IonPacket<any>
end

return Ion