# Writing an Extractor

An **Extractor** is a separate, independently-maintained KOReader plugin that
reads a third-party plugin's on-disk format and pushes it through
AnnotationSync so it merges safely across a user's devices. AnnotationSync
never parses your format and never writes into your plugin's own files — you
call in, hand over neutral keyed records, and get the merged result back.

See ADR [`0007-extractor-push-model.md`](adr/0007-extractor-push-model.md)
for the design rationale, and `CONTEXT.md`'s "Extractors" section for the
Extractor / Extractor Record / Keyed Merge vocabulary used below.

## 1. Detect AnnotationSync and listen for sync episodes

```lua
local PluginShare = require("pluginshare")

function MyExtractor:onAnnotationSyncRequested()
    if not PluginShare.AnnotationSync then
        return -- AnnotationSync isn't installed/enabled; nothing to do.
    end
    self:pushMyData()
end
```

`AnnotationSyncRequested` is a payload-free event broadcast once per
annotation-sync episode (manual sync or a background network-reconnect
sync), regardless of whether any documents actually had changes. You are not
required to listen for it — you can call `pushExtractorData` from any other
trigger of your own — but it's the natural hook for "sync alongside
AnnotationSync."

## 2. Push your data

```lua
PluginShare.AnnotationSync.pushExtractorData(
    "vocabdeck",        -- extractor_id: namespaces your storage/merge keys
    "spanish",           -- filename: e.g. one call per per-language DB
    records,              -- array of Extractor Records (each carries its own merge_key)
    function(merged_records)
        -- Write merged_records back into your own on-disk format.
    end
)
```

- `extractor_id` and `filename` together namespace your data
  (`<extractor_id>/<filename>`), so two Extractors — or one Extractor's
  multiple files — never collide.
- `writeback_fn` is always called, whether or not anything changed. Writing
  the merged result back into your plugin's own file format is entirely
  your responsibility; AnnotationSync only invokes the callback.
- A thrown error anywhere in your extraction, merge, or writeback code is
  caught and logged by AnnotationSync — it never aborts or corrupts
  AnnotationSync's own annotation/progress/settings sync running in the
  same episode. Still, don't rely on this for control flow: treat it as a
  safety net, not a substitute for validating your own data.

## 3. Shape your records: Merge Key + per-field policy

```lua
records = {
    {
        merge_key = "normalized-phrase-key",
        fields = {
            phrase   = { value = "hola",   policy = "write_once",      changed_at = os.time() },
            sentence = { value = "¡Hola!", policy = "write_once",      changed_at = os.time() },
            due      = { value = 3,        policy = "last_write_wins", changed_at = os.time() },
        },
    },
}
```

- The **Merge Key** (`merge_key`) must be a stable, content-derived
  identifier — not a local autoincrement row id, which isn't safe across
  devices with independent databases. Derive it from something intrinsic to
  the record (e.g. a normalized phrase).
- Each field declares its own policy:
  - `write_once` — first value wins; never overwritten once set. Use for
    fields that shouldn't drift once created (e.g. the phrase text itself).
  - `last_write_wins` — the field with the newer `changed_at` (a numeric
    epoch) wins. Use for fields two devices might legitimately update
    independently (e.g. spaced-repetition scheduling state).
- Fields your plugin doesn't recognize on a merged record (e.g. from a
  newer version of your own Extractor) pass through untouched — schema
  drift is never an error.

## Reference implementations

Two real Extractors are built against this API:

- [`vocabdeckextractor.koplugin`](https://github.com/jdbway/vocabdeckextractor.koplugin) —
  per-language vocabulary records, mixing `write_once` fields (`phrase`,
  `sentence`) with `last_write_wins` fields (`due`, `fsrs_state`).
- [`assistantextractor.koplugin`](https://github.com/jdbway/assistantextractor.koplugin) —
  append-mostly notebook entries where every field is `write_once`.
