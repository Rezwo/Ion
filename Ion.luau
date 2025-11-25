--!strict
--!native
--!optimize 2

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

export type IonPacket<T...> = {
	Server : {
		SendTo : (Recipient : Player, T...) -> (),
		SendToAll : (T...) -> (),
		SendToList : (Recipients : {Player}, T...) -> (),
		Listen : (Callback : (Player, T...) -> ()) -> ()
	},
	Client : {
		Send : (T...) -> (),
		Listen : (Callback : (T...) -> ()) -> ()
	}
}

export type TypeSerializer<ValueType = any> = {
	Write : (TargetBuffer : buffer, CurrentOffset : number, ValueToWrite : ValueType, InstanceAccumulator : {Instance}?, InstanceLookup : {[Instance]: number}?) -> number,
	Read : (SourceBuffer : buffer, CurrentOffset : number, InstanceSource : {Instance}?) -> (ValueType, number),
	GetByteSize : (ValueToCheck : ValueType) -> number,
	IsDynamic : boolean,
	ContainsInstances : boolean
}

export type PacketOptions = {
	Unreliable : boolean?,
	RateLimit : number?,
	Dedicated : boolean?
}

local ReliableChannelName = "IonReliable"
local UnreliableChannelName = "IonUnreliable"
local IsServerEnvironment = RunService:IsServer()

local MainReliableRemote : RemoteEvent
local MainUnreliableRemote : UnreliableRemoteEvent

local SharedInstanceLookupTable = {}

local function GetRemoteEvent(RemoteName : string, IsUnreliable : boolean) : RemoteEvent | UnreliableRemoteEvent
	if IsServerEnvironment then
		local RemoteObject = ReplicatedStorage:FindFirstChild(RemoteName)
		if not RemoteObject then
			RemoteObject = Instance.new(if IsUnreliable then "UnreliableRemoteEvent" else "RemoteEvent")
			RemoteObject.Name = RemoteName
			RemoteObject.Parent = ReplicatedStorage
		end
		return (RemoteObject :: any) :: (RemoteEvent | UnreliableRemoteEvent)
	else
		return (ReplicatedStorage:WaitForChild(RemoteName) :: any) :: (RemoteEvent | UnreliableRemoteEvent)
	end
end

MainReliableRemote = GetRemoteEvent(ReliableChannelName, false) :: RemoteEvent
MainUnreliableRemote = GetRemoteEvent(UnreliableChannelName, true) :: UnreliableRemoteEvent

local function WriteFloat16(TargetBuffer : buffer, ByteOffset : number, ValueToWrite : number)
	local SignBit = if ValueToWrite < 0 then 0x8000 else 0
	if ValueToWrite < 0 then ValueToWrite = -ValueToWrite end

	local EncodedValue = 0
	if ValueToWrite ~= 0 then
		local Mantissa, Exponent = math.frexp(ValueToWrite)
		Exponent += 14
		if Exponent <= 0 then
			Mantissa = math.ldexp(Mantissa, Exponent + 10)
			EncodedValue = SignBit + math.floor(Mantissa + 0.5)
		elseif Exponent >= 32 then
			EncodedValue = SignBit + 0x7C00
		else
			EncodedValue = SignBit + bit32.lshift(Exponent, 10) + math.floor(Mantissa * 1024 + 0.5) % 1024
		end
	end
	buffer.writeu16(TargetBuffer, ByteOffset, EncodedValue)
end

local function ReadFloat16(SourceBuffer : buffer, ByteOffset : number) : number
	local EncodedValue = buffer.readu16(SourceBuffer, ByteOffset)
	local SignBit = bit32.btest(EncodedValue, 0x8000)
	local Exponent = bit32.rshift(bit32.band(EncodedValue, 0x7C00), 10)
	local Mantissa = bit32.band(EncodedValue, 0x03FF)

	if Exponent == 0 then
		if Mantissa == 0 then return 0 end
		local ResultValue = math.ldexp(Mantissa, -24)
		return if SignBit then -ResultValue else ResultValue
	elseif Exponent == 31 then
		return if Mantissa == 0 then (if SignBit then -math.huge else math.huge) else 0/0
	end

	local ResultValue = math.ldexp(Mantissa + 1024, Exponent - 25)
	return if SignBit then -ResultValue else ResultValue
end

local DataTypes = {}

DataTypes.Byte = {
	IsDynamic = false, ContainsInstances = false,
	GetByteSize = function(_ : number) : number return 1 end,
	Write = function(TargetBuffer : buffer, CurrentOffset : number, ValueToWrite : number) : number 
		buffer.writeu8(TargetBuffer, CurrentOffset, ValueToWrite or 0) 
		return CurrentOffset + 1 
	end,
	Read = function(SourceBuffer : buffer, CurrentOffset : number) : (number, number) 
		return buffer.readu8(SourceBuffer, CurrentOffset), CurrentOffset + 1 
	end
} :: TypeSerializer<number>

DataTypes.Int8 = {
	IsDynamic = false, ContainsInstances = false,
	GetByteSize = function(_ : number) : number return 1 end,
	Write = function(TargetBuffer : buffer, CurrentOffset : number, ValueToWrite : number) : number 
		buffer.writei8(TargetBuffer, CurrentOffset, ValueToWrite or 0) 
		return CurrentOffset + 1 
	end,
	Read = function(SourceBuffer : buffer, CurrentOffset : number) : (number, number) 
		return buffer.readi8(SourceBuffer, CurrentOffset), CurrentOffset + 1 
	end
} :: TypeSerializer<number>

DataTypes.UInt8 = DataTypes.Byte

DataTypes.Int16 = {
	IsDynamic = false, ContainsInstances = false,
	GetByteSize = function(_ : number) : number return 2 end,
	Write = function(TargetBuffer : buffer, CurrentOffset : number, ValueToWrite : number) : number 
		buffer.writei16(TargetBuffer, CurrentOffset, ValueToWrite or 0) 
		return CurrentOffset + 2 
	end,
	Read = function(SourceBuffer : buffer, CurrentOffset : number) : (number, number) 
		return buffer.readi16(SourceBuffer, CurrentOffset), CurrentOffset + 2 
	end
} :: TypeSerializer<number>

DataTypes.UInt16 = {
	IsDynamic = false, ContainsInstances = false,
	GetByteSize = function(_ : number) : number return 2 end,
	Write = function(TargetBuffer : buffer, CurrentOffset : number, ValueToWrite : number) : number 
		buffer.writeu16(TargetBuffer, CurrentOffset, ValueToWrite or 0) 
		return CurrentOffset + 2 
	end,
	Read = function(SourceBuffer : buffer, CurrentOffset : number) : (number, number) 
		return buffer.readu16(SourceBuffer, CurrentOffset), CurrentOffset + 2 
	end
} :: TypeSerializer<number>

DataTypes.UInt24 = {
	IsDynamic = false, ContainsInstances = false,
	GetByteSize = function(_ : number) : number return 3 end,
	Write = function(TargetBuffer : buffer, CurrentOffset : number, ValueToWrite : number) : number 
		buffer.writebits(TargetBuffer, CurrentOffset * 8, 24, ValueToWrite or 0) 
		return CurrentOffset + 3 
	end,
	Read = function(SourceBuffer : buffer, CurrentOffset : number) : (number, number) 
		return buffer.readbits(SourceBuffer, CurrentOffset * 8, 24), CurrentOffset + 3 
	end
} :: TypeSerializer<number>

DataTypes.Int32 = {
	IsDynamic = false, ContainsInstances = false,
	GetByteSize = function(_ : number) : number return 4 end,
	Write = function(TargetBuffer : buffer, CurrentOffset : number, ValueToWrite : number) : number 
		buffer.writei32(TargetBuffer, CurrentOffset, ValueToWrite or 0) 
		return CurrentOffset + 4 
	end,
	Read = function(SourceBuffer : buffer, CurrentOffset : number) : (number, number) 
		return buffer.readi32(SourceBuffer, CurrentOffset), CurrentOffset + 4 
	end
} :: TypeSerializer<number>

DataTypes.UInt32 = {
	IsDynamic = false, ContainsInstances = false,
	GetByteSize = function(_ : number) : number return 4 end,
	Write = function(TargetBuffer : buffer, CurrentOffset : number, ValueToWrite : number) : number 
		buffer.writeu32(TargetBuffer, CurrentOffset, ValueToWrite or 0) 
		return CurrentOffset + 4 
	end,
	Read = function(SourceBuffer : buffer, CurrentOffset : number) : (number, number) 
		return buffer.readu32(SourceBuffer, CurrentOffset), CurrentOffset + 4 
	end
} :: TypeSerializer<number>

DataTypes.Float16 = {
	IsDynamic = false, ContainsInstances = false,
	GetByteSize = function(_ : number) : number return 2 end,
	Write = function(TargetBuffer : buffer, CurrentOffset : number, ValueToWrite : number) : number 
		WriteFloat16(TargetBuffer, CurrentOffset, ValueToWrite or 0) 
		return CurrentOffset + 2 
	end,
	Read = function(SourceBuffer : buffer, CurrentOffset : number) : (number, number) 
		return ReadFloat16(SourceBuffer, CurrentOffset), CurrentOffset + 2 
	end
} :: TypeSerializer<number>

DataTypes.Float32 = {
	IsDynamic = false, ContainsInstances = false,
	GetByteSize = function(_ : number) : number return 4 end,
	Write = function(TargetBuffer : buffer, CurrentOffset : number, ValueToWrite : number) : number 
		buffer.writef32(TargetBuffer, CurrentOffset, ValueToWrite or 0) 
		return CurrentOffset + 4 
	end,
	Read = function(SourceBuffer : buffer, CurrentOffset : number) : (number, number) 
		return buffer.readf32(SourceBuffer, CurrentOffset), CurrentOffset + 4 
	end
} :: TypeSerializer<number>

DataTypes.Float64 = {
	IsDynamic = false, ContainsInstances = false,
	GetByteSize = function(_ : number) : number return 8 end,
	Write = function(TargetBuffer : buffer, CurrentOffset : number, ValueToWrite : number) : number 
		buffer.writef64(TargetBuffer, CurrentOffset, ValueToWrite or 0) 
		return CurrentOffset + 8 
	end,
	Read = function(SourceBuffer : buffer, CurrentOffset : number) : (number, number) 
		return buffer.readf64(SourceBuffer, CurrentOffset), CurrentOffset + 8 
	end
} :: TypeSerializer<number>

DataTypes.Boolean = {
	IsDynamic = false, ContainsInstances = false,
	GetByteSize = function(_ : boolean) : number return 1 end,
	Write = function(TargetBuffer : buffer, CurrentOffset : number, ValueToWrite : boolean) : number 
		buffer.writeu8(TargetBuffer, CurrentOffset, if ValueToWrite then 1 else 0) 
		return CurrentOffset + 1 
	end,
	Read = function(SourceBuffer : buffer, CurrentOffset : number) : (boolean, number) 
		return buffer.readu8(SourceBuffer, CurrentOffset) == 1, CurrentOffset + 1 
	end
} :: TypeSerializer<boolean>

DataTypes.Instance = {
	IsDynamic = false, ContainsInstances = true,
	GetByteSize = function(_ : Instance) : number return 2 end,
	Write = function(TargetBuffer : buffer, CurrentOffset : number, ValueToWrite : Instance, InstanceAccumulator : {Instance}?, InstanceLookup : {[Instance]: number}?) : number
		if InstanceAccumulator and InstanceLookup then
			local ExistingIndex = InstanceLookup[ValueToWrite]
			if ExistingIndex then
				buffer.writeu16(TargetBuffer, CurrentOffset, ExistingIndex)
			else
				local NewIndex = #InstanceAccumulator + 1
				InstanceAccumulator[NewIndex] = ValueToWrite
				InstanceLookup[ValueToWrite] = NewIndex
				buffer.writeu16(TargetBuffer, CurrentOffset, NewIndex)
			end
		else
			buffer.writeu16(TargetBuffer, CurrentOffset, 0) 
		end
		return CurrentOffset + 2
	end,
	Read = function(SourceBuffer : buffer, CurrentOffset : number, InstanceSource : {Instance}?) : (Instance?, number)
		local InstanceIndex = buffer.readu16(SourceBuffer, CurrentOffset)
		return if InstanceSource and InstanceSource[InstanceIndex] then InstanceSource[InstanceIndex] else nil, CurrentOffset + 2
	end
} :: TypeSerializer<Instance>

DataTypes.Enum = {
	IsDynamic = false, ContainsInstances = false,
	GetByteSize = function(_ : EnumItem) : number return 2 end,
	Write = function(TargetBuffer : buffer, CurrentOffset : number, ValueToWrite : EnumItem) : number 
		buffer.writeu16(TargetBuffer, CurrentOffset, ValueToWrite.Value) 
		return CurrentOffset + 2 
	end,
	Read = function(SourceBuffer : buffer, CurrentOffset : number) : (number, number) 
		return buffer.readu16(SourceBuffer, CurrentOffset), CurrentOffset + 2 
	end
} :: TypeSerializer<EnumItem>

DataTypes.NativeVector = {
	IsDynamic = false, ContainsInstances = false,
	GetByteSize = function(_ : vector) : number return 12 end,
	Write = function(TargetBuffer : buffer, CurrentOffset : number, ValueToWrite : vector) : number
		buffer.writef32(TargetBuffer, CurrentOffset, ValueToWrite.x)
		buffer.writef32(TargetBuffer, CurrentOffset + 4, ValueToWrite.y)
		buffer.writef32(TargetBuffer, CurrentOffset + 8, ValueToWrite.z)
		return CurrentOffset + 12
	end,
	Read = function(SourceBuffer : buffer, CurrentOffset : number) : (vector, number)
		return vector.create(
			buffer.readf32(SourceBuffer, CurrentOffset), 
			buffer.readf32(SourceBuffer, CurrentOffset + 4), 
			buffer.readf32(SourceBuffer, CurrentOffset + 8)
		), CurrentOffset + 12
	end
} :: TypeSerializer<vector>

DataTypes.Vector3Float32 = {
	IsDynamic = false, ContainsInstances = false,
	GetByteSize = function(_ : Vector3) : number return 12 end,
	Write = function(TargetBuffer : buffer, CurrentOffset : number, ValueToWrite : Vector3) : number
		buffer.writef32(TargetBuffer, CurrentOffset, ValueToWrite.X)
		buffer.writef32(TargetBuffer, CurrentOffset + 4, ValueToWrite.Y)
		buffer.writef32(TargetBuffer, CurrentOffset + 8, ValueToWrite.Z)
		return CurrentOffset + 12
	end,
	Read = function(SourceBuffer : buffer, CurrentOffset : number) : (Vector3, number)
		return Vector3.new(
			buffer.readf32(SourceBuffer, CurrentOffset), 
			buffer.readf32(SourceBuffer, CurrentOffset + 4), 
			buffer.readf32(SourceBuffer, CurrentOffset + 8)
		), CurrentOffset + 12
	end
} :: TypeSerializer<Vector3>

DataTypes.Vector3 = DataTypes.Vector3Float32

DataTypes.Vector3Float16 = {
	IsDynamic = false, ContainsInstances = false,
	GetByteSize = function(_ : Vector3) : number return 6 end,
	Write = function(TargetBuffer : buffer, CurrentOffset : number, ValueToWrite : Vector3) : number
		WriteFloat16(TargetBuffer, CurrentOffset, ValueToWrite.X)
		WriteFloat16(TargetBuffer, CurrentOffset + 2, ValueToWrite.Y)
		WriteFloat16(TargetBuffer, CurrentOffset + 4, ValueToWrite.Z)
		return CurrentOffset + 6
	end,
	Read = function(SourceBuffer : buffer, CurrentOffset : number) : (Vector3, number)
		local VectorX = ReadFloat16(SourceBuffer, CurrentOffset)
		local VectorY = ReadFloat16(SourceBuffer, CurrentOffset + 2)
		local VectorZ = ReadFloat16(SourceBuffer, CurrentOffset + 4)
		return Vector3.new(VectorX, VectorY, VectorZ), CurrentOffset + 6
	end
} :: TypeSerializer<Vector3>

DataTypes.Vector3Float64 = {
	IsDynamic = false, ContainsInstances = false,
	GetByteSize = function(_ : Vector3) : number return 24 end,
	Write = function(TargetBuffer : buffer, CurrentOffset : number, ValueToWrite : Vector3) : number
		buffer.writef64(TargetBuffer, CurrentOffset, ValueToWrite.X)
		buffer.writef64(TargetBuffer, CurrentOffset + 8, ValueToWrite.Y)
		buffer.writef64(TargetBuffer, CurrentOffset + 16, ValueToWrite.Z)
		return CurrentOffset + 24
	end,
	Read = function(SourceBuffer : buffer, CurrentOffset : number) : (Vector3, number)
		return Vector3.new(
			buffer.readf64(SourceBuffer, CurrentOffset), 
			buffer.readf64(SourceBuffer, CurrentOffset + 8), 
			buffer.readf64(SourceBuffer, CurrentOffset + 16)
		), CurrentOffset + 24
	end
} :: TypeSerializer<Vector3>

DataTypes.Vector3Int8 = {
	IsDynamic = false, ContainsInstances = false,
	GetByteSize = function(_ : Vector3) : number return 3 end,
	Write = function(TargetBuffer : buffer, CurrentOffset : number, ValueToWrite : Vector3) : number
		buffer.writei8(TargetBuffer, CurrentOffset, math.round(ValueToWrite.X))
		buffer.writei8(TargetBuffer, CurrentOffset + 1, math.round(ValueToWrite.Y))
		buffer.writei8(TargetBuffer, CurrentOffset + 2, math.round(ValueToWrite.Z))
		return CurrentOffset + 3
	end,
	Read = function(SourceBuffer : buffer, CurrentOffset : number) : (Vector3, number)
		return Vector3.new(
			buffer.readi8(SourceBuffer, CurrentOffset), 
			buffer.readi8(SourceBuffer, CurrentOffset + 1), 
			buffer.readi8(SourceBuffer, CurrentOffset + 2)
		), CurrentOffset + 3
	end
} :: TypeSerializer<Vector3>

DataTypes.Vector3Int16 = {
	IsDynamic = false, ContainsInstances = false,
	GetByteSize = function(_ : Vector3) : number return 6 end,
	Write = function(TargetBuffer : buffer, CurrentOffset : number, ValueToWrite : Vector3) : number
		buffer.writei16(TargetBuffer, CurrentOffset, math.round(ValueToWrite.X))
		buffer.writei16(TargetBuffer, CurrentOffset + 2, math.round(ValueToWrite.Y))
		buffer.writei16(TargetBuffer, CurrentOffset + 4, math.round(ValueToWrite.Z))
		return CurrentOffset + 6
	end,
	Read = function(SourceBuffer : buffer, CurrentOffset : number) : (Vector3, number)
		return Vector3.new(
			buffer.readi16(SourceBuffer, CurrentOffset), 
			buffer.readi16(SourceBuffer, CurrentOffset + 2), 
			buffer.readi16(SourceBuffer, CurrentOffset + 4)
		), CurrentOffset + 6
	end
} :: TypeSerializer<Vector3>

DataTypes.Vector3Int32 = {
	IsDynamic = false, ContainsInstances = false,
	GetByteSize = function(_ : Vector3) : number return 12 end,
	Write = function(TargetBuffer : buffer, CurrentOffset : number, ValueToWrite : Vector3) : number
		buffer.writei32(TargetBuffer, CurrentOffset, math.round(ValueToWrite.X))
		buffer.writei32(TargetBuffer, CurrentOffset + 4, math.round(ValueToWrite.Y))
		buffer.writei32(TargetBuffer, CurrentOffset + 8, math.round(ValueToWrite.Z))
		return CurrentOffset + 12
	end,
	Read = function(SourceBuffer : buffer, CurrentOffset : number) : (Vector3, number)
		return Vector3.new(
			buffer.readi32(SourceBuffer, CurrentOffset), 
			buffer.readi32(SourceBuffer, CurrentOffset + 4), 
			buffer.readi32(SourceBuffer, CurrentOffset + 8)
		), CurrentOffset + 12
	end
} :: TypeSerializer<Vector3>

DataTypes.CFrame = {
	IsDynamic = false, ContainsInstances = false,
	GetByteSize = function(_ : CFrame) : number return 18 end,
	Write = function(TargetBuffer : buffer, CurrentOffset : number, ValueToWrite : CFrame) : number
		buffer.writef32(TargetBuffer, CurrentOffset, ValueToWrite.X)
		buffer.writef32(TargetBuffer, CurrentOffset + 4, ValueToWrite.Y)
		buffer.writef32(TargetBuffer, CurrentOffset + 8, ValueToWrite.Z)
		local EulerAngleX, EulerAngleY, EulerAngleZ = ValueToWrite:ToEulerAnglesXYZ()
		buffer.writeu16(TargetBuffer, CurrentOffset + 12, EulerAngleX * 10430.2191955 + 0.5)
		buffer.writeu16(TargetBuffer, CurrentOffset + 14, EulerAngleY * 10430.2191955 + 0.5)
		buffer.writeu16(TargetBuffer, CurrentOffset + 16, EulerAngleZ * 10430.2191955 + 0.5)
		return CurrentOffset + 18
	end,
	Read = function(SourceBuffer : buffer, CurrentOffset : number) : (CFrame, number)
		local PositionX, PositionY, PositionZ = buffer.readf32(SourceBuffer, CurrentOffset), buffer.readf32(SourceBuffer, CurrentOffset + 4), buffer.readf32(SourceBuffer, CurrentOffset + 8)
		local EulerAngleX, EulerAngleY, EulerAngleZ = buffer.readu16(SourceBuffer, CurrentOffset + 12) / 10430.2191955, buffer.readu16(SourceBuffer, CurrentOffset + 14) / 10430.2191955, buffer.readu16(SourceBuffer, CurrentOffset + 16) / 10430.2191955
		return CFrame.fromEulerAnglesXYZ(EulerAngleX, EulerAngleY, EulerAngleZ) + Vector3.new(PositionX, PositionY, PositionZ), CurrentOffset + 18
	end
} :: TypeSerializer<CFrame>

DataTypes.CFramePosition = {
	IsDynamic = false, ContainsInstances = false,
	GetByteSize = function(_ : CFrame) : number return 12 end,
	Write = function(TargetBuffer : buffer, CurrentOffset : number, ValueToWrite : CFrame) : number
		buffer.writef32(TargetBuffer, CurrentOffset, ValueToWrite.X)
		buffer.writef32(TargetBuffer, CurrentOffset + 4, ValueToWrite.Y)
		buffer.writef32(TargetBuffer, CurrentOffset + 8, ValueToWrite.Z)
		return CurrentOffset + 12
	end,
	Read = function(SourceBuffer : buffer, CurrentOffset : number) : (CFrame, number)
		return CFrame.new(
			buffer.readf32(SourceBuffer, CurrentOffset),
			buffer.readf32(SourceBuffer, CurrentOffset + 4),
			buffer.readf32(SourceBuffer, CurrentOffset + 8)
		), CurrentOffset + 12
	end
} :: TypeSerializer<CFrame>

DataTypes.CFrameFloat16 = {
	IsDynamic = false, ContainsInstances = false,
	GetByteSize = function(_ : CFrame) : number return 12 end,
	Write = function(TargetBuffer : buffer, CurrentOffset : number, ValueToWrite : CFrame) : number
		WriteFloat16(TargetBuffer, CurrentOffset, ValueToWrite.X)
		WriteFloat16(TargetBuffer, CurrentOffset + 2, ValueToWrite.Y)
		WriteFloat16(TargetBuffer, CurrentOffset + 4, ValueToWrite.Z)
		local EulerAngleX, EulerAngleY, EulerAngleZ = ValueToWrite:ToEulerAnglesXYZ()
		buffer.writeu16(TargetBuffer, CurrentOffset + 6, EulerAngleX * 10430.2191955 + 0.5)
		buffer.writeu16(TargetBuffer, CurrentOffset + 8, EulerAngleY * 10430.2191955 + 0.5)
		buffer.writeu16(TargetBuffer, CurrentOffset + 10, EulerAngleZ * 10430.2191955 + 0.5)
		return CurrentOffset + 12
	end,
	Read = function(SourceBuffer : buffer, CurrentOffset : number) : (CFrame, number)
		local PositionX = ReadFloat16(SourceBuffer, CurrentOffset)
		local PositionY = ReadFloat16(SourceBuffer, CurrentOffset + 2)
		local PositionZ = ReadFloat16(SourceBuffer, CurrentOffset + 4)
		local EulerAngleX, EulerAngleY, EulerAngleZ = buffer.readu16(SourceBuffer, CurrentOffset + 6) / 10430.2191955, buffer.readu16(SourceBuffer, CurrentOffset + 8) / 10430.2191955, buffer.readu16(SourceBuffer, CurrentOffset + 10) / 10430.2191955
		return CFrame.fromEulerAnglesXYZ(EulerAngleX, EulerAngleY, EulerAngleZ) + Vector3.new(PositionX, PositionY, PositionZ), CurrentOffset + 12
	end
} :: TypeSerializer<CFrame>

DataTypes.CFrameInt16 = {
	IsDynamic = false, ContainsInstances = false,
	GetByteSize = function(_ : CFrame) : number return 12 end,
	Write = function(TargetBuffer : buffer, CurrentOffset : number, ValueToWrite : CFrame) : number
		buffer.writei16(TargetBuffer, CurrentOffset, math.round(ValueToWrite.X))
		buffer.writei16(TargetBuffer, CurrentOffset + 2, math.round(ValueToWrite.Y))
		buffer.writei16(TargetBuffer, CurrentOffset + 4, math.round(ValueToWrite.Z))
		local EulerAngleX, EulerAngleY, EulerAngleZ = ValueToWrite:ToEulerAnglesXYZ()
		buffer.writeu16(TargetBuffer, CurrentOffset + 6, EulerAngleX * 10430.2191955 + 0.5)
		buffer.writeu16(TargetBuffer, CurrentOffset + 8, EulerAngleY * 10430.2191955 + 0.5)
		buffer.writeu16(TargetBuffer, CurrentOffset + 10, EulerAngleZ * 10430.2191955 + 0.5)
		return CurrentOffset + 12
	end,
	Read = function(SourceBuffer : buffer, CurrentOffset : number) : (CFrame, number)
		local PositionX, PositionY, PositionZ = buffer.readi16(SourceBuffer, CurrentOffset), buffer.readi16(SourceBuffer, CurrentOffset + 2), buffer.readi16(SourceBuffer, CurrentOffset + 4)
		local EulerAngleX, EulerAngleY, EulerAngleZ = buffer.readu16(SourceBuffer, CurrentOffset + 6) / 10430.2191955, buffer.readu16(SourceBuffer, CurrentOffset + 8) / 10430.2191955, buffer.readu16(SourceBuffer, CurrentOffset + 10) / 10430.2191955
		return CFrame.fromEulerAnglesXYZ(EulerAngleX, EulerAngleY, EulerAngleZ) + Vector3.new(PositionX, PositionY, PositionZ), CurrentOffset + 12
	end
} :: TypeSerializer<CFrame>

DataTypes.CFrameHighPrecision = {
	IsDynamic = false, ContainsInstances = false,
	GetByteSize = function(_ : CFrame) : number return 30 end,
	Write = function(TargetBuffer : buffer, CurrentOffset : number, ValueToWrite : CFrame) : number
		buffer.writef64(TargetBuffer, CurrentOffset, ValueToWrite.X)
		buffer.writef64(TargetBuffer, CurrentOffset + 8, ValueToWrite.Y)
		buffer.writef64(TargetBuffer, CurrentOffset + 16, ValueToWrite.Z)
		local EulerAngleX, EulerAngleY, EulerAngleZ = ValueToWrite:ToEulerAnglesXYZ()
		buffer.writeu16(TargetBuffer, CurrentOffset + 24, EulerAngleX * 10430.2191955 + 0.5)
		buffer.writeu16(TargetBuffer, CurrentOffset + 26, EulerAngleY * 10430.2191955 + 0.5)
		buffer.writeu16(TargetBuffer, CurrentOffset + 28, EulerAngleZ * 10430.2191955 + 0.5)
		return CurrentOffset + 30
	end,
	Read = function(SourceBuffer : buffer, CurrentOffset : number) : (CFrame, number)
		local PositionX, PositionY, PositionZ = buffer.readf64(SourceBuffer, CurrentOffset), buffer.readf64(SourceBuffer, CurrentOffset + 8), buffer.readf64(SourceBuffer, CurrentOffset + 16)
		local EulerAngleX, EulerAngleY, EulerAngleZ = buffer.readu16(SourceBuffer, CurrentOffset + 24) / 10430.2191955, buffer.readu16(SourceBuffer, CurrentOffset + 26) / 10430.2191955, buffer.readu16(SourceBuffer, CurrentOffset + 28) / 10430.2191955
		return CFrame.fromEulerAnglesXYZ(EulerAngleX, EulerAngleY, EulerAngleZ) + Vector3.new(PositionX, PositionY, PositionZ), CurrentOffset + 30
	end
} :: TypeSerializer<CFrame>

DataTypes.Color3 = {
	IsDynamic = false, ContainsInstances = false,
	GetByteSize = function(_ : Color3) : number return 3 end,
	Write = function(TargetBuffer : buffer, CurrentOffset : number, ValueToWrite : Color3) : number
		buffer.writeu8(TargetBuffer, CurrentOffset, math.round(ValueToWrite.R * 255))
		buffer.writeu8(TargetBuffer, CurrentOffset+1, math.round(ValueToWrite.G * 255))
		buffer.writeu8(TargetBuffer, CurrentOffset+2, math.round(ValueToWrite.B * 255))
		return CurrentOffset + 3
	end,
	Read = function(SourceBuffer : buffer, CurrentOffset : number) : (Color3, number)
		return Color3.fromRGB(
			buffer.readu8(SourceBuffer, CurrentOffset), 
			buffer.readu8(SourceBuffer, CurrentOffset+1), 
			buffer.readu8(SourceBuffer, CurrentOffset+2)
		), CurrentOffset + 3 
	end
} :: TypeSerializer<Color3>

DataTypes.String = {
	IsDynamic = true, ContainsInstances = false,
	GetByteSize = function(ValueToWrite : string) : number return 2 + #ValueToWrite end,
	Write = function(TargetBuffer : buffer, CurrentOffset : number, ValueToWrite : string) : number
		local StringLength = #ValueToWrite
		buffer.writeu16(TargetBuffer, CurrentOffset, StringLength)
		buffer.writestring(TargetBuffer, CurrentOffset + 2, ValueToWrite)
		return CurrentOffset + 2 + StringLength
	end,
	Read = function(SourceBuffer : buffer, CurrentOffset : number) : (string, number)
		local StringLength = buffer.readu16(SourceBuffer, CurrentOffset)
		return buffer.readstring(SourceBuffer, CurrentOffset + 2, StringLength), CurrentOffset + 2 + StringLength
	end
} :: TypeSerializer<string>

DataTypes.ShortString = {
	IsDynamic = true, ContainsInstances = false,
	GetByteSize = function(ValueToWrite : string) : number return 1 + #ValueToWrite end,
	Write = function(TargetBuffer : buffer, CurrentOffset : number, ValueToWrite : string) : number
		local StringLength = #ValueToWrite
		buffer.writeu8(TargetBuffer, CurrentOffset, StringLength)
		buffer.writestring(TargetBuffer, CurrentOffset + 1, ValueToWrite)
		return CurrentOffset + 1 + StringLength
	end,
	Read = function(SourceBuffer : buffer, CurrentOffset : number) : (string, number)
		local StringLength = buffer.readu8(SourceBuffer, CurrentOffset)
		return buffer.readstring(SourceBuffer, CurrentOffset + 1, StringLength), CurrentOffset + 1 + StringLength
	end
} :: TypeSerializer<string>

DataTypes.RestOfString = {
	IsDynamic = true, ContainsInstances = false,
	GetByteSize = function(ValueToWrite : string) : number return #ValueToWrite end,
	Write = function(TargetBuffer : buffer, CurrentOffset : number, ValueToWrite : string) : number
		buffer.writestring(TargetBuffer, CurrentOffset, ValueToWrite)
		return CurrentOffset + #ValueToWrite
	end,
	Read = function(SourceBuffer : buffer, CurrentOffset : number) : (string, number)
		local RemainingLength = buffer.len(SourceBuffer) - CurrentOffset
		return buffer.readstring(SourceBuffer, CurrentOffset, RemainingLength), CurrentOffset + RemainingLength
	end
} :: TypeSerializer<string>

DataTypes.Buffer = {
	IsDynamic = true, ContainsInstances = false,
	GetByteSize = function(ValueToWrite : buffer) : number return 2 + buffer.len(ValueToWrite) end,
	Write = function(TargetBuffer : buffer, CurrentOffset : number, ValueToWrite : buffer) : number
		local BufferLength = buffer.len(ValueToWrite)
		buffer.writeu16(TargetBuffer, CurrentOffset, BufferLength)
		buffer.copy(TargetBuffer, CurrentOffset + 2, ValueToWrite, 0, BufferLength)
		return CurrentOffset + 2 + BufferLength
	end,
	Read = function(SourceBuffer : buffer, CurrentOffset : number) : (buffer, number)
		local BufferLength = buffer.readu16(SourceBuffer, CurrentOffset)
		local NewBuffer = buffer.create(BufferLength)
		buffer.copy(NewBuffer, 0, SourceBuffer, CurrentOffset + 2, BufferLength)
		return NewBuffer, CurrentOffset + 2 + BufferLength
	end
} :: TypeSerializer<buffer>

function DataTypes.FixedString(StringLength : number) : TypeSerializer<string>
	return {
		IsDynamic = false, ContainsInstances = false,
		GetByteSize = function(_ : string) : number return StringLength end,
		Write = function(TargetBuffer : buffer, CurrentOffset : number, ValueToWrite : string) : number 
			buffer.writestring(TargetBuffer, CurrentOffset, ValueToWrite, StringLength) 
			return CurrentOffset + StringLength 
		end,
		Read = function(SourceBuffer : buffer, CurrentOffset : number) : (string, number) 
			return buffer.readstring(SourceBuffer, CurrentOffset, StringLength), CurrentOffset + StringLength 
		end
	}
end

function DataTypes.Optional<ValueType>(InnerType : TypeSerializer<ValueType>) : TypeSerializer<ValueType?>
	return {
		IsDynamic = true, ContainsInstances = InnerType.ContainsInstances,
		GetByteSize = function(ValueToWrite : ValueType?) : number return if ValueToWrite == nil then 1 else 1 + InnerType.GetByteSize(ValueToWrite) end,
		Write = function(TargetBuffer : buffer, CurrentOffset : number, ValueToWrite : ValueType?, InstanceAccumulator : {Instance}?, InstanceLookup : {[Instance]: number}?) : number
			if ValueToWrite == nil then
				buffer.writeu8(TargetBuffer, CurrentOffset, 0)
				return CurrentOffset + 1
			else
				buffer.writeu8(TargetBuffer, CurrentOffset, 1)
				return InnerType.Write(TargetBuffer, CurrentOffset + 1, ValueToWrite, InstanceAccumulator, InstanceLookup)
			end
		end,
		Read = function(SourceBuffer : buffer, CurrentOffset : number, InstanceSource : {Instance}?) : (ValueType?, number)
			if buffer.readu8(SourceBuffer, CurrentOffset) == 0 then return nil, CurrentOffset + 1
			else return InnerType.Read(SourceBuffer, CurrentOffset + 1, InstanceSource) end
		end
	}
end

function DataTypes.Array<ValueType>(InnerType : TypeSerializer<ValueType>) : TypeSerializer<{ValueType}>
	return {
		IsDynamic = true, ContainsInstances = InnerType.ContainsInstances,
		GetByteSize = function(ValuesToWrite : {ValueType}) : number
			local TotalSize = 2
			if InnerType.IsDynamic then
				for _, Item in ipairs(ValuesToWrite) do TotalSize += InnerType.GetByteSize(Item) end
			else
				TotalSize += (#ValuesToWrite * InnerType.GetByteSize(nil :: any))
			end
			return TotalSize
		end,
		Write = function(TargetBuffer : buffer, CurrentOffset : number, ValuesToWrite : {ValueType}, InstanceAccumulator : {Instance}?, InstanceLookup : {[Instance]: number}?) : number
			local ItemCount = #ValuesToWrite
			buffer.writeu16(TargetBuffer, CurrentOffset, ItemCount)
			CurrentOffset += 2
			for Index = 1, ItemCount do 
				CurrentOffset = InnerType.Write(TargetBuffer, CurrentOffset, ValuesToWrite[Index], InstanceAccumulator, InstanceLookup) 
			end
			return CurrentOffset
		end,
		Read = function(SourceBuffer : buffer, CurrentOffset : number, InstanceSource : {Instance}?) : ({ValueType}, number)
			local ItemCount = buffer.readu16(SourceBuffer, CurrentOffset)
			CurrentOffset += 2
			local ResultTable = table.create(ItemCount)
			for Index = 1, ItemCount do
				local DecodedValue
				DecodedValue, CurrentOffset = InnerType.Read(SourceBuffer, CurrentOffset, InstanceSource)
				ResultTable[Index] = DecodedValue
			end
			return ResultTable, CurrentOffset
		end
	}
end

function DataTypes.Map<KeyType, ValueType>(KeyTypeSerializer : TypeSerializer<KeyType>, ValueTypeSerializer : TypeSerializer<ValueType>) : TypeSerializer<{[KeyType]: ValueType}>
	return {
		IsDynamic = true, ContainsInstances = KeyTypeSerializer.ContainsInstances or ValueTypeSerializer.ContainsInstances,
		GetByteSize = function(MapValues : {[KeyType]: ValueType}) : number
			local TotalSize = 2 
			for Key, Value in pairs(MapValues) do
				TotalSize += KeyTypeSerializer.GetByteSize(Key)
				TotalSize += ValueTypeSerializer.GetByteSize(Value)
			end
			return TotalSize
		end,
		Write = function(TargetBuffer : buffer, CurrentOffset : number, MapValues : {[KeyType]: ValueType}, InstanceAccumulator : {Instance}?, InstanceLookup : {[Instance]: number}?) : number
			local MapCount = 0; for _ in pairs(MapValues) do MapCount += 1 end
			buffer.writeu16(TargetBuffer, CurrentOffset, MapCount)
			CurrentOffset += 2
			for Key, Value in pairs(MapValues) do
				CurrentOffset = KeyTypeSerializer.Write(TargetBuffer, CurrentOffset, Key, InstanceAccumulator, InstanceLookup)
				CurrentOffset = ValueTypeSerializer.Write(TargetBuffer, CurrentOffset, Value, InstanceAccumulator, InstanceLookup)
			end
			return CurrentOffset
		end,
		Read = function(SourceBuffer : buffer, CurrentOffset : number, InstanceSource : {Instance}?) : ({[KeyType]: ValueType}, number)
			local MapCount = buffer.readu16(SourceBuffer, CurrentOffset)
			CurrentOffset += 2
			local ResultMap = {}
			for _ = 1, MapCount do
				local DecodedKey, DecodedValue
				DecodedKey, CurrentOffset = KeyTypeSerializer.Read(SourceBuffer, CurrentOffset, InstanceSource)
				DecodedValue, CurrentOffset = ValueTypeSerializer.Read(SourceBuffer, CurrentOffset, InstanceSource)
				ResultMap[DecodedKey] = DecodedValue
			end
			return ResultMap, CurrentOffset
		end
	}
end

function DataTypes.Struct(StructureDefinition: {[string]: TypeSerializer}) : TypeSerializer<{ [string]: any }>
	local SortedKeys = {}
	local HasInstances = false
	local IsDynamic = false

	for DefinitionKey, Serializer in pairs(StructureDefinition) do
		table.insert(SortedKeys, DefinitionKey)
		if Serializer.ContainsInstances then HasInstances = true end
		if Serializer.IsDynamic then IsDynamic = true end
	end
	table.sort(SortedKeys)

	return {
		IsDynamic = IsDynamic, ContainsInstances = HasInstances,
		GetByteSize = function(ValueToWrite : {[string]: any}) : number
			local TotalSize = 0
			for _, DefinitionKey in ipairs(SortedKeys) do
				TotalSize += StructureDefinition[DefinitionKey].GetByteSize(ValueToWrite[DefinitionKey])
			end
			return TotalSize
		end,
		Write = function(TargetBuffer : buffer, CurrentOffset : number, ValueToWrite : {[string]: any}, InstanceAccumulator : {Instance}?, InstanceLookup : {[Instance]: number}?) : number
			for _, DefinitionKey in ipairs(SortedKeys) do
				CurrentOffset = StructureDefinition[DefinitionKey].Write(TargetBuffer, CurrentOffset, ValueToWrite[DefinitionKey], InstanceAccumulator, InstanceLookup)
			end
			return CurrentOffset
		end,
		Read = function(SourceBuffer : buffer, CurrentOffset : number, InstanceSource : {Instance}?) : ({[string]: any}, number)
			local ResultTable = {}
			for _, DefinitionKey in ipairs(SortedKeys) do
				ResultTable[DefinitionKey], CurrentOffset = StructureDefinition[DefinitionKey].Read(SourceBuffer, CurrentOffset, InstanceSource)
			end
			return ResultTable, CurrentOffset
		end
	}
end

do
	local DATA_TYPE_NIL              = 0
	local DATA_TYPE_FALSE            = 1
	local DATA_TYPE_TRUE             = 2
	local DATA_TYPE_F64              = 3
	local DATA_TYPE_F32              = 4
	local DATA_TYPE_INT32            = 5
	local DATA_TYPE_INT16            = 6
	local DATA_TYPE_INT8             = 7
	local DATA_TYPE_VECTOR3          = 8
	local DATA_TYPE_VECTOR3_ZERO     = 9
	local DATA_TYPE_VECTOR3_ONE      = 10
	local DATA_TYPE_VECTOR3_INT16    = 11
	local DATA_TYPE_CFRAME           = 12
	local DATA_TYPE_COLOR3           = 13
	local DATA_TYPE_INSTANCE         = 14
	local DATA_TYPE_BUFFER_16        = 15
	local DATA_TYPE_BUFFER_32        = 16
	local DATA_TYPE_STRING_LONG      = 17
	local DATA_TYPE_ARRAY_LONG       = 18
	local DATA_TYPE_MAP_LONG         = 19
	local DATA_TYPE_VECTOR3_INT8     = 20

	local DATA_TYPE_CF_IDENTITY_ZERO  = 21
	local DATA_TYPE_CF_IDENTITY_INT8  = 22
	local DATA_TYPE_CF_IDENTITY_INT16 = 23
	local DATA_TYPE_CF_IDENTITY_F32   = 24
	local DATA_TYPE_CF_ROTATION_INT8  = 25
	local DATA_TYPE_CF_ROTATION_F32   = 26

	local OFFSET_ARRAY_SHORT  = 32
	local OFFSET_MAP_SHORT    = 64
	local OFFSET_STRING_SHORT = 128

	local GetAnyByteSize : (any) -> number
	local WriteAny : (buffer, number, any, {Instance}?, {[Instance]: number}?) -> number
	local ReadAny : (buffer, number, {Instance}?) -> (any, number)

	local function IsTableArray(TableToCheck: {any}) : boolean
		if #TableToCheck == 0 then return false end
		local ElementCount = 0
		for _ in pairs(TableToCheck) do ElementCount += 1 end
		return ElementCount == #TableToCheck
	end

	GetAnyByteSize = function(ValueToCheck: any) : number
		local ValueType = typeof(ValueToCheck)

		if ValueType == "string" then
			local StringLength = #ValueToCheck
			return if StringLength < 128 then 1 + StringLength else 5 + StringLength
		elseif ValueType == "number" then
			if ValueToCheck % 1 == 0 then
				if ValueToCheck >= -128 and ValueToCheck <= 127 then return 2
				elseif ValueToCheck >= -32768 and ValueToCheck <= 32767 then return 3
				elseif ValueToCheck >= -2147483648 and ValueToCheck <= 2147483647 then return 5
				end
			end
			return 9
		elseif ValueType == "Vector3" then
			if ValueToCheck == Vector3.zero or ValueToCheck == Vector3.one then return 1 end
			local VectorX, VectorY, VectorZ = ValueToCheck.X, ValueToCheck.Y, ValueToCheck.Z
			if VectorX % 1 == 0 and VectorY % 1 == 0 and VectorZ % 1 == 0 then
				if VectorX >= -128 and VectorX <= 127 and VectorY >= -128 and VectorY <= 127 and VectorZ >= -128 and VectorZ <= 127 then
					return 4
				elseif VectorX >= -32768 and VectorX <= 32767 and VectorY >= -32768 and VectorY <= 32767 and VectorZ >= -32768 and VectorZ <= 32767 then
					return 7
				end
			end
			return 13
		elseif ValueType == "boolean" then
			return 1
		elseif ValueType == "nil" then
			return 1
		elseif ValueType == "table" then
			local TotalSize = 1
			if IsTableArray(ValueToCheck) then
				local ElementCount = #ValueToCheck
				if ElementCount >= 32 then TotalSize += 2 end
				for _, SubValue in ipairs(ValueToCheck) do TotalSize += GetAnyByteSize(SubValue) end
			else
				local ElementCount = 0
				for Key, SubValue in pairs(ValueToCheck) do
					ElementCount += 1
					TotalSize += GetAnyByteSize(Key)
					TotalSize += GetAnyByteSize(SubValue)
				end
				if ElementCount >= 32 then TotalSize += 2 end
			end
			return TotalSize
		elseif ValueType == "CFrame" then
			local PositionX, PositionY, PositionZ, RotationMatrix00, RotationMatrix01, RotationMatrix02, RotationMatrix10, RotationMatrix11, RotationMatrix12, RotationMatrix20, RotationMatrix21, RotationMatrix22 = ValueToCheck:GetComponents()
			local IsIdentityRotation = (RotationMatrix00 == 1 and RotationMatrix11 == 1 and RotationMatrix22 == 1 and RotationMatrix01 == 0 and RotationMatrix02 == 0 and RotationMatrix10 == 0 and RotationMatrix12 == 0 and RotationMatrix20 == 0 and RotationMatrix21 == 0)

			if IsIdentityRotation then
				if PositionX == 0 and PositionY == 0 and PositionZ == 0 then return 1 end
				if PositionX % 1 == 0 and PositionY % 1 == 0 and PositionZ % 1 == 0 then
					if PositionX >= -128 and PositionX <= 127 and PositionY >= -128 and PositionY <= 127 and PositionZ >= -128 and PositionZ <= 127 then return 4 end
					if PositionX >= -32768 and PositionX <= 32767 and PositionY >= -32768 and PositionY <= 32767 and PositionZ >= -32768 and PositionZ <= 32767 then return 7 end
				end
				return 13
			else
				if PositionX % 1 == 0 and PositionY % 1 == 0 and PositionZ % 1 == 0 then
					if PositionX >= -128 and PositionX <= 127 and PositionY >= -128 and PositionY <= 127 and PositionZ >= -128 and PositionZ <= 127 then
						return 10 
					end
				end
				return 19 
			end
		elseif ValueType == "Color3" then
			return 4
		elseif ValueType == "Instance" then
			return 3
		elseif ValueType == "buffer" then
			local BufferLength = buffer.len(ValueToCheck)
			return if BufferLength < 65536 then 3 + BufferLength else 5 + BufferLength
		else
			error("Ion: Unsupported type in Any serializer: " .. ValueType)
		end
	end

	WriteAny = function(TargetBuffer: buffer, CurrentOffset: number, ValueToWrite: any, InstanceAccumulator: {Instance}?, InstanceLookup: {[Instance]: number}?) : number
		local ValueType = typeof(ValueToWrite)
		if ValueType == "Instance" then
			buffer.writeu8(TargetBuffer, CurrentOffset, DATA_TYPE_INSTANCE)
			if InstanceAccumulator and InstanceLookup then
				local ExistingIndex = InstanceLookup[ValueToWrite :: Instance]
				if ExistingIndex then
					buffer.writeu16(TargetBuffer, CurrentOffset + 1, ExistingIndex)
				else
					local NewIndex = #InstanceAccumulator + 1
					InstanceAccumulator[NewIndex] = ValueToWrite :: Instance
					InstanceLookup[ValueToWrite :: Instance] = NewIndex
					buffer.writeu16(TargetBuffer, CurrentOffset + 1, NewIndex)
				end
			else
				buffer.writeu16(TargetBuffer, CurrentOffset + 1, 0)
			end
			return CurrentOffset + 3
		elseif ValueType == "string" then
			local StringLength = #ValueToWrite
			if StringLength < 128 then
				buffer.writeu8(TargetBuffer, CurrentOffset, OFFSET_STRING_SHORT + StringLength)
				buffer.writestring(TargetBuffer, CurrentOffset + 1, ValueToWrite)
				return CurrentOffset + 1 + StringLength
			else
				buffer.writeu8(TargetBuffer, CurrentOffset, DATA_TYPE_STRING_LONG)
				buffer.writeu32(TargetBuffer, CurrentOffset + 1, StringLength)
				buffer.writestring(TargetBuffer, CurrentOffset + 5, ValueToWrite)
				return CurrentOffset + 5 + StringLength
			end
		elseif ValueType == "number" then
			if ValueToWrite % 1 == 0 then
				if ValueToWrite >= -128 and ValueToWrite <= 127 then
					buffer.writeu8(TargetBuffer, CurrentOffset, DATA_TYPE_INT8)
					buffer.writei8(TargetBuffer, CurrentOffset + 1, ValueToWrite)
					return CurrentOffset + 2
				elseif ValueToWrite >= -32768 and ValueToWrite <= 32767 then
					buffer.writeu8(TargetBuffer, CurrentOffset, DATA_TYPE_INT16)
					buffer.writei16(TargetBuffer, CurrentOffset + 1, ValueToWrite)
					return CurrentOffset + 3
				elseif ValueToWrite >= -2147483648 and ValueToWrite <= 2147483647 then
					buffer.writeu8(TargetBuffer, CurrentOffset, DATA_TYPE_INT32)
					buffer.writei32(TargetBuffer, CurrentOffset + 1, ValueToWrite)
					return CurrentOffset + 5
				end
			end
			buffer.writeu8(TargetBuffer, CurrentOffset, DATA_TYPE_F64)
			buffer.writef64(TargetBuffer, CurrentOffset + 1, ValueToWrite)
			return CurrentOffset + 9
		elseif ValueType == "Vector3" then
			if ValueToWrite == Vector3.zero then
				buffer.writeu8(TargetBuffer, CurrentOffset, DATA_TYPE_VECTOR3_ZERO)
				return CurrentOffset + 1
			elseif ValueToWrite == Vector3.one then
				buffer.writeu8(TargetBuffer, CurrentOffset, DATA_TYPE_VECTOR3_ONE)
				return CurrentOffset + 1
			end

			local VectorX, VectorY, VectorZ = ValueToWrite.X, ValueToWrite.Y, ValueToWrite.Z
			if VectorX % 1 == 0 and VectorY % 1 == 0 and VectorZ % 1 == 0 then
				if VectorX >= -128 and VectorX <= 127 and VectorY >= -128 and VectorY <= 127 and VectorZ >= -128 and VectorZ <= 127 then
					buffer.writeu8(TargetBuffer, CurrentOffset, DATA_TYPE_VECTOR3_INT8)
					buffer.writei8(TargetBuffer, CurrentOffset + 1, VectorX)
					buffer.writei8(TargetBuffer, CurrentOffset + 2, VectorY)
					buffer.writei8(TargetBuffer, CurrentOffset + 3, VectorZ)
					return CurrentOffset + 4
				elseif VectorX >= -32768 and VectorX <= 32767 and VectorY >= -32768 and VectorY <= 32767 and VectorZ >= -32768 and VectorZ <= 32767 then
					buffer.writeu8(TargetBuffer, CurrentOffset, DATA_TYPE_VECTOR3_INT16)
					buffer.writei16(TargetBuffer, CurrentOffset + 1, VectorX)
					buffer.writei16(TargetBuffer, CurrentOffset + 3, VectorY)
					buffer.writei16(TargetBuffer, CurrentOffset + 5, VectorZ)
					return CurrentOffset + 7
				end
			end
			buffer.writeu8(TargetBuffer, CurrentOffset, DATA_TYPE_VECTOR3)
			buffer.writef32(TargetBuffer, CurrentOffset + 1, VectorX)
			buffer.writef32(TargetBuffer, CurrentOffset + 5, VectorY)
			buffer.writef32(TargetBuffer, CurrentOffset + 9, VectorZ)
			return CurrentOffset + 13
		elseif ValueType == "boolean" then
			buffer.writeu8(TargetBuffer, CurrentOffset, if ValueToWrite then DATA_TYPE_TRUE else DATA_TYPE_FALSE)
			return CurrentOffset + 1
		elseif ValueType == "nil" then
			buffer.writeu8(TargetBuffer, CurrentOffset, DATA_TYPE_NIL)
			return CurrentOffset + 1
		elseif ValueType == "table" then
			if IsTableArray(ValueToWrite) then
				local ElementCount = #ValueToWrite
				if ElementCount < 32 then
					buffer.writeu8(TargetBuffer, CurrentOffset, OFFSET_ARRAY_SHORT + ElementCount)
					CurrentOffset += 1
				else
					buffer.writeu8(TargetBuffer, CurrentOffset, DATA_TYPE_ARRAY_LONG)
					buffer.writeu16(TargetBuffer, CurrentOffset + 1, ElementCount)
					CurrentOffset += 3
				end
				for Index = 1, ElementCount do CurrentOffset = WriteAny(TargetBuffer, CurrentOffset, ValueToWrite[Index], InstanceAccumulator, InstanceLookup) end
				return CurrentOffset
			else
				local ElementCount = 0; for _ in pairs(ValueToWrite) do ElementCount += 1 end
				if ElementCount < 32 then
					buffer.writeu8(TargetBuffer, CurrentOffset, OFFSET_MAP_SHORT + ElementCount)
					CurrentOffset += 1
				else
					buffer.writeu8(TargetBuffer, CurrentOffset, DATA_TYPE_MAP_LONG)
					buffer.writeu16(TargetBuffer, CurrentOffset + 1, ElementCount)
					CurrentOffset += 3
				end
				for Key, Value in pairs(ValueToWrite) do
					CurrentOffset = WriteAny(TargetBuffer, CurrentOffset, Key, InstanceAccumulator, InstanceLookup)
					CurrentOffset = WriteAny(TargetBuffer, CurrentOffset, Value, InstanceAccumulator, InstanceLookup)
				end
				return CurrentOffset
			end
		elseif ValueType == "CFrame" then
			local PositionX, PositionY, PositionZ, RotationMatrix00, RotationMatrix01, RotationMatrix02, RotationMatrix10, RotationMatrix11, RotationMatrix12, RotationMatrix20, RotationMatrix21, RotationMatrix22 = ValueToWrite:GetComponents()
			local IsIdentityRotation = (RotationMatrix00 == 1 and RotationMatrix11 == 1 and RotationMatrix22 == 1 and RotationMatrix01 == 0 and RotationMatrix02 == 0 and RotationMatrix10 == 0 and RotationMatrix12 == 0 and RotationMatrix20 == 0 and RotationMatrix21 == 0)

			if IsIdentityRotation then
				if PositionX == 0 and PositionY == 0 and PositionZ == 0 then
					buffer.writeu8(TargetBuffer, CurrentOffset, DATA_TYPE_CF_IDENTITY_ZERO)
					return CurrentOffset + 1
				end

				if PositionX % 1 == 0 and PositionY % 1 == 0 and PositionZ % 1 == 0 then
					if PositionX >= -128 and PositionX <= 127 and PositionY >= -128 and PositionY <= 127 and PositionZ >= -128 and PositionZ <= 127 then
						buffer.writeu8(TargetBuffer, CurrentOffset, DATA_TYPE_CF_IDENTITY_INT8)
						buffer.writei8(TargetBuffer, CurrentOffset + 1, PositionX)
						buffer.writei8(TargetBuffer, CurrentOffset + 2, PositionY)
						buffer.writei8(TargetBuffer, CurrentOffset + 3, PositionZ)
						return CurrentOffset + 4
					elseif PositionX >= -32768 and PositionX <= 32767 and PositionY >= -32768 and PositionY <= 32767 and PositionZ >= -32768 and PositionZ <= 32767 then
						buffer.writeu8(TargetBuffer, CurrentOffset, DATA_TYPE_CF_IDENTITY_INT16)
						buffer.writei16(TargetBuffer, CurrentOffset + 1, PositionX)
						buffer.writei16(TargetBuffer, CurrentOffset + 3, PositionY)
						buffer.writei16(TargetBuffer, CurrentOffset + 5, PositionZ)
						return CurrentOffset + 7
					end
				end
				buffer.writeu8(TargetBuffer, CurrentOffset, DATA_TYPE_CF_IDENTITY_F32)
				buffer.writef32(TargetBuffer, CurrentOffset + 1, PositionX)
				buffer.writef32(TargetBuffer, CurrentOffset + 5, PositionY)
				buffer.writef32(TargetBuffer, CurrentOffset + 9, PositionZ)
				return CurrentOffset + 13
			else
				local EulerAngleX, EulerAngleY, EulerAngleZ = ValueToWrite:ToEulerAnglesXYZ()
				local EncodedRotationX = EulerAngleX * 10430.2191955 + 0.5
				local EncodedRotationY = EulerAngleY * 10430.2191955 + 0.5
				local EncodedRotationZ = EulerAngleZ * 10430.2191955 + 0.5

				if PositionX % 1 == 0 and PositionY % 1 == 0 and PositionZ % 1 == 0 then
					if PositionX >= -128 and PositionX <= 127 and PositionY >= -128 and PositionY <= 127 and PositionZ >= -128 and PositionZ <= 127 then
						buffer.writeu8(TargetBuffer, CurrentOffset, DATA_TYPE_CF_ROTATION_INT8)
						buffer.writei8(TargetBuffer, CurrentOffset + 1, PositionX)
						buffer.writei8(TargetBuffer, CurrentOffset + 2, PositionY)
						buffer.writei8(TargetBuffer, CurrentOffset + 3, PositionZ)
						buffer.writeu16(TargetBuffer, CurrentOffset + 4, EncodedRotationX)
						buffer.writeu16(TargetBuffer, CurrentOffset + 6, EncodedRotationY)
						buffer.writeu16(TargetBuffer, CurrentOffset + 8, EncodedRotationZ)
						return CurrentOffset + 10
					end
				end

				buffer.writeu8(TargetBuffer, CurrentOffset, DATA_TYPE_CF_ROTATION_F32)
				buffer.writef32(TargetBuffer, CurrentOffset + 1, PositionX)
				buffer.writef32(TargetBuffer, CurrentOffset + 5, PositionY)
				buffer.writef32(TargetBuffer, CurrentOffset + 9, PositionZ)
				buffer.writeu16(TargetBuffer, CurrentOffset + 13, EncodedRotationX)
				buffer.writeu16(TargetBuffer, CurrentOffset + 15, EncodedRotationY)
				buffer.writeu16(TargetBuffer, CurrentOffset + 17, EncodedRotationZ)
				return CurrentOffset + 19
			end

		elseif ValueType == "Color3" then
			buffer.writeu8(TargetBuffer, CurrentOffset, DATA_TYPE_COLOR3)
			buffer.writeu8(TargetBuffer, CurrentOffset + 1, math.round(ValueToWrite.R * 255))
			buffer.writeu8(TargetBuffer, CurrentOffset + 2, math.round(ValueToWrite.G * 255))
			buffer.writeu8(TargetBuffer, CurrentOffset + 3, math.round(ValueToWrite.B * 255))
			return CurrentOffset + 4
		elseif ValueType == "buffer" then
			local BufferLength = buffer.len(ValueToWrite)
			if BufferLength < 65536 then
				buffer.writeu8(TargetBuffer, CurrentOffset, DATA_TYPE_BUFFER_16)
				buffer.writeu16(TargetBuffer, CurrentOffset + 1, BufferLength)
				buffer.copy(TargetBuffer, CurrentOffset + 3, ValueToWrite, 0, BufferLength)
				return CurrentOffset + 3 + BufferLength
			else
				buffer.writeu8(TargetBuffer, CurrentOffset, DATA_TYPE_BUFFER_32)
				buffer.writeu32(TargetBuffer, CurrentOffset + 1, BufferLength)
				buffer.copy(TargetBuffer, CurrentOffset + 5, ValueToWrite, 0, BufferLength)
				return CurrentOffset + 5 + BufferLength
			end
		end
		error("Ion: Unserializable type in Any: " .. ValueType)
	end

	local function ReadArray(SourceBuffer: buffer, CurrentOffset: number, InstanceSource: {Instance}?, ElementCount: number) : ({any}, number)
		local ResultTable = table.create(ElementCount)
		for Index = 1, ElementCount do local DecodedValue; DecodedValue, CurrentOffset = ReadAny(SourceBuffer, CurrentOffset, InstanceSource); ResultTable[Index] = DecodedValue end
		return ResultTable, CurrentOffset
	end

	local function ReadMap(SourceBuffer: buffer, CurrentOffset: number, InstanceSource: {Instance}?, ElementCount: number) : ({[any]: any}, number)
		local ResultTable = {}
		for _ = 1, ElementCount do local DecodedKey, DecodedValue; DecodedKey, CurrentOffset = ReadAny(SourceBuffer, CurrentOffset, InstanceSource); DecodedValue, CurrentOffset = ReadAny(SourceBuffer, CurrentOffset, InstanceSource); ResultTable[DecodedKey] = DecodedValue end
		return ResultTable, CurrentOffset
	end

	local StaticTypeHandlers: { [number]: (buffer, number, {Instance}?) -> (any, number) } = {}

	StaticTypeHandlers[DATA_TYPE_NIL] = function(SourceBuffer, CurrentOffset, InstanceSource) return nil, CurrentOffset end
	StaticTypeHandlers[DATA_TYPE_FALSE] = function(SourceBuffer, CurrentOffset, InstanceSource) return false, CurrentOffset end
	StaticTypeHandlers[DATA_TYPE_TRUE] = function(SourceBuffer, CurrentOffset, InstanceSource) return true, CurrentOffset end
	StaticTypeHandlers[DATA_TYPE_F64] = function(SourceBuffer, CurrentOffset, InstanceSource) return buffer.readf64(SourceBuffer, CurrentOffset), CurrentOffset + 8 end
	StaticTypeHandlers[DATA_TYPE_INT8] = function(SourceBuffer, CurrentOffset, InstanceSource) return buffer.readi8(SourceBuffer, CurrentOffset), CurrentOffset + 1 end
	StaticTypeHandlers[DATA_TYPE_INT16] = function(SourceBuffer, CurrentOffset, InstanceSource) return buffer.readi16(SourceBuffer, CurrentOffset), CurrentOffset + 2 end
	StaticTypeHandlers[DATA_TYPE_INT32] = function(SourceBuffer, CurrentOffset, InstanceSource) return buffer.readi32(SourceBuffer, CurrentOffset), CurrentOffset + 4 end
	StaticTypeHandlers[DATA_TYPE_VECTOR3] = function(SourceBuffer, CurrentOffset, InstanceSource) return Vector3.new(buffer.readf32(SourceBuffer,CurrentOffset), buffer.readf32(SourceBuffer,CurrentOffset+4), buffer.readf32(SourceBuffer,CurrentOffset+8)), CurrentOffset + 12 end
	StaticTypeHandlers[DATA_TYPE_VECTOR3_ZERO] = function(SourceBuffer, CurrentOffset, InstanceSource) return Vector3.zero, CurrentOffset end
	StaticTypeHandlers[DATA_TYPE_VECTOR3_ONE] = function(SourceBuffer, CurrentOffset, InstanceSource) return Vector3.one, CurrentOffset end
	StaticTypeHandlers[DATA_TYPE_VECTOR3_INT16] = function(SourceBuffer, CurrentOffset, InstanceSource) return Vector3.new(buffer.readi16(SourceBuffer,CurrentOffset), buffer.readi16(SourceBuffer,CurrentOffset+2), buffer.readi16(SourceBuffer,CurrentOffset+4)), CurrentOffset + 6 end
	StaticTypeHandlers[DATA_TYPE_VECTOR3_INT8] = function(SourceBuffer, CurrentOffset, InstanceSource) return Vector3.new(buffer.readi8(SourceBuffer,CurrentOffset), buffer.readi8(SourceBuffer,CurrentOffset+1), buffer.readi8(SourceBuffer,CurrentOffset+2)), CurrentOffset + 3 end
	StaticTypeHandlers[DATA_TYPE_COLOR3] = function(SourceBuffer, CurrentOffset, InstanceSource) return Color3.fromRGB(buffer.readu8(SourceBuffer,CurrentOffset), buffer.readu8(SourceBuffer,CurrentOffset+1), buffer.readu8(SourceBuffer,CurrentOffset+2)), CurrentOffset + 3 end
	StaticTypeHandlers[DATA_TYPE_INSTANCE] = function(SourceBuffer, CurrentOffset, InstanceSource: {Instance}?) local InstanceIndex = buffer.readu16(SourceBuffer, CurrentOffset); return if InstanceSource and InstanceSource[InstanceIndex] then InstanceSource[InstanceIndex] else nil, CurrentOffset + 2 end
	StaticTypeHandlers[DATA_TYPE_BUFFER_16] = function(SourceBuffer, CurrentOffset, InstanceSource) local BufferLength = buffer.readu16(SourceBuffer, CurrentOffset); local NewBuffer = buffer.create(BufferLength); buffer.copy(NewBuffer, 0, SourceBuffer, CurrentOffset+2, BufferLength); return NewBuffer, CurrentOffset + 2 + BufferLength end
	StaticTypeHandlers[DATA_TYPE_BUFFER_32] = function(SourceBuffer, CurrentOffset, InstanceSource) local BufferLength = buffer.readu32(SourceBuffer, CurrentOffset); local NewBuffer = buffer.create(BufferLength); buffer.copy(NewBuffer, 0, SourceBuffer, CurrentOffset+4, BufferLength); return NewBuffer, CurrentOffset + 4 + BufferLength end
	StaticTypeHandlers[DATA_TYPE_STRING_LONG] = function(SourceBuffer, CurrentOffset, InstanceSource) local StringLength = buffer.readu32(SourceBuffer, CurrentOffset); return buffer.readstring(SourceBuffer, CurrentOffset+4, StringLength), CurrentOffset + 4 + StringLength end

	StaticTypeHandlers[DATA_TYPE_CFRAME] = function(SourceBuffer, CurrentOffset, InstanceSource)
		local PositionX, PositionY, PositionZ = buffer.readf32(SourceBuffer, CurrentOffset), buffer.readf32(SourceBuffer, CurrentOffset+4), buffer.readf32(SourceBuffer, CurrentOffset+8)
		local EulerAngleX, EulerAngleY, EulerAngleZ = buffer.readu16(SourceBuffer, CurrentOffset+12) / 10430.2191955, buffer.readu16(SourceBuffer, CurrentOffset+14) / 10430.2191955, buffer.readu16(SourceBuffer, CurrentOffset+16) / 10430.2191955
		return CFrame.fromEulerAnglesXYZ(EulerAngleX, EulerAngleY, EulerAngleZ) + Vector3.new(PositionX, PositionY, PositionZ), CurrentOffset + 20
	end

	StaticTypeHandlers[DATA_TYPE_CF_IDENTITY_ZERO] = function(SourceBuffer, CurrentOffset, InstanceSource) return CFrame.new(), CurrentOffset end
	StaticTypeHandlers[DATA_TYPE_CF_IDENTITY_INT8] = function(SourceBuffer, CurrentOffset, InstanceSource) return CFrame.new(buffer.readi8(SourceBuffer,CurrentOffset), buffer.readi8(SourceBuffer,CurrentOffset+1), buffer.readi8(SourceBuffer,CurrentOffset+2)), CurrentOffset + 3 end
	StaticTypeHandlers[DATA_TYPE_CF_IDENTITY_INT16] = function(SourceBuffer, CurrentOffset, InstanceSource) return CFrame.new(buffer.readi16(SourceBuffer,CurrentOffset), buffer.readi16(SourceBuffer,CurrentOffset+2), buffer.readi16(SourceBuffer,CurrentOffset+4)), CurrentOffset + 6 end
	StaticTypeHandlers[DATA_TYPE_CF_IDENTITY_F32] = function(SourceBuffer, CurrentOffset, InstanceSource) return CFrame.new(buffer.readf32(SourceBuffer,CurrentOffset), buffer.readf32(SourceBuffer,CurrentOffset+4), buffer.readf32(SourceBuffer,CurrentOffset+8)), CurrentOffset + 12 end

	StaticTypeHandlers[DATA_TYPE_CF_ROTATION_INT8] = function(SourceBuffer, CurrentOffset, InstanceSource) 
		local PositionX, PositionY, PositionZ = buffer.readi8(SourceBuffer, CurrentOffset), buffer.readi8(SourceBuffer, CurrentOffset+1), buffer.readi8(SourceBuffer, CurrentOffset+2)
		local EulerAngleX, EulerAngleY, EulerAngleZ = buffer.readu16(SourceBuffer, CurrentOffset+3) / 10430.2191955, buffer.readu16(SourceBuffer, CurrentOffset+5) / 10430.2191955, buffer.readu16(SourceBuffer, CurrentOffset+7) / 10430.2191955
		return CFrame.fromEulerAnglesXYZ(EulerAngleX, EulerAngleY, EulerAngleZ) + Vector3.new(PositionX, PositionY, PositionZ), CurrentOffset + 9
	end

	StaticTypeHandlers[DATA_TYPE_CF_ROTATION_F32] = function(SourceBuffer, CurrentOffset, InstanceSource)
		local PositionX, PositionY, PositionZ = buffer.readf32(SourceBuffer, CurrentOffset), buffer.readf32(SourceBuffer, CurrentOffset+4), buffer.readf32(SourceBuffer, CurrentOffset+8)
		local EulerAngleX, EulerAngleY, EulerAngleZ = buffer.readu16(SourceBuffer, CurrentOffset+12) / 10430.2191955, buffer.readu16(SourceBuffer, CurrentOffset+14) / 10430.2191955, buffer.readu16(SourceBuffer, CurrentOffset+16) / 10430.2191955
		return CFrame.fromEulerAnglesXYZ(EulerAngleX, EulerAngleY, EulerAngleZ) + Vector3.new(PositionX, PositionY, PositionZ), CurrentOffset + 18
	end

	StaticTypeHandlers[DATA_TYPE_ARRAY_LONG] = function(SourceBuffer, CurrentOffset, InstanceSource: {Instance}?) return ReadArray(SourceBuffer, CurrentOffset + 2, InstanceSource, buffer.readu16(SourceBuffer, CurrentOffset)) end
	StaticTypeHandlers[DATA_TYPE_MAP_LONG] = function(SourceBuffer, CurrentOffset, InstanceSource: {Instance}?) return ReadMap(SourceBuffer, CurrentOffset + 2, InstanceSource, buffer.readu16(SourceBuffer, CurrentOffset)) end

	ReadAny = function(SourceBuffer: buffer, CurrentOffset: number, InstanceSource: {Instance}?) : (any, number)
		local DataTypeId = buffer.readu8(SourceBuffer, CurrentOffset)
		CurrentOffset += 1

		if DataTypeId >= 128 then
			local StringLength = DataTypeId - 128
			return buffer.readstring(SourceBuffer, CurrentOffset, StringLength), CurrentOffset + StringLength
		elseif DataTypeId >= 64 then
			local ElementCount = DataTypeId - 64
			return ReadMap(SourceBuffer, CurrentOffset, InstanceSource, ElementCount)
		elseif DataTypeId >= 32 then
			local ElementCount = DataTypeId - 32
			return ReadArray(SourceBuffer, CurrentOffset, InstanceSource, ElementCount)
		else
			local TypeHandler = StaticTypeHandlers[DataTypeId]
			if TypeHandler then return TypeHandler(SourceBuffer, CurrentOffset, InstanceSource)
			else error("Ion: Unknown Any Type ID: " .. tostring(DataTypeId)) end
		end
	end

	DataTypes.Any = {
		IsDynamic = true, ContainsInstances = true,
		GetByteSize = GetAnyByteSize, Write = WriteAny, Read = ReadAny
	} :: TypeSerializer<any>
end

local IonLibrary = {}
IonLibrary.Types = DataTypes

type RateLimitInfo = { LastCheck : number, Count : number }

local PacketDefinitionRegistry : { [number] : {TypeSerializer} } = {}
local ListenerCallbackRegistry : { [number] : (...any) -> () } = {}
local RateLimitRegistry : { [number] : number } = {}
local RateLimitTrackerRegistry : { [number] : { [Player] : RateLimitInfo } } = {}
local PacketIdentifierCounter = 0

if IsServerEnvironment then
	Players.PlayerRemoving:Connect(function(PlayerToRemove : Player)
		for _, TrackerTable in pairs(RateLimitTrackerRegistry) do TrackerTable[PlayerToRemove] = nil end
	end)
end

function IonLibrary.Define(SchemaDefinitions : {TypeSerializer}, Options : PacketOptions?) : any
	PacketIdentifierCounter += 1
	local UniquePacketIdentifier = PacketIdentifierCounter
	PacketDefinitionRegistry[UniquePacketIdentifier] = SchemaDefinitions

	local IsUnreliable = if Options and Options.Unreliable then true else false
	local RateLimit = if Options then Options.RateLimit else nil
	local IsDedicated = if Options and Options.Dedicated then true else false

	if RateLimit and IsServerEnvironment then
		RateLimitRegistry[UniquePacketIdentifier] = RateLimit
		RateLimitTrackerRegistry[UniquePacketIdentifier] = {}
	end

	local ActiveRemoteChannel
	if IsDedicated then
		ActiveRemoteChannel = GetRemoteEvent("Ion_" .. UniquePacketIdentifier, IsUnreliable)
	else
		ActiveRemoteChannel = if IsUnreliable then MainUnreliableRemote else MainReliableRemote
	end

	local BasePacketSize = if IsDedicated then 0 else 1
	local IsSchemaDynamic = false
	local RequiresInstanceAccumulator = false

	for _, TypeDefinition in ipairs(SchemaDefinitions) do
		if TypeDefinition.ContainsInstances then RequiresInstanceAccumulator = true end
		if TypeDefinition.IsDynamic then IsSchemaDynamic = true else BasePacketSize += TypeDefinition.GetByteSize(nil :: any) end
	end

	local function SerializeArguments(ArgumentList : {any}) : (buffer, {Instance}?)
		local InstanceAccumulator = if RequiresInstanceAccumulator then {} else nil
		local InstanceLookup = if RequiresInstanceAccumulator then SharedInstanceLookupTable else nil

		if InstanceLookup then table.clear(InstanceLookup) end

		local AllocationSize = BasePacketSize
		if IsSchemaDynamic then
			AllocationSize = if IsDedicated then 0 else 1
			for Index, TypeDefinition in ipairs(SchemaDefinitions) do
				AllocationSize += TypeDefinition.GetByteSize(ArgumentList[Index])
			end
		end

		local PayloadBuffer = buffer.create(AllocationSize)
		local WriteOffset = 0

		if not IsDedicated then
			buffer.writeu8(PayloadBuffer, 0, UniquePacketIdentifier)
			WriteOffset = 1
		end

		for Index, TypeDefinition in ipairs(SchemaDefinitions) do
			WriteOffset = TypeDefinition.Write(PayloadBuffer, WriteOffset, ArgumentList[Index], InstanceAccumulator, InstanceLookup)
		end

		return PayloadBuffer, InstanceAccumulator
	end

	local PacketObject = {}

	function PacketObject.Listen(CallbackFunction : (...any) -> ())
		ListenerCallbackRegistry[UniquePacketIdentifier] = CallbackFunction

		if IsDedicated then
			local function DedicatedHandler(SenderPlayer : Player?, PayloadBuffer : buffer, InstanceSource : {Instance}?)
				if not IsServerEnvironment then SenderPlayer = nil end

				if IsServerEnvironment and SenderPlayer and RateLimit then
					local TrackerTable = RateLimitTrackerRegistry[UniquePacketIdentifier]
					local PlayerRateInfo = TrackerTable[SenderPlayer]
					local CurrentTime = os.clock()
					if not PlayerRateInfo then PlayerRateInfo = { LastCheck = CurrentTime, Count = 0 }; TrackerTable[SenderPlayer] = PlayerRateInfo end
					if CurrentTime - PlayerRateInfo.LastCheck >= 1 then PlayerRateInfo.Count = 0; PlayerRateInfo.LastCheck = CurrentTime end
					PlayerRateInfo.Count += 1
					if PlayerRateInfo.Count > RateLimit then return end
				end

				local ReadOffset = 0
				local ArgumentCount = #SchemaDefinitions

				if ArgumentCount <= 8 then
					local Argument1, Argument2, Argument3, Argument4, Argument5, Argument6, Argument7, Argument8
					if ArgumentCount >= 1 then Argument1, ReadOffset = (SchemaDefinitions[1] :: TypeSerializer).Read(PayloadBuffer, ReadOffset, InstanceSource) end
					if ArgumentCount >= 2 then Argument2, ReadOffset = (SchemaDefinitions[2] :: TypeSerializer).Read(PayloadBuffer, ReadOffset, InstanceSource) end
					if ArgumentCount >= 3 then Argument3, ReadOffset = (SchemaDefinitions[3] :: TypeSerializer).Read(PayloadBuffer, ReadOffset, InstanceSource) end
					if ArgumentCount >= 4 then Argument4, ReadOffset = (SchemaDefinitions[4] :: TypeSerializer).Read(PayloadBuffer, ReadOffset, InstanceSource) end
					if ArgumentCount >= 5 then Argument5, ReadOffset = (SchemaDefinitions[5] :: TypeSerializer).Read(PayloadBuffer, ReadOffset, InstanceSource) end
					if ArgumentCount >= 6 then Argument6, ReadOffset = (SchemaDefinitions[6] :: TypeSerializer).Read(PayloadBuffer, ReadOffset, InstanceSource) end
					if ArgumentCount >= 7 then Argument7, ReadOffset = (SchemaDefinitions[7] :: TypeSerializer).Read(PayloadBuffer, ReadOffset, InstanceSource) end
					if ArgumentCount >= 8 then Argument8, ReadOffset = (SchemaDefinitions[8] :: TypeSerializer).Read(PayloadBuffer, ReadOffset, InstanceSource) end

					if IsServerEnvironment then
						CallbackFunction(SenderPlayer, Argument1, Argument2, Argument3, Argument4, Argument5, Argument6, Argument7, Argument8)
					else
						CallbackFunction(Argument1, Argument2, Argument3, Argument4, Argument5, Argument6, Argument7, Argument8)
					end
				else
					local ArgumentsTable = table.create(ArgumentCount)
					for Index = 1, ArgumentCount do ArgumentsTable[Index], ReadOffset = (SchemaDefinitions[Index] :: TypeSerializer).Read(PayloadBuffer, ReadOffset, InstanceSource) end

					if IsServerEnvironment then
						CallbackFunction(SenderPlayer, table.unpack(ArgumentsTable))
					else
						CallbackFunction(table.unpack(ArgumentsTable))
					end
				end
			end

			if IsServerEnvironment then
				(ActiveRemoteChannel :: RemoteEvent).OnServerEvent:Connect(DedicatedHandler)
			else
				(ActiveRemoteChannel :: RemoteEvent).OnClientEvent:Connect(function(ReceivedBuffer, ReceivedInstances) DedicatedHandler(nil, ReceivedBuffer, ReceivedInstances) end)
			end
		end
	end

	if IsServerEnvironment then
		function PacketObject.Send() error("Ion: Server must use SendTo/SendToAll/SendToList") end
		function PacketObject.SendTo(RecipientPlayer : Player, ...)
			local PayloadBuffer, InstanceList = SerializeArguments({...})
			local RemoteObject = ActiveRemoteChannel :: RemoteEvent
			if InstanceList and #InstanceList > 0 then
				if IsUnreliable then (RemoteObject :: any):FireClient(RecipientPlayer, PayloadBuffer, InstanceList)
				else RemoteObject:FireClient(RecipientPlayer, PayloadBuffer, InstanceList) end
			else
				if IsUnreliable then (RemoteObject :: any):FireClient(RecipientPlayer, PayloadBuffer)
				else RemoteObject:FireClient(RecipientPlayer, PayloadBuffer) end
			end
		end
		function PacketObject.SendToAll(...)
			local PayloadBuffer, InstanceList = SerializeArguments({...})
			local RemoteObject = ActiveRemoteChannel :: RemoteEvent
			if InstanceList and #InstanceList > 0 then
				if IsUnreliable then (RemoteObject :: any):FireAllClients(PayloadBuffer, InstanceList)
				else RemoteObject:FireAllClients(PayloadBuffer, InstanceList) end
			else
				if IsUnreliable then (RemoteObject :: any):FireAllClients(PayloadBuffer)
				else RemoteObject:FireAllClients(PayloadBuffer) end
			end
		end
		function PacketObject.SendToList(RecipientPlayers : {Player}, ...)
			local PayloadBuffer, InstanceList = SerializeArguments({...})
			local RemoteObject = ActiveRemoteChannel :: RemoteEvent
			local HasInstances = InstanceList and #InstanceList > 0

			if IsUnreliable then
				local UnreliableObject = RemoteObject :: any
				if HasInstances then for _, RecipientPlayer in ipairs(RecipientPlayers) do UnreliableObject:FireClient(RecipientPlayer, PayloadBuffer, InstanceList) end
				else for _, RecipientPlayer in ipairs(RecipientPlayers) do UnreliableObject:FireClient(RecipientPlayer, PayloadBuffer) end end
			else
				if HasInstances then for _, RecipientPlayer in ipairs(RecipientPlayers) do RemoteObject:FireClient(RecipientPlayer, PayloadBuffer, InstanceList) end
				else for _, RecipientPlayer in ipairs(RecipientPlayers) do RemoteObject:FireClient(RecipientPlayer, PayloadBuffer) end end
			end
		end
	else
		function PacketObject.Send(...)
			local PayloadBuffer, InstanceList = SerializeArguments({...})
			local RemoteObject = ActiveRemoteChannel :: RemoteEvent
			if InstanceList and #InstanceList > 0 then
				if IsUnreliable then (RemoteObject :: any):FireServer(PayloadBuffer, InstanceList)
				else RemoteObject:FireServer(PayloadBuffer, InstanceList) end
			else
				if IsUnreliable then (RemoteObject :: any):FireServer(PayloadBuffer)
				else RemoteObject:FireServer(PayloadBuffer) end
			end
		end
		function PacketObject.SendTo() error("Ion: Client cannot use SendTo") end
		function PacketObject.SendToAll() error("Ion: Client cannot use SendToAll") end
		function PacketObject.SendToList() error("Ion: Client cannot use SendToList") end
	end

	(PacketObject :: any).Client = PacketObject;
	(PacketObject :: any).Server = PacketObject;

	return table.freeze(PacketObject)
end

local function HandleNetworkEvent(SenderPlayer : Player?, PayloadBuffer : buffer, InstanceSource : {Instance}?)
	if buffer.len(PayloadBuffer) < 1 then return end
	local PacketIdentifier = buffer.readu8(PayloadBuffer, 0)
	local SchemaDefinitions = PacketDefinitionRegistry[PacketIdentifier]
	local CallbackFunction = ListenerCallbackRegistry[PacketIdentifier]
	if not SchemaDefinitions or not CallbackFunction then return end

	if IsServerEnvironment and SenderPlayer then
		local Limit = RateLimitRegistry[PacketIdentifier]
		if Limit then
			local TrackerTable = RateLimitTrackerRegistry[PacketIdentifier]
			local PlayerRateInfo = TrackerTable[SenderPlayer]
			local CurrentTime = os.clock()
			if not PlayerRateInfo then PlayerRateInfo = { LastCheck = CurrentTime, Count = 0 }; TrackerTable[SenderPlayer] = PlayerRateInfo end
			if CurrentTime - PlayerRateInfo.LastCheck >= 1 then PlayerRateInfo.Count = 0; PlayerRateInfo.LastCheck = CurrentTime end
			PlayerRateInfo.Count += 1
			if PlayerRateInfo.Count > Limit then return end
		end
	end

	local ReadOffset = 1
	local ArgumentCount = #SchemaDefinitions

	if ArgumentCount <= 8 then
		local Argument1, Argument2, Argument3, Argument4, Argument5, Argument6, Argument7, Argument8
		if ArgumentCount >= 1 then Argument1, ReadOffset = (SchemaDefinitions[1] :: TypeSerializer).Read(PayloadBuffer, ReadOffset, InstanceSource) end
		if ArgumentCount >= 2 then Argument2, ReadOffset = (SchemaDefinitions[2] :: TypeSerializer).Read(PayloadBuffer, ReadOffset, InstanceSource) end
		if ArgumentCount >= 3 then Argument3, ReadOffset = (SchemaDefinitions[3] :: TypeSerializer).Read(PayloadBuffer, ReadOffset, InstanceSource) end
		if ArgumentCount >= 4 then Argument4, ReadOffset = (SchemaDefinitions[4] :: TypeSerializer).Read(PayloadBuffer, ReadOffset, InstanceSource) end
		if ArgumentCount >= 5 then Argument5, ReadOffset = (SchemaDefinitions[5] :: TypeSerializer).Read(PayloadBuffer, ReadOffset, InstanceSource) end
		if ArgumentCount >= 6 then Argument6, ReadOffset = (SchemaDefinitions[6] :: TypeSerializer).Read(PayloadBuffer, ReadOffset, InstanceSource) end
		if ArgumentCount >= 7 then Argument7, ReadOffset = (SchemaDefinitions[7] :: TypeSerializer).Read(PayloadBuffer, ReadOffset, InstanceSource) end
		if ArgumentCount >= 8 then Argument8, ReadOffset = (SchemaDefinitions[8] :: TypeSerializer).Read(PayloadBuffer, ReadOffset, InstanceSource) end

		if IsServerEnvironment then
			CallbackFunction(SenderPlayer, Argument1, Argument2, Argument3, Argument4, Argument5, Argument6, Argument7, Argument8)
		else
			CallbackFunction(Argument1, Argument2, Argument3, Argument4, Argument5, Argument6, Argument7, Argument8)
		end
	else
		local ArgumentsTable = table.create(ArgumentCount)
		for Index = 1, ArgumentCount do
			local DecodedValue
			DecodedValue, ReadOffset = (SchemaDefinitions[Index] :: TypeSerializer).Read(PayloadBuffer, ReadOffset, InstanceSource)
			ArgumentsTable[Index] = DecodedValue
		end

		if IsServerEnvironment then
			CallbackFunction(SenderPlayer, table.unpack(ArgumentsTable))
		else
			CallbackFunction(table.unpack(ArgumentsTable))
		end
	end
end

if IsServerEnvironment then
	MainReliableRemote.OnServerEvent:Connect(HandleNetworkEvent)
	MainUnreliableRemote.OnServerEvent:Connect(HandleNetworkEvent)
else
	MainReliableRemote.OnClientEvent:Connect(function(ReceivedBuffer, ReceivedInstances) HandleNetworkEvent(nil, ReceivedBuffer, ReceivedInstances) end)
	MainUnreliableRemote.OnClientEvent:Connect(function(ReceivedBuffer, ReceivedInstances) HandleNetworkEvent(nil, ReceivedBuffer, ReceivedInstances) end)
end

return table.freeze(IonLibrary)