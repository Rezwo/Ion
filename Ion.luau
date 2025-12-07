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

local MathFrexp = math.frexp
local MathLdexp = math.ldexp
local MathFloor = math.floor
local MathRound = math.round

local IonVersion : number = 1
local MaxPacketSize : number = 900
local BufferPool : { buffer } = {}
local PoolCapacity : number = 64
local PoolBufferSize : number = 4096

export type IonPacket<T...> = {
	Server : {
		SendTo : (Recipient : Player, T...) -> (),
		SendToAll : (T...) -> (),
		SendToList : (Recipients : { Player }, T...) -> (),
		Listen : (Callback : (Player, T...) -> ()) -> ()
	},
	Client : {
		Send : (T...) -> (),
		Listen : (Callback : (T...) -> ()) -> ()
	}
}

for PoolIndex : number = 1, PoolCapacity do
	table.insert(BufferPool, BufferCreate(PoolBufferSize))
end

local function AcquireBuffer(MinimumSize : number) : buffer
	if MinimumSize > PoolBufferSize then return BufferCreate(MinimumSize) end
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
	if CursorPosition + Size > BufferLen(TargetBuffer) then error("Ion: Buffer overflow") end
end

local function WriteFloat16(TargetBuffer : buffer, CursorPosition : number, Value : number)
	local Sign : number = if Value < 0 then 0x8000 else 0
	if Value < 0 then Value = -Value end
	local Encoded : number = 0
	if Value ~= 0 then
		local Mantissa : number, Exponent : number = MathFrexp(Value)
		Exponent += 14
		if Exponent <= 0 then
			Mantissa = MathLdexp(Mantissa, Exponent + 10)
			Encoded = Sign + MathFloor(Mantissa + 0.5)
		elseif Exponent >= 32 then
			Encoded = Sign + 0x7C00
		else
			Encoded = Sign + Bit32LShift(Exponent, 10) + MathFloor(Mantissa * 1024 + 0.5) % 1024
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
		return if Mantissa == 0 then (if Sign then -math.huge else math.huge) else 0/0
	end
	local Result : number = MathLdexp(Mantissa + 1024, Exponent - 25)
	return if Sign then -Result else Result
end

export type TypeSerializer<T> = {
	Write : (buffer, number, T, { Instance }, { [Instance] : number }) -> number,
	Read : (buffer, number, { Instance }) -> (T, number),
	GetByteSize : (T) -> number,
	IsDynamic : boolean,
	ContainsInstances : boolean
}

local DataTypes = {}

DataTypes.UInt8 = {
	IsDynamic = false, ContainsInstances = false,
	GetByteSize = function(_ : number) : number return 1 end,
	Write = function(TargetBuffer : buffer, CursorPosition : number, Value : number) TargetBuffer = EnsureCapacity(TargetBuffer, CursorPosition, 1); BufferWriteU8(TargetBuffer, CursorPosition, Value or 0); return CursorPosition + 1 end,
	Read = function(TargetBuffer : buffer, CursorPosition : number) CheckBounds(TargetBuffer, CursorPosition, 1); return BufferReadU8(TargetBuffer, CursorPosition), CursorPosition + 1 end
} :: TypeSerializer<number>

DataTypes.UInt16 = {
	IsDynamic = false, ContainsInstances = false,
	GetByteSize = function(_ : number) : number return 2 end,
	Write = function(TargetBuffer : buffer, CursorPosition : number, Value : number) TargetBuffer = EnsureCapacity(TargetBuffer, CursorPosition, 2); BufferWriteU16(TargetBuffer, CursorPosition, Value or 0); return CursorPosition + 2 end,
	Read = function(TargetBuffer : buffer, CursorPosition : number) CheckBounds(TargetBuffer, CursorPosition, 2); return BufferReadU16(TargetBuffer, CursorPosition), CursorPosition + 2 end
} :: TypeSerializer<number>

DataTypes.UInt24 = {
	IsDynamic = false, ContainsInstances = false,
	GetByteSize = function(_ : number) : number return 3 end,
	Write = function(TargetBuffer : buffer, CursorPosition : number, Value : number) 
		TargetBuffer = EnsureCapacity(TargetBuffer, CursorPosition, 3)
		local Clamped : number = math.clamp(Value or 0, 0, 16777215)
		BufferWriteU8(TargetBuffer, CursorPosition, Bit32Band(Bit32RShift(Clamped, 16), 0xFF))
		BufferWriteU8(TargetBuffer, CursorPosition + 1, Bit32Band(Bit32RShift(Clamped, 8), 0xFF))
		BufferWriteU8(TargetBuffer, CursorPosition + 2, Bit32Band(Clamped, 0xFF))
		return CursorPosition + 3 
	end,
	Read = function(TargetBuffer : buffer, CursorPosition : number) 
		CheckBounds(TargetBuffer, CursorPosition, 3)
		local B1 : number = BufferReadU8(TargetBuffer, CursorPosition)
		local B2 : number = BufferReadU8(TargetBuffer, CursorPosition + 1)
		local B3 : number = BufferReadU8(TargetBuffer, CursorPosition + 2)
		return Bit32LShift(B1, 16) + Bit32LShift(B2, 8) + B3, CursorPosition + 3 
	end
} :: TypeSerializer<number>

DataTypes.UInt32 = {
	IsDynamic = false, ContainsInstances = false,
	GetByteSize = function(_ : number) : number return 4 end,
	Write = function(TargetBuffer : buffer, CursorPosition : number, Value : number) TargetBuffer = EnsureCapacity(TargetBuffer, CursorPosition, 4); BufferWriteU32(TargetBuffer, CursorPosition, Value or 0); return CursorPosition + 4 end,
	Read = function(TargetBuffer : buffer, CursorPosition : number) CheckBounds(TargetBuffer, CursorPosition, 4); return BufferReadU32(TargetBuffer, CursorPosition), CursorPosition + 4 end
} :: TypeSerializer<number>

DataTypes.UInt64 = {
	IsDynamic = false, ContainsInstances = false,
	GetByteSize = function(_ : any) : number return 8 end,
	Write = function(TargetBuffer : buffer, CursorPosition : number, Value : any)
		TargetBuffer = EnsureCapacity(TargetBuffer, CursorPosition, 8)
		local NumberValue : number = tonumber(Value) or 0
		local Upper : number = math.floor(NumberValue / 4294967296)
		local Lower : number = NumberValue % 4294967296
		BufferWriteU32(TargetBuffer, CursorPosition, Upper)
		BufferWriteU32(TargetBuffer, CursorPosition + 4, Lower)
		return CursorPosition + 8
	end,
	Read = function(TargetBuffer : buffer, CursorPosition : number)
		CheckBounds(TargetBuffer, CursorPosition, 8)
		local Upper : number = BufferReadU32(TargetBuffer, CursorPosition)
		local Lower : number = BufferReadU32(TargetBuffer, CursorPosition + 4)
		local Result : string = string.format("%.0f", Upper * 4294967296 + Lower)
		return Result, CursorPosition + 8
	end
} :: TypeSerializer<string>

DataTypes.Int8 = {
	IsDynamic = false, ContainsInstances = false,
	GetByteSize = function(_ : number) : number return 1 end,
	Write = function(TargetBuffer : buffer, CursorPosition : number, Value : number) TargetBuffer = EnsureCapacity(TargetBuffer, CursorPosition, 1); BufferWriteI8(TargetBuffer, CursorPosition, Value or 0); return CursorPosition + 1 end,
	Read = function(TargetBuffer : buffer, CursorPosition : number) CheckBounds(TargetBuffer, CursorPosition, 1); return BufferReadI8(TargetBuffer, CursorPosition), CursorPosition + 1 end
} :: TypeSerializer<number>

DataTypes.Int16 = {
	IsDynamic = false, ContainsInstances = false,
	GetByteSize = function(_ : number) : number return 2 end,
	Write = function(TargetBuffer : buffer, CursorPosition : number, Value : number) TargetBuffer = EnsureCapacity(TargetBuffer, CursorPosition, 2); BufferWriteI16(TargetBuffer, CursorPosition, Value or 0); return CursorPosition + 2 end,
	Read = function(TargetBuffer : buffer, CursorPosition : number) CheckBounds(TargetBuffer, CursorPosition, 2); return BufferReadI16(TargetBuffer, CursorPosition), CursorPosition + 2 end
} :: TypeSerializer<number>

DataTypes.Int32 = {
	IsDynamic = false, ContainsInstances = false,
	GetByteSize = function(_ : number) : number return 4 end,
	Write = function(TargetBuffer : buffer, CursorPosition : number, Value : number) TargetBuffer = EnsureCapacity(TargetBuffer, CursorPosition, 4); BufferWriteI32(TargetBuffer, CursorPosition, Value or 0); return CursorPosition + 4 end,
	Read = function(TargetBuffer : buffer, CursorPosition : number) CheckBounds(TargetBuffer, CursorPosition, 4); return BufferReadI32(TargetBuffer, CursorPosition), CursorPosition + 4 end
} :: TypeSerializer<number>

DataTypes.Int64 = {
	IsDynamic = false, ContainsInstances = false,
	GetByteSize = function(_ : any) : number return 8 end,
	Write = function(TargetBuffer : buffer, CursorPosition : number, Value : any)
		TargetBuffer = EnsureCapacity(TargetBuffer, CursorPosition, 8)
		local NumberValue : number = tonumber(Value) or 0
		local High : number = math.floor(NumberValue / 4294967296)
		local Low : number = NumberValue % 4294967296
		BufferWriteI32(TargetBuffer, CursorPosition, High)
		BufferWriteU32(TargetBuffer, CursorPosition + 4, Low)
		return CursorPosition + 8
	end,
	Read = function(TargetBuffer : buffer, CursorPosition : number)
		CheckBounds(TargetBuffer, CursorPosition, 8)
		local High : number = BufferReadI32(TargetBuffer, CursorPosition)
		local Low : number = BufferReadU32(TargetBuffer, CursorPosition + 4)
		local Result : string = string.format("%.0f", High * 4294967296 + Low)
		return Result, CursorPosition + 8
	end
} :: TypeSerializer<string>

DataTypes.Float16 = {
	IsDynamic = false, ContainsInstances = false,
	GetByteSize = function(_ : number) : number return 2 end,
	Write = function(TargetBuffer : buffer, CursorPosition : number, Value : number) TargetBuffer = EnsureCapacity(TargetBuffer, CursorPosition, 2); WriteFloat16(TargetBuffer, CursorPosition, Value or 0); return CursorPosition + 2 end,
	Read = function(TargetBuffer : buffer, CursorPosition : number) CheckBounds(TargetBuffer, CursorPosition, 2); return ReadFloat16(TargetBuffer, CursorPosition), CursorPosition + 2 end
} :: TypeSerializer<number>

DataTypes.Float32 = {
	IsDynamic = false, ContainsInstances = false,
	GetByteSize = function(_ : number) : number return 4 end,
	Write = function(TargetBuffer : buffer, CursorPosition : number, Value : number) TargetBuffer = EnsureCapacity(TargetBuffer, CursorPosition, 4); BufferWriteF32(TargetBuffer, CursorPosition, Value or 0); return CursorPosition + 4 end,
	Read = function(TargetBuffer : buffer, CursorPosition : number) CheckBounds(TargetBuffer, CursorPosition, 4); return BufferReadF32(TargetBuffer, CursorPosition), CursorPosition + 4 end
} :: TypeSerializer<number>

DataTypes.Float64 = {
	IsDynamic = false, ContainsInstances = false,
	GetByteSize = function(_ : number) : number return 8 end,
	Write = function(TargetBuffer : buffer, CursorPosition : number, Value : number) TargetBuffer = EnsureCapacity(TargetBuffer, CursorPosition, 8); BufferWriteF64(TargetBuffer, CursorPosition, Value or 0); return CursorPosition + 8 end,
	Read = function(TargetBuffer : buffer, CursorPosition : number) CheckBounds(TargetBuffer, CursorPosition, 8); return BufferReadF64(TargetBuffer, CursorPosition), CursorPosition + 8 end
} :: TypeSerializer<number>

DataTypes.Boolean = {
	IsDynamic = false, ContainsInstances = false,
	GetByteSize = function(_ : boolean) : number return 1 end,
	Write = function(TargetBuffer : buffer, CursorPosition : number, Value : boolean) TargetBuffer = EnsureCapacity(TargetBuffer, CursorPosition, 1); BufferWriteU8(TargetBuffer, CursorPosition, Value and 1 or 0); return CursorPosition + 1 end,
	Read = function(TargetBuffer : buffer, CursorPosition : number) CheckBounds(TargetBuffer, CursorPosition, 1); return BufferReadU8(TargetBuffer, CursorPosition) == 1, CursorPosition + 1 end
} :: TypeSerializer<boolean>

DataTypes.String = {
	IsDynamic = true, ContainsInstances = false,
	GetByteSize = function(Value : string) : number return 4 + #Value end,
	Write = function(TargetBuffer : buffer, CursorPosition : number, Value : string)
		local Length : number = #Value
		TargetBuffer = EnsureCapacity(TargetBuffer, CursorPosition, 4 + Length)
		BufferWriteU32(TargetBuffer, CursorPosition, Length)
		BufferWriteString(TargetBuffer, CursorPosition + 4, Value)
		return CursorPosition + 4 + Length
	end,
	Read = function(TargetBuffer : buffer, CursorPosition : number)
		CheckBounds(TargetBuffer, CursorPosition, 4)
		local Length : number = BufferReadU32(TargetBuffer, CursorPosition)
		CheckBounds(TargetBuffer, CursorPosition + 4, Length)
		return BufferReadString(TargetBuffer, CursorPosition + 4, Length), CursorPosition + 4 + Length
	end
} :: TypeSerializer<string>

DataTypes.ShortString = {
	IsDynamic = true, ContainsInstances = false,
	GetByteSize = function(Value : string) : number return 1 + #Value end,
	Write = function(TargetBuffer : buffer, CursorPosition : number, Value : string)
		local Length : number = #Value
		TargetBuffer = EnsureCapacity(TargetBuffer, CursorPosition, 1 + Length)
		BufferWriteU8(TargetBuffer, CursorPosition, Length)
		BufferWriteString(TargetBuffer, CursorPosition + 1, Value)
		return CursorPosition + 1 + Length
	end,
	Read = function(TargetBuffer : buffer, CursorPosition : number)
		CheckBounds(TargetBuffer, CursorPosition, 1)
		local Length : number = BufferReadU8(TargetBuffer, CursorPosition)
		CheckBounds(TargetBuffer, CursorPosition + 1, Length)
		return BufferReadString(TargetBuffer, CursorPosition + 1, Length), CursorPosition + 1 + Length
	end
} :: TypeSerializer<string>

DataTypes.FixedString = function(Length : number) : TypeSerializer<string>
	return {
		IsDynamic = false, ContainsInstances = false,
		GetByteSize = function(_ : string) : number return Length end,
		Write = function(TargetBuffer : buffer, CursorPosition : number, Value : string)
			TargetBuffer = EnsureCapacity(TargetBuffer, CursorPosition, Length)
			BufferWriteString(TargetBuffer, CursorPosition, Value, Length)
			return CursorPosition + Length
		end,
		Read = function(TargetBuffer : buffer, CursorPosition : number)
			CheckBounds(TargetBuffer, CursorPosition, Length)
			return BufferReadString(TargetBuffer, CursorPosition, Length), CursorPosition + Length
		end
	}
end

DataTypes.RestOfString = {
	IsDynamic = true, ContainsInstances = false,
	GetByteSize = function(Value : string) : number return #Value end,
	Write = function(TargetBuffer : buffer, CursorPosition : number, Value : string)
		local Length : number = #Value
		TargetBuffer = EnsureCapacity(TargetBuffer, CursorPosition, Length)
		BufferWriteString(TargetBuffer, CursorPosition, Value)
		return CursorPosition + Length
	end,
	Read = function(TargetBuffer : buffer, CursorPosition : number)
		local Remaining : number = BufferLen(TargetBuffer) - CursorPosition
		CheckBounds(TargetBuffer, CursorPosition, Remaining)
		return BufferReadString(TargetBuffer, CursorPosition, Remaining), CursorPosition + Remaining
	end
} :: TypeSerializer<string>

DataTypes.Instance = {
	IsDynamic = false, ContainsInstances = true,
	GetByteSize = function(_ : Instance) : number return 2 end,
	Write = function(TargetBuffer : buffer, CursorPosition : number, Value : Instance, InstanceAccumulator : { Instance }, InstanceLookup : { [Instance] : number })
		TargetBuffer = EnsureCapacity(TargetBuffer, CursorPosition, 2)
		if Value and typeof(Value) == "Instance" and Value:IsDescendantOf(game) then
			local Index : number = InstanceLookup[Value]
			if Index then BufferWriteU16(TargetBuffer, CursorPosition, Index)
			else
				local NewIndex : number = #InstanceAccumulator + 1
				InstanceAccumulator[NewIndex] = Value
				InstanceLookup[Value] = NewIndex
				BufferWriteU16(TargetBuffer, CursorPosition, NewIndex)
			end
		else BufferWriteU16(TargetBuffer, CursorPosition, 0) end
		return CursorPosition + 2
	end,
	Read = function(TargetBuffer : buffer, CursorPosition : number, InstanceSource : { Instance })
		CheckBounds(TargetBuffer, CursorPosition, 2)
		local Index : number = BufferReadU16(TargetBuffer, CursorPosition)
		return InstanceSource[Index], CursorPosition + 2
	end
} :: TypeSerializer<Instance>

function DataTypes.UseEnum(EnumType : any) : TypeSerializer<EnumItem>
	return {
		IsDynamic = false, ContainsInstances = false,
		GetByteSize = function(_ : EnumItem) : number return 2 end,
		Write = function(TargetBuffer : buffer, CursorPosition : number, Value : EnumItem) 
			TargetBuffer = EnsureCapacity(TargetBuffer, CursorPosition, 2)
			BufferWriteU16(TargetBuffer, CursorPosition, Value.Value)
			return CursorPosition + 2 
		end,
		Read = function(TargetBuffer : buffer, CursorPosition : number) 
			CheckBounds(TargetBuffer, CursorPosition, 2)
			local Value : number = BufferReadU16(TargetBuffer, CursorPosition)
			local Items : { EnumItem } = EnumType:GetEnumItems()
			for _, Item : EnumItem in ipairs(Items) do
				if Item.Value == Value then return Item, CursorPosition + 2 end
			end
			error("Ion: Invalid Enum value " .. tostring(Value))
		end
	}
end

DataTypes.Vector2 = {
	IsDynamic = false, ContainsInstances = false,
	GetByteSize = function(_ : Vector2) : number return 8 end,
	Write = function(TargetBuffer : buffer, CursorPosition : number, Value : Vector2)
		TargetBuffer = EnsureCapacity(TargetBuffer, CursorPosition, 8)
		BufferWriteF32(TargetBuffer, CursorPosition, Value.X)
		BufferWriteF32(TargetBuffer, CursorPosition + 4, Value.Y)
		return CursorPosition + 8
	end,
	Read = function(TargetBuffer : buffer, CursorPosition : number)
		CheckBounds(TargetBuffer, CursorPosition, 8)
		return Vector2.new(BufferReadF32(TargetBuffer, CursorPosition), BufferReadF32(TargetBuffer, CursorPosition + 4)), CursorPosition + 8
	end
} :: TypeSerializer<Vector2>

DataTypes.Vector3 = {
	IsDynamic = false, ContainsInstances = false,
	GetByteSize = function(_ : Vector3) : number return 12 end,
	Write = function(TargetBuffer : buffer, CursorPosition : number, Value : Vector3)
		TargetBuffer = EnsureCapacity(TargetBuffer, CursorPosition, 12)
		BufferWriteF32(TargetBuffer, CursorPosition, Value.X)
		BufferWriteF32(TargetBuffer, CursorPosition + 4, Value.Y)
		BufferWriteF32(TargetBuffer, CursorPosition + 8, Value.Z)
		return CursorPosition + 12
	end,
	Read = function(TargetBuffer : buffer, CursorPosition : number)
		CheckBounds(TargetBuffer, CursorPosition, 12)
		return Vector3.new(BufferReadF32(TargetBuffer, CursorPosition), BufferReadF32(TargetBuffer, CursorPosition + 4), BufferReadF32(TargetBuffer, CursorPosition + 8)), CursorPosition + 12
	end
} :: TypeSerializer<Vector3>

DataTypes.Vector3Int16 = {
	IsDynamic = false, ContainsInstances = false,
	GetByteSize = function(_ : Vector3) : number return 6 end,
	Write = function(TargetBuffer : buffer, CursorPosition : number, Value : Vector3)
		TargetBuffer = EnsureCapacity(TargetBuffer, CursorPosition, 6)
		BufferWriteI16(TargetBuffer, CursorPosition, MathRound(Value.X))
		BufferWriteI16(TargetBuffer, CursorPosition + 2, MathRound(Value.Y))
		BufferWriteI16(TargetBuffer, CursorPosition + 4, MathRound(Value.Z))
		return CursorPosition + 6
	end,
	Read = function(TargetBuffer : buffer, CursorPosition : number)
		CheckBounds(TargetBuffer, CursorPosition, 6)
		return Vector3.new(BufferReadI16(TargetBuffer, CursorPosition), BufferReadI16(TargetBuffer, CursorPosition + 2), BufferReadI16(TargetBuffer, CursorPosition + 4)), CursorPosition + 6
	end
} :: TypeSerializer<Vector3>

DataTypes.Vector3Float16 = {
	IsDynamic = false, ContainsInstances = false,
	GetByteSize = function(_ : Vector3) : number return 6 end,
	Write = function(TargetBuffer : buffer, CursorPosition : number, Value : Vector3)
		TargetBuffer = EnsureCapacity(TargetBuffer, CursorPosition, 6)
		WriteFloat16(TargetBuffer, CursorPosition, Value.X)
		WriteFloat16(TargetBuffer, CursorPosition + 2, Value.Y)
		WriteFloat16(TargetBuffer, CursorPosition + 4, Value.Z)
		return CursorPosition + 6
	end,
	Read = function(TargetBuffer : buffer, CursorPosition : number)
		CheckBounds(TargetBuffer, CursorPosition, 6)
		return Vector3.new(ReadFloat16(TargetBuffer, CursorPosition), ReadFloat16(TargetBuffer, CursorPosition + 2), ReadFloat16(TargetBuffer, CursorPosition + 4)), CursorPosition + 6
	end
} :: TypeSerializer<Vector3>

DataTypes.Vector3Float64 = {
	IsDynamic = false, ContainsInstances = false,
	GetByteSize = function(_ : Vector3) : number return 24 end,
	Write = function(TargetBuffer : buffer, CursorPosition : number, Value : Vector3)
		TargetBuffer = EnsureCapacity(TargetBuffer, CursorPosition, 24)
		BufferWriteF64(TargetBuffer, CursorPosition, Value.X)
		BufferWriteF64(TargetBuffer, CursorPosition + 8, Value.Y)
		BufferWriteF64(TargetBuffer, CursorPosition + 16, Value.Z)
		return CursorPosition + 24
	end,
	Read = function(TargetBuffer : buffer, CursorPosition : number)
		CheckBounds(TargetBuffer, CursorPosition, 24)
		return Vector3.new(BufferReadF64(TargetBuffer, CursorPosition), BufferReadF64(TargetBuffer, CursorPosition + 8), BufferReadF64(TargetBuffer, CursorPosition + 16)), CursorPosition + 24
	end
} :: TypeSerializer<Vector3>

DataTypes.CFrame = {
	IsDynamic = false, ContainsInstances = false,
	GetByteSize = function(_ : CFrame) : number return 24 end,
	Write = function(TargetBuffer : buffer, CursorPosition : number, Value : CFrame)
		TargetBuffer = EnsureCapacity(TargetBuffer, CursorPosition, 24)
		local PosX : number = Value.X
		local PosY : number = Value.Y
		local PosZ : number = Value.Z
		local Axis : Vector3, Angle : number = Value:ToAxisAngle()
		BufferWriteF32(TargetBuffer, CursorPosition, PosX)
		BufferWriteF32(TargetBuffer, CursorPosition + 4, PosY)
		BufferWriteF32(TargetBuffer, CursorPosition + 8, PosZ)
		BufferWriteF32(TargetBuffer, CursorPosition + 12, Axis.X)
		BufferWriteF32(TargetBuffer, CursorPosition + 16, Axis.Y)
		BufferWriteF32(TargetBuffer, CursorPosition + 20, Axis.Z)
		return CursorPosition + 24
	end,
	Read = function(TargetBuffer : buffer, CursorPosition : number)
		CheckBounds(TargetBuffer, CursorPosition, 24)
		local PosX : number = BufferReadF32(TargetBuffer, CursorPosition)
		local PosY : number = BufferReadF32(TargetBuffer, CursorPosition + 4)
		local PosZ : number = BufferReadF32(TargetBuffer, CursorPosition + 8)
		local AxisX : number = BufferReadF32(TargetBuffer, CursorPosition + 12)
		local AxisY : number = BufferReadF32(TargetBuffer, CursorPosition + 16)
		local AxisZ : number = BufferReadF32(TargetBuffer, CursorPosition + 20)
		local PosV : Vector3 = Vector3.new(PosX, PosY, PosZ)
		local Axis : Vector3 = Vector3.new(AxisX, AxisY, AxisZ)
		if Axis.Magnitude < 0.001 then return CFrame.new(PosV), CursorPosition + 24 end
		return CFrame.fromAxisAngle(Axis, Axis.Magnitude) + PosV, CursorPosition + 24
	end
} :: TypeSerializer<CFrame>

DataTypes.CFramePosition = {
	IsDynamic = false, ContainsInstances = false,
	GetByteSize = function(_ : CFrame) : number return 12 end,
	Write = function(TargetBuffer : buffer, CursorPosition : number, Value : CFrame)
		TargetBuffer = EnsureCapacity(TargetBuffer, CursorPosition, 12)
		BufferWriteF32(TargetBuffer, CursorPosition, Value.X)
		BufferWriteF32(TargetBuffer, CursorPosition + 4, Value.Y)
		BufferWriteF32(TargetBuffer, CursorPosition + 8, Value.Z)
		return CursorPosition + 12
	end,
	Read = function(TargetBuffer : buffer, CursorPosition : number)
		CheckBounds(TargetBuffer, CursorPosition, 12)
		return CFrame.new(BufferReadF32(TargetBuffer, CursorPosition), BufferReadF32(TargetBuffer, CursorPosition + 4), BufferReadF32(TargetBuffer, CursorPosition + 8)), CursorPosition + 12
	end
} :: TypeSerializer<CFrame>

DataTypes.CFrameFloat16 = {
	IsDynamic = false, ContainsInstances = false,
	GetByteSize = function(_ : CFrame) : number return 12 end,
	Write = function(TargetBuffer : buffer, CursorPosition : number, Value : CFrame)
		TargetBuffer = EnsureCapacity(TargetBuffer, CursorPosition, 12)
		WriteFloat16(TargetBuffer, CursorPosition, Value.X)
		WriteFloat16(TargetBuffer, CursorPosition + 2, Value.Y)
		WriteFloat16(TargetBuffer, CursorPosition + 4, Value.Z)
		local EulerX : number, EulerY : number, EulerZ : number = Value:ToEulerAnglesXYZ()
		BufferWriteU16(TargetBuffer, CursorPosition + 6, EulerX * 10430.2191955 + 0.5)
		BufferWriteU16(TargetBuffer, CursorPosition + 8, EulerY * 10430.2191955 + 0.5)
		BufferWriteU16(TargetBuffer, CursorPosition + 10, EulerZ * 10430.2191955 + 0.5)
		return CursorPosition + 12
	end,
	Read = function(TargetBuffer : buffer, CursorPosition : number)
		CheckBounds(TargetBuffer, CursorPosition, 12)
		local PosX : number = ReadFloat16(TargetBuffer, CursorPosition)
		local PosY : number = ReadFloat16(TargetBuffer, CursorPosition + 2)
		local PosZ : number = ReadFloat16(TargetBuffer, CursorPosition + 4)
		local EulerX : number = BufferReadU16(TargetBuffer, CursorPosition + 6) / 10430.2191955
		local EulerY : number = BufferReadU16(TargetBuffer, CursorPosition + 8) / 10430.2191955
		local EulerZ : number = BufferReadU16(TargetBuffer, CursorPosition + 10) / 10430.2191955
		return CFrame.fromEulerAnglesXYZ(EulerX, EulerY, EulerZ) + Vector3.new(PosX, PosY, PosZ), CursorPosition + 12
	end
} :: TypeSerializer<CFrame>

DataTypes.CFrameHighPrecision = {
	IsDynamic = false, ContainsInstances = false,
	GetByteSize = function(_ : CFrame) : number return 30 end,
	Write = function(TargetBuffer : buffer, CursorPosition : number, Value : CFrame)
		TargetBuffer = EnsureCapacity(TargetBuffer, CursorPosition, 30)
		BufferWriteF64(TargetBuffer, CursorPosition, Value.X)
		BufferWriteF64(TargetBuffer, CursorPosition + 8, Value.Y)
		BufferWriteF64(TargetBuffer, CursorPosition + 16, Value.Z)
		local EulerX : number, EulerY : number, EulerZ : number = Value:ToEulerAnglesXYZ()
		BufferWriteU16(TargetBuffer, CursorPosition + 24, EulerX * 10430.2191955 + 0.5)
		BufferWriteU16(TargetBuffer, CursorPosition + 26, EulerY * 10430.2191955 + 0.5)
		BufferWriteU16(TargetBuffer, CursorPosition + 28, EulerZ * 10430.2191955 + 0.5)
		return CursorPosition + 30
	end,
	Read = function(TargetBuffer : buffer, CursorPosition : number)
		CheckBounds(TargetBuffer, CursorPosition, 30)
		local PosX : number = BufferReadF64(TargetBuffer, CursorPosition)
		local PosY : number = BufferReadF64(TargetBuffer, CursorPosition + 8)
		local PosZ : number = BufferReadF64(TargetBuffer, CursorPosition + 16)
		local EulerX : number = BufferReadU16(TargetBuffer, CursorPosition + 24) / 10430.2191955
		local EulerY : number = BufferReadU16(TargetBuffer, CursorPosition + 26) / 10430.2191955
		local EulerZ : number = BufferReadU16(TargetBuffer, CursorPosition + 28) / 10430.2191955
		return CFrame.fromEulerAnglesXYZ(EulerX, EulerY, EulerZ) + Vector3.new(PosX, PosY, PosZ), CursorPosition + 30
	end
} :: TypeSerializer<CFrame>

DataTypes.UDim2 = {
	IsDynamic = false, ContainsInstances = false,
	GetByteSize = function(_ : UDim2) : number return 16 end,
	Write = function(TargetBuffer : buffer, CursorPosition : number, Value : UDim2)
		TargetBuffer = EnsureCapacity(TargetBuffer, CursorPosition, 16)
		BufferWriteF32(TargetBuffer, CursorPosition, Value.X.Scale)
		BufferWriteI32(TargetBuffer, CursorPosition + 4, Value.X.Offset)
		BufferWriteF32(TargetBuffer, CursorPosition + 8, Value.Y.Scale)
		BufferWriteI32(TargetBuffer, CursorPosition + 12, Value.Y.Offset)
		return CursorPosition + 16
	end,
	Read = function(TargetBuffer : buffer, CursorPosition : number)
		CheckBounds(TargetBuffer, CursorPosition, 16)
		local ScaleX : number = BufferReadF32(TargetBuffer, CursorPosition)
		local OffsetX : number = BufferReadI32(TargetBuffer, CursorPosition + 4)
		local ScaleY : number = BufferReadF32(TargetBuffer, CursorPosition + 8)
		local OffsetY : number = BufferReadI32(TargetBuffer, CursorPosition + 12)
		return UDim2.new(ScaleX, OffsetX, ScaleY, OffsetY), CursorPosition + 16
	end
} :: TypeSerializer<UDim2>

DataTypes.Color3 = {
	IsDynamic = false, ContainsInstances = false,
	GetByteSize = function(_ : Color3) : number return 3 end,
	Write = function(TargetBuffer : buffer, CursorPosition : number, Value : Color3)
		TargetBuffer = EnsureCapacity(TargetBuffer, CursorPosition, 3)
		BufferWriteU8(TargetBuffer, CursorPosition, MathRound(Value.R * 255))
		BufferWriteU8(TargetBuffer, CursorPosition + 1, MathRound(Value.G * 255))
		BufferWriteU8(TargetBuffer, CursorPosition + 2, MathRound(Value.B * 255))
		return CursorPosition + 3
	end,
	Read = function(TargetBuffer : buffer, CursorPosition : number)
		CheckBounds(TargetBuffer, CursorPosition, 3)
		return Color3.fromRGB(BufferReadU8(TargetBuffer, CursorPosition), BufferReadU8(TargetBuffer, CursorPosition + 1), BufferReadU8(TargetBuffer, CursorPosition + 2)), CursorPosition + 3
	end
} :: TypeSerializer<Color3>

DataTypes.DateTime = {
	IsDynamic = false, ContainsInstances = false,
	GetByteSize = function(_ : DateTime) : number return 8 end,
	Write = function(TargetBuffer : buffer, CursorPosition : number, Value : DateTime)
		TargetBuffer = EnsureCapacity(TargetBuffer, CursorPosition, 8)
		BufferWriteF64(TargetBuffer, CursorPosition, Value.UnixTimestampMillis)
		return CursorPosition + 8
	end,
	Read = function(TargetBuffer : buffer, CursorPosition : number)
		CheckBounds(TargetBuffer, CursorPosition, 8)
		return DateTime.fromUnixTimestampMillis(BufferReadF64(TargetBuffer, CursorPosition)), CursorPosition + 8
	end
} :: TypeSerializer<DateTime>

DataTypes.Buffer = {
	IsDynamic = true, ContainsInstances = false,
	GetByteSize = function(Value : buffer) : number return 4 + BufferLen(Value) end,
	Write = function(TargetBuffer : buffer, CursorPosition : number, Value : buffer)
		local Length : number = BufferLen(Value)
		TargetBuffer = EnsureCapacity(TargetBuffer, CursorPosition, 4 + Length)
		BufferWriteU32(TargetBuffer, CursorPosition, Length)
		BufferCopy(TargetBuffer, CursorPosition + 4, Value, 0, Length)
		return CursorPosition + 4 + Length
	end,
	Read = function(TargetBuffer : buffer, CursorPosition : number)
		CheckBounds(TargetBuffer, CursorPosition, 4)
		local Length : number = BufferReadU32(TargetBuffer, CursorPosition)
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
		Write = function(TargetBuffer : buffer, CursorPosition : number, Value : { T }, InstanceAccumulator : { Instance }, InstanceLookup : { [Instance] : number })
			local Count : number = #Value
			TargetBuffer = EnsureCapacity(TargetBuffer, CursorPosition, 4)
			BufferWriteU32(TargetBuffer, CursorPosition, Count)
			CursorPosition += 4
			for Index : number = 1, Count do CursorPosition = Inner.Write(TargetBuffer, CursorPosition, Value[Index], InstanceAccumulator, InstanceLookup) end
			return CursorPosition
		end,
		Read = function(TargetBuffer : buffer, CursorPosition : number, InstanceSource : { Instance })
			CheckBounds(TargetBuffer, CursorPosition, 4)
			local Count : number = BufferReadU32(TargetBuffer, CursorPosition)
			CursorPosition += 4
			local Result : { T } = table.create(Count)
			for Index : number = 1, Count do local Item : T; Item, CursorPosition = Inner.Read(TargetBuffer, CursorPosition, InstanceSource); Result[Index] = Item end
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
		Write = function(TargetBuffer : buffer, CursorPosition : number, Value : { [K] : V }, InstanceAccumulator : { Instance }, InstanceLookup : { [Instance] : number })
			local Count : number = 0
			for _ in pairs(Value) do Count += 1 end
			TargetBuffer = EnsureCapacity(TargetBuffer, CursorPosition, 4)
			BufferWriteU32(TargetBuffer, CursorPosition, Count)
			CursorPosition += 4
			for Key : K, Val : V in pairs(Value) do CursorPosition = KeyType.Write(TargetBuffer, CursorPosition, Key, InstanceAccumulator, InstanceLookup); CursorPosition = ValType.Write(TargetBuffer, CursorPosition, Val, InstanceAccumulator, InstanceLookup) end
			return CursorPosition
		end,
		Read = function(TargetBuffer : buffer, CursorPosition : number, InstanceSource : { Instance })
			CheckBounds(TargetBuffer, CursorPosition, 4)
			local Count : number = BufferReadU32(TargetBuffer, CursorPosition)
			CursorPosition += 4
			local Result : { [K] : V } = {}
			for Index : number = 1, Count do local Key : K, Val : V; Key, CursorPosition = KeyType.Read(TargetBuffer, CursorPosition, InstanceSource); Val, CursorPosition = ValType.Read(TargetBuffer, CursorPosition, InstanceSource); Result[Key] = Val end
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
		Write = function(TargetBuffer : buffer, CursorPosition : number, Value : { [string] : any }, InstanceAccumulator : { Instance }, InstanceLookup : { [Instance] : number })
			for Index : number, Key : string in ipairs(SortedKeys) do
				CursorPosition = FieldWriters[Index](TargetBuffer, CursorPosition, Value[Key], InstanceAccumulator, InstanceLookup)
			end
			return CursorPosition
		end,
		Read = function(TargetBuffer : buffer, CursorPosition : number, InstanceSource : { Instance })
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
	local function WriteAny(TargetBuffer : buffer, CursorPosition : number, Value : any, InstanceAccumulator : { Instance }, InstanceLookup : { [Instance] : number }) : number
		local Type : string = typeof(Value)
		TargetBuffer = EnsureCapacity(TargetBuffer, CursorPosition, 1)

		if Value == nil then BufferWriteU8(TargetBuffer, CursorPosition, 0); return CursorPosition + 1
		elseif Type == "string" then BufferWriteU8(TargetBuffer, CursorPosition, 3); return DataTypes.String.Write(TargetBuffer, CursorPosition + 1, Value, InstanceAccumulator, InstanceLookup)
		elseif Type == "number" then BufferWriteU8(TargetBuffer, CursorPosition, 2); return DataTypes.Float64.Write(TargetBuffer, CursorPosition + 1, Value, InstanceAccumulator, InstanceLookup)
		elseif Type == "boolean" then BufferWriteU8(TargetBuffer, CursorPosition, 1); return DataTypes.Boolean.Write(TargetBuffer, CursorPosition + 1, Value, InstanceAccumulator, InstanceLookup)
		elseif Type == "Instance" then BufferWriteU8(TargetBuffer, CursorPosition, 4); return DataTypes.Instance.Write(TargetBuffer, CursorPosition + 1, Value, InstanceAccumulator, InstanceLookup)
		elseif Type == "Vector3" then BufferWriteU8(TargetBuffer, CursorPosition, 5); return DataTypes.Vector3.Write(TargetBuffer, CursorPosition + 1, Value, InstanceAccumulator, InstanceLookup)
		elseif Type == "CFrame" then BufferWriteU8(TargetBuffer, CursorPosition, 7); return DataTypes.CFrame.Write(TargetBuffer, CursorPosition + 1, Value, InstanceAccumulator, InstanceLookup)
		elseif Type == "EnumItem" then BufferWriteU8(TargetBuffer, CursorPosition, 6); return DataTypes.UInt16.Write(TargetBuffer, CursorPosition + 1, Value.Value, InstanceAccumulator, InstanceLookup)
		else error("Ion: Unsupported Any type " .. Type) end
	end

	local function ReadAny(TargetBuffer : buffer, CursorPosition : number, InstanceSource : { Instance }) : (any, number)
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
		else error("Ion: Corrupt Any type") end
	end

	AnyTypeHandler = { IsDynamic = true, ContainsInstances = true, GetByteSize = function(Value : any) : number return 10 end, Write = WriteAny, Read = ReadAny }
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

type Middleware = {
	OnBeforeSend : ((...any) -> boolean)?,
	OnAfterReceived : ((...any) -> ())?
}

local function GetRateLimiter(PacketId : number, Player : Player, Rate : number) : RateLimit
	local PacketCache = RateLimiters[PacketId]
	if not PacketCache then PacketCache = {}; RateLimiters[PacketId] = PacketCache end
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
	for _, Cache in pairs(RateLimiters) do Cache[Player] = nil end
	GlobalRateLimitPerPlayer[Player] = nil
end)

local Ion = {}
Ion.Types = DataTypes

function Ion.GetStats() : Stats return GlobalStats end

function Ion.SetGlobalRateLimit(LimitPerSecond : number)
	GlobalLimitSettings = LimitPerSecond
end

function Ion.Define(Namespace : string, Schema : { TypeSerializer<any> }, Options : { Unreliable : boolean?, RateLimit : number?, Compress : boolean?, Middleware : Middleware? }?)
	local Hash : number = 0
	for Index = 1, #Namespace do Hash = (Hash * 31 + string.byte(Namespace, Index)) % 256 end

	if Definitions[Hash] then error("Ion: Namespace collision for '" .. Namespace .. "'") end
	Definitions[Hash] = Schema

	local IsUnreliable : boolean = Options and Options.Unreliable or false
	local Rate : number? = Options and Options.RateLimit
	local UseCompression : boolean = Options and Options.Compress or false
	local Hooks : Middleware? = Options and Options.Middleware

	local RemoteName : string = "Ion_" .. Hash

	if RunService:IsServer() then
		local Remote : Instance
		if IsUnreliable then Remote = Instance.new("UnreliableRemoteEvent") else Remote = Instance.new("RemoteEvent") end
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
				if Limiter.Tokens >= 1 then Limiter.Tokens -= 1 else return end
			end

			local Length : number = BufferLen(Data)
			GlobalStats.TotalBytesReceived += Length
			GlobalStats.PacketsReceived += 1

			if UseCompression then
				local Base64Data : buffer = Data
				local Compressed : buffer = EncodingService:Base64Decode(Base64Data)
				Data = EncodingService:DecompressBuffer(Compressed, Enum.CompressionAlgorithm.Zstd)
			end

			local Callback = Listeners[Hash]
			if Callback then
				local Args : { any } = {}
				local CursorPosition : number = 0
				CheckBounds(Data, CursorPosition, 2)
				local Version : number = BufferReadU8(Data, CursorPosition)
				local PacketId : number = BufferReadU8(Data, CursorPosition + 1)
				CursorPosition += 2

				if Version ~= IonVersion or PacketId ~= Hash then return end
				for Index, Serializer : TypeSerializer<any> in ipairs(Schema) do
					local Value : any
					Value, CursorPosition = Serializer.Read(Data, CursorPosition, Instances)
					table.insert(Args, Value)
				end

				if Hooks and Hooks.OnAfterReceived then Hooks.OnAfterReceived(Player, table.unpack(Args)) end
				Callback(Player, table.unpack(Args))
			end
		end

		if IsUnreliable then (Remote :: UnreliableRemoteEvent).OnServerEvent:Connect(OnServerEvent)
		else (Remote :: RemoteEvent).OnServerEvent:Connect(OnServerEvent) end
	else
		local Remote : Instance = ReplicatedStorage:WaitForChild(RemoteName)
		RemoteCache[Hash] = Remote :: any

		local function OnClientEvent(Data : buffer, Instances : { Instance })
			local Length : number = BufferLen(Data)
			GlobalStats.TotalBytesReceived += Length
			GlobalStats.PacketsReceived += 1

			if UseCompression then
				local Base64Data : buffer = Data
				local Compressed : buffer = EncodingService:Base64Decode(Base64Data)
				Data = EncodingService:DecompressBuffer(Compressed, Enum.CompressionAlgorithm.Zstd)
			end

			local Callback = Listeners[Hash]
			if Callback then
				local Args : { any } = {}
				local CursorPosition : number = 0
				CheckBounds(Data, CursorPosition, 2)
				local Version : number = BufferReadU8(Data, CursorPosition)
				local PacketId : number = BufferReadU8(Data, CursorPosition + 1)
				CursorPosition += 2

				if Version ~= IonVersion or PacketId ~= Hash then return end
				for Index, Serializer : TypeSerializer<any> in ipairs(Schema) do
					local Value : any
					Value, CursorPosition = Serializer.Read(Data, CursorPosition, Instances)
					table.insert(Args, Value)
				end

				if Hooks and Hooks.OnAfterReceived then Hooks.OnAfterReceived(table.unpack(Args)) end
				Callback(table.unpack(Args))
			end
		end

		if IsUnreliable then (Remote :: UnreliableRemoteEvent).OnClientEvent:Connect(OnClientEvent)
		else (Remote :: RemoteEvent).OnClientEvent:Connect(OnClientEvent) end
	end

	local PacketObject = {}

	function PacketObject.Send(Target : Player?, ... : any)
		if Hooks and Hooks.OnBeforeSend then
			if not Hooks.OnBeforeSend(...) then return end
		end

		local Args : { any } = { ... }
		local TargetBuffer : buffer = AcquireBuffer(1024)
		local CursorPosition : number = 0
		local InstanceAccumulator : { Instance } = {}
		local InstanceLookup : { [Instance] : number } = {}

		TargetBuffer = EnsureCapacity(TargetBuffer, CursorPosition, 2)
		BufferWriteU8(TargetBuffer, CursorPosition, IonVersion)
		BufferWriteU8(TargetBuffer, CursorPosition + 1, Hash)
		CursorPosition += 2

		for Index, Serializer : TypeSerializer<any> in ipairs(Schema) do
			CursorPosition = Serializer.Write(TargetBuffer, CursorPosition, Args[Index], InstanceAccumulator, InstanceLookup)
		end

		local FinalBuffer : buffer = BufferCreate(CursorPosition)
		BufferCopy(FinalBuffer, 0, TargetBuffer, 0, CursorPosition)
		ReleaseBuffer(TargetBuffer)

		if UseCompression then
			local Compressed : buffer = EncodingService:CompressBuffer(FinalBuffer, Enum.CompressionAlgorithm.Zstd)
			FinalBuffer = EncodingService:Base64Encode(Compressed)
		end

		local Size : number = BufferLen(FinalBuffer)
		if IsUnreliable and Size > MaxPacketSize then warn("Ion: Unreliable packet too large"); return end

		GlobalStats.TotalBytesSent += Size
		GlobalStats.PacketsSent += 1

		local Remote : any = RemoteCache[Hash]
		if RunService:IsServer() then
			if Target then Remote:FireClient(Target, FinalBuffer, InstanceAccumulator)
			else Remote:FireAllClients(FinalBuffer, InstanceAccumulator) end
		else
			Remote:FireServer(FinalBuffer, InstanceAccumulator)
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
	function ServerInterface.SendToList(Recipients : { Player }, ... : any) for _, Player in ipairs(Recipients) do PacketObject.Send(Player, ...) end end
	function ServerInterface.Listen(Callback : (Player, ...any) -> ()) PacketObject.Listen(Callback) end

	function ClientInterface.Send(... : any) PacketObject.Send(nil, ...) end
	function ClientInterface.Listen(Callback : (...any) -> ()) PacketObject.Listen(Callback) end

	return {
		Server = ServerInterface,
		Client = ClientInterface
	} :: IonPacket<any>
end

return Ion