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
  alias Unzip.FileBuffer
  alias Unzip.RangeTree
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
    unless Map.has_key?(cd_list, file_name) do
      raise Error, message: "File #{inspect(file_name)} not present in the zip"
    end

    entry = Map.fetch!(cd_list, file_name)
    local_header = pread!(zip, entry.local_header_offset, 30)

    <<0x04034B50::little-32, _::little-32, compression_method::little-16, _::little-128,
      file_name_length::little-16, extra_field_length::little-16>> = local_header

    offset = entry.local_header_offset + 30 + file_name_length + extra_field_length

    stream!(zip, offset, entry.compressed_size)
    |> decompress(compression_method)
    |> crc_check(entry.crc)
  end

  defp stream!(file, offset, size) do
    end_offset = offset + size

    Stream.unfold(offset, fn
      offset when offset >= end_offset ->
        nil

      offset ->
        next_offset = min(offset + @chunk_size, end_offset)
        data = pread!(file, offset, next_offset - offset)
        {data, next_offset}
    end)
  end

  defp decompress(stream, 0x8) do
    stream
    |> Stream.transform(
      fn ->
        z = :zlib.open()
        :ok = :zlib.inflateInit(z, -15)
        :zlib.setBufSize(z, 512 * 1024)
        {z, true}
      end,
      fn data, {z, flag} ->
        case flag do
          true ->
            uncompressed1 = case :zlib.inflateChunk(z, data) do
              {_, uncompressed} -> uncompressed;
              uncompressed -> uncompressed
            end
            {[uncompressed1], {z, false}};
          false ->
            uncompressed = :zlib.inflateChunk(z)
            {[uncompressed], {z, false}}
        end
      end,
      fn {z, _flag} ->
        :zlib.inflateEnd(z)
        :zlib.close(z)
      end
    )
  end

  defp decompress(stream, 0x0), do: stream

  defp decompress(_stream, compression_method),
    do: raise(Error, message: "Compression method #{compression_method} is not supported")

  defp crc_check(stream, expected_crc) do
    stream
    |> Stream.transform(
      fn -> :erlang.crc32(<<>>) end,
      fn data, crc -> {[data], :erlang.crc32(crc, data)} end,
      fn crc ->
        unless crc == expected_crc do
          raise Error, message: "CRC mismatch. expected: #{expected_crc} got: #{crc}"
        end
      end
    )
  end

  defp read_cd_entries(zip, eocd) do
    with {:ok, file_buffer} <-
           FileBuffer.new(
             zip,
             @chunk_size,
             eocd.cd_offset + eocd.cd_size,
             eocd.cd_offset,
             :forward
           ) do
      parse_cd(file_buffer, %{entries: %{}, range_tree: RangeTree.new()})
    end
  end

  defp parse_cd(%FileBuffer{buffer_position: pos, limit: limit}, %{entries: entries})
       when pos >= limit,
       do: {:ok, entries}

  defp parse_cd(buffer, acc) do
    with {:ok, chunk, buffer} <- FileBuffer.next_chunk(buffer, 46),
         <<0x02014B50::little-32, _::little-32, flag::little-16, compression_method::little-16,
           mtime::little-16, mdate::little-16, crc::little-32, compressed_size::little-32,
           uncompressed_size::little-32, file_name_length::little-16,
           extra_field_length::little-16, comment_length::little-16, _::little-64,
           local_header_offset::little-32>> <- chunk,
         {:ok, buffer} <- FileBuffer.move_forward_by(buffer, 46),
         {:ok, file_name, buffer} <- FileBuffer.next_chunk(buffer, file_name_length),
         {:ok, buffer} <- FileBuffer.move_forward_by(buffer, file_name_length),
         {:ok, extra_fields, buffer} <- FileBuffer.next_chunk(buffer, extra_field_length),
         {:ok, buffer} <- FileBuffer.move_forward_by(buffer, extra_field_length),
         {:ok, _file_comment, buffer} <- FileBuffer.next_chunk(buffer, comment_length),
         {:ok, buffer} <- FileBuffer.move_forward_by(buffer, comment_length) do
      entry = %{
        bit_flag: flag,
        compression_method: compression_method,
        last_modified_datetime: to_datetime(<<mdate::16>>, <<mtime::16>>),
        crc: crc,
        compressed_size: compressed_size,
        uncompressed_size: uncompressed_size,
        local_header_offset: local_header_offset,
        # TODO: we should treat binary as "IBM Code Page 437" encoded string if GP flag 11 is not set
        file_name: file_name
      }

      entry =
        if need_zip64_extra?(entry) do
          merge_zip64_extra(entry, extra_fields)
        else
          entry
        end

      case add_entry(acc, file_name, entry) do
        {:error, _} = error -> error
        acc -> parse_cd(buffer, acc)
      end
    end
  else
    {:error, :invalid_count} -> {:error, "Invalid zip file, invalid central directory"}
    error -> error
  end

  defp add_entry(%{entries: entries, range_tree: range_tree}, file_name, entry) do
    if RangeTree.overlap?(range_tree, entry.local_header_offset, entry.compressed_size) do
      {:error, "Invalid zip file, found overlapping zip entries"}
    else
      %{
        entries: Map.put(entries, file_name, entry),
        range_tree: RangeTree.insert(range_tree, entry.local_header_offset, entry.compressed_size)
      }
    end
  end

  defp need_zip64_extra?(%{
         compressed_size: cs,
         uncompressed_size: ucs,
         local_header_offset: offset
       }) do
    Enum.any?([cs, ucs, offset], &(&1 == 0xFFFFFFFF))
  end

  @zip64_extra_field_id 0x0001
  defp merge_zip64_extra(entry, extra) do
    zip64_extra =
      find_extra_fields(extra)
      |> Map.fetch!(@zip64_extra_field_id)

    {entry, zip64_extra} =
      if entry[:uncompressed_size] == 0xFFFFFFFF do
        <<uncompressed_size::little-64, zip64_extra::binary>> = zip64_extra
        {%{entry | uncompressed_size: uncompressed_size}, zip64_extra}
      else
        {entry, zip64_extra}
      end

    {entry, zip64_extra} =
      if entry[:compressed_size] == 0xFFFFFFFF do
        <<compressed_size::little-64, zip64_extra::binary>> = zip64_extra
        {%{entry | compressed_size: compressed_size}, zip64_extra}
      else
        {entry, zip64_extra}
      end

    {entry, _zip64_extra} =
      if entry[:local_header_offset] == 0xFFFFFFFF do
        <<local_header_offset::little-64, zip64_extra::binary>> = zip64_extra
        {%{entry | local_header_offset: local_header_offset}, zip64_extra}
      else
        {entry, zip64_extra}
      end

    entry
  end

  defp find_extra_fields(extra, result \\ %{})
  defp find_extra_fields(<<>>, result), do: result

  defp find_extra_fields(
         <<id::little-16, size::little-16, data::binary-size(size), rest::binary>>,
         result
       ) do
    find_extra_fields(rest, Map.put(result, id, data))
  end

  defp find_eocd(zip) do
    with {:ok, file_buffer} <- FileBuffer.new(zip, @chunk_size),
         {:ok, eocd, file_buffer} <- find_eocd(file_buffer, 0) do
      case find_zip64_eocd(file_buffer) do
        {:ok, zip64_eocd} ->
          {:ok, zip64_eocd}

        _ ->
          {:ok, eocd}
      end
    end
  end

  @zip64_eocd_locator_size 20
  @zip64_eocd_size 56

  defp find_zip64_eocd(file_buffer) do
    with {:ok, chunk, file_buffer} <-
           FileBuffer.next_chunk(file_buffer, @zip64_eocd_locator_size),
         true <- zip64?(chunk) do
      <<0x07064B50::little-32, _::little-32, eocd_offset::little-64, _::little-32>> = chunk

      {:ok,
       <<0x06064B50::little-32, _::64, _::16, _::16, _::32, _::32, _::64,
         total_entries::little-64, cd_size::little-64,
         cd_offset::little-64>>} = pread(file_buffer.file, eocd_offset, @zip64_eocd_size)

      {:ok, %{total_entries: total_entries, cd_size: cd_size, cd_offset: cd_offset}}
    else
      _ ->
        false
    end
  end

  defp zip64?(<<0x07064B50::little-32, _::little-128>>), do: true
  defp zip64?(_), do: false

  # Spec has variable length comment at the end of zip after EOCD, so
  # EOCD can anywhere in the zip file. To avoid exhaustive search, we
  # limit search space to last 5Mb. If we don't find EOCD within that
  # we assume it's an invalid zip
  @eocd_seach_limit 5 * 1024 * 1024
  defp find_eocd(_file_buffer, consumed) when consumed > @eocd_seach_limit,
    do: {:error, "Invalid zip file, missing EOCD record"}

  @eocd_header_size 22
  defp find_eocd(file_buffer, consumed) do
    with {:ok, chunk, file_buffer} <- FileBuffer.next_chunk(file_buffer, @eocd_header_size) do
      case chunk do
        <<0x06054B50::little-32, _ignore::little-48, total_entries::little-16, cd_size::little-32,
          cd_offset::little-32, ^consumed::little-16>> ->
          {:ok, buffer} = FileBuffer.move_backward_by(file_buffer, @eocd_header_size)
          {:ok, %{total_entries: total_entries, cd_size: cd_size, cd_offset: cd_offset}, buffer}

        chunk when byte_size(chunk) < @eocd_header_size ->
          {:error, "Invalid zip file, missing EOCD record"}

        _ ->
          {:ok, buffer} = FileBuffer.move_backward_by(file_buffer, 1)
          find_eocd(buffer, consumed + 1)
      end
    end
  end

  defp to_datetime(<<year::7, month::4, day::5>> = date, <<hour::5, minute::6, second::5>> = time) do
    case NaiveDateTime.new(1980 + year, month, day, hour, minute, second * 2) do
      {:ok, datetime} ->
        datetime

      _ ->
        Logger.warn(
          "[unzip] invalid datetime. date: #{inspect_binary(date)} time: #{inspect_binary(time)}"
        )

        nil
    end
  end

  defp pread!(file, offset, length) do
    case pread(file, offset, length) do
      {:ok, term} -> term
      {:error, reason} when is_binary(reason) -> raise Error, message: reason
      {:error, reason} -> raise Error, message: inspect(reason)
    end
  end

  defp pread(file, offset, length) do
    case FileAccess.pread(file, offset, length) do
      {:ok, term} when is_binary(term) ->
        {:ok, term}

      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error, "Invalid data returned by pread/3. Expected binary"}
    end
  end

  defp inspect_binary(binary), do: inspect(binary, binaries: :as_binaries, base: :hex)
end
