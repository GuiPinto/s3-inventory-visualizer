# S3 Inventory Visualizer

A native macOS app that loads an AWS S3 Inventory CSV export and renders a WinDirStat style
cushion treemap of a whole bucket, at billion object scale.

The reference bucket is 1,119,900,884 objects and 790 TiB. It imports once in about 15 minutes and
then opens instantly, with hover, zoom, colour switching and search that stay responsive.

![The whole bucket by storage class](docs/screenshots/01-storage-class.png)

The teal is `STANDARD_IA`, the amber block is `GLACIER_IR`, and the violet speckles scattered through
`assets` are the objects already in `DEEP_ARCHIVE`.

| | |
|---|---|
| [Colour by folder](docs/screenshots/02-folder.png) | [by extension](docs/screenshots/03-extension.png) |
| [by age](docs/screenshots/04-age.png) | [a directory selected](docs/screenshots/05-directory-selected.png) |
| [zoomed into one prefix](docs/screenshots/06-zoomed-prefix.png) | [a file selected](docs/screenshots/07-file-selected.png) |
| [one storage class isolated](docs/screenshots/08-legend-highlight.png) | [find by prefix](docs/screenshots/09-find-starts-with.png) |
| [find scanning every name](docs/screenshots/10-find-contains-scanning.png) | [its results](docs/screenshots/11-find-contains-results.png) |
| [about](docs/screenshots/12-about.png) | [building an index](docs/screenshots/14-import-progress.png) |

## What it does

- **Treemap.** Flat tiles, sized by bytes, nested by key prefix, separated by a gutter that scales
  with the tile. Each fill is the same colour as its legend swatch. Hover reads the
  full key. Double click zooms into a prefix. The breadcrumb and Back, Forward and Up navigate.
- **Colour modes.** Storage class, file extension, last modified age, or folder. Switching is one
  frame, because the mode is a shader uniform and never triggers a new layout.
- **Colour by folder** gives each of the twenty largest folders directly under whatever you are
  viewing its own hue, largest first, and everything smaller a neutral grey. At the root that means
  `assets`, `shared`, `OrphanedUploads` and the rest each become one readable block. Zoom in
  and the accounts inside take over the palette. It is the mode that shows the bucket's shape; the
  others answer questions about it.
- **Selection.** The chosen cell gets a bright ring with a dark halo. A cell only a few pixels
  across also gets guide lines out to the canvas edges, so it can be found at a glance. When the
  selection covers enough of the canvas to read as a region, the rest is dimmed and desaturated
  instead.
- **Directory tree.** A lazy outline of every prefix, largest first, with a stacked storage class
  bar per row and the 100 largest files inside each prefix. Clicking in the treemap collapses the
  tree, reopens only the path down to what you clicked, and centres it.
- **Details.** Totals, bytes per storage class, the top extensions, and an age histogram.
- **Find.** "Starts with" answers immediately. "Contains" scans every name in parallel with a
  progress bar and a cancel button.

## Build and run

    make test     # unit tests
    make release  # the command line tool at .build/release/s3-inventory-tool
    make app      # the app bundle

Requires Xcode 26 with the Metal toolchain component:

    xcodebuild -downloadComponent MetalToolchain

Open the app and choose the folder that holds `manifest.json` and the inventory data files. The
first open builds an index beside the inventory in `.s3-inventory-index`; later opens are instant.
A folder can also be passed on the command line. Choosing a finished index folder works too, which
is how an index built on another machine is opened.

## Command line tool

    s3-inventory-tool index <inventory folder> [--threads N] [--force] [--allow-missing]
    s3-inventory-tool stats <index folder>
    s3-inventory-tool bench <index folder> [--root <prefix>] [--width W] [--height H]
    s3-inventory-tool lookup <index folder> <key prefix>
    s3-inventory-tool find <index folder> <substring> [--limit N]
    s3-inventory-tool generate-fixture <folder> --rows N [--files F]

## How it holds a billion objects

One object per node in memory would need over 60 GB. Instead the importer streams the key sorted
inventory once and writes struct of arrays column files, which the viewer memory maps and pages in
on demand.

- Directories are numbered in depth first pre-order, so a subtree is one contiguous identifier
  range and its files are one contiguous file range. Subtree membership is a single comparison,
  even inside the Metal shader.
- File names are stored in key order in blocks of 4096, compressed with LZFSE. Neighbouring keys
  share long prefixes, so a name costs about 12 bytes. Hovering decodes one block.
- The treemap consumes children largest first and stops when a cell would fall below a few square
  pixels; everything after that becomes one "remainder" cell. The layout never visits more items
  than the screen can show.

The index for the reference bucket is 37 GB and the import peaks at 6.7 GB of memory.

## Two things the real data taught us

- **S3 Inventory sorts by the decoded key, not the percent encoded one.**
  `schedules/email/…-2021.png` is written before `…-2021%402x.png`, because decoded `.` precedes
  `@`. Comparing encoded bytes rejects a valid export. The importer decodes before it compares.
- **23 percent of the reference bucket's objects are tiny.** Storage class and age colouring is
  usually more informative than extension colouring, which is why storage class is the default.

## Credits

Guiware LLC, [guipinto.com](https://guipinto.com). Swift, AppKit and Metal, with no third party
code. The same information is in the About panel.

## Documents

- Design: `docs/superpowers/specs/2026-09-12-s3-inventory-visualizer-design.md`
- Implementation plan: `docs/superpowers/plans/2026-09-12-s3-inventory-visualizer.md`

## Limits

Parquet and ORC inventory formats, live S3 listing, comparing two inventories over time,
non-current version display, and inventories that are not key sorted are all out of scope.
