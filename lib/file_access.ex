defprotocol Unzip.FileAccess do
  def pread(file, offset, length)
  def size(file)
end
