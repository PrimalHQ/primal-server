# Instructions for Checking and Fixing Differences Between Julia and Rust Processing Node Executions

## Overview
This guide helps identify and fix discrepancies between Julia processing node implementations and their Rust equivalents in the primal-media module.

## Step 1: Capture Expected Results from Julia

1. Find the processing node you want to test in the Julia codebase:
   ```bash
   grep -r "function <function_name>" ../src/*.jl
   ```

2. Execute the node and capture the database results:
   ```bash
   # Run the node execution in Julia (if available)
   # Then capture the database state
   psql "host=127.0.0.1 port=54017 dbname=primal1 user=pr" -c \
     "select * from processing_nodes pn1, processing_edges pe, processing_nodes pn2
      where pn1.id = '\x<NODE_ID_HEX>'
      and pn1.id = pe.id1
      and pe.id2 = pn2.id;" > expected_results.txt
   ```

3. Save this output as your baseline for comparison.

## Step 2: Execute Rust Implementation

1. Build and run the Rust implementation:
   ```bash
   RUST_BACKTRACE=full cargo run --bin primal-media -- \
     --config primal-media.config.json \
     execute-node --id <NODE_ID_HEX>
   ```

2. Capture any output or errors shown during execution.

3. Query the database to get the actual results:
   ```bash
   psql "host=127.0.0.1 port=54017 dbname=primal1 user=pr" -c \
     "select * from processing_nodes pn1, processing_edges pe, processing_nodes pn2
      where pn1.id = '\x<NODE_ID_HEX>'
      and pn1.id = pe.id1
      and pe.id2 = pn2.id;" > actual_results.txt
   ```

## Step 3: Compare Results

Compare the following key fields in the processing_nodes table:

### A. Result Field
**Expected format** (from Julia @procnode macro):
```json
{
  "_ty": "NamedTuple",
  "_v": {
    "ok": true,
    "r": <actual_return_value>,
    "id": {"_ty": "NodeId", "_v": "<node_id_hex>"}
  }
}
```

**Common issues:**
- Returning `null` instead of the proper NamedTuple structure
- Missing the `ok`, `r`, or `id` fields
- Incorrect `_ty` type annotations

**Fix location:** The return statement at the end of your handler function

### B. Extra Field (Log Entries)
The `extra` field contains a `log` array with operation records.

**Expected format:**
```json
{
  "log": [
    {
      "op": "insert",
      "table": "<table_name>",
      "<field1>": <value1>,
      "<field2>": <value2>,
      ...
    },
    ...
  ]
}
```

**Common issues:**
- Using different field names (e.g., `download_duration` vs `dldur`)
- Missing fields that were included in Julia version
- Incorrect type formatting (e.g., plain strings instead of typed objects like EventId)
- Not including all metadata fields that Julia spreads with `r...`

**Fix location:** Calls to `processing_graph::extralog()`

## Step 4: Understand Julia @procnode Macro Behavior

Read the Julia implementation to understand key behaviors:

1. **Return value wrapping** (processing_graph.jl:263):
   ```julia
   (; ok=true, r=_result, id=_id)
   ```
   All @procnode functions return this structure automatically.

2. **Extra logging** (processing_graph.jl:236-242):
   ```julia
   function extralog(v)
       if !haskey(_extra, :log)
           _extra[:log] = []
       end
       push!(_extra[:log], v)
       _update_extra()
       v
   end
   ```
   Each extralog call appends to the log array.

3. **Field spreading** in Julia:
   ```julia
   extralog((; op="insert", table="preview", url, dldur, r...))
   ```
   The `r...` spreads all fields from the `r` variable into the tuple.

## Step 5: Common Fixes in Rust

### Fix 1: Correct Return Value
**Before:**
```rust
Ok(Value::Null)
```

**After:**
```rust
Ok(json!({
    "_ty": "NamedTuple",
    "_v": {
        "ok": true,
        "r": [],  // or the actual return value
        "id": {"_ty": "NodeId", "_v": hex::encode(nid.0)}
    }
}))
```

### Fix 2: Correct Extralog Field Names
**Before:**
```rust
processing_graph::extralog(state, nid, json!({
    "op": "insert",
    "table": "preview",
    "url": url,
    "download_duration": dldur,  // Wrong field name
    ...
})).await;
```

**After:**
```rust
processing_graph::extralog(state, nid, json!({
    "op": "insert",
    "table": "preview",
    "url": url,
    "dldur": dldur,  // Correct field name matching Julia
    "image": md.image,
    "title": md.title,
    "icon_url": md.icon_url,
    "mimetype": md.mimetype,
    "description": md.description
})).await;
```

### Fix 3: Correct Type Annotations for Nested Objects
**Before:**
```rust
json!({
    "op": "insert",
    "table": "event_preview",
    "event_id": eid_hex,  // Plain string
    "url": url
})
```

**After:**
```rust
json!({
    "op": "insert",
    "table": "event_preview",
    "eid": {"_ty": "EventId", "_v": eid_hex},  // Typed object
    "url": url
})
```

## Step 6: Verify the Fix

1. Rebuild and run the Rust implementation again:
   ```bash
   RUST_BACKTRACE=full cargo run --bin primal-media -- \
     --config primal-media.config.json \
     execute-node --id <NODE_ID_HEX>
   ```

2. Query the database again and compare with expected results.

3. Check that:
   - The `result` field structure matches
   - All `extra.log` entries have the correct fields
   - Field names match exactly between Julia and Rust
   - Type annotations (_ty, _v) are consistent

## Step 7: Field-by-Field Comparison Checklist

Use this checklist when comparing results:

- [ ] `result._ty` = "NamedTuple"
- [ ] `result._v.ok` = true (or false if error)
- [ ] `result._v.r` = expected return value
- [ ] `result._v.id._ty` = "NodeId"
- [ ] `result._v.id._v` = correct node ID hex
- [ ] `extra.log` is an array
- [ ] Each log entry has correct field names
- [ ] Field values match (accounting for timing differences)
- [ ] Type annotations on nested objects match Julia serialization
- [ ] All metadata fields from Julia are included in Rust

## Common Julia Patterns to Match in Rust

| Julia Pattern | Rust Equivalent |
|--------------|-----------------|
| `(; ok=true, r=[], id=_id)` | `{"_ty":"NamedTuple","_v":{"ok":true,"r":[],"id":...}}` |
| `Nostr.EventId("...")` | `{"_ty":"EventId","_v":"..."}` |
| `NodeId(...)` | `{"_ty":"NodeId","_v":"..."}` |
| `r...` (field spread) | Manually list all fields: `"field1":val1,"field2":val2,...` |
| `:symbol` | `{"_ty":"Symbol","_v":"symbol"}` |
| `nothing` | `null` |

## Debugging Tips

1. **Enable verbose logging** to see what's happening:
   ```rust
   tracing::info!("About to call extralog with: {:?}", log_data);
   ```

2. **Compare JSON structures** using jq:
   ```bash
   # Extract just the result field
   echo '<query_output>' | jq '.result'
   ```

3. **Check the Julia source** for the exact field names:
   ```bash
   grep -A 20 "@procnode function <func_name>" ../src/*.jl
   ```

4. **Look for field spreading** (`r...`) in Julia - these need to be manually expanded in Rust.

5. **Check return statements** - Julia functions return the last expression, which might not be obvious.

## Example: Fixing import_preview_pn

See the changes in commit history for a complete example of fixing `import_preview_pn`:
- Changed `download_duration` → `dldur` in extralog
- Added all metadata fields (image, title, description, icon_url, mimetype) to match Julia's `r...` spread
- Fixed return value from `Value::Null` to proper NamedTuple structure
- Fixed EventId serialization in event_preview log entry

## Files to Check

When fixing processing node differences, check these files:

1. **Julia implementation:**
   - `../src/cache_storage_media.jl` - Media processing nodes
   - `../src/processing_graph.jl` - @procnode macro definition
   - `../src/media.jl` - Media utility functions

2. **Rust implementation:**
   - `src/cache_storage_media.rs` - Rust handlers
   - `src/processing_graph.rs` - Node execution logic
   - `src/media.rs` - Media utility functions

3. **Database schemas:**
   - Check PostgreSQL table definitions to understand field types

## Testing Workflow

1. Find a node ID that was executed by Julia (from production or test data)
2. Capture the Julia execution results from the database
3. Re-execute the node using Rust implementation
4. Compare results field-by-field
5. Fix discrepancies in Rust code
6. Iterate until results match

## Notes

- The `updated_at` and `started_at` timestamps will differ - this is expected
- The `finished_at` timestamp will differ - this is expected
- Duration fields (like `dldur`) may vary slightly - this is acceptable
- Empty vs populated metadata fields may differ due to external data sources
- Focus on structure and field names, not dynamic content values
