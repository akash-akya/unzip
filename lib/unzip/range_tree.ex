defmodule Unzip.RangeTree do
  @moduledoc false
  # Simple binary search tree implementaion using gb_trees.

  def new, do: :gb_trees.empty()

  def insert(t, offset, length), do: :gb_trees.insert(offset, length, t)

  @doc """
  Returns true if the range overlap with any of the range entry in the tree
  """
  def overlap?({_, tree}, offset, length) do
    pos_overlap?(tree, offset, nil) || pos_overlap?(tree, offset + length - 1, nil)
  end

  defp pos_overlap?(nil, _, nil), do: false

  defp pos_overlap?(nil, pos, {offset, length, _, _}),
    do: offset <= pos && pos < offset + length - 1

  defp pos_overlap?({offset, _, smaller, _}, pos, prev_range) when offset > pos,
    do: pos_overlap?(smaller, pos, prev_range)

  defp pos_overlap?({_, _, _, bigger} = range, pos, _),
    do: pos_overlap?(bigger, pos, range)
end
