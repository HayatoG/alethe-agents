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
- Data is stored per profile in `~/Library/Application Support/com.kc1t.alethe.mac`.
