# List Merge Bug: Detailed Investigation & Proposed Fix

## Executive Summary

**Bug**: The `model_merge_resolver/3` function in [lib/llm_db/engine.ex](file:///Users/mhostetler/Source/ReqLLM/sync_db/llm_db/lib/llm_db/engine.ex) always replaces lists from lower-precedence sources, despite comments claiming it unions known list fields like `:aliases`.

**Impact**: When multiple sources provide the same model with different aliases, tags, or modalities, data from lower-precedence sources is lost.

**Fix**: Implement key-aware union for accumulative list fields (`:aliases`, `:tags`, `:input`, `:output`); keep last-wins replace for all other fields.

**Effort**: S (≤1 hour)

---

## 1. Bug Location & Analysis

### Code Location

[lib/llm_db/engine.ex](file:///Users/mhostetler/Source/ReqLLM/sync_db/llm_db/lib/llm_db/engine.ex), lines ~310–344:

```elixir
# Lines 310-312 (comment)
# List fields are merged by unioning when it makes sense:
# Union for known list fields (aliases), replace for others

# Lines 329-344 (actual implementation)
defp model_merge_resolver(_key, left_val, right_val) 
     when is_list(left_val) and is_list(right_val) do
  right_val  # ❌ Always replaces, never unions!
end
```

### The Bug

**Comment claims**: "Union for known list fields (aliases)"  
**Code does**: Unconditionally replaces all lists with `right_val`

No key-aware logic exists; the `_key` parameter is ignored for list values.

### Affected List Fields on Model

From [lib/llm_db/schema/model.ex](file:///Users/mhostetler/Source/ReqLLM/sync_db/llm_db/lib/llm_db/schema/model.ex):

- `:aliases` - `[string]` (default `[]`)
- `:tags` - `[string]` (optional)
- `:modalities` - map containing:
  - `:input` - `[atom]` (optional)
  - `:output` - `[atom]` (optional)
- `:extra` - freeform map (may contain lists, but semantics unknown)

---

## 2. Understanding the Source System

### Multi-Source Architecture

LLMDb uses a layered ETL pipeline where multiple sources are merged with **last-wins precedence**.

### Source Precedence (from [config/config.exs](file:///Users/mhostetler/Source/ReqLLM/sync_db/llm_db/config/config.exs))

Sources are processed in order from lowest to highest precedence:

1. **LLMDb.Sources.ModelsDev** (lowest precedence)
2. **LLMDb.Sources.OpenRouter**
3. **LLMDb.Sources.Local**
4. **LLMDb.Sources.Config** (highest precedence)

Later sources override earlier ones for scalar fields.

### Merge Process in `merge_layers/1`

From [lib/llm_db/engine.ex](file:///Users/mhostetler/Source/ReqLLM/sync_db/llm_db/lib/llm_db/engine.ex), lines ~170–194:

1. **Providers**: Merged via `Merge.merge_providers/2` (last-wins)
2. **Models**: 
   - Merged by identity key `{provider, id}`
   - Deep-merged using `model_merge_resolver/3` for conflict resolution
   - Then provider-level `exclude_models` are applied

### Current Behavior

```elixir
defp merge_models_with_list_rules(base_models, override_models) do
  base_map = Map.new(base_models, fn m -> 
    {{Map.get(m, :provider), Map.get(m, :id)}, m} 
  end)
  
  override_map = Map.new(override_models, fn m -> 
    {{Map.get(m, :provider), Map.get(m, :id)}, m} 
  end)

  Map.merge(base_map, override_map, fn _identity, base_model, override_model ->
    deep_merge_with_list_rules(base_model, override_model)
  end)
  |> Map.values()
end
```

For each model identity, maps are deep-merged; conflicts resolved by `model_merge_resolver/3`.

---

## 3. Concrete Example: The Bug in Action

### Scenario

**Source A** (ModelsDev - lower precedence):
```elixir
%Model{
  provider: :openai,
  id: "gpt-4",
  aliases: ["gpt-4-0314"],
  tags: ["general", "production"]
}
```

**Source B** (OpenRouter - higher precedence):
```elixir
%Model{
  provider: :openai,
  id: "gpt-4",
  aliases: ["gpt-4-2023", "gpt4"],
  tags: ["fast"]
}
```

### Expected Result (Union)

```elixir
%Model{
  provider: :openai,
  id: "gpt-4",
  aliases: ["gpt-4-0314", "gpt-4-2023", "gpt4"],  # ✅ Union from both sources
  tags: ["general", "production", "fast"]          # ✅ Union from both sources
}
```

### Actual Result (Bug - Replace)

```elixir
%Model{
  provider: :openai,
  id: "gpt-4",
  aliases: ["gpt-4-2023", "gpt4"],  # ❌ Source A's aliases lost!
  tags: ["fast"]                     # ❌ Source A's tags lost!
}
```

**Impact**: Valuable alias and tag data from lower-precedence sources is silently discarded.

---

## 4. Proposed Fix

### Which Fields Should Be Unioned vs Replaced?

| Field | Type | Behavior | Rationale |
|-------|------|----------|-----------|
| `:aliases` | `[string]` | **Union** | Accumulated identity references across ecosystems; discarding earlier ones is lossy |
| `:tags` | `[string]` | **Union** | Categorical annotations where combining makes sense |
| `:modalities.input` | `[atom]` | **Union** | Supported input modalities; combining preserves truth when sources are incomplete |
| `:modalities.output` | `[atom]` | **Union** | Supported output modalities; combining preserves truth when sources are incomplete |
| All other lists | varies | **Replace** | Safe default for unknown semantics; preserves last-wins precedence |

### Implementation

Add a module attribute defining union keys and modify the resolver:

```elixir
# lib/llm_db/engine.ex

# Add near the top of the module or with other module attributes
@list_union_keys MapSet.new([:aliases, :tags, :input, :output])

# Replace the existing model_merge_resolver/3 implementation:

# CHANGED: Key-aware union for specific list fields
defp model_merge_resolver(key, left_val, right_val)
     when is_list(left_val) and is_list(right_val) do
  if MapSet.member?(@list_union_keys, key) do
    union_unique(left_val, right_val)
  else
    # Default: last-wins replace for unknown list semantics
    right_val
  end
end

defp model_merge_resolver(_key, left_val, right_val)
     when is_map(left_val) and is_map(right_val) do
  DeepMerge.continue_deep_merge()
end

defp model_merge_resolver(_key, _left_val, right_val) do
  right_val
end

# Add helper for stable union
defp union_unique(left, right) do
  (left ++ right) |> Enum.uniq()
end
```

### Update Comment

Update the comment at lines ~310–312 to reflect the actual behavior:

```elixir
# List fields are merged by unioning when it makes sense:
# Union for known list fields (:aliases, :tags, modalities :input/:output), replace for others
```

---

## 5. Verification Strategy

### Test Case

Add to [test/llm_db/engine_test.exs](file:///Users/mhostetler/Source/ReqLLM/sync_db/llm_db/test/llm_db/engine_test.exs):

```elixir
describe "merge_models_with_list_rules/2" do
  test "unions accumulative list fields across sources" do
    base_models = [
      %{
        provider: :openai,
        id: "gpt-4",
        aliases: ["gpt-4-0314"],
        tags: ["general", "production"],
        modalities: %{input: [:text], output: [:text]}
      }
    ]
    
    override_models = [
      %{
        provider: :openai,
        id: "gpt-4",
        aliases: ["gpt-4-2023", "gpt4"],
        tags: ["fast"],
        modalities: %{input: [:image], output: [:json]}
      }
    ]
    
    result = Engine.merge_models_with_list_rules(base_models, override_models)
    model = Enum.find(result, fn m -> m.id == "gpt-4" end)
    
    # Should union aliases and tags
    assert model.aliases == ["gpt-4-0314", "gpt-4-2023", "gpt4"]
    assert model.tags == ["general", "production", "fast"]
    
    # Should union nested modalities
    assert model.modalities.input == [:text, :image]
    assert model.modalities.output == [:text, :json]
  end
  
  test "replaces non-accumulative lists with last-wins" do
    base_models = [
      %{
        provider: :openai,
        id: "gpt-4",
        extra: %{custom_list: ["a", "b"]}
      }
    ]
    
    override_models = [
      %{
        provider: :openai,
        id: "gpt-4",
        extra: %{custom_list: ["c"]}
      }
    ]
    
    result = Engine.merge_models_with_list_rules(base_models, override_models)
    model = Enum.find(result, fn m -> m.id == "gpt-4" end)
    
    # Unknown list fields should replace
    assert model.extra.custom_list == ["c"]
  end
end
```

### Manual Verification

After fix:

```bash
# Rebuild snapshot with multi-source data
mix llm_db.build

# Inspect merged model in IEx
iex -S mix
{:ok, model} = LLMDb.model("openai:gpt-4")
model.aliases  # Should show union from all sources
```

---

## 6. Rationale & Trade-offs

### Why Union These Fields?

- **`:aliases`**: Identity references accumulate across ecosystems. Different sources may know the model by different aliases. Discarding earlier ones breaks lookups.
- **`:tags`**: Categorical annotations are additive. One source tagging "production" and another "fast" should preserve both.
- **`:modalities.input`/`output`**: Represent supported capabilities. If one source knows about text input and another about image input, both are true.

### Why Not Union All Lists?

Some lists semantically represent replacements (e.g., arbitrary arrays under `:extra`, or future list fields with unknown semantics). A safe default is last-wins replace for unknowns.

### Union Order

`left ++ right |> Enum.uniq()` preserves stable left-first order while removing duplicates. Using `MapSet` would be faster but loses order; lists are small (typically <10 items) so `Enum.uniq/1` is fine.

### Edge Cases Handled

- **nil lists**: Deep-merge behavior already handles absent fields gracefully
- **Empty lists**: Union of `[] ++ ["a"]` produces `["a"]` correctly
- **Duplicates**: `Enum.uniq/1` removes them while preserving first occurrence

---

## 7. Risks & Guardrails

### Risk: Mixed Types

If a later source changes a union field to a non-list (bad data), the last-wins scalar clause still applies. Schema validation should prevent this upstream.

### Risk: Cannot Clear Unioned Lists

A higher-precedence source can no longer "remove" prior entries by setting `[]`; union keeps prior values.

**Mitigation**: If explicit clearing is needed, consider:
- Special sentinel value (e.g., `{:replace, []}`)
- Per-field merge mode metadata

This is unlikely to be needed for aliases/tags.

### Risk: Case Sensitivity

Aliases/tags compared as-is; duplicates with different cases won't collapse (e.g., `"GPT-4"` vs `"gpt-4"`).

**Mitigation**: Normalize upstream in source modules if needed.

---

## 8. Advanced Considerations (Future)

### When to Consider Advanced Path

- Need per-field/per-source merge policies (e.g., allow clearing or intersection)
- Performance constraints with very large lists (unlikely for aliases/tags)
- Require path-aware semantics beyond just the key

### Possible Advanced Approach

Introduce merge policy metadata:

```elixir
@merge_policies %{
  aliases: :union,
  tags: :union,
  modalities: %{input: :union, output: :union}
}
```

Support sentinel values for forced replacement:

```elixir
%{aliases: {:replace, []}}  # Explicitly clear aliases
```

Use path-aware resolver with full key path for precise control.

**Recommendation**: Not needed now. Implement if requirements emerge.

---

## 9. Implementation Checklist

- [ ] Add `@list_union_keys` module attribute to [lib/llm_db/engine.ex](file:///Users/mhostetler/Source/ReqLLM/sync_db/llm_db/lib/llm_db/engine.ex)
- [ ] Modify `model_merge_resolver/3` to implement key-aware union
- [ ] Add `union_unique/2` helper function
- [ ] Update comment at lines ~310–312 to match implementation
- [ ] Add test cases for union behavior
- [ ] Add test cases for non-union (replace) behavior
- [ ] Run `mix test` to verify no regressions
- [ ] Rebuild snapshot with `mix llm_db.build`
- [ ] Manually verify union behavior in IEx
- [ ] Update [CHANGELOG.md](file:///Users/mhostetler/Source/ReqLLM/sync_db/llm_db/CHANGELOG.md) with bugfix entry

---

## 10. Summary

**Current Behavior**: Lists always replaced (last-wins)  
**Expected Behavior**: Accumulative lists unioned, others replaced  
**Root Cause**: Missing key-aware logic in `model_merge_resolver/3`  
**Fix Complexity**: Simple (one function change + one helper)  
**Risk**: Low (isolated change, preserves existing behavior for non-union fields)  
**Value**: High (prevents data loss from multi-source merges)

---

**Investigation Date**: Fri Nov 07 2025  
**Investigated By**: Oracle (GPT-5 Reasoning Model)
