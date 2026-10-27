# Controls and playlist modes

Transport keys work from every view, including the menu and inspector.
Navigation keys belong to the focused menu, list, visualizer, or popup.
Ctrl+C always quits.

## Transport

| Key | Action | Available when |
|-----|--------|----------------|
| Space | Pause, resume, or replay a finished track | A track is loaded |
| + / = | Raise volume | Below 100%, or muted |
| - | Lower volume | Above 0%, or muted |
| M | Mute / unmute | A track is loaded |
| R | Cycle 280, 560, and 700 Hz | The source supports rate changes |
| `,` / `.` | Previous / next archive member, wrapping | The archive has more than one member |
| `[` / `]` | Previous / next playlist entry | A playable target exists in that direction |
| L | Toggle playlist loop | The playlist has more than one entry |
| S | Toggle shuffle | The playlist has more than one entry |

These keys are reserved. A menu or plugin must not bind them to another action.
Letter keys accept either case. Transport matching excludes Ctrl, Alt, and
Super combinations.

Volume changes by about 2.4 dB per press. Either volume key also unmutes,
including at a volume boundary. Volume remains adjustable while idle. Mute and
volume persist across track changes. Meters are measured before output gain,
so the display keeps moving while muted.

Status labels describe the next action: `pause` or `resume`, `mute` or
`unmute`, `loop` or `once`, and `shuffle` or `order`. Disabled controls dim.
The `L loop/once` control refers to the playlist. A visualizer's `Song LOOP`
or `Song ONCE` badge describes the decoder's own loop behavior.

R applies to IMF, WLF, and AudioT. Replay and archive selection preserve the
chosen rate. Moving to another file restores that file's default or playlist
rate. A launch with `--rate` supplies a session override, and R updates it.
Changing the rate changes timing, not pitch.

## Menu and lists

| Key | Action |
|-----|--------|
| F10 or Alt | Toggle menu focus |
| Alt+B / Alt+P / Alt+V / Alt+T | Open Browse / Playlist / Visualize / Theme |
| Alt+Q or Ctrl+C | Quit |
| B / P / V / T / Q | Activate that item while the menu is focused |
| Tab / Shift+Tab | Move to the next / previous enabled menu item |
| Left / Right | Move menu focus, or navigate the active pane |
| Up / Down | Move a list cursor |
| Page Up / Page Down | Page through a list |
| Home / End | First / last list entry |
| Enter | Activate the focused menu item or selected list entry |

Tab opens view items as it reaches them. It only focuses action items such as
Quit. Enter or the item's mnemonic performs the action. Visualize is disabled
when there is no loaded track.

In Browse, Right and Enter open the selected directory, playlist, or music
file. Left and Backspace open the parent. On Windows, moving above a drive
root opens the virtual Drives list. A Unix root or UNC share root has no
parent. Playlist and Theme consume Left/Right without moving menu focus.

Enter in Playlist loads the selected row, or retries it if a previous load
failed. Enter in Theme applies the selected theme. The active theme is marked.
Opening a music file from Browse detaches playback from the current playlist.
The list and its shuffle/loop settings remain available. Song end does not
advance a detached session or mark playlist rows. `]` and `[` still move
through the list, and a track that loads is marked played.

## Visualizer navigation

I opens the shared inspector. Outside the inspector, Left/Right pages Tracker
and Sequence channels, or Stream hardware voices.

Tracker uses backtick to cycle its available pattern, instrument, order,
macro, live-state, spectrum, and riff regions. Up/Down moves within a
scrollable region, Page Up/Down moves eight positions, and End selects the
last position. In the pattern and order regions, Home restores automatic
following, and any other move pins the view, even at row zero. In the other
regions, Home selects the first position. Instrument selection follows the
last instrument until the user changes it.

Sequence uses Up/Down and Page Up/Down to scroll the tick, command, or bytecode
window. Home restores automatic following. End shows the last screen of ticks
or events, or brings the last bytecode row to the top. Use the inspector for
complete event lists and long bytecode programs.
Sequence and Stream do not cycle regions with backtick outside the inspector.

## Inspector

I opens a centered popup over a dimmed pane. Only sections supplied by the
source are offered: song, instruments, macros, pattern, channels, events,
branches, order, and chip state.

| Key | Action |
|-----|--------|
| Backtick | Next available section |
| Up / Down | Scroll one row or select a branch |
| Page Up / Page Down | Scroll one popup page |
| Home / End | First / last position |
| Left / Right | Pan long lines by eight columns |
| J / K | Previous / next instrument |
| C | Next voice-program channel, in the events section |
| Enter | Request the selected branch, in the branch section |
| Escape or I | Close |

The wheel scrolls three rows per notch inside the popup. Its footer controls
and close button are clickable. Clicking outside closes it and consumes that
click. Mouse input does not reach the background status bar while the popup
is open. Keyboard transport remains available.

The popup recalculates its page size after a resize. Event inspection uses a
32-bit index, and bytecode paging exposes the complete remaining program.
Left and Right pan as far as the widest row on screen.
Branch requests are applied on the audio thread. The inspector does not call
the decoder's playback methods from the UI thread.

## Mouse controls

Where the terminal reports mouse input, click a menu item to open it. Click a
list row to select it, then click the selected row to activate it. The wheel
scrolls lists. Browse, Playlist, Theme, and status-bar footer controls invoke
the same actions as their printed keys.

Only enabled, visible controls have hit areas. A control clipped out of a
narrow window cannot be clicked. A list-footer click also releases menu focus.
Resizing, changing views, and displaying a notice clear old hit areas before
new ones are drawn.

The progress bar displays elapsed time and duration. Click or drag it to seek.
While the button is held, the bar and the time show the target, and playback
moves there on release. A track parked at its end plays on from the new
position. A track without a known duration cannot be sought. Notes held across
the seek point start again from their attack, because the chip is not rendered
while the player runs ahead. A separate repeat-one mode is not implemented.

## Playlist playback

A single file or one-entry playlist follows `TrackInfo.loop`. Some decoders
repeat the whole stream without an explicit loop marker. A non-looping track
plays once and parks at its end. Space loads it again from the beginning.

With multiple entries, a song boundary advances to the next playable entry.
Loop wraps at both ends of the current play order. Without loop, playback
parks after the last track's final interval. Space replays that track, and
Previous can return to earlier entries. The application remains open.

| Shuffle | Loop | At the end of a forward pass |
|---------|------|-------------------------------|
| Off | Off | Stop on the last entry |
| Off | On | Continue from the first entry |
| On | Off | Stop after the current permutation |
| On | On | Build a fresh permutation and continue |

Shuffle uses a Fisher-Yates permutation. Enabling it puts the current entry
first so a forward pass can visit the whole list. At a loop wrap, the next
permutation avoids immediately repeating the just-played entry when another
playable entry is available. Disabling shuffle restores file order around
the current entry.

The header's playlist position is the entry's index in file order. Previous
and Next use its position in the active play order. These are different
numbers during shuffle. Enter on a list row aligns the play-order cursor with
that entry, so subsequent skips continue from it.

Previous and Next are disabled with fewer than two entries or no playable
target. Without loop, they stop at the current order's ends. With loop, they
wrap. Failure scans are bounded by the list length, including when every entry
has failed.

## Markers, cursor, and failures

A successfully loaded playlist entry is marked played for the session. Its
number dims on an ordinary row. This records a playback load, not whether the
speakers produced sound. Selection and current-playback styles take precedence.
Played flags survive shuffle and loop changes and reset when the list is
replaced. They are not saved between sessions.

A failed load marks the entry with a themed failure symbol and dimmed text.
Automatic advance and skips pass over marked entries. Enter retries one, and
a successful retry clears its failure flag. Cancelling a slow candidate does
not mark it failed. Failure flags reset when the playlist is replaced.

A notice such as `✗ name: reason` replaces the status controls for about five
seconds. The covered controls have no mouse hit areas, but their keyboard
actions still work. A new failure replaces the notice.

The list cursor follows playback only while it already sits on the playing
row. Moving it elsewhere gives the user control, including while a load is
pending. Opening the Playlist view or replacing the list can deliberately
reposition it.

A running session does not quit because a load failed. Fetch-only failures
can resume the old source if it is still intact. If no source remains and all
candidates fail, the player returns to a stopped state with the playlist
available for retries. A startup argument that cannot be played exits with
status 1 after terminal teardown.

## Loading and archives

Loading runs in the background. The header shows `[Loading]`, audio stops, and
input remains active. Live visualizer values and held meters clear to zero.
The previous layout stays dimmed while its immutable views remain available.
The loader detaches these views before freeing their source.

Additional Previous/Next presses while a playlist advance is pending add
skips. Each press advances another candidate. A slow fetch therefore does not
trap navigation on its original target.

AudioT, ADL, and XMI expose archive members. The header format tag shows the
one-based member number and count even when a playlist title overrides the
track name. Comma and period wrap within the archive. ADL and XMI select a
member from the loaded source using a fresh chip. AudioT reloads because it
keeps only the selected IMF stream.

During a same-file reload, extra archive-key presses update the pending member.
They do not retarget a load that is opening a different file. Rate overrides
survive same-file replay and archive selection.

## Drawing and dispatch

`src/paint.zig` defines the shared footer control:

```zig
pub const Hotkey = struct {
    key: []const u8,
    codepoint: ?u21 = null,
    label: []const u8,
    enabled: bool = true,
    label_enabled: ?bool = null,
    glue: bool = false,
};
```

The call order is `drawHotkeyHints(win, theme, row, hints, x0, hits)`.
`codepoint` identifies the action for mouse dispatch. The caller clears
`HotkeyHits` each frame. Drawing records the same terminal-cell bounds used by
the text. Disabled controls and controls without a codepoint have no hit area.
A control that cannot fit ends the row rather than drawing a partial label.

Controls are separated by ` · ` unless `glue` joins a pair. Empty labels are
allowed. A shared pair label uses `label_enabled` when either direction still
works. At the bottom of a list, Down can dim while the word `move` remains
active for Up. Label styling does not enable a disabled key.

`main.handleKeyPress` checks quit and playlist transport before forwarding to
`Model.handleKey`. The model checks the remaining transport keys before popup,
menu, and pane navigation. `Model.handleMouse` returns the key represented by
a footer click so it follows this same dispatch path.

Header mode lights show playlist loop (`↻`), shuffle (`⤨`), and mute (`⊘`).
The first two appear only for multi-entry playlists. Colors come from the
theme. Mute also replaces the volume percentage with `mute` and changes its
control to `unmute`.

## Checks when changing input

Check idle and paused states, volume limits, and transport under menu and
popup focus. Confirm that a disabled control cannot act by mouse, and that
paired labels remain active when one direction works.

Exercise file order and shuffle with loop both on and off. Include a failed
entry, an all-failed list, an explicit retry, and cursor movement during a
pending load. Confirm that Space replays a parked track and that archive
selection preserves the selected rate.

Resize with the inspector open, with a status notice visible, and with list
footers clipped. Old hit areas must not remain clickable. During a song
change, all three visualizers must retain their layout with zero live output.
