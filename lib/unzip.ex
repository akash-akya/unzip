defmodule Unzip do
  require Logger
  alias Unzip.FileAccess
  use Bitwise, only_operators: true

  @chunk_size 65_000

  defstruct [:zip, :cd_list]

  defmodule Error do
    defexception [:message]
  end

  defmodule Entry do
    defstruct [
      :file_name,
      :last_modified_datetime,
      :compressed_size,
      :uncompressed_size
    ]
  end

  def new(zip) do
    eocd = find_eocd(zip)
    {:ok, %Unzip{zip: zip, cd_list: read_cd_entries(zip, eocd)}}
  end

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

  def file_stream!(%Unzip{zip: zip, cd_list: cd_list}, file_name) do
    entry = Map.fetch!(cd_list, file_name)
    {:ok, local_header} = FileAccess.pread(zip, entry.local_header_offset, 30)

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
          {:ok, data} = FileAccess.pread(file, offset, next_offset - offset)
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
        {:ok, data} = FileAccess.pread(file, offset, next_offset - offset)
        crc = :erlang.crc32(crc, data)
        {data, {next_offset, crc}}
    end)
  end

  defp read_cd_entries(zip, eocd) do
    {:ok, data} = FileAccess.pread(zip, eocd.cd_offset, eocd.cd_size)
    parse_cd(data, %{})
  end

  defp parse_cd(<<>>, result), do: result

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
    {:ok, file_size} = FileAccess.size(zip)

    Stream.unfold(file_size, fn
      offset when offset < 0 ->
        nil

      offset ->
        start_offset = max(offset - @chunk_size, 0)
        {{start_offset, @chunk_size}, start_offset}
    end)
    |> Enum.reduce_while({<<>>, 0}, fn {start_offset, length}, {acc, consumed} ->
      {:ok, data} = FileAccess.pread(zip, start_offset, length)

      case find_and_parse_eocd(data <> acc) do
        {%{comment_length: comment_length} = eocd, partial_comment}
        when comment_length == byte_size(partial_comment) + consumed ->
          {:halt, {:ok, eocd}}

        _ ->
          <<acc::binary-size(@eocd_header_size), rest::binary>> = data
          {:cont, {acc, consumed + byte_size(rest)}}
      end
    end)
    |> case do
      {:ok, eocd} -> eocd
      _ -> raise Error, message: "Invalid zip file, missing EOCD record"
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

  # We should handle encoding properly by checking bit 11, but zip files seems to ignore it
  defp to_utf8(binary) do
    :unicode.characters_to_binary(binary)
  end

  defp to_datetime(<<year::7, month::4, day::5>>, <<hour::5, minute::6, second::5>>) do
    {:ok, datetime} = NaiveDateTime.new(1980 + year, month, day, hour, minute, second)
    datetime
  end
end
