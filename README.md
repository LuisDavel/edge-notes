# edge-notes

macOS sticky notes that live on the edge of your screen — inspired by
[holdmynotes.app](https://holdmynotes.app/).

At rest the deck is a thin pill on the right edge, one coloured dash per
note. Hover and the notes fan down the edge, each with its own vertical
tab. Click one and it slides out full size — type and it autosaves to a
plain Markdown file 250 ms after you stop.

No Dock icon, no window chrome, works on top of fullscreen apps, never
steals focus until you click into a note.

## Build

```bash
./Scripts/bundle.sh
open EdgeNotes.app
```

Requires macOS 14+ and Xcode command line tools.

## Notes on disk

Each note is a Markdown file with YAML frontmatter in
`~/Library/Application Support/EdgeNotes/notes/`. Edit them with any
editor — the app picks up external changes automatically.

## Library

Menu bar icon → **Open Library** for search, Active/Archived filters,
import (.md/.txt), export and delete.

## Roadmap

- Left-edge deck integrated with [Day](https://github.com/LuisDavel/day)
  (tasks via API) — phase 2 in `docs/superpowers/specs/`.
