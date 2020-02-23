defmodule Unzip.FileBuffer do
  @moduledoc false

  defstruct [:file, :limit, :buffer, :buffer_size, :buffer_position, :direction]
  alias __MODULE__

  def new(file, buffer_size) do
    with {:ok, size} <- file_size(file) do
      position = size

      {:ok,
       %FileBuffer{
         file: file,
         limit: size,
         buffer: <<>>,
         buffer_position: position,
         buffer_size: buffer_size,
         direction: :backward
       }}
    end
  end

  def new(file, buffer_size, limit, position, direction) do
    with {:ok, size} <- file_size(file) do
      if limit > size do
        {:error, "Invalid limit"}
      else
        {:ok,
         %FileBuffer{
           file: file,
           limit: limit,
           buffer: <<>>,
           buffer_position: position,
           buffer_size: buffer_size,
           direction: direction
         }}
      end
    end
  end

  def next_chunk(%FileBuffer{direction: :forward} = buffer, size) do
    buffer_end_pos = buffer.buffer_position + byte_size(buffer.buffer)
    end_pos = min(buffer.buffer_position + size, buffer.limit)

    if end_pos > buffer_end_pos do
      new_buffer_end_pos = min(buffer.limit, max(buffer_end_pos + buffer.buffer_size, end_pos))
      chunk_size = new_buffer_end_pos - buffer.buffer_position

      with {:ok, binary} <-
             pread(buffer.file, buffer.buffer_position + byte_size(buffer.buffer), chunk_size) do
        buffer = %FileBuffer{buffer | buffer: buffer.buffer <> binary}
        {:ok, binary_part(buffer.buffer, 0, min(size, byte_size(buffer.buffer))), buffer}
      end
    else
      {:ok, binary_part(buffer.buffer, 0, min(size, byte_size(buffer.buffer))), buffer}
    end
  end

  def next_chunk(buffer, size) do
    buffer_end_pos = buffer.buffer_position + byte_size(buffer.buffer)
    start_pos = max(0, buffer_end_pos - size)

    if buffer.buffer_position > start_pos do
      new_buffer_pos = max(0, min(buffer.buffer_position - buffer.buffer_size, start_pos))
      chunk_size = buffer.buffer_position - new_buffer_pos

      with {:ok, binary} <- pread(buffer.file, new_buffer_pos, chunk_size) do
        offset = start_pos - new_buffer_pos

        buffer = %FileBuffer{
          buffer
          | buffer: binary <> buffer.buffer,
            buffer_position: new_buffer_pos
        }

        {:ok, binary_part(buffer.buffer, offset, min(size, byte_size(buffer.buffer))), buffer}
      end
    else
      offset = start_pos - buffer.buffer_position
      {:ok, binary_part(buffer.buffer, offset, min(size, byte_size(buffer.buffer))), buffer}
    end
  end

  def move_backward_by(%FileBuffer{buffer: buffer}, count) when byte_size(buffer) < count,
    do: {:error, :invalid_count}

  def move_backward_by(buffer, count) do
    {:ok,
     %FileBuffer{
       buffer
       | buffer: binary_part(buffer.buffer, 0, byte_size(buffer.buffer) - count)
     }}
  end

  def move_forward_by(%FileBuffer{buffer: buffer}, count) when byte_size(buffer) < count,
    do: {:error, :invalid_count}

  def move_forward_by(buffer, count) do
    {:ok,
     %FileBuffer{
       buffer
       | buffer: binary_part(buffer.buffer, count, byte_size(buffer.buffer) - count),
         buffer_position: min(buffer.buffer_position + count, buffer.limit)
     }}
  end

  defp pread(file, offset, length) do
    case Unzip.FileAccess.pread(file, offset, length) do
      {:ok, term} when is_binary(term) -> {:ok, term}
      {:error, reason} -> {:error, reason}
      _ -> {:error, "Invalid data returned by pread/3. Expected binary"}
    end
  end

  defp file_size(file) do
    case Unzip.FileAccess.size(file) do
      {:ok, term} when is_integer(term) -> {:ok, term}
      {:error, reason} -> {:error, reason}
      _ -> {:error, "Invalid data returned by size/1. Expected integer"}
    end
  end
end
