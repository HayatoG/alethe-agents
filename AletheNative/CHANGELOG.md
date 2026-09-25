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
- Terminal output survives quitting: when Alethe reopens, each shell terminal shows what it had on
  screen above the new session (agent terminals start clean; the agent redraws its own conversation). Terminal › Clear Scrollback (⌥⌘K) erases it; restarting a terminal starts it
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
- When nothing is open, the workspace offers quick actions with their shortcuts — open the
  selected project, new terminal, new project, add content, reopen a closed tab. Before your first
  project, pick an agent and open a folder: Alethe makes it a project and starts the agent there.
- Disable a terminal (its menu, or the sidebar) to stop it without losing it: nothing runs until you
  enable it, and its output comes back. Disable a whole project the same way, or suspend a group
  to stop every project in it and free their memory; Resume Group brings them back. All of it can
  be undone with ⌘Z.
- Memory: a toolbar indicator shows what your terminals use, turning amber or red as the Mac runs
  short; click it for each terminal's share. Terminals that are not on screen run at background
  priority. In Settings › Resources you can let Alethe hibernate idle hidden terminals — always
  after an idle limit, or only when memory is critical. A hibernated terminal keeps its output and
  picks up its session again as soon as you show it.
- Find or Jump (⌘K): type a few letters of a terminal, project or command and press Return — results
  are ranked by how well they match, so “cli” finds client-site. Commands like New Terminal, Flat
  Workspace or a project layout run from the same field.
- Alethe asks before quitting while terminals are running (with a “Don't ask again” option, also in
  Settings › General). Settings › General › Open with an empty workspace starts with nothing open,
  your workspace tabs ready to pick.
- Terminal › Resume Previous Conversations restarts your running agents on the conversation they
  had before the current one.
- Settings › Appearance › Style and motion: choose the Clean style — flat, compact surfaces with
  quiet borders and a denser sidebar — or keep Normal; turn on Reduce motion to stop panes and
  overlays from animating (it also follows the macOS setting).
- New agents: GitHub Copilot, Antigravity, Mimo, Freebuff and Kiro CLI join Claude Code, Codex,
  Cursor, OpenCode and the shell in New Terminal, each with its unrestricted mode where the CLI has one.
- Settings › Agents: turn agents you don't use off (they leave New Terminal), see which CLI each
  agent runs and its version, and point one at another CLI or back to automatic lookup.
- Install, update and uninstall agent CLIs from Settings › Agents: Alethe offers the ways that work
  on your Mac (the vendor's install script, Homebrew or npm), shows the exact command and its output,
  and checks the result. A newer release is flagged next to the installed version.
- File › New Terminal Like Last (⌥⌘T) opens another terminal just like the last one you created,
  without the sheet. New Terminal also lets you pick which of the project's grids it joins.
- New Terminal has a Model field: pick one of the models the agent reports (Cursor, OpenCode,
  Antigravity) or Claude Code's aliases, or type any model id; leave it empty for the agent's default.
- OpenCode, Antigravity and Cursor terminals now pick up their conversation again after Alethe
  restarts, like Claude Code and Codex. Resume Previous Conversations also covers Antigravity.
- History › Conversations… (⌘Y) lists your past Claude Code and Codex conversations for the project
  or for all projects, with titles, dates and sizes. Open one to pick it up in a new terminal — or to
  jump to the tab where it is already open.
- Terminal › Session Cost… shows what an agent session used — tokens per model and the cost where it
  is known (Claude Code, and OpenCode's own figure; Codex shows tokens). Conversations shows the same
  for the conversation you select.
- Alethe now knows what each agent is doing — working, waiting for you, or done — from Claude Code's
  and Codex's own events (without touching your settings) and, for other agents, from their output.
  A Claude conversation that you `/clear` or `/resume` stays bound to its terminal.
- Agent terminals are named after their conversation in the sidebar, the lane and the title bar, and
  show what they are doing: a pulsing dot while working, a question bubble when they wait for you, and
  a dot when they finished while you were looking elsewhere.
- Notifications: when an agent finishes or needs your answer in a terminal you are not looking at,
  it shows up under the bell in the toolbar — and as a macOS notification when Alethe is in the
  background. Click one to jump to that terminal. Turn it off in Settings › General.
- Continue in the Other Agent… (Terminal menu or a terminal's menu) hands a Claude Code conversation
  to Codex, or the other way round: review and edit the context capsule — secrets are redacted — and a
  new terminal of the other agent picks the work up from it.
- AI Usage (toolbar gauge) shows Claude Code, Codex and Antigravity limits — each window, how full it
  is and when it resets — with the Codex plan and reset credits. Turn on a provider's toolbar pill to
  keep an eye on it, and get notified when a limit resets.
- Alethe keeps activity statistics — time with it open and in use, and time agents spent working, in
  parallel or in the background, per agent and project — on this Mac for Home. Settings › General clears
  them.
- Home (⇧⌘H or the house button in the toolbar): a greeting, a quick launch that starts an agent with a
  prompt in any project, recent projects, AI usage, a 13-week activity graph with your streak, where your
  time went (active, agents working, in the background) and notifications. Settings › General can open
  Alethe on Home.
- Home shows setup steps until they are done — install an agent, create a project, open a terminal, pick
  a look — each one a click away. Hide them, and bring them back from Help › Show Setup Steps.
- Dictation: press ⌥⌘E and speak — the words go into the focused terminal or field; press again to stop,
  or hold the keys and release. Transcription runs on this Mac (Apple's speech model, downloaded the first
  time) in the interface language; Esc cancels.
- Fixed: the agent choices on the empty workspace no longer squeeze into one row.
- Fixed: a terminal restored after relaunch could start with a stray `^[[O` (and odd arrow keys) because
  the previous program's focus-reporting and key modes carried over to the new one.
- Fixed: a restored agent terminal could open with lines of garbage such as `^[[?62;22;52c` and
  `ghostty 1.3.2`: replaying the saved output re-ran the previous program's terminal queries, and the new
  process echoed the answers.
- Fixed: a restored terminal no longer draws the new session over the old screen (Claude Code's header
  and prompt came out garbled); the old output moves into the history and the new session starts clean.
- Plugin foundation: built-in plugins can add sidebar tabs, commands, themes, pane kinds, sheets,
  settings pages and agent providers, use only the host features they declare, and are turned on or off
  with the choice kept after relaunch; a plugin that fails to start does not affect the others.
- Git layer: runs your own `git` for status, diffs, branches, commits, history and sync (pull, push and
  fetch with progress), and refreshes when the repository changes.
- Theme Pack plugin: the Dark Lemon, Orca, Ember and Golden Premium themes.
- Groundwork for Git review (not in the interface yet): commit graph lane layout, a merge analyzer that
  trial-merges two branches in a throwaway worktree and classifies each conflict, your open pull requests
  through `gh`, and a squash merge guarded by the reviewed head commit.
- Groundwork for the Todos plugin (not in the interface yet): global and per-project lists with tags, PR
  links, reordering, the editable JSONC template file, and a Pomodoro session that survives relaunch.
- Settings › Plugins lists the built-in plugins with version and capabilities, turns each on or off and
  shows a load error; the Theme Pack themes appear in the theme picker.
- Fixed: after a relaunch, an agent terminal (Claude Code, Codex…) no longer shows the previous run's
  screen stacked above the new one; only shell terminals bring their saved output back.
- Fixed: a terminal now starts at its pane's real size, so an agent's first screen no longer leaves
  fragments behind when it redraws, and a starting program no longer echoes `^[[I` / `^[[O` when the
  window gains or loses focus.
- Data is stored per profile in `~/Library/Application Support/com.kc1t.alethe.mac`.
