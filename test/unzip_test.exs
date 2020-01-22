defmodule UnzipTest do
  use ExUnit.Case
  import Unzip

  @sample_zip Path.join(__DIR__, "support/zip_2MB.zip")

  test "stream" do
    file = Unzip.LocalFile.open(@sample_zip)

    try do
      {:ok, unzip} = Unzip.new(file)
      files = Unzip.list_entries(unzip)

      files
      |> Enum.map(fn entry ->
        IO.inspect(entry)

        file_stream!(unzip, entry.file_name)
        |> Stream.run()
      end)
    after
      Unzip.LocalFile.close(file)
    end
  end
end
