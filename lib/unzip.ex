defmodule Unzip do
  @moduledoc """
  Module to get files out of a zip. Works with local and remote files

  ## Overview
  Unzip tries to solve problem of accessing files from a zip which is not local (Aws S3, sftp etc). It does this by simply separating file system and zip implementation. Anything which implements `Unzip.FileAccess` can be used to get zip contents. Unzip relies on the ability to seek and read of the file, This is due to the nature of zip file.  Files from the zip are read on demand.

  ## Usage

      # Unzip.LocalFile implements Unzip.FileAccess
      zip_file = Unzip.LocalFile.open("foo/bar.zip")

      # `new` reads list of files by reading central directory found at the end of the zip
      {:ok, unzip} = Unzip.new(zip_file)

      # presents already read files metadata
      file_entries = Unzip.list_entries(unzip)

      # returns decompressed file stream
      stream = Unzip.file_stream!(unzip, "baz.png")


  Supports STORED and DEFLATE compression methods. Does not support zip64 specification yet

  """
  require Logger
  alias Unzip.FileAccess
  use Bitwise, only_operators: true

  @chunk_size 65_000

  defstruct [:zip, :cd_list]

  defmodule Error do
    defexception [:message]
  end

  defmodule Entry do
    @moduledoc """
    File metadata returned by `Unzip.list_entries/1`

      * `:file_name` - (string) File name with complete path. Directory files will have `/` at the end of their name

      * `:last_modified_datetime` - (NaiveDateTime) last modified date and time of the file

      * `:compressed_size` - (positive integer) Compressed file size in bytes

      * `:uncompressed_size` - (positive integer) Uncompressed file size in bytes

    """
    defstruct [
      :file_name,
      :last_modified_datetime,
      :compressed_size,
      :uncompressed_size
    ]
  end

  @doc """
  Creates Unzip struct by reading central directory found at the end of the zip (reads entries in the file)
  """
  def new(zip) do
    with {:ok, eocd} <- find_eocd(zip),
         {:ok, entries} <- read_cd_entries(zip, eocd) do
      {:ok, %Unzip{zip: zip, cd_list: entries}}
    end
  end

  @doc """
  Returns list of files metadata. This does not make `pread` call as metadata is already by `new/1`.

  See `Unzip.Entry` for metadata fields
  """
  def list_entries(unzip) do
    Enum.map(unzip.cd_list, fn {_, entry} ->
      %Entry{
        file_name: entry.file_name,
        last_modified_datetime: entry.last_modified_datetime,
        compressed_size: entry.compressed_size,
        uncompressed_size: entry.uncompressed_size
      }
    end)
  end

  @doc """
  Returns decompressed file entry from the zip as a stream. `file_name` *must* be complete file path. File is read in the chunks of 65k
  """
  def file_stream!(%Unzip{zip: zip, cd_list: cd_list}, file_name) do
    entry = Map.fetch!(cd_list, file_name)
    local_header = pread!(zip, entry.local_header_offset, 30)

    <<0x04034B50::little-32, _::little-32, compression_method::little-16, _::little-128,
      file_name_length::little-16, extra_field_length::little-16>> = local_header

    offset = entry.local_header_offset + 30 + file_name_length + extra_field_length
    decompress(compression_method, zip, offset, entry)
  end

  defp decompress(0x8, file, offset, %{crc: expected_crc, compressed_size: size}) do
    end_offset = offset + size

    Stream.resource(
      fn ->
        z = :zlib.open()
        :ok = :zlib.inflateInit(z, -15)
        {z, offset}
      end,
      fn
        {z, offset} when offset >= end_offset ->
          {:halt, {z, nil}}

        {z, offset} ->
          next_offset = min(offset + @chunk_size, end_offset)
          data = pread!(file, offset, next_offset - offset)
          {[:zlib.inflate(z, data)], {z, next_offset}}
      end,
      fn {z, _} ->
        crc = :zlib.crc32(z)

        unless crc == expected_crc do
          raise Error, message: "CRC mismatch. expected: #{expected_crc} got: #{crc}"
        end

        :zlib.inflateEnd(z)
        :zlib.close(z)
      end
    )
  end

  defp decompress(0x0, file, offset, %{crc: expected_crc, compressed_size: size}) do
    end_offset = offset + size
    crc = :erlang.crc32(<<>>)

    Stream.unfold({offset, crc}, fn
      {offset, crc} when offset >= end_offset ->
        unless crc == expected_crc do
          raise "CRC mismatch. expected: #{expected_crc} got: #{crc}"
        end

      {offset, crc} ->
        next_offset = min(offset + @chunk_size, end_offset)
        {:ok, data} = pread!(file, offset, next_offset - offset)
        crc = :erlang.crc32(crc, data)
        {data, {next_offset, crc}}
    end)
  end

  defp read_cd_entries(zip, eocd) do
    with {:ok, data} <- pread(zip, eocd.cd_offset, eocd.cd_size) do
      parse_cd(data, %{})
    end
  end

  defp parse_cd(<<>>, result), do: {:ok, result}

  defp parse_cd(<<0x02014B50::little-32, _::binary>> = cd, result) do
    <<0x02014B50::little-32, _::little-32, flag::little-16, compression_method::little-16,
      mtime::little-16, mdate::little-16, crc::little-32, compressed_size::little-32,
      uncompressed_size::little-32, file_name_length::little-16, extra_field_length::little-16,
      comment_length::little-16, _::little-64, local_header_offset::little-32,
      file_name::binary-size(file_name_length), _::binary-size(extra_field_length),
      _::binary-size(comment_length), rest::binary>> = cd

    entry = %{
      bit_flag: flag,
      compression_method: compression_method,
      last_modified_datetime: to_datetime(<<mdate::16>>, <<mtime::16>>),
      crc: crc,
      compressed_size: compressed_size,
      uncompressed_size: uncompressed_size,
      local_header_offset: local_header_offset,
      file_name: to_utf8(file_name)
    }

    parse_cd(rest, Map.put(result, file_name, entry))
  end

  @eocd_header_size 22
  defp find_eocd(zip) do
    with {:ok, size} <- file_size(zip) do
      offset_stream(size)
      |> Enum.reduce_while({<<>>, 0}, fn {start_offset, length}, {acc, consumed} ->
        with {:ok, data} <- pread(zip, start_offset, length) do
          case find_and_parse_eocd(data <> acc) do
            {%{comment_length: comment_length} = eocd, partial_comment}
            when comment_length == byte_size(partial_comment) + consumed ->
              {:halt, {:ok, eocd}}

            _ ->
              <<acc::binary-size(@eocd_header_size), rest::binary>> = data
              {:cont, {acc, consumed + byte_size(rest)}}
          end
        else
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, eocd} -> {:ok, eocd}
        {:error, reason} -> {:error, reason}
        _ -> {:error, "Invalid zip file, missing EOCD record"}
      end
    end
  end

  defp find_and_parse_eocd(data) when byte_size(data) < @eocd_header_size, do: nil

  defp find_and_parse_eocd(
         <<0x06054B50::little-32, _ignore::little-48, total_entries::little-16,
           cd_size::little-32, cd_offset::little-32, comment_length::little-16,
           partial_comment::binary>>
       ) do
    data = %{
      total_entries: total_entries,
      cd_size: cd_size,
      cd_offset: cd_offset,
      comment_length: comment_length
    }

    {data, partial_comment}
  end

  defp find_and_parse_eocd(<<_::8, rest::binary>>), do: find_and_parse_eocd(rest)

  defp offset_stream(size) do
    Stream.unfold(size, fn
      offset when offset < 0 ->
        nil

      offset ->
        start_offset = max(offset - @chunk_size, 0)
        {{start_offset, @chunk_size}, start_offset}
    end)
  end

  # We should handle encoding properly by checking bit 11, but zip files seems to ignore it
  defp to_utf8(binary) do
    :unicode.characters_to_binary(binary)
  end

  defp to_datetime(<<year::7, month::4, day::5>>, <<hour::5, minute::6, second::5>>) do
    {:ok, datetime} = NaiveDateTime.new(1980 + year, month, day, hour, minute, second)
    datetime
  end

  defp pread!(file, offset, length) do
    case pread(file, offset, length) do
      {:ok, term} -> term
      {:error, reason} -> raise Error, message: reason
    end
  end

  defp pread(file, offset, length) do
    case FileAccess.pread(file, offset, length) do
      {:ok, term} when is_binary(term) -> {:ok, term}
      {:error, reason} -> {:error, reason}
      _ -> {:error, "Invalid data returned by pread/3. Expected binary"}
    end
  end

  defp file_size(file) do
    case FileAccess.size(file) do
      {:ok, term} when is_integer(term) -> {:ok, term}
      {:error, reason} -> {:error, reason}
      _ -> {:error, "Invalid data returned by size/1. Expected integer"}
    end
  end
end
