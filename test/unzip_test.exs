defmodule UnzipTest do
  use ExUnit.Case

  @fixture_path Path.join(__DIR__, "support/")

  test "zip with invalid central directory file header" do
    <<_ignore::8, zip::binary>> = File.read!(Path.join(@fixture_path, "abc.zip"))
    assert {:error, "Invalid zip file, invalid central directory file header"} = Unzip.new(zip)
  end

  test "zip with invalid central directory" do
    assert {:error, "Invalid zip file, invalid central directory"} =
             Unzip.new(local_zip("bad_central_directory.zip"))
  end

  test "zip with missing EOCD record" do
    assert {:error, "Invalid zip file, missing EOCD record"} =
             Unzip.new(local_zip("bad_eocd.zip"))
  end

  test "zip with bad file local header" do
    {:ok, file} = Unzip.new(local_zip("bad_file_header.zip"))

    assert_raise Unzip.Error, "Compression method 30840 is not supported", fn ->
      Unzip.file_stream!(file, "abc.txt")
      |> Stream.run()
    end
  end

  test "list_entries/1" do
    {:ok, file} = Unzip.new(local_zip("abc.zip"))

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
    {:ok, file} = Unzip.new(local_zip("abc.zip"))

    assert "The rain in Spain stays mainly in the plain\n" =
             Unzip.file_stream!(file, "quotes/rain.txt") |> Enum.join()

    {:ok, file} = Unzip.new(local_zip("zip_2MB.zip"))

    result =
      Unzip.file_stream!(file, "zip_10MB/file-sample_1MB.doc")
      |> Enum.to_list()
      |> IO.iodata_to_binary()

    assert File.read!(Path.join(@fixture_path, "file-sample_1MB.doc")) == result
  end

  test "stream! with chunk_size" do
    {:ok, file} = Unzip.new(local_zip("stored.zip"))

    chunks =
      Unzip.file_stream!(file, "file-sample_1MB.doc", chunk_size: 100_000)
      |> Enum.to_list()

    assert IO.iodata_length(hd(chunks)) == 100_000

    assert File.read!(Path.join(@fixture_path, "file-sample_1MB.doc")) ==
             IO.iodata_to_binary(chunks)
  end

  test "decompression for deflate" do
    {:ok, file} = Unzip.new(local_zip("deflate.zip"))

    result =
      Unzip.file_stream!(file, "file-sample_1MB.doc")
      |> Enum.to_list()
      |> IO.iodata_to_binary()

    assert File.read!(Path.join(@fixture_path, "file-sample_1MB.doc")) == result
  end

  test "decompression for store" do
    {:ok, file} = Unzip.new(local_zip("stored.zip"))

    result =
      Unzip.file_stream!(file, "file-sample_1MB.doc")
      |> Enum.to_list()
      |> IO.iodata_to_binary()

    assert File.read!(Path.join(@fixture_path, "file-sample_1MB.doc")) == result
  end

  describe "zip64" do
    test "file_stream" do
      {:ok, file} = Unzip.new(local_zip("Zeros.zip"))

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
      {:ok, file} = Unzip.new(local_zip("90,000_files.zip"))
      entries = Unzip.list_entries(file)
      assert length(entries) == 90_000
    end
  end

  describe "handling zip bomb" do
    test "full overlapping range" do
      {:error, "Invalid zip file, found overlapping zip entries"} =
        Unzip.new(local_zip("full_overlap.zip"))
    end

    test "quoted overlapping range" do
      {:error, "Invalid zip file, found overlapping zip entries"} =
        Unzip.new(local_zip("quoted_overlap.zip"))
    end

    test "zip bomb zip64" do
      {:error, "Invalid zip file, found overlapping zip entries"} =
        Unzip.new(local_zip("quoted_overlap.zip"))
    end
  end

  defp local_zip(file_name) do
    Unzip.LocalFile.open(Path.join(@fixture_path, file_name))
  end
end
