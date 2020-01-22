defmodule Unzip.LocalFile do
  defstruct [:path, :handle]
  alias __MODULE__

  def open(path) do
    {:ok, file} = :file.open(path, [:read, :binary, :raw])
    %Unzip.LocalFile{path: path, handle: file}
  end

  def close(file) do
    :ok = :file.close(file.handle)
  end
end

defimpl Unzip.FileAccess, for: Unzip.LocalFile do
  def size(file) do
    %File.Stat{size: size} = File.lstat!(file.path)
    {:ok, size}
  end

  def pread(file, offset, length) do
    :file.pread(file.handle, offset, length)
  end
end
