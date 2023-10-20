defmodule Unzip.BitstringTest do
  use ExUnit.Case

  @fixture_path Path.join(__DIR__, "../support")

  test "list_entries/1" do
    {:ok, file} = Unzip.new(zip_binary("abc.zip"))

    assert [
             %Unzip.Entry{
               compressed_size: 701,
               file_name: "abc.txt",
               last_modified_datetime: ~N[2006-05-03 10:14:10],
               uncompressed_size: 1300
             },
             %Unzip.Entry{
               compressed_size: 0,
               file_name: "empty/",
               last_modified_datetime: ~N[2008-04-23 14:38:58],
               uncompressed_size: 0
             },
             %Unzip.Entry{
               compressed_size: 0,
               file_name: "emptyFile",
               last_modified_datetime: ~N[2008-04-23 18:20:52],
               uncompressed_size: 0
             },
             %Unzip.Entry{
               compressed_size: 36,
               file_name: "quotes/rain.txt",
               last_modified_datetime: ~N[2008-04-04 11:05:42],
               uncompressed_size: 44
             },
             %Unzip.Entry{
               compressed_size: 949,
               file_name: "wikipedia.txt",
               last_modified_datetime: ~N[2008-04-23 18:20:36],
               uncompressed_size: 1790
             }
           ] = Unzip.list_entries(file)
  end

  test "stream!" do
    {:ok, file} = Unzip.new(zip_binary("abc.zip"))

    assert "The rain in Spain stays mainly in the plain\n" =
             Unzip.file_stream!(file, "quotes/rain.txt") |> Enum.join()

    {:ok, file} = Unzip.new(zip_binary("zip_2MB.zip"))

    result =
      Unzip.file_stream!(file, "zip_10MB/file-sample_1MB.doc")
      |> Enum.to_list()
      |> IO.iodata_to_binary()

    assert File.read!(Path.join(@fixture_path, "file-sample_1MB.doc")) == result
  end

  test "decompression for deflate" do
    {:ok, file} = Unzip.new(zip_binary("deflate.zip"))

    result =
      Unzip.file_stream!(file, "file-sample_1MB.doc")
      |> Enum.to_list()
      |> IO.iodata_to_binary()

    assert File.read!(Path.join(@fixture_path, "file-sample_1MB.doc")) == result
  end

  test "decompression for store" do
    {:ok, file} = Unzip.new(zip_binary("stored.zip"))

    result =
      Unzip.file_stream!(file, "file-sample_1MB.doc")
      |> Enum.to_list()
      |> IO.iodata_to_binary()

    assert File.read!(Path.join(@fixture_path, "file-sample_1MB.doc")) == result
  end

  describe "zip64" do
    test "file_stream" do
      {:ok, file} = Unzip.new(zip_binary("Zeros.zip"))

      assert [
               %Unzip.Entry{
                 compressed_size: 5_611_526,
                 file_name: "0000",
                 last_modified_datetime: ~N[2011-03-25 17:14:14],
                 uncompressed_size: 5_368_709_120
               }
             ] = Unzip.list_entries(file)
    end

    test "large number of entires" do
      {:ok, file} = Unzip.new(zip_binary("90,000_files.zip"))
      entries = Unzip.list_entries(file)
      assert length(entries) == 90_000
    end
  end

  describe "handling zip bomb" do
    test "full overlapping range" do
      {:error, "Invalid zip file, found overlapping zip entries"} =
        Unzip.new(zip_binary("full_overlap.zip"))
    end

    test "quoted overlapping range" do
      {:error, "Invalid zip file, found overlapping zip entries"} =
        Unzip.new(zip_binary("quoted_overlap.zip"))
    end

    test "zip bomb zip64" do
      {:error, "Invalid zip file, found overlapping zip entries"} =
        Unzip.new(zip_binary("quoted_overlap.zip"))
    end
  end

  defp zip_binary(file_name) do
    Path.join(@fixture_path, file_name)
    |> File.read!()
  end
end
