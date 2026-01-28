defmodule LLMDB.MergeTest do
  use ExUnit.Case, async: true

  alias LLMDB.Merge

  test "merge_list_by_id preserves base order and appends extras" do
    base = [%{id: "a", rate: 1}, %{id: "b", rate: 2}]
    override = [%{id: "b", rate: 3}, %{id: "c", rate: 4}]

    result = Merge.merge_list_by_id(base, override)

    assert Enum.map(result, & &1.id) == ["a", "b", "c"]
    assert Enum.find(result, &(&1.id == "b")).rate == 3
  end

  test "merge_list_by_id matches string id keys" do
    base = [%{"id" => "a", "rate" => 1}]
    override = [%{"id" => "a", "rate" => 2}, %{"id" => "b", "rate" => 3}]

    result = Merge.merge_list_by_id(base, override)

    assert Enum.map(result, &Map.get(&1, "id")) == ["a", "b"]
    assert Enum.find(result, &(Map.get(&1, "id") == "a"))["rate"] == 2
  end

  test "merge_list_by_id matches atom ids with string id_key" do
    base = [%{id: "a", rate: 1}]
    override = [%{id: "a", rate: 2}, %{id: "b", rate: 3}]

    result = Merge.merge_list_by_id(base, override, "id")

    assert Enum.map(result, & &1.id) == ["a", "b"]
    assert Enum.find(result, &(&1.id == "a")).rate == 2
  end
end
