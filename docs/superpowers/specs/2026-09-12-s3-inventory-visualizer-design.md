# S3 Inventory Visualizer — design

Date: 2026-09-12. Status: approved design, ready for an implementation plan.

## 1. Goal

A native macOS app that loads an AWS S3 Inventory export (the CSV format AWS delivers) and
renders a WinDirStat / Disk Inventory X style cushion treemap of the whole bucket. The user
hovers to see individual objects, sees "folders" (key prefixes split on `/`) as nested
rectangles, zooms into any prefix, and reads totals per storage class, extension and age.

Two non-negotiables from the request:

1. **Responsiveness.** Hover, selection, color-mode switches and zooms must feel instant on a
   2019 Intel MacBook Pro. Idle CPU and GPU must be near zero.
2. **Scale.** The reference input is the `production-bucket` inventory: 574 gzipped CSVs,
   82.3 GB compressed, about 313 GB uncompressed, 1,119,935,804 rows, 790 TiB of objects.
   Any bucket at or below that scale must work. Smaller buckets are the easy case.

Everything else (a pretty UI, search, breakdowns) serves those two.

## 2. Facts that shape the design (measured 2026-09-12)

Machine: MacBookPro16,1, Intel i9 8 cores / 16 threads, 64 GB RAM, AMD Radeon Pro 5500M,
macOS 15.7, Xcode 26.3, Swift 6.2.4, 142 GB free on the startup disk. `import zlib`,
`import Compression` and `import Metal` all work from plain `swiftc`. `xcodegen` is installed.
Rust is not installed. gzip decompression runs at about 800 MB/s of output per core.

Reference inventory (`inventories/production-bucket`, full DuckDB pass over all rows):

| Fact | Value |
|---|---|
| Rows | 1,119,935,804 (29,542 non-current versions, 5,378 delete markers) |
| Bytes | 869,012,548,707,428 (790.4 TiB) |
| Distinct directory nodes (all prefixes) | 26,641,357 |
| Leaf directories (contain at least one file) | 20,114,359 |
| Max depth (segments in a directory path) | 9 |
| Max subdirectories in one directory | 39,744 |
| Files per leaf directory | p50 3, p90 9, p99 497, p99.9 5,766, max 5,150,670 (`albums`) |
| Sum of file basenames | 61,630,664,101 bytes (average 55 bytes, max key 1024 bytes) |
| Keys containing `%` (URL-encoded) | 1,129,651 |
| Keys ending in `/` (folder markers) | 13 |
| Keys containing `//` | 0 |

Key ordering: every inventory file is sorted by key, and files cover disjoint key ranges. The
manifest does NOT list files in key order. Sorting the files by their first key gives a globally
sorted stream.

**The sort is on the DECODED key, not the percent-encoded one** (found during the acceptance
import, 2026-09-12, and confirmed by scanning a whole 1,000,000-row inventory file: 0 violations
of decoded order, 2 violations of encoded order). Example from `production-bucket`:
`schedules/email/schedules-email-footer-2021.png` is written immediately before
`schedules/email/schedules-email-footer-2021%402x.png`. Decoded, `.` (0x2E) precedes `@` (0x40),
so the order is correct. Encoded, `%` is 0x25 and would sort first, so an encoded-byte comparison
rejects the real file as unsorted. The importer therefore decodes each key BEFORE the ordering
check, and `FileOrdering` sorts files by their decoded first key.

Name compressibility (zstd level 3, blocks of 4096 names): 11.7 bytes per name in key order,
13.6 in size order, 33.5 shuffled. Names in key order share long prefixes (the same UUID with
`_still`, `_thumb`, `_still_overlay` suffixes), so key order is the order to store them in.

Extrapolated index footprint for this bucket: about 40 GB on disk (section 5).

## 3. Approaches considered

**A. Everything in RAM, WinDirStat style.** One node per object. 1.12 billion nodes at 40+
bytes each plus names is 60 to 120 GB. Does not fit, and a 10-minute load before the first
frame on every open. Rejected.

**B. Query engine (DuckDB / SQLite) behind the UI.** The UI runs aggregate queries per zoom
level. Correct and flexible, but every hover, zoom or legend refresh becomes a query with tens
of milliseconds of latency at best, and the treemap needs per-file granularity in every visible
directory. Rejected for the interactive path. (DuckDB stays a fine offline tool.)

**C. One-time import into a memory-mapped columnar index, plus a pixel-budgeted renderer.
Chosen.** The import streams the sorted inventory once and writes struct-of-arrays column
files. The viewer memory-maps them and touches only the pages it needs. The treemap never
visits more items than the screen can show: children are consumed largest-first and everything
below a few square pixels collapses into one "remainder" cell. This is how a billion objects
render in tens of milliseconds.

## 4. Architecture overview

```
 inventory folder ──▶ Import (once) ──▶ .s3-inventory-index/ (column files, mmap)
                                              │
                    ┌─────────────────────────┼─────────────────────────┐
                    ▼                         ▼                         ▼
             IndexReader              TreemapLayout              Search / Aggregates
        (mmap, directory tree,   (squarify + cushion coeffs,   (prefix binary search,
         name block cache,        pixel budget, hit-test         parallel scans with
         own-files cache)         tree; background thread)       progress and cancel)
                    │                         │                         │
                    └────────────── AppKit UI + Metal treemap view ─────┘
```

Two build products, one Swift Package Manager package plus one generated Xcode project:

- `Package.swift` (Swift 5 language mode to keep unsafe-pointer code free of Swift 6
  strict-concurrency friction) with library targets `InventoryIndex`, `InventoryImport`,
  `TreemapLayout`, one executable `s3-inventory-tool` (CLI), and their test targets.
  `swift test` runs without Xcode.
- `App/project.yml` for xcodegen, producing `S3 Inventory Visualizer.app` (AppKit, Metal
  shaders compiled by Xcode into `default.metallib`). The app depends on the local package.
  The `.xcodeproj` is generated and not committed.

Identifiers are spelled in full everywhere (no abbreviations), per the repo owner's convention.

## 5. Index format (`.s3-inventory-index/`, version 1)

Written beside the inventory folder. One folder per inventory. Struct-of-arrays: one file per
column so each is a plain typed array under `mmap`. Every column file starts with a 64-byte
header: magic `S3VZ`, format version, element size, element count, then the data 64-byte
aligned. All integers little-endian.

### 5.1 `index.json` (written last; its absence means a partial index to delete)

- `formatVersion`, `createdAt`, `importDurationSeconds`, `appVersion`.
- Source identity: `sourceBucket`, `manifestCreationTimestamp`, `manifestFileCount`,
  `manifestTotalBytes`, `manifestMD5`. The app rebuilds when these differ from the manifest.
- Counts: `directoryCount`, `fileCount`, `totalBytes`, `skippedNonCurrent`,
  `skippedDeleteMarkers`, `rowParseErrors`, `missingDataFiles` (list; non-empty means the index
  is marked partial and the UI shows a warning badge).
- Dictionaries: `storageClasses` (id → name, at most 8 ids; the 8th is `OTHER`),
  `extensions` (id → lowercase string, id 0 is "no extension", at most 65,535 then `other`),
  `extensionPalette` (the 15 extensions with most bytes, in order, for the extension color mode).
- Schema actually used: which inventory columns were present.

### 5.2 Directory columns (26.6 M rows for the reference bucket, about 3.7 GB)

Directories are numbered in depth-first pre-order of key order. Consequences used everywhere:

- The subtree of directory `D` is the id range `[D, D + subtreeDirectoryCount[D])`. Membership
  is one comparison. The Metal shader uses it for "highlight selected subtree".
- The first child of `D` is `D + 1` when `childCount[D] > 0`; the next sibling of child `C`
  is `C + subtreeDirectoryCount[C] + 1`. No child pointer arrays are needed for key-order
  iteration.
- Files are stored in key order, so the files of `D`'s subtree are the contiguous range
  `[fileStart[D], fileStart[D] + subtreeFileCount[D])`. `D`'s own files are the gaps between
  its children's ranges (plus before the first child and after the last).

| Column | Type | Meaning |
|---|---|---|
| `directory.parent` | u32 | parent id; root is 0 with parent `UInt32.max` |
| `directory.depth` | u8 | 0 for root |
| `directory.subtreeDirectoryCount` | u32 | count of descendants, self excluded |
| `directory.childCount` | u32 | direct subdirectory count |
| `directory.fileStart` | u64 | first file index of the subtree (monotonic in id) |
| `directory.subtreeFileCount` | u64 | files in subtree |
| `directory.subtreeBytes` | u64 | bytes in subtree |
| `directory.ownFileCount` | u32 | files directly in this directory |
| `directory.ownBytes` | u64 | bytes of own files |
| `directory.nameOffset`, `directory.nameLength` | u64, u16 | segment name in `directory.names` (raw UTF-8 bytes, decoded key segment) |
| `directory.bytesByStorageClass` | 8 × u64 | subtree bytes per storage class id |
| `directory.dominantExtension` | u16 | extension id with most subtree bytes |
| `directory.ageWeightedBytes` | u64 | Σ size × ageDays (age in whole days relative to the inventory timestamp; 790 TiB × 4000 days ≈ 3.5 × 10¹⁸ stays under the u64 limit); average age = this / subtreeBytes |
| `directory.childListStart` | u32 | offset into `directory.childrenBySize` |
| `directory.childrenBySize` | u32 × (directoryCount − 1) | child ids sorted by subtreeBytes descending (computed in a post-pass) |
| `directory.childrenBySizeBytes` | u64 × (directoryCount − 1) | the subtree bytes of each entry above, in the same order (format version 2) |

Format version 2 added the last column. The treemap's inner loop compares a child's bytes against the
pixel threshold; reading that through the child's id is a random access into a 26.6 M-entry column,
and it was the single largest cost in a layout. Storing the bytes beside the ids makes the loop
sequential. An index written by version 1 is rejected at open, not misread.

### 5.3 File columns (1.12 B rows for the reference bucket, about 33 GB)

Files are in key order, index 0 upward. No per-file directory id is stored: the directory of
file `i` is found by a binary search on `directory.fileStart` (last id with `fileStart ≤ i`)
followed by at most 9 steps up the parent chain until the subtree range contains `i`.

| Column | Type | Notes |
|---|---|---|
| `file.size` | u64 | bytes |
| `file.lastModified` | u32 | seconds since 1970 (inventory has 1 s precision); 0 when the column is absent |
| `file.storageClass` | u8 | dictionary id |
| `file.extension` | u16 | dictionary id, lowercase text after the last `.` of the basename, 1 to 8 chars, else 0 |
| `file.names.blocks` | u64 offset + u32 compressed length + u32 raw length per block | 4096 names per block |
| `file.names.data` | bytes | LZFSE (Apple `Compression` framework) blocks; raw block = 4096 × (u16 length + UTF-8 bytes) |

Not stored: bucket, version id, ETag, multipart flag, replication status, intelligent-tiering
tier. Non-current versions and delete markers are skipped at import and counted.

A key ending in `/` becomes a file with an empty name in its directory (shown as
"(folder marker)"). An empty segment between two slashes becomes a directory with an empty
name (shown as "(empty segment)"). Non-UTF-8 bytes are kept as bytes and displayed lossily.

## 6. Import pipeline

Input: a folder that contains `manifest.json` and `data/*.csv.gz`, or a bare folder of
`.csv.gz` files (then the default 12-column schema is assumed). The manifest's `fileSchema`
maps column names to positions; `Key` and `Size` are required, the rest optional. Data files
are matched by the basename of each manifest `key`; the manifest `size` must equal the local
file size or the file is reported missing.

Steps:

1. **Order the files.** Decompress only the first row of each file and sort the files by that
   key (byte order of the encoded key). 574 small reads.
2. **Producers (one per core).** Each takes the next file in order, streams it through zlib
   (`inflateInit2` with `15 + 16` for gzip), splits rows, parses the quoted fields, flags keys
   that contain `%` (the consumer decodes `%XX`; `+` is literal; measured: spaces are `%20` and
   no literal `+` occurs), parses size and ISO-8601 date with a fixed-format fast
   path, maps the storage class, and emits chunks of 256 K rows as struct-of-arrays buffers.
   Chunks are handed to the consumer strictly in file order through a bounded queue (about
   4 M rows in flight, roughly 600 MB).
3. **Consumer (one thread) — the tree builder.** Keeps a stack of open directories (depth ≤ 10).
   For each key: split into the directory part and basename; find the longest common prefix of
   segments with the stack; pop and close the directories beyond it; push the new segments,
   assigning the next directory id on push (pre-order). Append the file to the sequential
   column writers and its name to the current 4096-name block. Update the open directories'
   running aggregates (bytes, files, bytes per storage class, age-weighted bytes, and a small
   map extension id → bytes that is merged into the parent on close and reduced to
   `dominantExtension`). The segment name is appended to `directory.names` on push, so
   `nameOffset` is known immediately. On close, write the directory's record into the writable
   memory-mapped directory columns at its id. The directory count is unknown until the end, so
   each directory column file is created as an APFS sparse file sized for 256 M directories,
   mapped `MAP_SHARED`, and truncated to the real count when the pass ends.
   Ordering assertions: each encoded key must be greater than the previous one, and a pushed
   child name must differ from the last closed child of the same parent. A violation aborts
   with "inventory is not key-sorted" (an unsorted export would need a k-way merge, which is
   out of scope and documented as a possible follow-up).
4. **Name blocks** are LZFSE-compressed on a small worker pool and appended in order.
5. **Post-pass** over the finished directory columns: `childListStart` prefix sums and
   `childrenBySize` (26.6 M small sorts, parallel), extension palette selection, and
   `index.json`.

Memory: the consumer holds only open directories plus writer buffers; the directory columns are
written through `mmap` so the kernel pages them. Target ≤ 8 GB resident during import.

Performance target on this Mac for the reference bucket: ≤ 15 minutes end to end (stretch
8 minutes). Budget: decompression 313 GB at 0.8 GB/s per core over 8 cores ≈ 50 s; parsing
≈ 1 minute; the single-threaded tree builder at ≈ 150 ns per row ≈ 3 minutes; LZFSE of 62 GB
of names on 6 cores ≈ 1 minute; 40 GB of sequential writes ≈ 1 minute; all overlapped.

Progress reporting: files done, rows per second, elapsed, ETA, current phase; cancel deletes
the partial index folder.

Failure handling: missing data files listed (user may continue with a partial index, flagged);
corrupt gzip aborts naming the file; more than 1000 row parse errors aborts; disk full aborts
and deletes the partial folder.

## 7. Viewer data access (`IndexReader`)

- Memory-maps every column read-only. Open cost is a few milliseconds plus reading
  `index.json`.
- `DirectoryTree` API: `parent`, `children(of:)` (key order via the id arithmetic), and
  `childrenBySize(of:)`, plus the stats above. Full path of a directory = walk parents and join
  segment names.
- `NameBlockCache`: LRU of decoded blocks (64 blocks, about 20 MB). Name of file `i` = decode
  block `i / 4096`, walk the length prefixes to entry `i % 4096`. Full key = directory path +
  `/` + name.
- `OwnFilesCache`: for directory `D`, the top-K own files by size, where
  `K = ceil(availableAreaPixels / minimumCellArea) + 1` is an upper bound on how many own files
  can be drawn. Built by scanning `file.size` over the own-file gaps with a bounded heap;
  cached per directory (LRU, 256 entries); recomputed with a larger K when a layout asks for
  more. Worst case (`albums`, 5.15 M own files) is a 41 MB scan, tens of milliseconds
  warm.
- On-demand aggregates for the details panel and legend: bytes per extension and per age
  bucket for a subtree, computed by a parallel scan over the subtree's contiguous file range
  (`file.extension`, `file.lastModified`, `file.size`), cached per directory, with progress and
  cancellation for large subtrees. Bytes per storage class are precomputed and instant.

## 8. Treemap layout (`TreemapLayout`, pure Swift, unit-tested)

Input: root directory id, viewport size in device pixels (backing-store pixels, so 2× the
point size on Retina), minimum cell area in device pixels squared (default 4 px², user
adjustable 1 to 16), and the reader. Output: `LayoutResult`:

- An instance array (struct-of-arrays, one entry per drawn rectangle): `x, y, width, height`
  (Float, pixels), cushion coefficients `sxx, sx, syy, sy` (Float), `directoryId` (u32; for a
  file cell the containing directory), `nodeReference` (u32 file index or directory id),
  `timeSeconds` (u32; a file's mtime, or a directory's average age converted to a timestamp),
  `extensionId` (u16), `storageClassId` (u8), `kind` (u8: directoryLeaf, file, remainder).
  48 bytes per instance.
- A hit-test tree: one node per laid-out directory with its rect, the ids of its child nodes,
  and the contiguous instance range of its own file cells.
- Labels: directory name and rect for directory nodes whose rect is at least 64 × 16 px, capped
  at 400 entries.

Algorithm (recursive, squarified, largest-first):

1. For directory `D` with rect `R` (after a 1 px inset that leaves the background visible as
   the separator): items = `childrenBySize(D)` merged lazily with `ownFilesCache(D)`, both
   descending, weight = bytes.
2. Squarify (Bruls, Huizing, van Wijk) over the merged sequence. Before placing an item, if
   `item.bytes / D.subtreeBytes × area(R) < minimumCellArea`, stop consuming: all remaining bytes
   (`D.subtreeBytes − Σ placed`) become one `remainder` item placed last. Because both inputs
   are sorted descending, no later item could have been drawable. The remainder is drawn flat
   and dim, and hovering it reports "N more items, X bytes".
3. A child directory recurses when its rect is at least `max(16, minimumCellArea × 16)` px², that
   is 64 px² at the default detail. Below that the recursed picture is indistinguishable from one
   flat cell, and each extra node costs a scattered read across the whole directory index. A smaller
   one is emitted as one `directoryLeaf` cell colored by its dominant storage class, dominant
   extension, or average age. Measured on the production index: a 16 px² threshold doubled the node
   count and the layout time for no visible gain.
3b. **The view root always places at least 2048 items.** A directory whose files are all tiny
   relative to its own total (`albums`: 5.15 M files averaging 742 KiB) passes the pixel test
   for nothing and would draw as a single remainder cell, which tells the reader nothing. At the
   root only, the engine falls back to the largest 2048 own files. Applying the same guarantee at
   every nesting level multiplies it by the node count: measured, that produced 12.4 M instances and
   an 8 s layout for the whole bucket.
4. Cushion coefficients (van Wijk and van de Wetering, as in WinDirStat), with height `h = 0.75`
   scaled by `f = 0.75` per nesting level: for a rect `[x1, x2] × [y1, y2]` at height `h`,
   `sxx −= 4h / (x2 − x1)`, `sx += 4h (x1 + x2) / (x2 − x1)`, and the same for `y`. Children
   inherit the parent's accumulated coefficients. The fragment shader evaluates
   `normal = normalize(−(2 sxx x + sx), −(2 syy y + sy), 1)` per pixel and lights it with the
   direction `(−1, −1, 10)` normalized, ambient 0.25.
5. Bound: the number of instances is at most `viewportArea / minimumCellArea`, about 900 K at
   2560 × 1440 with 4 px² cells, typically 100 K to 300 K. Target: ≤ 100 ms for any root at
   that size, measured by the CLI `bench` command; run on a background queue; results are
   cached per (root, viewport size, minimum cell area). Color mode is not a layout input.

## 9. Rendering (`TreemapMetalView`, MTKView)

- One instanced draw of `LayoutResult.instances` (4 vertices per instance expanded in the vertex
  shader from `x, y, width, height`). Uniforms: viewport size, color mode, inventory
  timestamp, hovered instance index, selected directory id range `[start, end)`, highlighted
  category (legend click), and a 65,536-entry u8 lookup from extension id to palette slot.
- Color modes resolve in the fragment shader: storage class palette, extension palette
  (15 hues + grey for the rest), or an age ramp from `timeSeconds`. Switching modes changes a
  uniform only: zero relayout, one frame.
- Hover brightens the instance and draws a 1 px white outline; the selected subtree keeps full
  color while everything outside it is desaturated 40 %; a highlighted category dims the rest.
  The remainder kind renders flat with a subtle diagonal hatch.
- The view is paused (`isPaused = true`, `enableSetNeedsDisplay = true`): it redraws only on
  state change. A zoom transition scales the previous instance buffer from the clicked rect to
  the full view over 180 ms with a display link while the new layout computes, then crossfades.
- Labels are drawn by a transparent overlay `NSView` with Core Text once per layout (≤ 400
  labels), not per frame. The breadcrumb bar sits above the canvas, the legend strip below.
- Hit testing walks the hit-test tree from the root: find the child rect containing the point,
  then scan that node's own-file instance range. Under 1 ms for the largest flat directory.

Palette (dark canvas `#16181D`, chrome follows the system appearance):

| Storage class | Color |
|---|---|
| STANDARD | `#4C8DFF` blue |
| STANDARD_IA | `#2BB5A0` teal |
| INTELLIGENT_TIERING | `#5FC96B` green |
| ONEZONE_IA | `#39C2E0` cyan |
| GLACIER_IR | `#F2A93B` amber |
| GLACIER | `#F07A3C` orange |
| DEEP_ARCHIVE | `#8B6CF6` violet |
| REDUCED_REDUNDANCY / OTHER | `#8C919B` grey |

Extension mode uses 15 distinct categorical hues (colorblind-safe ordering) plus grey. Age mode
uses a sequential ramp from bright warm (new) to dark cool (old) over 8 buckets: <30 d, <90 d,
<180 d, <1 y, <2 y, <3 y, <5 y, older.

## 10. Application (AppKit)

`NSDocument`-based: the "document" is the inventory folder (read-only). This gives Open
Recent, multiple windows (one per inventory) and the standard open panel for free.

Window layout: `NSSplitViewController` with three panes.

- **Left — directory tree** (`NSOutlineView`, lazy). Rows are directories, children from
  `childrenBySize`; each directory also gets one "Files (N)" row that expands to its 100 largest
  own files and a "… N more" row. Columns: Name, Size, % of parent (bar), Items, Class mix
  (a stacked mini-bar from `bytesByStorageClass`). Selecting a row selects the subtree in the
  treemap; double-click zooms the treemap root to it. Clicking in the treemap expands the tree
  to the item.
- **Center — treemap** with the breadcrumb bar (clickable path chips, Back/Forward/Up), the
  canvas, the legend strip (swatch, name, bytes, percent; click to highlight, click again to
  clear), and a status line showing the full key under the cursor.
- **Right — details**. For a file: key (selectable, with Copy key, Copy `s3://` URI, Open in AWS
  console), size, storage class, last modified, extension. For a directory: subtree bytes,
  files, directories, bytes per storage class (bars, instant), top extensions and age histogram
  (on demand with a spinner and cancel).

Toolbar: navigation buttons, color-mode segmented control (Class / Extension / Age), units
toggle (binary GiB default, decimal GB), minimum cell area popup, search field.

Find (Cmd+F): "Starts with" splits the query at the last `/`, walks the directory tree by
exact segments to that directory, then scans its children and its own files for names with the
remaining prefix. Decoded keys are not in strict byte order (encoded `%7E` sorts before `-`,
decoded `~` after it), so a binary search over decoded keys is not valid; the walk-and-scan
needs no ordering and costs one directory's names at most (about 0.4 s for the 5.15 M-file
`albums`, instant elsewhere). "Contains" runs a parallel scan over all name blocks and
directory names with progress and cancel (about 10 to 20 s for the reference bucket), capped at
10,000 hits. Results open in a panel; choosing one selects the
item, reveals it in the tree, and zooms the treemap to its directory when it is not visible.

Import: opening a folder without a complete matching index shows a sheet with file count,
compressed bytes, an estimate, Start and Cancel, then progress. A "Rebuild Index…" menu item
(with confirmation) deletes and re-imports. Partial indexes show a warning badge.

Keyboard: Cmd+O open, Cmd+F find, Cmd+↑ up, Cmd+[ back, Cmd+] forward, Return zoom into the
selection, Esc clear the selection, Cmd+C copy key, Cmd+1/2/3 color modes, Cmd+R rebuild.

Preferences (UserDefaults): units, minimum cell area, default color mode, follow-system or
always-dark chrome.

## 11. CLI (`s3-inventory-tool`)

- `index <inventory folder> [--output <folder>] [--threads N] [--force]`: the import, with a
  text progress line. Same engine as the app; usable overnight or under `time`.
- `stats <index folder>`: totals, top directories by bytes and by files, storage class table.
- `bench <index folder> [--width 2560 --height 1440 --min-area 4] [--root <prefix>]`: layout
  timing and instance counts; the tool for the performance targets in section 8.
- `lookup <index folder> <key>`: prints the file's record (a test aid for the search code).
- `generate-fixture <folder> --rows N`: writes a synthetic inventory for local performance runs.

## 12. Testing

- `swift test` on the package. Fixtures are generated in tests: small synthetic inventories
  (`manifest.json` + gzipped CSVs) with the awkward cases: URL-encoded keys, trailing slash,
  empty segment, depth 9, 1024-byte key, sizes above 4 GiB, the `.`-before-`/` interleaving
  (`a/b/c.txt`, `a/b/c/x`, `a/b/d`), non-current versions and delete markers, missing optional
  columns, unsorted input (must abort), a missing data file.
- Tree builder tests assert pre-order ids, subtree ranges, own-file gaps and all aggregates
  against a brute-force reference built from the same fixture.
- Index round-trip tests: write, reopen, compare every column.
- Own-files cache tests: top-K equals a full sort's prefix.
- Layout tests: no overlaps, every cell inside its parent, areas proportional within 1 px²,
  remainder bytes exact, instance count under the bound, cushion coefficients match a hand
  computation for a two-level nest.
- Search tests: prefix results equal a linear filter; contains results likewise.
- A synthetic 10 M-row generator (`s3-inventory-tool generate-fixture`) for local performance
  runs without the 82 GB dataset. The real dataset is the acceptance run for section 6 and 8
  targets, recorded in `docs/benchmarks.md`.
- App: a manual checklist per phase (open, hover, zoom, color modes, tree sync, details, find,
  import sheet), with screenshots.

## 13. Out of scope for version 1

Parquet and ORC inventory formats; live S3 listing; multi-inventory diffing over time;
non-current version display; delete actions; a file list table for a directory (the tree's
"Files" row covers the largest ones); k-way merge of unsorted exports.
