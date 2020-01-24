defprotocol Unzip.FileAccess do
  @moduledoc """
  Should be implemented for the module which can read from the file system.
  """

  @type reason() :: String.t()
  @type chunk() :: binary()

  @doc """
  Reads the chunk of data from the `file`.

  It should return `{:ok, binary}` where binary is the chunk found at `offset` with length `length`
  """
  def pread(file, offset, length)

  @doc """
  Returns the size of the file in bytes.
  """
  @spec size(any()) :: {:ok, pos_integer()} | {:error, reason}
  def size(file)
end
