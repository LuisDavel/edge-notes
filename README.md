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

## Day integration

EdgeNotes can connect to a [Day](https://github.com/LuisDavel/day) board so
your tasks live alongside your notes.

### Connecting

1. In Day, go to **Settings → API Tokens** and create a token.
2. In EdgeNotes, open the menu bar icon → **Day Settings…** and paste the
   token together with your Day server's base URL. **Test Connection**
   confirms the server is reachable before you save.
3. **Save** stores the base URL in `UserDefaults` and the token in the
   macOS **Keychain** — the token is never written to disk in the clear and
   never appears in a note file. Saving immediately connects (or
   reconnects) the integration; clearing the settings disconnects it.

### The left-edge deck

Once connected, a second pill deck appears on the **left** edge of the
screen (notes stay on the right). At rest it's a thin pill; hover to fan
it into the board's columns (To do / In progress / In review / Done, per
your Day board), each with a task count. Click a column to see its tasks,
and click a task to open its detail card — status, priority, a timer you
can start/stop, and comments. Drag a task between columns, or within a
column to reorder it, and the change is sent to Day immediately (and
reverted if the request fails). Use the menu bar's **Open Kanban** for the
same board in a full window with a sprint/backlog picker.

### Offline behaviour

The board is cached to disk after every successful load. If a refresh
fails because the network is unreachable, the deck keeps showing the last
cached board (marked stale) rather than going blank, and retries silently
every 60 seconds while any Day surface (the deck or the kanban window) is
visible. A mutation made while offline (status/priority change, reorder,
drag) is applied locally right away and rolled back if the server call
ultimately fails, with the error shown on the task it affected.

### Sending a note to Day

Open any note and, when Day is connected, its footer shows a **Send to
Day** action. It creates a Day task titled after the note with the note's
full body as the task's description, and remembers the returned task id in
the note's frontmatter (`dayTaskId`, only ever written for notes that have
actually been sent — every other note's frontmatter is unaffected). Once
linked, the footer instead shows the task's current status, read live from
the Day board.

## Roadmap

- Opening a linked note's Day task directly in the left-edge deck from the
  note editor (currently the editor only shows its status — the two decks
  don't yet share a way to hand off "open task X").
