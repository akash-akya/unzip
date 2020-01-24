# Unzip [![Hex.pm](https://img.shields.io/hexpm/v/unzip.svg)](https://hex.pm/packages/unzip)

Module to get files out of a zip. Works with local and remote files

## Overview

Unzip tries to solve problem of accessing files from a zip which is not local (Aws S3, sftp etc). It does this by simply separating file system and zip implementation. Anything which implements `Unzip.FileAccess` can be used to get zip contents. Unzip relies on the ability to seek and read of the file, This is due to the nature of zip file.  Files from the zip are read on demand.

## Installation

```elixir
def deps do
  [
    {:unzip, "~> 0.1.0"}
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
