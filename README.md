# Unzip [![Hex.pm](https://img.shields.io/hexpm/v/unzip.svg)](https://hex.pm/packages/unzip)

Module to get files out of a zip. Works with local and remote files

## Overview

Unzip tries to solve problem of accessing files from a zip which is not local (Aws S3, sftp etc). It does this by simply separating file system and zip implementation. Anything which implements `Unzip.FileAccess` can be used to get zip contents. Unzip relies on the ability to seek and read of the file, This is due to the nature of zip file.  Files from the zip are read on demand.

## Installation

```elixir
def deps do
  [
    {:unzip, "~> x.x.x"}
  ]
end
```

## Usage

```elixir
# Unzip.LocalFile implements Unzip.FileAccess
zip_file = Unzip.LocalFile.open("foo/bar.zip")

# `new` reads list of files by reading central directory found at the end of the zip
{:ok, unzip} = Unzip.new(zip_file)

# presents already read files metadata
file_entries = Unzip.list_entries(unzip)

# returns decompressed file stream
stream = Unzip.file_stream!(unzip, "baz.png")
```

Supports STORED and DEFLATE compression methods. Does not support zip64 specification yet.

## Implementing `Unzip.FileAccess` protocol

### S3 File

Using [ExAws](https://hexdocs.pm/ex_aws/ExAws.html)

```elixir
defmodule Unzip.S3File do
  defstruct [:path, :bucket, :s3_config]
  alias __MODULE__

  def new(path, bucket, s3_config) do
    %S3File{path: path, bucket: bucket, s3_config: s3_config}
  end
end

defimpl Unzip.FileAccess, for: Unzip.S3File do
  alias ExAws.S3

  def size(file) do
    %{headers: headers} = S3.head_object(file.bucket, file.path) |> ExAws.request!(file.s3_config)

    size =
      headers
      |> Enum.find(fn {k, _} -> String.downcase(k) == "content-length" end)
      |> elem(1)
      |> String.to_integer()

    {:ok, size}
  end

  def pread(file, offset, length) do
    {_, chunk} =
      S3.Download.get_chunk(
        %S3.Download{bucket: file.bucket, path: file.path, dest: nil},
        %{start_byte: offset, end_byte: offset + length - 1},
        file.s3_config
      )

    {:ok, chunk}
  end
end


# Using S3File

aws_s3_config = ExAws.Config.new(:s3,
  access_key_id: ["key_id", :instance_role],
  secret_access_key: ["key", :instance_role]
)

file = Unzip.S3File.new("pets.zip", "pics", aws_s3_config)
{:ok, unzip} = Unzip.new(file)
files = Unzip.list_entries(unzip)

Unzip.file_stream!(unzip, "cats/kitty.png")
|> Stream.into(File.stream!("kitty.png"))
|> Stream.run()

```

### SFTP File

```elixir
defmodule Unzip.SftpFile do
  defstruct [:channel_pid, :connection_ref, :handle, :file_path]
  alias __MODULE__

  def new(host, port, sftp_opts, file_path) do
    :ok = :ssh.start()

    {:ok, channel_pid, connection_ref} =
      :ssh_sftp.start_channel(to_charlist(host), port, sftp_opts)

    {:ok, handle} = :ssh_sftp.open(channel_pid, file_path, [:read, :raw, :binary])

    %SftpFile{
      channel_pid: channel_pid,
      connection_ref: connection_ref,
      handle: handle,
      file_path: file_path
    }
  end

  def close(file) do
    :ssh_sftp.close(file.channel_pid, file.handle)
    :ssh_sftp.stop_channel(file.channel_pid)
    :ssh.close(file.connection_ref)
    :ok
  end
end

defimpl Unzip.FileAccess, for: Unzip.SftpFile do
  def size(file) do
    {:ok, file_info} = :ssh_sftp.read_file_info(file.channel_pid, file.file_path)
    {:ok, elem(file_info, 1)}
  end

  def pread(file, offset, length) do
    :ssh_sftp.pread(file.channel_pid, file.handle, offset, length)
  end
end


# Using SftpFile

sftp_opts = [
  user_interaction: false,
  silently_accept_hosts: true,
  rekey_limit: 1_000_000_000_000,
  user: 'user',
  password: 'password'
]

file = Unzip.SftpFile.new('127.0.0.1', 22, sftp_opts, '/home/user/pics.zip')

try do
  {:ok, unzip} = Unzip.new(file)
  files = Unzip.list_entries(unzip)

  Unzip.file_stream!(unzip, "cats/kitty.png")
  |> Stream.into(File.stream!("kitty.png"))
  |> Stream.run()
after
  Unzip.SftpFile.close(file)
end

```
