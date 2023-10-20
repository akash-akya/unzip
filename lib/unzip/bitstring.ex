# FileAccess implementation for files in memory as binary/bitstring
defimpl Unzip.FileAccess, for: BitString do
  def size(binary) do
    {:ok, byte_size(binary)}
  end

  def pread(binary, offset, length) do
    if offset < 0 do
      raise ArgumentError, "offset must be non negative integer"
    end

    if length < 1 do
      raise ArgumentError, "length must be positive integer"
    end

    {:ok, binary_part(binary, offset, length)}
  end
end
