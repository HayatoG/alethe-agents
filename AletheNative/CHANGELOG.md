# Changelog

All notable user-facing changes to Alethe for macOS (native) are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added
- Native macOS app skeleton (Swift, macOS 26+), bundle id `com.kc1t.alethe.mac`.
- Main window with a sidebar and toolbar, a Settings window (⌘,) and UI zoom in the View menu
  (⌘+ / ⌘− / ⌘0); the zoom level and sidebar visibility are restored on relaunch.
- Sidebar with nested groups, projects and their terminals: add project folders (⌘O, the + button
  or by dropping folders from Finder), create groups (⇧⌘N), drag projects between groups or onto a
  group, move them with the context menu, show them in Finder, and undo any change with ⌘Z.
- New Project (⌘N) and New Group (⇧⌘N) sheets, plus Edit Project… / Edit Group… in the sidebar
  context menu: name, color, folder and group (or parent group); missing or already-added folders
  are reported before saving, and every edit can be undone with ⌘Z.
- Agent launching for Claude Code, Codex, OpenCode, Cursor and the shell: each CLI is found even
  when Alethe is opened from Finder (PATH, Homebrew, npm, pnpm, bun, Volta, fnm, nvm, asdf, mise),
  can be pointed at a custom path, and starts in unrestricted mode when requested.
- Terminals: open Claude Code, Codex, OpenCode, Cursor or a shell in a project (New Terminal in
  the project's menu), rendered with the app theme and following the UI zoom. Terminals keep running
  while you switch projects; an ended process can be restarted, a missing CLI can be pointed at with
  Choose CLI…, and terminals are closed from the sidebar (undoable).
- Workspace panes: open projects sit side by side, each with its terminals in the Auto layout (one
  fills the area, two side by side, more in rows of two). Drag the gaps to resize projects and splits
  live, drag a pane's header onto another to swap them, and close panes or projects from their
  headers (undoable). Sizes are remembered.
- New Terminal sheet (⌘T, or New Terminal… on a project): pick the agent, project and folder, start
  unrestricted, and give it a first prompt that is typed in once the agent is ready. The last agent
  used is preselected.
- Claude Code and Codex terminals resume their own conversation when Alethe is reopened. A new
  Codex conversation is linked to its terminal as soon as Codex saves it, two terminals never take
  the same conversation, and one that can no longer be resumed opens a fresh session instead.
- Settings › Appearance: choose among the 16 built-in themes (applied at once, terminals included),
  set the interface size, and switch the language between English and Português (Brasil) or follow
  the system; a language change offers to restart Alethe.
- File › Import from Alethe (Tauri)…: bring groups, projects and their terminals (and, optionally,
  theme, interface size, enabled agents, CLI paths and language) over from the Windows/Tauri app's data.
  A summary shows what will be added and what is left out before importing, the import can be undone
  with ⌘Z, and the Tauri app's files are only read.
- Sub-tabs: a terminal can hold several agents or shells. A lane on the pane's left edge switches
  between them, adds one with + (or New Sub-tab… in the pane's or the sidebar's menu) and closes them,
  undoable with ⌘Z. The lane appears by itself when a terminal has more than one sub-tab and can be
  shown or hidden from the same menus.
- Press ⌃C twice in quick succession to force-quit a stuck terminal: the program and everything it
  started are killed, and the terminal offers to restart. A single ⌃C still reaches the program.
- Shell terminals (zsh, and bash from Homebrew) mark each prompt, so Terminal › Previous Prompt (⌘↑)
  and Next Prompt (⌘↓) jump between commands and the prompt redraws cleanly after a resize. Your
  shell's startup files are used as before and are never modified.
- Find in the terminal (⌘F): matches are highlighted as you type, the bar shows which match you
  are on out of how many, ↩ / ⇧↩ or ⌘G / ⇧⌘G move between them, ⌘E searches the selected text and
  Esc closes the bar.
- Paste a screenshot or a copied image into a terminal with ⌘V: it is saved as a PNG and its path is
  typed in, ready for an agent to open. Files and images dragged onto a terminal paste as their paths.
- Prompt history per terminal: ⌥⌘↑ / ⌥⌘↓ (Terminal › Older / Newer Prompt from History) bring back
  what you sent before, and each terminal remembers its last 50 prompts across relaunches.
- Terminal output survives quitting: when Alethe reopens, each terminal shows what it had on screen
  above the new session. Terminal › Clear Scrollback (⌥⌘K) erases it; restarting a terminal starts it
  clean, and closing it deletes what was saved.
- Markdown panes: File › Add Content… (⇧⌘A) › README or Markdown shows a Markdown file beside your
  terminals, with tables, task lists and code blocks, and reloads it whenever an agent or editor
  changes it. Edit it in place and save with ⌘S, copy its source or show it in Finder.
- Image and video panes: Add Content › Image or Video shows a picture (fitted or at actual size,
  refreshed when the file changes) or plays a video with the system player, beside your terminals.
- Diff panes: Add Content › Git Changes shows a project's uncommitted changes with line numbers,
  unified or side by side, for the working tree or what is staged.
- Web panes: Add Content › Website shows a live page beside your terminals — the app an agent is
  building on localhost, docs, anything over http(s) — with back, forward, reload and an address bar.
  Pages are private (nothing is kept after closing) and, while hidden, are released to save memory
  unless you choose to keep them loaded.
- ⌘-click a link in a terminal: Markdown, images and videos open as panes beside it, other files in
  their app, folders in Finder, web addresses in your browser — or in a web pane with ⌥⌘-click.
  Relative paths follow the shell's current folder, and `file.swift:42` style locations work.
- ⇧⌘-click a terminal link for all its actions — open in a pane or the browser, show in Finder, copy
  — or Preview it: Markdown, images, videos, pages and text files open in a quick sheet that Esc
  closes, without adding a pane.
- When a terminal prints a local server address (a dev server saying `Local: http://localhost:5173`),
  a bar above it offers to open the page in a pane beside it or in your browser, once per address.
- Project containers can be collapsed to a narrow strip, shown alone (⌥⌘↩ or the header button) and
  reordered by dragging their header; a single pane can be shown alone from its menu or with ⇧⌘↩.
- Workspace tabs: clicking a project in the sidebar opens it in its own tab (⌥-click adds it to the
  current one instead). Tabs sit above your panes; switch with a click or ⌃Tab / ⌃⇧Tab, drag to
  reorder, pin the ones you keep, and close them — History › Reopen Closed Tab (⇧⌘T) brings the last
  one back. Back (⌘[) and Forward (⌘]) retrace the views you visited, and everything is restored on
  relaunch.
- Project layouts: the layout button in a project's header (or View › Project Layout) switches
  between Auto, Spotlight (the first terminal large, the others stacked beside it) and Sidebar (the
  others in a narrow list, the first terminal large). Each project keeps its own layout, and the
  splits stay resizable.
- Custom grids: choose Custom Grid in a project's layout menu, or Design Grid… to draw one — set the
  columns and rows, start from a preset (balanced, columns, rows, focus left or top) or a recent
  grid, and grow, shrink or drag each terminal's box into place. In the workspace, drag a terminal
  onto an empty slot or another terminal to move it, resize any row or column, and use Fill Free
  Space from a terminal's menu to let it take the room next to it.
- Named grids: a project can keep several sets of terminals, each with its own layout — for
  example “Review” beside the main one. Create one with New Grid… (layout menu or the project's
  menu), switch from the grid menu in the project's header, move a terminal with Move to Grid, and
  rename or delete a grid (keeping or closing its terminals). New terminals join the grid on screen.
- Flat workspace (View › Flat Workspace): the terminals of every open project share one area,
  without project headers. Each workspace tab remembers whether it is flat.
- Focus mode: double-click a terminal's title bar (or View › Focus on Pane, ⇧⌘F) to float it over a
  blurred workspace; Esc or a click outside brings everything back.
- Data is stored per profile in `~/Library/Application Support/com.kc1t.alethe.mac`.
