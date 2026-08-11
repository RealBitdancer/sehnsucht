# Hotkeys, indicators, and playlist modes

This note captures the interaction rules built for the shell key bars,
header mode lights, and playlist shuffle/loop. It is the place to resume
when changing transport keys, list navigation chips, or play-order
behavior.

Related code:

| Area | Where |
|------|--------|
| Status transport key row | `src/ui.zig` (`drawStatusHotkeys`) |
| Reserved transport keys | `src/ui.zig` (`transport_keys`, `Model.handleTransportKey`), `src/main.zig` (`handlePlaylistKey`) |
| Header mode lights | `src/ui.zig` (`drawTitleBar`, row 1 right) |
| Chip drawing (shared) | `src/paint.zig` (`Hotkey`, `drawHotkeyHints`) |
| Browse navigation bar | `src/browse.zig` (`drawKeyBar`) |
| Playlist navigation bar | `src/playlist.zig` (`drawKeyBar`) |
| Play order, shuffle, loop | `src/player.zig` (`Player`, `buildOrder`, `reshuffleWrap`, `canStep`, `stepOrder`) |
| End-of-playlist halt | `src/bridge.zig` (`halt_at_songend`), `src/audioengine.zig` (songend edge) |

---

## Design principles

1. **Three homes for keys**
   - Menu mnemonics (`B` `P` `V` `T` `Q`) work while F10 or Alt has
     focused the header menu. Alt plus a mnemonic activates it directly.
   - Global transport lives on the status frame key row (under the progress bar).
   - List navigation lives on the bottom of the Browse / Playlist panes.

2. **The transport row outranks every focus**
   A chip the status row draws as live must work when pressed, whatever
   holds focus: the menu, Browse, Playlist, the Theme browser, or the
   visualizer. `ui.transport_keys` lists the whole row
   (Space `+` `=` `-` `M` `R` `,` `.` `L` `S` `[` `]`), and
   `Model.handleTransportKey` plus `main.handlePlaylistKey` run before any
   menu or pane handling. The corollary is a hard rule: **nothing else in
   the player may bind one of those keys.** A test asserts that no menu
   mnemonic lands in `transport_keys`. Only `Ctrl+C` is matched earlier,
   because quitting outranks everything.

3. **Show what the next press does**
   Toggle chips label the *action you get by pressing*, not a negated
   form of the current mode:
   - Space: `pause` while playing, `resume` while paused
   - `M`: `mute` / `unmute`
   - `L`: `loop` (off) / `once` (on, press to play through once)
   - `S`: `shuffle` (off) / `order` (on, press to restore file order)

   Avoid awkward coinages such as “unloop” or “unshuffle”.

4. **Dim when the key cannot act**
   Key glyphs and their labels use `theme.style(.key_key_disabled)` /
   `theme.style(.key_label_disabled)` when that press would no-op. Shared
   pair labels are an exception (see below).

5. **Glued pairs share one description**
   Directional pairs are drawn without a middle dot between the two keys
   (`glue = true`):
   - `↑ ↓ move`, `PgUp PgDn page`, `Home End jump`
   - `+ - volume`
   - `, . track`
   - `[ prev ] next`

   Chips are otherwise separated by ` · `.

6. **Pair label stays live if either side works**
   The description sits on the second key of a glued pair. It must not
   gray out just because that second key is at a dead end. Use
   `Hotkey.label_enabled` so the label is enabled when *either*
   direction still acts:
   - At list top: `↑` dim, `↓` live, **move** live
   - At list bottom: `↓` dim, `↑` live, **move** live
   - Empty list: both dim, **move** dim

   Prev/next labels follow their own keys (no shared pair label enable).

7. **Empty labels are allowed**
   Self-explanatory glyphs (`↑`, `+`, `PgUp`) may use `label = ""` so the
   description is only on the second key of the pair.

8. **An open list owns the arrows**
   While Browse or Playlist is open, Enter always acts on the list, and
   left/right belong to it too: Browse treats right as open and left as
   parent (the ranger/lf/MC habit), Playlist swallows both. F10 or Alt
   moves focus to the menu. Left/right move between enabled items without
   opening them. Tab/Shift+Tab move one item and immediately open Browse,
   Playlist, Visualize, or Theme. Action-only items such as Quit receive
   focus without activation. Enter activates the focused item, and a
   mnemonic activates its matching item. Alt plus a mnemonic activates it
   without focusing the menu. `Q` quits from the focused menu, while
   `Alt+Q` and `Ctrl+C` quit directly.

   The Theme browser follows the Playlist navigation model. Arrows,
   paging keys, Home, and End move the cursor. Enter applies the
   selected theme.

9. **Mouse mirrors the keyboard, never extends it**
   A left click activates a menu item (disabled items ignore it, Quit
   quits: a pointed click is deliberate). A click selects a list row,
   a second click on the selected row opens/plays it, and the wheel
   scrolls the open list three rows per notch. Hit zones are recorded
   at draw time (`Model.menu_hits`, `browse.rowAt`,
   `playlist_list.rowAt`), so clicks always match the visible layout.
   Chips, mode lights, and the progress bar are not clickable.

---

## Status frame transport row

Layout (content column `x = 1`, aligned with the `▶` play glyph):

```
⎵ pause · + - volume · M mute · R rate · , . track · L once · S order · [ prev ] next
```

When the loader marks an entry unplayable, a transient skip notice
takes over this row for about five seconds: `✗ name: reason`, the `✗`
in `theme.style(.notice_mark)`, the name percent-decoded like the Playlist rows,
the reason a plain phrase from `loadErrorLabel` (`src/loaderr.zig`). The
chips return when the countdown expires (`Model.noticeSkip`,
`notice_ticks`). The progress row above is untouched.

Conditional chips:

| Chip | Shown when |
|------|------------|
| `R rate` | Track loaded and `rate_adjustable` |
| `, . track` | Track loaded and `archive_track_count > 1` (AudioT) |
| `L loop\|once` | `playlist_count > 1` |
| `S shuffle\|order` | `playlist_count > 1` |
| `[ prev ] next` | `playlist_count > 1` |

`L` is multi-entry only, like `S`: a single file is internally a one-entry
playlist and always loops until quit, so loop-off would have nothing to
mean there.

Enable rules:

| Key | Live when |
|-----|-----------|
| Space | `has_track` |
| `+` | muted or volume &lt; 100. Volume is a global setting, so the chips stay lit while idle, matching the keys. Mute still allows both steps because a step unmutes |
| `-` | muted or volume &gt; 0 |
| `M` | `has_track` |
| `,` / `.` | always while shown (reloads the archive at the previous or next track, wrapping) |
| `L` / `S` | always while shown (toggles always apply) |
| `[` | `Player.canStep(.prev)` |
| `]` | `Player.canStep(.next)` |

Model fields synced from the player each frame (and on S/L toggle):

- `shuffle`, `loop_all`
- `can_playlist_prev`, `can_playlist_next` (via `Player.canStep`)

The frame sync also arms `bridge.halt_at_songend` so the engine can park
playback exactly at the songend edge, in two cases:

- last track of a non-looping pass (multi-entry, not detached, no next
  step)
- a one-shot track (`TrackInfo.loop` false, its finished decoder yields
  only silence) playing alone or detached

Space on a parked one-shot goes through `Action.replay`, which
`main.applyUiAction` hands to `Loader.request(.replay, …)` (reload from
the top, then unpause), because a finished decoder has nothing to resume
into. That case is matched inside `main.handlePlaylistKey`, and every other
Space falls through to the shell's pause toggle. A mid-track pause has
`loop_count == 0` and resumes normally.

---

## Header mode lights

Second title row, right side, under the volume percentage block.

| Glyph | Code point | Meaning | Shown when |
|-------|------------|---------|------------|
| `↻` | U+21BB | Playlist loop | `playlist_count > 1` |
| `⤨` | U+2928 | Shuffle | `playlist_count > 1` |
| `⊘` | U+2298 | Mute | always |

Loop and shuffle use faceplate glyphs, and mute joins them on the same
row.

Style (always drawn while available, never hidden when off):

- **On:** `theme.style(.mode_light_on)` (amber), bold
- **Off:** `theme.style(.mode_light_off)` (gray)

Drawn right-to-left so left-to-right order is loop, shuffle, mute. Mute
is the outermost, so it holds the same column when the playlist pair is
absent. It is drawn unconditionally because mute survives track changes:
a muted player that skips to the next entry keeps playing silently, and
this light is what says so.

---

## Browse and Playlist key bars

Each list pane reserves two bottom rows: a barely-visible `─` rule
(`paint.drawRule`, `theme.style(.list_rule)`) then the chip row. The column-header
rule uses the same rail style (four rules total: two per list pane).

### Browse

```
↑ ↓ move · PgUp PgDn page · Home End jump · Enter → open · Bksp ← parent
```

`Enter →` and `Bksp ←` are glued alias pairs (principle 8): `→` opens
the selection like Enter, `←` goes to the parent like Backspace.

| Key | Dim when |
|-----|----------|
| `↑` / `PgUp` / `Home` | Cursor already on first row |
| `↓` / `PgDn` / `End` | Cursor already on last row |
| Pair labels `move` / `page` / `jump` | Empty list only (`label_enabled = can_up or can_down`) |
| `Enter → open` | List empty |
| `Bksp ← parent` | Already at the top of the browse tree: the virtual **Drives** list on Windows, or a non-drive filesystem root (`/`, UNC share root) on any OS |

On Windows, a drive root (`C:\`, `D:\`, …) is not a dead end. Parent climbs into a
virtual **Drives** list (path header shows `Drives`, rows are `<DRV>` entries such
as `C:\`). Opening a drive sets the browse path to that root and lists it like any
other directory. The drive you left is re-selected in the list. UNC share roots
and Unix `/` still stop at the real root; the virtual list is Windows-only.

### Playlist list pane

```
↑ ↓ move · PgUp PgDn page · Home End jump · Enter play
```

Same end-of-list rules, and `Enter play` dims when the list is empty. The
chip reads `Enter retry` while the cursor sits on an unplayable row
(see the unplayable marker below).

---

## Playlist play order (Player)

State on `Player` in `src/player.zig`:

| Field | Role |
|-------|------|
| `entries` | Playlist paths |
| `index` | Current entry index into `entries` |
| `order` | Play order as indices into `entries` |
| `order_pos` | Cursor into `order` |
| `shuffle` | Use shuffled `order` |
| `loop_all` | Wrap at ends of `order` |
| `played` | Per-entry "played this session" flags for the list view's coverage marker |
| `unplayable` | Per-entry "failed to load" flags for the ✗ marker and the skip rules |

### `buildOrder`

```
buildOrder(order, shuffle, current, rng) -> start_pos
```

- **No shuffle:** `order = 0..n-1`, start = `current`.
- **Shuffle:** Fisher-Yates permute `order`, then swap `current` to slot 0,
  start = 0. A forward pass from the start therefore visits every track
  exactly once, rather than parking mid-order and stopping early.

`rebuildOrder` uses `buildOrder` (current pinned first). Used when
toggling shuffle or replacing the playlist.

`reshuffleWrap` builds a fresh permutation when **loop + shuffle** wrap
past an end of a pass. It does not pin the current track, but it swaps
the just-played track out of the slot about to play, so the wrap never
repeats a track back to back.

### Stepping

`stepOrder(dir)` moves `order_pos`, returns the next `entries` index, or
null at an end when `loop_all` is false. Entries marked unplayable are
passed over. The scan is bounded by the list length, so an all-marked
list returns null instead of spinning through a looping order.

Wrap when `loop_all`:

- No shuffle: modular wrap on `order_pos`.
- Shuffle: `reshuffleWrap()`, then play from the start (or end for prev)
  of the new permutation, never the just-played track. That is “S and L
  on, finished the list, reset the algo and continue”.

`playPos()` returns the position of `index` inside `order` (self-heals if
`order_pos` drifts).

`canStep(dir)` drives the status bar `[` / `]` chips and must agree with
whether `stepOrder` would succeed. A lit chip is a promise that pressing
the key steps.

### `canStep` rules

| Mode | Prev | Next |
|------|------|------|
| Fewer than 2 entries | false | false |
| No playable entry left (all marked) | false | false |
| `loop_all` | true | true |
| No loop | playable entry behind in the active order | playable entry ahead in the active order |

Entries marked unplayable count in neither direction, so the chips dim
as the playable set shrinks.

One rule serves file order and shuffle alike: positions are slots in the
active `order`, which is the identity for file order and the current
permutation for shuffle. At the start of a shuffle pass prev is dark,
since nothing in this pass lies behind, and it lights after the first
advance. Once the pass is exhausted, next dims and prev keeps the pass
history reachable. An earlier release kept both chips lit mid-pass as a
deliberate softness, which let prev advertise a step that `stepOrder`
refused. Version 0.1.1 removed it.

Auto-advance (song end while multi and not detached) picks its target
with `stepOrder(.next)` and hands the load to the async `Loader` (a busy
loader suppresses re-triggering). At the end without loop the engine
has already parked playback: the UI arms `bridge.halt_at_songend` while
the last track of the pass plays, and the engine pauses exactly at the
songend edge. The app does not quit, and the parked track stays loaded
for resume (Space) or skips.

### Manual jump (Playlist Enter)

Enter hands the entry to the async loader, which on success sets
`order_pos` to the track’s slot in the current `order` so subsequent
`[` / `]` continue from there.

### Cursor follow rule

The Playlist cursor follows playback only while it already sits on the
playing row (`cursorFollowsPlayback` in `src/loader.zig`): idly watching
the list keeps the cursor gliding along with auto-advance. The moment
the user moves the cursor it belongs to the user, and no later event
touches it, including an async load finishing seconds after the Enter
that started it. Deliberate view activations still place the cursor
(opening the Playlist view with F10 then `P`, opening an M3U, startup).

### Played marker

Rows that have played this session extinguish their number in the
Playlist view (ghost ink, `theme.colors.playlist_played_fg`), like the music
calendar of a CD player, so shuffle coverage reads down the column at a
glance. Rules:

- `Player.markPlayed` runs from `Loader.commitLoadedTrack`, so an entry is
  marked exactly when it starts sounding: skips, auto-advance, Enter
  jumps, replay, the startup track, and the first track of an M3U opened
  from Browse.
- A failed candidate never reaches `commitLoadedTrack`, so the loader's
  scan marks only the entry that actually sounded.
- Flags survive shuffle/loop toggles and reshuffles. They reset only when
  the playlist itself is replaced (`replaceEntries`). Never persisted.
- Detached Browse play marks nothing: no playlist row is sounding.
- Precedence in the row: the cursor and playing styles win, and only a plain
  row shows the ghost number. The title keeps `theme.colors.list_row_fg` either
  way, so a played row stays as readable as an unplayed one.

### Unplayable marker

Entries that fail to load are marked unplayable instead of quitting the
player. Rules:

- `Player.markUnplayable` runs from `Loader.advance` wherever a load
  fails: the startup scan, skips, auto-advance, Enter jumps, replay, and
  the candidates an M3U opened from Browse passed over before its first
  playable entry. A detached Browse play is the exception, since its index
  addresses no playlist row.
- Auto-advance, shuffle passes, and `[` / `]` skip marked entries
  (`stepOrder` scans past them, `canStep` counts them in neither
  direction). A dead remote entry therefore costs its download timeout
  once per session, not on every pass.
- Loads run on the async loader: the status icon spins and the header
  reads `[Loading]` while bytes are in flight, and the device is silent.
  Pressing the same skip key again passes over a slow candidate without
  marking it (the mark means dead, not slow). A scan whose failures were
  all fetch-side resumes the untouched previous track when it runs out
  of candidates.
- Enter on a marked row retries it, because remote failures are often
  transient. A successful load clears the mark. The list key bar reads
  `Enter retry` while the cursor sits on a marked row.
- The moment an entry is marked, the status key row shows the transient
  `✗ name: reason` notice (see the status row section), so a skip is
  visible even while the Playlist view is closed.
- Row treatment: red `✗` (`theme.colors.playlist_dead_mark_fg`) in the marker
  column, number, title, and format dimmed to `theme.colors.playlist_dead_fg`.
  Cursor and playing styles
  win so the selected row stays readable for the retry. The unplayable
  dimming outranks the played ghost ink.
- Flags reset only when the playlist is replaced, like `played`.
- When every entry is marked and the current source is gone, `parkIdle`
  drops the model to the no-track idle state: `[Stopped]` header,
  device stopped, playlist still on screen for retries. A Visualize
  view falls back to the Playlist pane, since there is nothing left to
  visualize and retry lives in the list.

---

## Interaction matrix (playlist)

| S | L | Next at end of pass | Prev at start of pass | Auto-advance after last |
|---|---|---------------------|------------------------|-------------------------|
| off | off | disabled / no-op | disabled / no-op | halts at the songend edge (paused) |
| off | on | wraps to first (file order) | wraps to last | continues |
| on | off | disabled when pass exhausted | disabled at pass start, live once the pass has history | halts when pass exhausted |
| on | on | reshuffle, play new pass | reshuffle path for prev wrap | reshuffle and continue |

---

## Chip drawing API (`paint.Hotkey`)

```zig
pub const Hotkey = struct {
    key: []const u8,
    label: []const u8,
    enabled: bool = true,           // key glyph
    label_enabled: ?bool = null,  // null => follow enabled
    glue: bool = false,             // no " · " before this chip
};
```

`drawHotkeyHints(win, row, theme, hints, x0)`:

- Starts at `x0` (status and lists use `1` to clear the frame border).
- Between chips: ` · ` unless `glue`.
- Omits space+label when `label` is empty.
- Key style: `theme.style(.key_key)` vs `theme.style(.key_key_disabled)`.
- Label style: `theme.style(.key_label)` vs `theme.style(.key_label_disabled)`,
  chosen by `label_enabled orelse enabled`.
- A chip that would not fit the window ends the row: narrow terminals
  truncate at chip boundaries, never mid-chip.

List internal rules: `paint.drawRule` uses `theme.style(.list_rule)` (barely
visible on the canvas), not frame chrome.

---

## Gotchas

1. **Menu collision:** the transport row owns its keys everywhere
   (principle 2), so a menu mnemonic may never be one of them. The
   archive track keys were `T` at first, which collided with the `Theme`
   item and forced it onto its `h`. Moving them to `,` and `.` gave
   `Theme` its natural `T` back. `MenuItem.mnemonic` still carries the
   emphasized column per label, for the next label whose first letter is
   taken. Adding a chip means checking `menu_items` first, and a test
   enforces it.

2. **Order vs index:** Header `3/10` is `playlist_index` (file order).
   Skip enable uses `playPos()` (order slot). Never dim next from a high
   file index while that track is still early in a shuffle pass.

3. **Toggle S rebuilds order** with current first and `order_pos = 0`.
   Sync `can_playlist_*` on the model in the same event handler, not only
   at end of frame.

4. **End vs idle:** a step with no target (stepOrder null) changes
   nothing: the engine has parked at the songend edge and the current
   track stays. A `Loader` scan that wrecked the chip and then ran out
   of candidates calls `parkIdle` to drop the model to its no-track
   state before the next draw. A scan whose failures were fetch-only
   resumes the untouched old source instead. `parkIdle` also clears
   `bridge.paused`: the idle state must not hide an armed pause behind
   its `[Stopped]` header. Load failures never quit
   the player once the TUI is up. Only a startup argument that cannot
   play exits, with stderr messages and code 1 (printed after teardown,
   collected during the async startup scan).

5. **Detached Browse play:** multi auto-advance is skipped while
   detached. Playlist entries and S/L state remain so the user can return
   to the list.

6. **Volume while muted:** both `+` and `-` stay enabled when muted
   because either step unmutes. At 0%/100% without mute the dead end
   dims.

7. **Pair label trap:** putting `move` only on `↓` and tying label style
   to `↓.enabled` grays the word at the bottom of the list. Always set
   `label_enabled = can_up or can_down` (and the volume analogue).

8. **Loop vocabulary:** the status chip `L loop|once` means the playlist.
   The stream strip's `Song ◆ LOOP / ○ ONCE` badge means the track's own
   loop behavior and keeps its `Song` prefix so the two cannot be read as
   one setting. Do not add a third unqualified loop/once anywhere.

9. **Resuming a parked one-shot:** plain unpause would play the finished
   decoder's eternal silence. Space must route to `Action.replay` when
   `paused and loop_count > 0 and !track.loop`.

10. **Mute outlives the track:** `Bridge.resetTrackState` keeps `volume`
    and `muted` on purpose, so `]`, auto-advance, and Enter jumps all
    land on a silent track while mute is on. That is a global setting
    behaving like one, but it reads as a dead player, so the state must
    stay legible: the `⊘` light, the `mute` word in place of the volume
    percentage, and the `M unmute` chip. Metering is pre-fader
    (`AudioEngine.publishPcmMeters` runs before `applyGain`), so the
    visualizers keep moving while muted instead of half of them going
    flat and half not, and the light is the one thing that says why the
    room is quiet.

---

## Follow-ups / not implemented

- Repeat-one (a single-track repeat mode) is not implemented.
- On narrow terminals every key bar truncates at chip boundaries, so
  later chips simply drop out. A priority order (drop labels before
  whole chips) could keep more visible.

---

## Quick test checklist

- [ ] No track: Space and M chips dim, and neither key changes state
      (no silently armed pause or mute), and `+` / `-` stay lit and move
      the header gauge (volume is global)
- [ ] Playing / paused: Space `pause` / `resume`
- [ ] Mute / unmute labels, and volume ends at 0 and 100
- [ ] Browse root: `Bksp ← parent` dim, not root: live
- [ ] Browse: `→` opens the selection, `←` goes to the parent, and menu
      focus stays on the tab while the list is open
- [ ] Playlist view: `←` / `→` do nothing, and Enter plays the cursor row
      even after wandering keys
- [ ] Browse/Playlist: arrows and page keys dim only on the dead side,
      and pair labels stay live until empty
- [ ] AudioT archive with several tracks: `, . track` chip shown, `.`
      reloads the next track and `,` the previous one (the synthesized
      `track k/N` title moves, wraps at both ends, and works detached
      from Browse too, while a curated EXTINF title on the entry covers
      the synthesized one and the chip still steps). Plain file or
      single-track archive: no chip, both keys inert
- [ ] F10 then T opens Theme, the list shows display name and description,
      marks the active theme, and Enter applies the cursor row. `,` and `.`
      still step the AudioT track while the menu holds focus
- [ ] With the menu focused, Space, `+` / `-`, `M`, `R`, `[` / `]`, `S`,
      and `L` still act, and focus stays on the menu
- [ ] Header title priority: GD3 / ADLIB-wrapper title beats the
      curated EXTINF title, which beats synthesized names (DRO,
      AudioT) and the decoded basename without extension
- [ ] Playlist pane title: `#PLAYLIST` name, else the playlist's file
      name, then `· N tracks`, and argv-assembled lists show the count
      alone
- [ ] Single file or one-entry playlist: no `L` / `S` chips, no mode
      lights, loops until quit
- [ ] Single one-shot file (VGM without loop point): parks at its end
      instead of going silent, Space replays it from the top
- [ ] Multi playlist: `L` / `S` chips and header `↻` / `⤨` (dim vs amber)
- [ ] Mute, then `]`: the next track loads silent, the `⊘` light is amber,
      the volume readout reads `mute`, the chip reads `M unmute`, and the
      visualizer keeps moving. `M` restores sound on the new track
- [ ] Volume at 30% and at 100%: the analyzer bars and VU meters read the
      same (pre-fader metering), only the loudness changes
- [ ] S on, L off: next stays live until last of shuffle pass, then after
      last, next dim, prev live, and auto-advance halts
- [ ] S on, L off, fresh pass: `[` is dim before the first advance and
      lights after it, and pressing `[` while dim changes nothing
- [ ] End of list without loop: playback pauses at the songend edge,
      Space replays the last track, `[` steps back
- [ ] S on, L on: after last track, new shuffle and continue (never the
      same track twice in a row)
- [ ] S off, L off: linear ends, and `[` / `]` match ends of file order
- [ ] Toggle S then check `[` / `]` against the new pass without a restart
- [ ] Played numbers dim as shuffle progresses, every number is dim when
      the pass ends, and opening another M3U relights the whole column
- [ ] Dead entry (deleted file, dead URL): auto-advance skips it, the
      row shows a red ✗ with dim text, its number never extinguishes,
      and a `✗ name: reason` notice holds the status key row for a few
      seconds
- [ ] Enter on a marked row retries it (key bar reads `retry`), and a
      successful load clears the mark
- [ ] Every entry dead: the player parks in `[Stopped]` with the
      playlist on screen instead of quitting
