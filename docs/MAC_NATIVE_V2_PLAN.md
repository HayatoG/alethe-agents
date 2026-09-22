# Alethe for macOS — native rewrite plan (v2)

> Status: **Phase 1 in progress** — done: P1-2, P1-3, P1-1, P1-4; P1-5 WIP (see its notes). Next:
> finish P1-5, then P1-8 → P1-7 → P1-6 → P1-9 → P1-10 → P1-11 → P1-12 → P1-13. Branch: `mac-native-v2` (created from `origin/main` @ `75083e2`, v1.7.0).
> This branch never merges into `main` or any release branch, and no PR targets them. The native app
> will later move to its own repository (see §9.4).

## 1. Executive summary

The first native attempt (`AletheMac/`, branch `mac-native`) proved that a native Alethe is viable, but
it bound itself to the Tauri codebase: one Rust crate compiled two ways (294 `cfg(feature)` gates),
61 ad-hoc `*_json` UniFFI wrappers, and three generators that re-derived themes, strings and
migrations from React sources. Every upstream merge became a porting project, and parity fell to
30 done / 15 open plus 11 new upstream features mostly absent.

v2 is a **separate macOS product**, written **entirely in Swift**, that uses the Tauri app at
`origin/main` as a **behavioral specification**, not as shared code.

| Decision | Choice |
|---|---|
| Relationship to the Tauri app | Independent product, independent data; optional one-shot, read-only import of `projects.json` v9 |
| Core logic | Ported to Swift services per domain (no Rust, no FFI) |
| Terminal | libghostty in `HOST_MANAGED` I/O mode (renderer + input) with a Swift-owned PTY host |
| UI | SwiftUI app shell + AppKit workspace pane host |
| Minimum OS | macOS 26 Tahoe; macOS 27 APIs behind `#available` |
| Plugins | Native Swift plugin API from day one; Git, Todos and Theme-pack are built on it |
| v1 scope | Full parity, including Orchestrator v2, Remote control, Spotify/Discord/9router, Graphify/ai-memory/GSD |
| Distribution | Outside the App Sandbox; Developer ID + notarization + Sparkle once the account exists |

Execution runs in 9 phases (§7). Phase 0 is a gated foundation + terminal spike; Phase 1 ships a
usable vertical skeleton; Phases 2–7 reach parity; Phase 8 is release engineering and extraction to
the new repository.

## 2. Source of truth and feature inventory

- **Reference:** `origin/main` @ `75083e2` (tag `v1.7.0`, 2026-09-20, plus README/CI commits). Recorded
  in `AletheNative/UPSTREAM_BASELINE` in Phase 0.
- **Size:** 290 commands in `src-tauri/src/lib.rs` `invoke_handler` across ~80 Rust modules; 13 Zustand
  stores (only `projectsStore` persists, to `projects.json` **v9**); ~110 user-facing features.
- `docs/FEATURES.md` lags the code (it lists 4 agents; the code has 11) — the matrix in §8 is built from
  the code, not from that file.

### 2.1 Persistence at upstream (the import contract)

- Root: `app_local_data_dir()`; `profiles.json` (`ProfilesIndex { version: 1 }`); per-profile folder
  `profiles/<id>/`.
- Per profile: `projects.json` (v9, migrations v2→v9 in `src/stores/projectsStore.migrations.ts`),
  `scrollback/<ptyId>.bin` (4 MiB cap), `activity-stats.json`, `orchestrator-jobs.json`, `spawn.log`,
  `spotify_tokens.json`, `github_sync.json`, `handoffs/`, `speech-models/`, `mcp/backups/`,
  `plugins/<id>/`, `plugin-data/<id>`, `plugins/state.json`.
- `projects.json` v9 top level: `version, groups, ungroupedOrder, projects, todos, activeProjectId,
  workspace{…}, preferences (~80 keys), cliPaths`. `Project`, `Terminal` (kinds: terminal, markdown,
  file, image, video, web, graphify, diff, orchestrator), `SubTab` and `Group` shapes are described in
  `src/lib/types.ts`.
- External files the app edits: `~/.claude.json`, `~/.claude/{agents,skills,projects}`,
  `~/.codex/config.toml` (comment-preserving), `~/.codex/sessions`, `opencode.json`, `.opencode/plugins`,
  `~/.cursor/mcp.json`, `~/.gemini`, `~/.agents`, and `.alethe/` inside repos.

### 2.2 Inventory by area

Each row: feature — upstream source (components/stores/libs) — commands — persisted data. Full IDs are
used in the parity matrix (§8).

**Home (HOME)**
- HOME-1 Dashboard (greeting, recent projects, quick actions, ASCII background) — `HomeView/index.tsx`,
  `ui/ascii-effect.tsx`, `lib/greeting.ts` — — — `preferences.alwaysStartOnHome`, `motionPreference`.
- HOME-2 Mini-terminal quick launch — `HomeView` → `createAgentTerminal` — `spawn_pty` — terminals.
- HOME-3 Activity graph / time analytics / usage strip — `ActivityGraph.tsx`, `TimeAnalytics.tsx`,
  `UsageStrip.tsx` — `get_activity_summary`, `get_multi_agent_activity` — `activity-stats.json`.
- HOME-4 Setup walkthrough — `SetupWalkthrough.tsx` — — — `preferences.setupWalkthrough*`.
- HOME-5 Notifications list — `uiStore.notifications` — — — memory.

**Workspace, panes and layouts (WS)**
- WS-1 Project containers (open many, collapse, fullscreen, reorder) — `WorkspaceView/*` —
  — — `workspace.containers`, `fullscreenContainerId`, `isolatedPaneId`.
- WS-2 Flat mode — `MainMenu` — — — `preferences.workspaceFlat`.
- WS-3 Layouts Auto/Spotlight/Sidebar/Custom grid — `lib/gridLayout.ts`, `lib/layoutPresets.ts`,
  `LayoutDesignerModal`, `GridCellHandles`, `useGridCellDrag`, `LayoutFooter` — — — `layoutMode`,
  `gridLayout`, `gridLayoutHistory` (project/group/workspace).
- WS-4 Named project grids (1.7) — `lib/projectGrids.ts`, `ProjectGrids.tsx`, `ProjectGridModal` — — —
  `project.grids`, `activeGridId`, `terminal.gridId`.
- WS-5 Workspace tabs, closed tabs, history (Ctrl+Tab, Alt+arrows) — `lib/workspaceNavigation.ts` — — —
  `workspace.tabs/closedTabs/history`.
- WS-6 Markdown pane — `MarkdownPane` — `read_text_file`, `write_text_file`, `watch_file` — file.
- WS-7 Image pane / WS-8 Video pane — `ImagePane`, `VideoPane` — — — `terminal.filePath`.
- WS-9 Diff pane — `DiffPane` — `git_diff` — —.
- WS-10 Focus mode — `FocusOverlay` — — — —.
- WS-11 Add content modal — `AddContentModal` — — — —.
- WS-12 Link viewer overlay — `LinkViewerOverlay` — `read_text_file`, `open_in_browser` — —.
- WS-13 Empty workspace launcher — `WorkspaceEmptyState.tsx` — — — —.
- WS-14 Disable terminal/project, suspend group — projectsStore slices — `suspend_pty` —
  `terminal.disabled`, `group.suspended`.

**Terminal (TERM)**
- TERM-1 Real PTYs (spawn/attach/write/resize/restart/kill, process tree) — `XTermView/useXtermSession.ts`,
  `TerminalPane`, `lib/terminalFactory.ts`, `terminalLifecycle.ts`, `spawnQueue.ts`, `mountQueue.ts` —
  15 `pty_*` commands + `get_pty_tree_info`, `kill_pty_tree_cmd` — `scrollback/*.bin`.
- TERM-2 Sub-tabs lane — `SubTabsLane`, `NewSubTabModal` — — — `terminal.tabs`, `laneVisible`.
- TERM-3 Search in terminal — `SearchAddon` — — — —.
- TERM-4 Smart copy/paste (text, images, files) — `read_clipboard_payload`, `write_clipboard_text` — —.
- TERM-5 Prompt history (Ctrl+↑/↓) — XTermView — — — localStorage `prompt-history:<ptyId>`.
- TERM-6 Clickable file/URL/image links (open in grid or browser pane) — `terminalLinks.ts` — — —.
- TERM-7 Terminal themes, font, unicode11 — `xtermThemes.ts`, `lib/themeTokens.ts` — — —
  `preferences.terminalTheme`.
- TERM-8 Restart overlay + "command not found" overlay — `TerminalPane` — `restart_pty` — —.
- TERM-9 Double Ctrl+C force-kill — `useXtermSession.ts` — `kill_pty` — —.
- TERM-10 Scrollback persistence + reattach — `pty.rs` — `attach_pty`, `clear_pty_scrollback` —
  `scrollback/*.bin`.
- TERM-11 `alethe` CLI shim (open a folder in the running app) — `lib/cliOpen.ts`,
  `useCliOpenRequests.ts` — `cli_shim_*`, `cli_take_pending_open` — —.

**Sidebar, projects and groups (SB)**
- SB-1 Project tree (groups, subgroups, projects, terminals), Normal and Clean styles —
  `ProjectSidebar/*`, `lib/sidebarDrag.ts` — — — groups, projects, `ungroupedOrder`.
- SB-2 New/edit project (clone from GitHub, restore from `.alethe/project.json`, git init, worktree
  settings, stack detection) — `NewProjectModal`, `EditProjectModal`, `EditProjectAgentSettings` —
  `clone_github_repo`, `read/write_project_marker`, `git_init`, `detect_project_stack`,
  `git_list_branches`, `worktree_*`, `discover_provider_models` — project fields.
- SB-3 Groups (new/edit/suspend, nested) — `NewGroupModal`, `EditGroupModal`, `SuspendGroupModal` —
  — — groups.
- SB-4 Export/import project config — `sidebarMenus.tsx` — `read/write_text_file` — file.
- SB-5 Live chat title + busy/done glyph — `useSidebarChatTitle.ts`, `agentCompletionMonitor.ts` —
  `get_claude_session_title`, `get_codex_session_title` — `SubTab.completionUnread`.
- SB-6 Open in VS Code / Finder / browser — `open_in_vscode`, `open_in_file_explorer`, `open_in_browser`.
- SB-7 Right sidebar (markdown docs/plans, GSD, MCP, PRs, plugin tabs) — `RightSidebar` — — —
  `rightSidebarVisible/Width`, `markdown-sidebar-history-v1`.
- SB-8 View placement of contributed tabs — `lib/viewPlacement.ts` — — — `viewPlacements`.

**Agents (AG)**
- AG-1 11 agent types (claude, codex, copilot, cursor, antigravity, opencode, mimo, freebuff, kiro,
  shell, wsl) — `lib/agentProviders.ts`, `agentCliPath.ts`, `agentRuntimeAdapter.ts`, `sessionLaunch.ts`.
- AG-2 Unrestricted flags per agent + `alwaysStartUnrestricted` — `UNRESTRICTED_FLAG`.
- AG-3 New-terminal modal (row stack, grid picker, 9router toggle, planner option, repeat last) —
  `NewTerminalModal` — — — `lastTerminalCreation`.
- AG-4 Launcher resolution + override — `find_cli_launcher`, `refresh_cli_launcher` — `cliPaths`.
- AG-5 Install/update/uninstall agent CLIs — `AgentInstall/*`, `useAgentInstall.ts` —
  `probe_install_toolchain`, `agent_cli_version` — —.
- AG-6 Enable/disable agents — Preferences → Terminal — — — `enabledAgents`.
- AG-7 Claude ↔ Codex handoff — `HandoffModal` — `prepare/materialize/complete_agent_handoff` —
  `handoffs/`, `SubTab.handoff`.
- AG-8 Agent hook bridge (Claude/Codex events) — `useAgentHookBridge.ts` — `agent_hooks_*`,
  `codex_hooks_config_write` — `~/.codex/config.toml`, Claude settings.
- AG-9 Model discovery per provider — `discover_provider_models`.

**Sessions (SE)**
- SE-1 Auto-resume Claude/Codex/OpenCode/Antigravity/Cursor sessions — `lib/sessionResume.ts`,
  `sessionDiscovery.ts`, `paneResume.ts`, `claudeSessionTracking.ts`, `sessionWatch.ts` —
  `snapshot_*_sessions`, `create_cursor_chat` — `SubTab.sessionId`, localStorage `active-sessions`.
- SE-2 Resume last session — `lib/resetLastSession.ts`.
- SE-3 Claude history + Recent chats — `ClaudeHistoryModal`, `RecentChatsModal` —
  `list_claude_sessions`, `snapshot_codex_sessions`.
- SE-4 Session/transcript cost — `get_session_cost`, `get_transcript_cost`, `get_model_pricing`.

**Git, diff and Merge Center (GIT)**
- GIT-1 Git Control (status, stage, commit ⌘↩, pull/push, discard) — `plugins/git-control/*` —
  `git_status/stage/unstage/commit/discard/pull/push/init`.
- GIT-2 Commit graph (cherry-pick, revert, reset, branch from commit) — `GitGraph*.tsx` —
  `git_log_graph`, `git_show_commit_*`, `git_cherry_pick_commit`, `git_revert_commit`,
  `git_reset_to_commit`, `git_create_branch_from_commit`.
- GIT-3 Incoming/outgoing — `IncomingOutgoing.tsx` — `git_incoming_outgoing`.
- GIT-4 Worktree isolation per agent — `worktree_provision/list/remove/cleanup/lock/unlock/…` —
  `autoWorktree`, `worktreeMode`, `worktreeAgentId`.
- GIT-5 Merge Center (analyze, prepare, validate, finalize, abort, rebase, force cleanup, health probe,
  contract check) — `SidebarMergePanel`, `MergeTree`, `MergeCenterModal`, `BranchTestingModal`,
  `ConfirmWorktreeCommitModal`, `mergeStore` — `merge_*`, `worktree_*`, `git_diff_summary`,
  `run_validation`, `health_probe`, `contract_check`, `read_gsd_procedure` — `validationCommands`,
  `healthCheck*`, `orphanWorktrees`, `mergePostAction`, `conflictAgentProvider/Model`.

**Pull requests (PR)**
- PR-1 Open PRs tab (`gh search prs --involves=@me`) + send to Todo — `PullRequestsSidebar` —
  `github_pr_list_mine` — todo `prUrl/prNumber/prRepo`.
- PR-2 PR AI review + squash merge with SHA guard — `PullRequestReviewModal`, `lib/pullRequestMerge.ts` —
  `github_pr_find`, `github_pr_merge` — `reviewAgentProvider/Model`.

**Files (FS)**
- FS-1 File explorer (tree, rename, delete, preview, drag into grid, git badges, icons) —
  `FileExplorer.tsx`, `fileExplorerGit.ts`, `FileIcon.tsx`, `lib/fileDrag.ts` — `list_directory`,
  `rename/delete_filesystem_entry`, `read_text_file`, `git_status`.
- FS-2 In-app folder browser — `FsBrowserModal` — `browse_directory` (native: `NSOpenPanel`).

**Browser (BR)**
- BR-1 Web pane (tabs, reload, resource modes) — `WebPane/*`, `lib/browserUrl.ts`,
  `browserResourcePolicy.ts` — `browser_pane_*` — `terminal.url`, `browserConfig`.
- BR-2 "Agent opened a page" offer — `useAgentBrowserOffers.ts`.
- BR-3 Playwright MCP shared/dedicated browser — `browser_session_*`, `playwright_mcp_config_path` —
  `playwrightBrowserMode`, `playwrightDedicatedHeadless`.

**MCP, Skills, Plugins, Agent library (EXT)**
- EXT-1 MCP manager (scan all agents incl. Cursor, add from registry, enable/disable, health, sync,
  reveal env, backups) — `McpPanel/*`, `McpManagerModal`, `mcp/AddServerFlow`, `McpIntroModal`,
  `mcpStore` — `mcp_*`, `mcp_registry_search`, `mcp_health_check` — `mcpDefaultScope`,
  `mcp/backups/`, `mcp/registry-cache.json`.
- EXT-2 Skills browser — `mcp/SkillsBrowser.tsx`, `lib/skills*.ts` — `skills_scan/detail/uninstall`.
- EXT-3 Plugin system (install, import dir, enable, catalogue, storage, capabilities) — `lib/plugins/*`,
  `PluginsPage`, `PluginCatalog`, `ContributedModals`, `ContributedView` — `plugins_*`, `plugin_*` —
  `plugins/`, `plugin-data/`, `catalog-cache.json`.
- EXT-4 Agent library (subagent templates) + economy agents — `lib/agentLibrary.ts`,
  `AgentLibraryPalette`, `useInstalledAgents` — `list_installed_agents`, `install_agent`,
  `uninstall_agent`, `economy_agents_enabled`, `set_economy_agents` — `~/.claude/agents`.
- EXT-5 Graphify (graph MCP, view, snapshots, rollback) — `graphifyStore`, `GraphifyView` — `graphify_*` —
  `project.graphifyEnabled`, `.alethe/`.
- EXT-6 ai-memory MCP wiring — `ai_memory_*`.
- EXT-7 GSD Sync (OpenCode child sessions feed, planning status) — `GsdSyncActivityView`,
  `useGsdSyncSessions.ts` — `opencode_export_session`, `read_gsd_child_*`, `start/stop_gsd_watcher`,
  `gsd_opencode_plugin_write`, `read_planning_status`, `list_project_plans` — `gsdSyncModelChain`.

**Orchestrator (ORC)**
- ORC-1 Planner board (workers, runs, approvals, steering, diffs, apply worktree, media cards, quota
  warnings, subagents) — `OrchestratorPane/index.tsx`, `lib/orchestrator*.ts`, `lib/agentFitness.ts`,
  `useOrchestratorQuotaWarnings.ts` — `orchestrator_*` — `orchestrator-jobs.json`,
  `project.paneGroups[kind=orchestration]`.
- ORC-2 MCP tools for agents (`alethe_delegate/check/status/steer/send/cancel/answer/diff/release`) —
  `src/bin/alethe-orchestrator-mcp.rs`, `orchestrator_core.rs` (2380 LOC).
- ORC-3 Scheduler, telemetry, planning audit (Preferences → Multiagent) — `MultiagentPage`,
  `schedulerStore` — `get_scheduler_tasks`, `trigger_scheduler_tick`, `cancel_task`, `publish_event`,
  `get_telemetry_*`, `planning_audit_*`, `get/set_planning_autocommit`.

**Usage, stats and resources (USE)**
- USE-1 Claude/Codex/Antigravity usage pills + AI Usage modal + Codex reset credit —
  `lib/*UsageCache.ts`, `AiUsageModal`, `ResetCreditModal`, `limitResetWatch.ts` — `get_*_usage`,
  `consume_codex_reset_credit`, `get_opencode_usage_summary` — `topbarShow*Usage`, `notifyOnLimitReset`.
- USE-2 Activity tracking — `activityTracker.ts`, `activityCache.ts` — `record_activity_samples`,
  `get_claude_activity`, `clear_activity_stats` — `activity-stats.json`.
- USE-3 RAM indicator, memory analytics, resource supervisor (hibernate idle, priorities, pressure) —
  `useResourceSupervisor.ts`, `MemoryAnalyticsModal`, `lib/ptyVisibility.ts` — `get_memory_stats`,
  `get_runtime_snapshot`, `get_resource_metrics`, `set_resource_policy`, `update_pty_runtime_meta`,
  `set_pty_visible/priority` — `resourcePolicy`, `spawnConcurrency`.
- USE-4 Crash watch / last crash report — `get_last_crash_report`, `get_job_guard_status` —
  `last_session.json`.

**Appearance (UI)**
- UI-1 16 built-in themes + 4 theme-pack themes, ~87 CSS tokens — `lib/themes.ts`, `themeTokens.ts`,
  `ThemePickerModal`, `AppearancePage` — `uiTheme`.
- UI-2 Visual style normal/clean — `visualStyle`.
- UI-3 Motion preference (animated/reduced) — `motionPreference`.
- UI-4 App icon themes (4) — `appIconTheme`.
- UI-5 UI zoom (⌘+/−/0) — `uiZoom`.
- UI-6 Window opacity — `set_window_opacity` (Win32 only upstream).
- UI-7 Title bar / topbar config (RAM, usage pills, remote counter, pomodoro, 9router, profile) —
  `TitleBar`, `TopbarSettingsModal` — `topbarStyle`, `topbarShow*`.
- UI-8 i18n EN + pt-BR — `lib/i18n/*` — `language`.

**Settings, profiles, backup (SET)**
- SET-1 Preferences (10 pages) — `PreferencesModal` + `preferences/*`.
- SET-2 Feature toggles (browser, graphify, mcp, playwright, orchestrator, gsdSync, aiMemory, prs) —
  `lib/features.ts` — `enabledFeatures`.
- SET-3 Profiles — `ProfilesModal`, `UserProfile`, `lib/profile.ts` — `list/create/rename/delete/…
  _profile(s)`, `export_profile_backup` — `profiles.json`.
- SET-4 Backup/import, reset, factory wipe, logs — `export_backup`, `import_backup`, `reset_app_data`,
  `wipe_all_app_data`, `export_logs`, `open_logs_folder`, `open_data_folder`, `open_spawn_log`.
- SET-5 GitHub gist sync — `SyncModal` — `github_sync_*` — `github_sync.json`.
- SET-6 Cloud sync — `lib/cloudSync.ts` — `cloud_sync_*` (server default `127.0.0.1:8787`).
- SET-7 Onboarding (profile/GitHub, style, agents, features, 9router, MCP) + Welcome — `OnboardingModal`,
  `onboarding/*`, `WelcomeModal` — `onboardingDone`, `accountCreated`, `displayName`.
- SET-8 Updater + What's New — `lib/updater.ts`, `UpdateModal`, `WhatsNewModal`, `changelogData.ts`.
- SET-9 Notifications (desktop + toasts, 5 s dedupe, actionable) — `lib/notifications.ts`.
- SET-10 Find/Jump (commands + terminals) — `FindJumpModal`.
- SET-11 Audit center (errors, export JSON) — `AuditModal`, `lib/auditLogger.ts` —
  `record_frontend_error`, `record_app_event`.
- SET-12 Close confirmation + quit coordination — `useCloseConfirmation.ts`, `closeCoordinator.ts` —
  `quit_app`.
- SET-13 Keyboard shortcuts (see §6.3 for the Mac mapping).

**Widgets and peripherals (PER)**
- PER-1 Todo list (tags, per-project, PR links) — `plugins/todos/*` — `ensure_todo_template` — plugin
  storage / external `todos.jsonc`.
- PER-2 Pomodoro (todo panel + title pill, focus todo) — `PomodoroWidget`, `pomodoroStore` —
  `pomodoro*Minutes`, `pomodoroSession`.
- PER-3 Spotify Now Playing — `useNowPlaying.ts`, `NowPlayingWidget`, `SidebarNowPlaying` —
  `spotify_*` — `spotify_tokens.json`.
- PER-4 Discord Rich Presence — `useDiscordPresence.ts` — `set/clear_discord_presence`.
- PER-5 9router routing — `Router9/*`, `useRouter9*.ts` — `router9_*` — `preferences.router9`,
  `SubTab.useRouter9`.
- PER-6 Dictation (Parakeet, ⌘E, toggle/hold) — `DictationButton`, `lib/speech/*`,
  `VoiceDictationSection` — `speech_*` — `dictation*`, `speech-models/`.
- PER-7 Remote control (QR pairing, read-only, shell input, device limits, Tailscale, PWA client) —
  `RemoteControlModal`, `RemoteControlPage`, `useRemoteControlService.ts`, `src-tauri/src/remote/` —
  `remote_control_*` — `remote*`, `terminal.remoteShared`.

**Experimental / gated upstream (EXP)**
- EXP-1 Agent Canvas POC + TokenHud — `AgentCanvasPOC/*`, `TokenHud`, `agentCanvasStore`.
- EXP-2 Agent Sandbox (disabled: `AGENT_SANDBOX_ENABLED=false`) — `codex_app_server_*`.
- EXP-3 Native Ghostty backend in the Tauri app — `GhosttySurface`, `ghostty_*`.

## 3. Lessons from the first attempt

Evidence is from `git log main..mac-native` and the old docs (`PLANO_MIGRACAO_MAC_SWIFT.md`,
`MAC_PARITY_BACKLOG.md`, `MAC_PARITY_POS_MERGE.md`, `MELHORIAS_MAC.md`, `PROMPT_CONTINUACAO_MAC.md`).

**What worked**
1. The Phase-0 gate: Ghostty inside SwiftUI plus an FFI throughput benchmark before building features.
   Batching output before crossing any boundary mattered (14 MB/s unbatched vs 315 MB/s batched).
2. Hosting Ghostty in a real view hierarchy fixed focus and backing-scale bugs that the Tauri overlay had.
3. Pure-logic models with XCTests (GridMath, WorkspaceLayout, SessionLaunch, PromptHistory,
   WorkTimeTracker…) — the bulk of 142 tests; several real parity bugs were caught this way
   (`3269464` extraArgs dropped, `f7ab37d` double-credited work time).
4. Failing the strings build on pt-BR drift.

**What went wrong, and the rule v2 adopts**
1. `scaleEffect` zoom displaced AppKit hit-targets (`07406f2`) → zoom scales **font and metric tokens**
   only; hit-target UI tests guard it (§7 P0-9). On macOS 27 the displacement no longer reproduces
   (P0-9 pins that); the rule stays.
2. Global shortcuts stole terminal keys: Esc (`99fa717`), Shift+Tab (`8a4f067`) → app shortcuts only as
   ⌘ key equivalents (§6.3).
3. ⌘W lost to the shim's local key monitor (`937d324`, a 35-file debugging commit) → no local event
   monitors in the terminal layer; key routing designed and tested up front (P0-6).
4. An overlay swallowed clicks because a gesture was attached after `.position()` (`490aa64`) →
   hit-target tests for every overlay.
5. Two instances reaped each other's terminals → single-instance guard + per-instance PTY ownership.
6. Keychain prompts from unstable dev signing blocked the UI (`cb6f6ec`) → one stable local signing
   identity from Phase 0.
7. Generated artifacts (themes, strings, `migrations.js`) went stale after the merge (`31de59b`) → no
   continuous generation from React; Swift is the source of truth.
8. FFI grew ad hoc to 61 stringly `*_json` exports → no FFI at all; typed Swift services.
9. Orphan strings (2256 keys shipped, ~21% referenced; 169 `merge.*`) → strings land only with code;
   an orphan-key test fails the build.
10. Merge tax on Rust (294 `cfg` gates, modules made Tauri-only) → no shared code with upstream.
11. The plan said "PTY stays in Rust", but Ghostty silently took ownership → no scrollback, hibernation
    or remote. v2 uses `HOST_MANAGED` I/O so the app owns the PTY (ADR-2).
12. Terminal theming was never wired (Ghostty defaults) → theme → Ghostty config is a Phase 1 acceptance
    criterion.
13. Debug residue and committed `xcuserstate` → `.gitignore` from P0-1; no disabled-code comments.
14. Docs drift (`Scripts/` vs `scripts/`, contradictory commit rules) → one plan doc, one backlog.
15. A browser pane that claimed to honor config but had an empty `updateNSView` → acceptance criteria
    name observable behavior.
16. Spawn allow-list disagreed with the agent map → one `AgentRegistry` is the only source.
17. Scope creep: shallow showcase features (canvas, ASCII backdrop, token HUD) shipped while Cmd+F,
    scrollback and IME stayed open → phases order depth before breadth.
18. Three paths to read one schema (`ProjectsDocument`, `ProjectsFile`, JSC) → one Codable model per
    schema version.
19. Tests depended on a prebuilt Rust staticlib → the test suite runs from a clean checkout with
    `xcodebuild test` only.

## 4. Asset reuse decisions

| Asset (branch `mac-native`) | Decision | Justification |
|---|---|---|
| Rust core + UniFFI (`ffi.rs`, `host.rs`, `core_events.rs`, `core_runtime.rs`, generated bindings) | **Discard** | Swift-only product; this layer caused the merge tax. |
| Ghostty ObjC shim (849 LOC) + `AletheGhostty` (171) | **Rewrite in Swift**, keep the knowledge | Keep dead-key handling (UCKeyTranslate), clipboard callbacks, OPEN_URL, focus handling. Fix the global 60 Hz timer (use `NSView.displayLink` per surface), the global app/config, the missing theme/search, and test hooks mixed into the production API. |
| libghostty binary (prebuilt `Lakr233/libghostty-spm` `storage.1.2.5`) | **Keep the API, replace the supply** | Its header exposes `GHOSTTY_SURFACE_IO_BACKEND_HOST_MANAGED`, `ghostty_surface_write_buffer`, `receive_buffer`/`receive_resize` callbacks and search actions. Built locally from pinned sources by `Vendor/ghostty/build.sh` (P0-5, done). |
| `generate-themes.mjs` | **Discard as a generator; use once** | One-shot conversion (P0-3) of `theme.css` + `themes.ts` + `xtermThemes.ts` ANSI palettes into Swift; the output becomes hand-owned source. |
| `generate-strings.mjs` | **Discard** | Strings are added with each feature into `.xcstrings`; no bulk import. |
| `generate-migrations-bundle.mjs` + `LegacyMigration.swift` (JSC) | **Discard** | Replaced by a Swift `TauriImporter` for v9 only (P1-12). |
| `PomodoroState` (174 LOC, 7 tests) | **Rewrite**; reuse tests as spec | Its persisted shape diverged from upstream (no `focusTodoId`, different fields). |
| `UIZoom` + `BrandFonts` | **Rewrite** | Keep the principle; replace the `nonisolated(unsafe)` static with an environment value that scales fonts **and** metric tokens (fixed widths did not scale before). |
| Kit pure-logic models (GridMath, WorkspaceLayout, SessionLaunch, AgentCommand, PromptHistory, WorkTimeTracker, NavigationHistory, JumpSearch) | **Reuse selectively** | Copy, review against the v1.7.0 TS, adapt to the new schema; keep their tests. |
| `AppStore` (1400), `ContentView` (1025), `WorkspaceAreaView` (599) | **Discard** | God objects. |
| `make-app.sh`, `make-dmg.sh`, `sign-dev.sh` | **Rewrite** | `xcodebuild archive` → export → DMG, hardened runtime, entitlements, later `notarytool` + staple + Sparkle. |
| `smoke-clicks` (AX + CGEvent helpers) | **Reuse the technique** | Becomes an XCUITest hit-target suite (P0-9); the AX script stays as a release smoke check. |
| Core-spike targets (`AletheMacSpike`, `CoreSpikeSmokeTest`, `core-spike/`) | **Discard** | Dead weight. |

## 5. Architecture decisions

### ADR-1 — Core/UI boundary: Swift everywhere
- **Options:** (a) shared Rust core via UniFFI; (b) extract a Rust core crate shared with Tauri;
  (c) port everything to Swift.
- **Decision:** (c), by owner choice. Swift 6 language mode, strict concurrency.
- **Consequences:** the Rust/React code is a specification. Each port task cites the upstream module
  and ports its tests as golden cases. Services are `actor`s by domain; UI stores are `@MainActor`.
- **Library mapping:** git/gh → `Subprocess` wrapper around `Process` with async streams; rusqlite
  (read-only) → system SQLite3; keyring → Security.framework; notify → FSEvents; sysinfo → libproc /
  `host_statistics64`; reqwest → `URLSession`; tiny_http/tungstenite → Network.framework
  (`NWListener`, WebSocket); zip → Apple Archive or `ditto`; qrcode → `CIQRCodeGenerator`;
  toml_edit → a small comment-preserving TOML table editor with golden tests; sherpa-onnx → Apple
  SpeechAnalyzer (owner decision, §11); OAuth callbacks → `ASWebAuthenticationSession` or loopback
  `NWListener`.
- **Third-party dependencies (allow-list):** libghostty and libghostty-spm's `GhosttyKit` +
  `GhosttyTerminal` (MIT, built from pinned sources by `Vendor/ghostty/build.sh`), its transitive
  `MSDisplayLink` (MIT, pinned `exact: 2.2.0`), Sparkle. Anything else needs an ADR.

### ADR-2 — Terminal: libghostty (HOST_MANAGED) + Swift PTY host
- **Options:**
  - libghostty surface owning its PTY (first attempt): best rendering, but no scrollback persistence,
    hibernation or remote tap.
  - SwiftTerm: pure Swift, trivially host-fed, but a CPU/CoreText renderer and weaker throughput.
  - libghostty in `HOST_MANAGED` mode: Metal renderer, Ghostty's input/IME/search, and the host owns
    I/O.
- **Decision (confirmed by the P0-6 gate):** libghostty in `HOST_MANAGED` mode, driven through
  libghostty-spm's `GhosttyTerminal` Swift wrapper (AppKit view, `NSTextInputClient`, key handling,
  host-managed session bridge) — adopted instead of writing our own ~1k-LOC shim, since it passed every
  gate. Alethe owns everything around it (`AletheTerminal`). SwiftTerm stays only as a documented
  fallback.
- **Design:**
  - `PTYHost` (actor): `forkpty` with a clean environment, login shell resolution, process group,
    `kqueue` `NOTE_EXIT`, a ring buffer (4 MiB) flushed to `scrollback/<id>.bin`, hibernation
    (terminate and later resume the agent session), priorities, and a tap API for remote control and
    the orchestrator.
  - Output is batched (≥ 16 KiB or one frame) before `ghostty_surface_write_buffer`.
  - Input from `receive_buffer` goes to the PTY; `receive_resize` drives `TIOCSWINSZ`.
  - One `ghostty_app` per process, one config per theme; per-surface rendering driven by
    `NSView.displayLink`.
  - IME/CJK via a real `NSTextInputClient`; ⌘F search via the header's search actions; links via
    OPEN_URL + hover.
  - Terminal theme: the Alethe theme's ANSI palette + font are written into a Ghostty config.
- **Risk:** `HOST_MANAGED` is a patch maintained by `Lakr233/libghostty-spm` (MIT), not upstream
  Ghostty. P0-5 builds it from pinned sources (libghostty-spm `b7f888e` + Ghostty `3c47ca1`); moving the
  pin forward is a deliberate task that re-runs the P0-6 checks.

### ADR-3 — UI: SwiftUI shell + AppKit pane host

| Area | Technology | Why |
|---|---|---|
| App lifecycle, menus, shortcuts, Settings | SwiftUI `App`, `Commands`, `Settings` scene | Standard Mac behavior for free |
| Sidebar | `NavigationSplitView` + `List(.sidebar)`, `Transferable` drag & drop (incl. Finder) | Source-list material, keyboard navigation, VoiceOver |
| Toolbar, pills, search | `.toolbar` (NSToolbar, Liquid Glass) | Integrated title bar |
| Inspector (agent details) | `.inspector` | Native trailing column |
| Sheets, popovers, Home, Git/MCP/PR/Orchestrator panels | SwiftUI | Fast iteration |
| Workspace pane area | **AppKit** `PaneHostView` (NSView) owning terminal/web surfaces; SwiftUI headers via `NSHostingView` | Metal surfaces are never recreated by SwiftUI identity changes; splits/reorder animate with interruptible Core Animation springs |
| File explorer tree | SwiftUI `List` with `OutlineGroup`; `NSOutlineView` if it misses the performance budget | Large trees |
| Web pane | `WKWebView` (SwiftUI `WebView` on 26+ where it fits) | Replaces the CDP engine |

Known SwiftUI-on-macOS limits the design avoids: representable identity churn, weak first-responder
control, key-equivalent conflicts, and large-list performance.

### ADR-4 — State and persistence
- Observation: `@Observable @MainActor` stores per domain (`ProjectsStore`, `WorkspaceStore`,
  `PreferencesStore`, `TerminalsStore`, `GitStore`, `UsageStore`, …). No god object; stores talk
  through services, not through each other's internals.
- `DocumentStore<Document: Codable & Versioned>`: load → migrate through a chain of pure
  `(vN) -> vN+1` functions → validate. Before migrating, back up to `<name>.v<N>.bak`. Writes are
  debounced (300 ms), sequence-guarded, and atomic (`Data.write(options: .atomic)`, i.e. tmp → rename).
- Data layout: `~/Library/Application Support/<bundle-id>/profiles/<id>/workspace.json`,
  `preferences.json`, `scrollback/`, `activity-stats.json`, `orchestrator-jobs.json`, … Secrets in the
  Keychain. `UserDefaults` only for per-machine window state.
- No compatibility with Tauri data, except `TauriImporter`: reads v9 from the Tauri data dir,
  read-only, maps groups/projects/terminals/preferences it understands, and reports what it skipped.
  Fixture tests with anonymized v9 files.

### ADR-5 — Design system
- `AletheDesign` module: `Theme` (semantic tokens from `theme.css` — bg/fg/accent/agent-*/status-*…
  plus a 16-color ANSI palette, cursor and selection), `Typography` (size → tracking/leading table,
  SF Pro for UI, the Alethe mono for terminals), `Metrics` (spacing/radius/sizes, all scaled by
  `uiScale`), `Motion` (named springs, §6.1), `Materials`.
- Themes: 16 built-ins stored as JSON resources in `AletheDesign` (every token resolved, no runtime
  cascade), decoded into `Theme` and validated at load and by tests; the 4 theme-pack themes ship the
  same JSON format as a data plugin (P4). Keeping hex values in data rather than Swift literals keeps
  the color lint simple: only `ThemeColor` may build colors from channels.
- Chrome (sidebar, toolbar, popovers) uses system materials/Liquid Glass tinted by the theme accent;
  content surfaces (panes, terminal, lists) use theme tokens. No gradients; a contrast test runs per
  theme.
- Lint (unit test over sources): no `Color(red:…)`, `Color(hex:)`, `#colorLiteral`, `LinearGradient`,
  `RadialGradient` or `AngularGradient` outside `AletheDesign`.

### ADR-6 — Internationalization
- String Catalogs (`.xcstrings`) with generated symbols (Xcode 26+); EN is the source language, pt-BR
  required.
- Keys are dotted identifiers (`sidebar.projects.title`) with an explicit `en` value, used as
  `Text("key", bundle: .module)` / `String(localized: "key", bundle: .module)`. Non-translatable text
  (product names, agent CLI names, user data) uses `Text(verbatim:)`.
- `Scripts/check-strings.py` runs as the app's first build phase and in `Scripts/test.sh`. It fails on:
  a key without a translated `en` and `pt-BR` value, an orphan key (never referenced by its module's
  Swift sources), a dotted key used in code but missing from the catalog, and plain-text literals passed
  to `Text`/`Label`/`Button`/`help`/… The app target sets `ENABLE_USER_SCRIPT_SANDBOXING = NO` because
  the gate reads every catalog and Swift source.

### ADR-7 — Project structure and build
- `AletheNative/` (self-contained; no symlinks or paths into `src-tauri/`):
  - `AletheNative.xcodeproj` with folder-synchronized groups.
  - `Packages/AletheKit` — local SwiftPM package with targets: `AletheFoundation` (subprocess, FS
    watch, atomic files, Keychain, logging), `AletheModel` (Codable domain + migrations),
    `AletheDesign`, `AletheTerminal` (PTYHost, TerminalEngine, Ghostty engine), `AletheAgents`,
    `AletheGit`, `AletheIntegrations` (MCP, skills, graphify, ai-memory, Spotify, Discord, 9router),
    `AletheOrchestrator`, `AlethePluginKit`, `AletheRemote`.
  - App target `Alethe` (feature UI in folders: Home, Workspace, Sidebar, Git, PRs, Files, MCP,
    Orchestrator, Settings, Onboarding, HUD).
  - CLI targets: `alethe` (open-folder shim) and `alethe-orchestrator-mcp` (stdio MCP server).
  - `Vendor/` (libghostty build script + checksum), `Scripts/`, `Tests/` (unit, UI, performance),
    `CHANGELOG.md`, `UPSTREAM_BASELINE`.
- Toolchain: Xcode 27, Swift 6.4, deployment target macOS 26.0. APIs from macOS 27 behind
  `if #available(macOS 27, *)`, adopted after a P0 audit of the SDK diff.
- `Scripts/build.sh`, `Scripts/test.sh` wrap `xcodebuild`; the suite runs from a clean checkout.

### ADR-7a — macOS 27 APIs adopted (P0-7 audit of the Xcode 27 SDK)

Many new APIs are annotated `@available(anyAppleOS 27, *)` rather than `macOS 27`; both forms were
searched. Every adoption is behind `if #available(macOS 27, *)` (or `anyAppleOS 27`) with the macOS 26
behavior as fallback — a 27-only API may improve a feature but never be required for it.

| API (macOS 27) | Use in Alethe | Task | macOS 26 fallback |
|---|---|---|---|
| `reorderable()`, `reorderContainer(for:itemID:in:isEnabled:move:)`, `ReorderDifference` | Sidebar reorder across groups, tab/pane lists | P1-4, WS-5 | `onMove` + `Transferable` drop delegates |
| `ToolbarItemVisibilityPriority(lowerThan:/higherThan:)`, `contentMarginsRemoved(_:)` | Dense toolbar: which pills overflow first; custom pill chrome | P1-1, UI-7 | default priorities; standard margins |
| `View.alert(error:actions:)` | Surfacing process/agent errors from optional `Error` state | P1 onward | `alert(isPresented:)` + stored error |
| `GeometryProxy.concentricCornerRadii`, `NSView.cornerConfiguration` / `NSViewCornerRadius.containerConcentric` | Panes and cards concentric with the window's glass corners | P1-6 | fixed `Metrics.Radius` |
| `NSGlassEffectView.effectIsInteractive` | Interactive glass on HUD pills that host controls | P3 USE-1, P2 | non-interactive glass |
| `NSToolbarItemGroup.role = .tabs`, `NSSegmentedControl.role` | Mode switchers (Home/Workspace, inspector modes) | P1-1 | plain segmented control |
| `NotificationCenter.MainActorMessage` typed notifications (`NSWindow.DidBecomeKeyMessage`, `NSSplitView.DidResizeSubviewsMessage`, …) | Concurrency-safe window/split observation in the pane host | P1-6 | selector/closure observers |
| Observation `withContinuousObservation(options:apply:)` | Bridging `@Observable` stores to AppKit views (pane host) | P1-6 | re-registering `withObservationTracking` |
| `withTaskCancellationShield(operation:)` | Guaranteed PTY teardown / scrollback flush on cancellation | P2 TERM-10 | detached cleanup task |
| System `FileDescriptor.pipe(options:)` (`O_NONBLOCK`, `O_CLOEXEC`) | Pipes for `git`/`gh`/agent CLI subprocesses | P3–P4 | `pipe()` + `fcntl` |
| Foundation `ProgressManager` / `Subprogress` | Progress trees: agent installs, Merge Center stages, model downloads | P3–P4 | `Progress` |
| `EnvironmentValues.systemPrefersReducedResourceUsage` | Resource supervisor: throttle polling/animation | P2 USE-3 | own policy only |
| Speech `CaptureInputSequenceProvider`, `AnalyzerInputConverter` | Dictation: mic → SpeechTranscriber without manual AVAudioEngine | P3 PER-6 | AVAudioEngine tap + format conversion |
| `NSStatusItem` expanded interface (`expandedInterfaceDelegate`) | Optional menu-bar agent monitor (post-v1 idea) | backlog | — |
| `NSRefreshController` (`NSScrollView.refreshController`) | Pull-to-refresh on PR/session lists (touch/trackpad) | P4 PR-1 | refresh button only |
| `NSScrollView.isTouchScrollingEnabled` and touch-gesture APIs | Verify terminal/list scrolling on touch-capable Macs | P2 | n/a |

Not adopted: the new SwiftUI document model (Alethe is not document-based), `TabView` sidebar
additions (the sidebar is a `NavigationSplitView` list), FoundationModels (no on-device agent in
scope), WebKit JS-handle/DOM-snapshot APIs (revisit with BR-3 browser automation). Nothing new in
CoreTransferable, ExtensionKit, UserNotifications or `NSTextInputClient`; there is no `Subprocess`
module in the SDK (P3 wraps `Process`/`posix_spawn` itself).

### ADR-8 — Distribution
- **No App Sandbox:** the app spawns arbitrary CLIs with `forkpty`, reads/writes `~/.claude`, `~/.codex`
  and arbitrary repos, and runs local servers (hooks, MCP, remote). Not a Mac App Store product.
- Hardened runtime from day one. Entitlements: none beyond hardened-runtime defaults unless proven
  necessary; usage strings for microphone and speech recognition.
- Until a Developer ID account exists: one stable, self-signed local signing identity (keeps Keychain
  ACLs stable), and a dev flag that disables Keychain reads.
- Release (Phase 8): Developer ID, `notarytool` + staple, Sparkle 2 (EdDSA; appcast on the new
  repository's releases), DMG.

### ADR-9 — Native plugin API
- `AlethePluginKit`: versioned Swift protocols. `AlethePlugin` (manifest: id, version, capabilities)
  with `activate(context:)`. Contribution points mirror upstream: sidebar tab (view), command (palette
  and menu), theme, pane kind, sheet/modal, agent provider, settings page, storage.
- Capabilities are declared and enforced by the host API surface (e.g. no raw PTY write or filesystem
  delete without a capability).
- Built-ins (Git Control, Todos + Pomodoro, Theme-pack) are registered statically and use only the
  public API (dogfooding).
- Third-party loading: **ExtensionKit** app extensions (owner decision, §11): out-of-process,
  sandboxed, remote UI via `EXHostViewController`, crash-isolated. Rejected: in-process bundles (they
  require `disable-library-validation` and share the app's address space and permissions). The P4
  spike validates the flow end to end.

### ADR-10 — Keyboard routing
- App shortcuts only through SwiftUI `Commands` / menu key equivalents using ⌘ (mapping in §6.3).
- Never bind Esc, Shift+Tab, Option+arrows, or Ctrl+letter as global key equivalents. Esc closes an
  overlay only when the first responder is not a terminal.
- No local `NSEvent` monitors in the terminal layer; the terminal view handles `keyDown`,
  `performKeyEquivalent` and `NSTextInputClient` itself. Ghostty's own keybinds are cleared
  (`keybind = clear`): a bound chord is claimed by the view before the menu bar sees it. Key routing is covered by UI tests (vim, Claude
  Code Shift+Tab, ⌘W, ⌘F, dead keys, IME).

## 6. Interaction and motion guide

Principles from the apple-design guidance, translated to SwiftUI/AppKit.

### 6.1 Rules
- **Response:** visual feedback on mouse-down (pressed styles via `ButtonStyle` `isPressed`); no
  artificial delays or debounces on the input path.
- **Direct manipulation:** drags track 1:1 and keep the grab offset; continuous updates during split
  resize, pane reorder and sidebar drag — never animate only at the end.
- **Springs by default:** `Motion.standard = .spring(response: 0.35, dampingFraction: 1.0)`;
  `Motion.quick = .spring(response: 0.25, dampingFraction: 1.0)`; `Motion.momentum =
  .spring(response: 0.35, dampingFraction: 0.8)` only after a gesture with momentum. In AppKit:
  `CASpringAnimation` built from the same response/damping. No fixed durations on user-interruptible
  interactions.
- **Interruptibility:** every transition can be grabbed and reversed; animate from the presentation
  value (CA `presentation()` layer; SwiftUI springs retarget from the current value). Input is never
  blocked during an animation.
- **Velocity handoff and projection:** on drag end, pass the release velocity into the spring and
  choose the snap target from `current + (v / 1000) * d / (1 − d)`, `d = 0.998`; the reverse/commit
  decision uses the velocity sign.
- **Rubber-banding** at bounds (min pane size, sidebar width limits, list ends):
  `(x * dim * 0.55) / (dim + 0.55 * |x|)`.
- **Spatial consistency:** panels and popovers leave the way they came, anchored to their origin
  (`.popover(attachmentAnchor:)`, sheets from the window, inspector from the trailing edge).
- **Materials and depth:** sidebar in the sidebar material, toolbar in Liquid Glass, popovers in their
  system material; hierarchy by material weight; scroll edge effects instead of 1 pt dividers; never
  stack translucent layers.
- **Typography:** SF Pro with size-specific tracking (tight for large titles, ~0 for body), leading
  inverse to size; zoom (⌘+/−/0) scales font and metric tokens together.
- **Accessibility:** Reduce Motion → cross-fades and no bounce; Reduce Transparency → solid surfaces;
  Increase Contrast → defined borders; VoiceOver labels for every control; full keyboard navigation
  (sidebar, panes, lists, sheets).
- **Mac-ness (Familiarity, Flexibility, Simplicity, Craft):** standard menus (File, Edit, View, Window,
  Help), standard shortcuts, multiple windows, Settings scene, Finder drag and drop, Quick Look,
  services, state restoration. Confirmation dialogs only for destructive, irreversible actions;
  otherwise undo.

### 6.2 Behavior per area
- **Home:** real data only (activity, usage, recent projects). Short staggered entrance (≤ 3 steps),
  none under Reduce Motion. Quick launch is a text field that expands in place.
- **Workspace / panes:** split resize is live and rubber-bands at min size; reorder lifts the pane
  (shadow + slight scale on mouse-down-and-move), neighbors reflow with `Motion.standard`, drop target
  chosen by projection. Focus mode zooms from the pane's frame and returns to it. Closing a pane
  collapses toward its neighbor; ⌘⇧T restores along the same path.
- **Sidebar:** reorder with a spring and an insertion gap; hover reveals row actions without layout
  shift; a folder dropped from Finder becomes a project with an anchored confirmation popover;
  busy/done glyphs change with a cross-fade, not motion.
- **Git / Merge Center:** stages (analyze → prepare → validate → finalize) show continuous status; long
  steps are cancelable; destructive steps (reset, discard, force cleanup) ask once.
- **PRs:** list updates in place; "send to Todo" animates the row toward the Todo tab (the direction of
  the outcome); review opens as a sheet from the row.
- **File explorer:** disclosure animates with `Motion.quick`; Space opens Quick Look; drag to a pane
  opens it there; rename inline.
- **MCP / Skills / Plugins:** list + detail; toggles apply instantly with undo; health checks show live
  status per server.
- **Orchestrator:** worker cards update live; approvals inline on the card; diffs open in the trailing
  inspector.
- **Settings:** the standard Settings window with toolbar tabs; changes apply immediately.
- **Onboarding:** short, skippable, keyboard-first; includes the optional Tauri import with a summary
  of what was imported.
- **HUDs (RAM, usage, pomodoro, remote, 9router):** toolbar pills; details in anchored popovers; values
  animate with numeric content transitions.

### 6.3 Shortcut mapping (upstream → Mac)

| Upstream | Mac | Action |
|---|---|---|
| Ctrl+T / Ctrl+Alt+T / Ctrl+Shift+T | ⌘T / ⌥⌘T / ⇧⌘T | New terminal / repeat last / reopen closed tab |
| Ctrl+W | ⌘W | Close pane (window when last) |
| Ctrl+P | ⌘K (and ⇧⌘P) | Find/Jump + commands |
| Ctrl+Shift+P / Ctrl+Shift+G | ⌘N / ⇧⌘N | New project / new group |
| Ctrl+Shift+A | ⇧⌘A | Add content |
| Ctrl+Shift+H | ⇧⌘H | Home ↔ workspace |
| Ctrl+1…9 | ⌘1…9 | Jump to project N |
| Alt+← / Alt+→ | ⌘[ / ⌘] | History back/forward |
| Ctrl+Tab / Ctrl+Shift+Tab | ⌃Tab / ⌃⇧Tab | Cycle workspace tabs (Mac-standard; delivered to terminal when it has focus and no tab exists) |
| Shift+Tab, Ctrl+PgUp/PgDn | ⌥⌘↑ / ⌥⌘↓ | Cycle terminals (Shift+Tab is left to the terminal) |
| Ctrl+B | ⌃⌘S | Toggle sidebar (standard) |
| Ctrl + / − / 0 | ⌘+ / ⌘− / ⌘0 | UI zoom |
| Ctrl+E | ⌘E is "Use Selection for Find" on Mac → dictation uses Fn-Fn / ⌥⌘D | Dictation |
| Ctrl+Enter (git) | ⌘↩ | Commit |
| Ctrl+↑/↓ (prompt history) | ⌥⌘↑/↓ inside the prompt | Prompt history — final binding decided in P2 with UI tests |
| — | ⌘F / ⌘G / ⇧⌘G | Terminal search |
| — | ⌘, | Settings |

## 7. Execution plan

**Workflow (non-negotiable, per task):** Implement → Test → Validate → Update docs + ai-memory → Commit → next task.
After every piece of work (including decisions and investigations), update the affected docs — this
plan's checkboxes, parity matrix (§8) and ADRs, `AletheNative/CHANGELOG.md`, feature docs — and record
the outcome in ai-memory (decisions, work state, gotchas, next steps). One task per
commit; tick its checkbox in the same commit. Commits have no co-author or tool signature. No push,
tag or release without the owner's explicit authorization at that moment. Every user-facing change
updates `AletheNative/CHANGELOG.md` `[Unreleased]` (owner decision, §11).

Sizes: **S** ≤ half a day, **M** 1–2 days, **L** 3–5 days (split anything larger).
Test kinds: **U** unit (Swift Testing), **UI** XCUITest, **HT** hit-target UI test, **P** performance
(XCTest metrics/signposts), **G** golden files ported from upstream tests.

### Phase 0 — Foundations and terminal spike (gate)

- [x] **P0-1 (S) Scaffold.** `AletheNative/` with Xcode project, `Packages/AletheKit`, app target,
  `Scripts/build.sh`/`test.sh`, `.gitignore` (xcuserdata, DerivedData, build outputs), `CHANGELOG.md`,
  `UPSTREAM_BASELINE` = `75083e2`. *Accept:* `Scripts/test.sh` passes from a clean clone; the app
  launches an empty window. *Tests:* U smoke.
  *Done:* hand-written `project.pbxproj` (objectVersion 77, folder-synchronized `Alethe/` group, local
  package reference); `AletheKit` starts with `AletheFoundation` (`AppIdentity`) and gains targets as
  their tasks begin; bundle id `com.kc1t.alethe.mac`, deployment target 26.0, string-catalog symbol
  generation on. Verified: 2 unit tests pass, the app launches a 900×532 "Alethe" window and quits.
  Finding for P0-2: ad-hoc signing (`CODE_SIGN_IDENTITY = -`) does not apply the hardened runtime.
- [x] **P0-2 (S) Stable dev signing.** Script to create/use one local identity; hardened runtime on
  (ad-hoc signing skips it — see P0-1). *Accept:* two consecutive builds keep the same designated
  requirement (`codesign -d -r-`) and `codesign -dv` shows the `runtime` flag.
  *Done:* `Scripts/dev-signing.sh` resolves the identity (`Alethe Dev Signing`, overridable with
  `ALETHE_SIGN_IDENTITY`; `--create` makes one; falls back to ad hoc with a warning) and `build.sh`
  passes it to `xcodebuild`. Verified: `flags=0x10000(runtime)`, identical designated requirement across
  rebuilds, `codesign --verify --strict` ok, app launches. *Gotcha:* a self-signed identity has no Team
  ID, so hardened-runtime library validation rejects any separately signed dylib — Xcode's
  `Alethe.debug.dylib` included. `ENABLE_DEBUG_DYLIB = NO` and all modules link statically; embedded
  frameworks (e.g. Sparkle) must wait for Developer ID signing (Phase 8).
- [x] **P0-3 (M) Design tokens + themes.** One-shot conversion of `theme.css`, `themes.ts`,
  `xtermThemes.ts` into `AletheDesign` (16 themes, tokens, ANSI); `Typography`, `Metrics`, `Motion`.
  Conversion script is kept under `Scripts/oneshot/` for audit, not run in the build. *Accept:* every
  upstream token has a Swift counterpart (U test with a token list); color lint test fails on a
  literal. *Parity:* UI-1 (data).
  *Done:* `Scripts/oneshot/convert-themes.py` → 16 `Resources/Themes/*.json` (71 color tokens, 3
  shadows, terminal palette with 16 ANSI colors; palettes that upstream leaves to xterm.js get its
  Tango defaults) + `ThemeToken.swift`. `ThemeColor`, `Theme`, `ThemeCatalog` (picker order, default
  `elite-indigo`, fallback `dark`), `Metrics` (UI scale 0.8–1.5 applied to space/radius/size/fonts),
  `TextStyle` (system font), `AletheFonts` (bundled Caskaydia Cove Nerd Font Mono, family
  `CaskaydiaCove Nerd Font Mono`), `Motion` (springs, projection, rubber-band, snap). Tests: 18
  (completeness, WCAG AA text contrast per theme, round-trip, motion math, font registration, lint for
  color literals and gradients — both verified to fail on a probe file). The app window paints
  `theme[.bg]`. *Gotcha:* passing `CODE_SIGN_IDENTITY` on the `xcodebuild` command line also signs the
  package resource bundle, which then demands a team; the app target reads `ALETHE_SIGN_IDENTITY`
  instead.
- [x] **P0-4 (S) i18n pipeline.** `.xcstrings` in app and packages; build-phase + U test for missing
  pt-BR and orphan keys. *Accept:* adding an EN-only key fails the build.
  *Done:* `Alethe/Localizable.xcstrings` + `Scripts/check-strings.py` as a build phase and in
  `test.sh`. Verified with probes: an EN-only key fails the build (`** BUILD FAILED **`); an orphan
  key, a missing key and a plain-text `Text("Hello there")` are reported; a complete key compiles into
  `en.lproj`/`pt-BR.lproj` and renders "Boas-vindas" when launched with `-AppleLanguages (pt-BR)`.
  Package-module catalogs are covered by the same checker and get validated when the first package
  string lands (P1).
- [x] **P0-5 (M) libghostty from source.** `Vendor/ghostty/build.sh`: pinned revision, `zig` build to
  an xcframework, checksum verification; confirm `HOST_MANAGED` API and whether upstream Ghostty has it.
  *Accept:* reproducible build; checksum recorded.
  *Done:* `HOST_MANAGED` is **not** in upstream Ghostty; it is `Patches/ghostty/0002-host-managed-io.patch`
  of `Lakr233/libghostty-spm` (MIT, actively maintained, Zig 0.16 pipeline). `Vendor/ghostty/build.sh`
  checks out libghostty-spm `b7f888e` and Ghostty `3c47ca1` (verified against libghostty-spm's
  `Ghostty.ref`), runs its macOS build, verifies the header carries `HOST_MANAGED`, copies
  `Vendor/GhosttyKit.xcframework` (universal arm64 + x86_64 `libghostty.a`, ~40 MB, gitignored) and
  writes `Vendor/ghostty/BUILD_INFO`. Requires Zig 0.16.0 and the Xcode Metal Toolchain
  (`xcodebuild -downloadComponent MetalToolchain`; the script checks both). Build time ≈ 5 min.
  *Finding:* the output is not bit-reproducible (differs across builds even with `ZERO_AR_DATE`), so
  inputs are pinned by commit and the recorded sha256 only identifies a build. Also found:
  libghostty-spm ships a Swift wrapper (`GhosttyTerminal`: AppKit view, `NSTextInputClient`, key
  routing via `performKeyEquivalent`, host-managed session bridge; ~8k LOC; depends on
  `MSDisplayLink`); P0-6 evaluates adopting it against writing our own.
- [x] **P0-6 (L) Terminal spike.** `PTYHost` (`forkpty`, batching, ring buffer) + Swift Ghostty view in
  `HOST_MANAGED` mode, `displayLink` rendering, `NSTextInputClient`, search action, theme → config.
  *Gate:* input latency ≤ 1 frame at 120 Hz; `cat` of 100 MB within 1.25× of Ghostty.app; vim, htop,
  Claude Code (Shift+Tab), dead keys (´ + e) and Japanese IME work; ⌘F finds text; no key stolen by the
  app. If any gate fails and cannot be fixed in the spike → switch `TerminalEngine` to SwiftTerm and
  record an ADR. *Tests:* P throughput, UI key-routing.
  *Done — gate PASSED with libghostty (HOST_MANAGED) + libghostty-spm's `GhosttyTerminal` wrapper;
  SwiftTerm fallback not needed.* Implemented `AletheTerminal`: `CAlethePTY` (C `forkpty` + exec —
  only async-signal-safe calls after fork), `PTYProcess` (64 KiB batched reads on a private queue,
  process-group signals, exit via `DispatchSource`), `ScrollbackRing` (4 MiB), `TerminalIOTap`,
  `ShellLaunch` (login shell, `TERM=xterm-ghostty` + bundled terminfo), `TerminalAppearance` (theme →
  Ghostty config), `TerminalPaneView`. Measured:
  | Gate | Result |
  |---|---|
  | Throughput, `cat` 101 MB | Alethe (Release) 1.02 s / 0.91 s vs Ghostty.app 1.05 / 1.06 / 1.05 s |
  | Input latency (Debug) | key → PTY write median 0.48 ms (p95 0.63); key → shell echo median 0.74 ms (p95 1.03) |
  | Key routing | Shift+Tab → `ESC[Z`, Esc → `ESC`, ⌥← → `ESC b`, ^C, ⌘W closes the window (menu) |
  | Dead keys (Brazilian - Pro) | `'`+`e` → é, `~`+`a` → ã |
  | IME | marked text + commit → 日本語 |
  | TUIs | vim (insert, Esc, `:wq` saved the file), htop (alternate screen, colors, `q`) |
  | Search | `search:<text>` highlights every match, including a soft-wrapped one |
  Findings: (1) the wrapper's default `TerminalTheme` renders after the terminal configuration and
  overrode our colors → Alethe's theme is passed as the controller's `TerminalTheme` (regression
  test); (2) Ghostty's default keybinds (⌘W/⌘T/⌘N/⌘K/⌘F/⌘±) are claimed in `performKeyEquivalent`
  before the menu bar → `keybind = clear`, copy/paste/select-all go through the Edit menu and the
  view's `copy:`/`paste:`/`selectAll:` (regression test); (3) synthetic `NSEvent`s do not compose
  dead keys — hardware-faithful tests use `Scripts/dev/keypost.swift` (`CGEvent.postToPid`, delivered
  to the app's process only; never global keystrokes); (4) gaps for P2 TERM-3: the wrapper does not
  surface search totals/selection and the selected match is not visually distinct. Debug-only spike
  hooks (`-AletheSpikeScript/Dump/Command`) live in `Alethe/Spike/`.
- [x] **P0-7 (S) macOS 27 SDK audit.** List of APIs adopted behind `#available(macOS 27, *)`, recorded
  in this doc (§5 ADR-7).
  *Done:* ADR-7a — 16 APIs mapped to tasks with macOS 26 fallbacks; audit read the SDK's
  `.swiftinterface`/header availability annotations (`macOS 27` and `anyAppleOS 27`).
- [x] **P0-8 (S) upstream-watch.** `Scripts/upstream-watch.py` (§9). *Accept:* running it against
  `75083e2..origin/main` produces a report.
  *Done:* reports commands, i18n keys, release sections/[Unreleased] bullets, new component dirs,
  `types.ts` changes and schema bumps into `AletheNative/upstream-reports/<date>-<sha>.md`. Validated
  on `v1.6.0..v1.7.0` (78 commits, 89 new commands, 851 new keys, 9 new component dirs, schema v7 → v9)
  and on the live range (0 commits since the baseline).
- [x] **P0-9 (M) Hit-target harness.** XCUITest helpers that click each control at its drawn frame and
  assert the effect, at zoom 0.9/1.0/1.2. *Accept:* a deliberately broken `scaleEffect` fixture fails.
  *Done:* `AletheUITests` target + shared `Alethe` scheme + `Scripts/uitest.sh`; debug fixture
  `-AletheUITestFixture hit-targets` (toggle, button, segmented picker, text field, NSView-backed
  button) clicked at the drawn (accessibility) frame at UI scale 0.9/1.0/1.2 — all land.
  *Finding — acceptance adjusted:* on macOS 27 `scaleEffect` no longer displaces hit areas, not even
  for an `NSButton` far from the transform anchor, so a `scaleEffect` fixture cannot fail; that fact is
  pinned by `testScaleEffectHitTestingOnThisOS` (fails if the platform regresses). The harness's
  sensitivity is proven instead with the first attempt's other real bug (lesson 4): an invisible
  full-window view taking clicks is detected. Zoom still scales metrics, never `scaleEffect`. The UI
  runner cannot take screenshots (no Screen Recording permission); use `screencapture -l` outside.

### Phase 1 — Usable vertical skeleton

- [x] **P1-1 (M) App shell.** Main window, `NavigationSplitView`, toolbar, standard menus, Settings
  scene, single-instance guard, state restoration. *Tests:* UI, HT.
  *Done:* single `Window` scene (⌘N stays free for New Project) with `NavigationSplitView`, unified
  toolbar, `SidebarCommands`, View › Zoom In/Out/Actual Size (metrics scale, persisted), `Settings`
  scene (General: start agents unrestricted), `AppEnvironment` composition root loading the active
  profile's documents, single-instance guard (activates the running copy), flush on quit
  (`applicationShouldTerminate` → `.terminateLater`), sidebar visibility via `@SceneStorage`, theme
  and `preferredColorScheme` from the active theme. Debug `-AletheDataRoot <path>` isolates data;
  UI tests use `/private/tmp/alethe-uitest-*` (a sandboxed runner's container is not writable by the
  app) and verify persistence by relaunching and reading the UI, never files. 4 UI tests.
- [x] **P1-2 (M) Model v1 + DocumentStore.** `Workspace`, `Group`, `Project`, `Pane`, `SubTab`,
  `Preferences`; migrations chain; atomic debounced writes; backup before migrate. *Tests:* U, G
  (round-trip, corrupted file, concurrent save). *Parity:* data layer for SB/WS.
  *Done:* `AletheFoundation.DocumentStore` (actor; `schemaVersion` + JSON-level migration chain;
  `<name>.v<N>.bak` before migrating; unreadable files moved to `<name>.corrupt-<time>` and the app
  starts fresh; files from a newer build are never written; debounced atomic writes ordered by a
  caller-owned revision). `AletheModel`: typed `Identifier`s (nanoid strings, compatible with imported
  ids), `WorkspaceDocument` v1 (groups with nesting and ordered project ids, ungrouped order, projects
  → panes → tabs, workspace state), `PreferencesDocument` v1, pure `WorkspaceOperations` (keeps every
  project placed exactly once; no group cycles; `repair()`), `DocumentModel` (`@Observable
  @MainActor`). Tests: 7 store + 12 model (incl. corruption, newer-version protection, migration with
  backup, debounce, out-of-order revisions, round-trip). Phase 1 runs in dependency order: P1-2, P1-3,
  then P1-1.
- [x] **P1-3 (M) Profiles folder layout.** Default profile; paths service. *Parity:* SET-3 (base).
  *Done:* `ProfileIndexDocument` (`profiles.json`: profiles, active id, built-in `default` profile
  whose name is localized) and `DataLocations` (`profiles/<id>/{workspace,preferences}.json`,
  `scrollback/`; ids sanitized so they cannot escape the folder). 5 tests.
- [x] **P1-4 (M) Sidebar tree.** Groups (nested), projects, terminals; reorder; context menus; Finder
  drop and `NSOpenPanel` to add a project. *Tests:* U reorder math, UI drag, HT. *Parity:* SB-1, SB-3.
  *Done:* `List(.sidebar)` tree with `DisclosureGroup` groups (collapse persisted), colored project
  dots (theme `project*` tokens), terminal rows per project, selection → open/focus; File › Add
  Project Folder… (⌘O, `NSOpenPanel`, multiple), New Group (⇧⌘N), Finder folder drop; context menus
  (Show in Finder, Move to Group, Remove, New Subgroup, Delete Group); every structural change is
  undoable (`DocumentModel.update(undoManager:actionName:)`, ⌘Z/⇧⌘Z) instead of confirmation
  dialogs. Drag and drop uses the outline view's own mechanism (`.itemProvider` rows, `onMove`,
  `onInsert`, row `onDrop`). *Finding:* XCUITest's synthesized drags never start a SwiftUI drag
  session on macOS (no drop handler runs), while real mouse events work — drags are verified by
  `Scripts/smoke/sidebar-drag.sh` (real events via `Scripts/dev/mousedrag.swift`, AX-located
  rows, asserts `workspace.json`), run by `uitest.sh`. UI tests: tree nesting, Move to Group + undo,
  delete group keeps projects, add-project panel; debug seed `-AletheUITestSeed sidebar`.
- [ ] **P1-5 (M) New/edit project and group.** Name, color (tokens), folder, default cwd. *Parity:*
  SB-2 (basic), SB-3.
  *In progress (WIP checkpoint, not validated):* `Alethe/Editors/` — `EditorRequest` (held by
  `AppEnvironment.editorRequest`, presented as a sheet by `MainWindow`), `ProjectEditor` (folder field
  + Choose…, name auto-filled from the folder, color swatches, group picker; validation: name, existing
  folder, duplicate folder), `GroupEditor` (name, optional color, parent picker excluding itself and
  descendants), `ColorSwatchPicker`, `ProjectColor.localizedName`. File menu: New Project… (⌘N), New
  Group… (⇧⌘N), Add Project Folder… (⌘O); context menus: Edit Project…, Edit Group…, New Project in
  Group…, New Subgroup…. 38 strings added (EN + pt-BR). Builds and passes the strings gate; the sheet
  was checked visually. The duplicate-folder fix is applied (standardized paths compared on both
  sides) and `AletheUITests/EditorTests.swift` exists (both in commit `8c6117a`). Last run:
  `testNewProjectSheetValidatesAndCreates` passes; `testEditGroupRenamesIt` renames correctly but
  fails at line 51 — after ⌘Z the row `sidebar.group.Clients` does not come back (check whether the
  sheet's undo registration reaches the window's undo manager, since the sheet has its own
  `\.undoManager`); `testNewGroupFromTheMenu` fails at line 64 — after Create on an empty workspace
  the row `sidebar.group.Research` is not found (check that an empty group renders in the sidebar and
  that the sheet's save reached the model). **Still to do before ticking:** fix those two, run
  `test.sh` and `uitest.sh`, add the CHANGELOG entry, commit as P1-5.
- [ ] **P1-6 (L) PaneHostView.** AppKit host with split layout (Auto), live resize, reorder, close,
  Motion springs, rubber-banding. *Tests:* U layout math (reuse GridMath), UI, HT. *Parity:* WS-1, WS-3
  (Auto).
- [ ] **P1-7 (L) Terminal panes.** `PTYHost` + Ghostty engine productionized: spawn, resize, restart,
  kill, exit handling, theme and font from the app theme. *Parity:* TERM-1, TERM-7, TERM-8.
- [ ] **P1-8 (M) AgentRegistry + launch.** Claude, Codex, OpenCode, Cursor, shell; launcher resolution
  (PATH, Homebrew, npm/pnpm/volta/fnm/asdf/mise), unrestricted flags, cwd. *Tests:* U, G (ported from
  `cli_resolver.rs` and `sessionLaunch` tests). *Parity:* AG-1 (subset), AG-2, AG-4.
- [ ] **P1-9 (M) New-terminal sheet.** Agent picker, folder, restricted/unrestricted, prompt; ⌘T.
  *Parity:* AG-3 (basic).
- [ ] **P1-10 (M) Session resume for Claude and Codex.** Snapshot sessions from `~/.claude/projects` and
  `~/.codex/sessions`, bind to sub-tabs, resume on relaunch. *Tests:* G with fixture transcripts.
  *Parity:* SE-1 (subset).
- [ ] **P1-11 (M) Themes + zoom + language in Settings.** Theme picker, UI zoom via `uiScale`, EN/pt-BR.
  *Tests:* HT at three zoom levels. *Parity:* UI-1, UI-5, UI-8.
- [ ] **P1-12 (M) TauriImporter.** Read-only import of `projects.json` v9 (groups, projects, terminals,
  core preferences), summary sheet. *Tests:* G with anonymized fixtures, including the v2–v8 shapes the
  upstream migration accepts (import requires v9; older files show a clear message).
- [ ] **P1-13 (S) Changelog + phase review.** Update the parity matrix statuses; run upstream-watch.

**Phase 1 exit criteria:** open existing folders as projects, organize them in the sidebar, run Claude/
Codex/OpenCode/Cursor/shell terminals in panes, quit and relaunch with everything restored, in both
languages and all themes.

### Phase 2 — Terminal and workspace depth
Tasks (each M unless noted), covering: TERM-2 sub-tab lanes; TERM-3 search UI (L); TERM-4 smart paste
(images/files); TERM-5 prompt history; TERM-6 links (open in pane/browser); TERM-9 double ^C; TERM-10
scrollback persistence + reattach (L); USE-3 hibernation, priorities and RAM control (L); WS-2 flat
mode; WS-3 Spotlight/Sidebar/Custom grid + layout designer (L); WS-4 named grids; WS-5 tabs, closed
tabs, history; WS-6 Markdown pane (live file watch); WS-7/WS-8 image/video panes (S each); WS-9 diff
pane; WS-10 focus mode; WS-11 add content; WS-12 link viewer; WS-13 empty state; WS-14 disable/suspend;
BR-1 web pane on WKWebView (L); BR-2 agent page offer; SET-10 Find/Jump (⌘K); SE-2 resume last session;
SET-12 close confirmation. *Tests:* U + UI + HT per task; P for scrollback and hibernation.

### Phase 3 — Agent ecosystem
AG-1 remaining agents (copilot, antigravity, mimo, freebuff, kiro; wsl → not applicable); AG-5
install/update/uninstall (L); AG-6 enable/disable; AG-7 handoff (L); AG-8 hook bridge (local HTTP via
Network.framework) (L); AG-9 model discovery; SE-1 remaining providers (OpenCode, Antigravity, Cursor);
SE-3 history + recent chats; SE-4 cost (SQLite read of `opencode.db`, transcript pricing); SB-5 live
chat titles + busy/done glyphs; USE-1 usage pills + AI Usage + Codex reset credit (L); USE-2 activity
tracking; HOME-1…5 Home dashboard with real data (L); SET-9 notifications (UserNotifications) with
completion detection; PER-6 dictation with Apple SpeechAnalyzer (L).

### Phase 4 — Plugins, Git and review
EXT-3 `AlethePluginKit` v1 (L) + plugin settings page; GIT-1 Git Control as a built-in plugin (L);
GIT-2 commit graph (L); GIT-3 incoming/outgoing; FS-1 file explorer with git badges, Quick Look, drag to
pane (L); FS-2 → `NSOpenPanel`; GIT-4 worktrees (L); GIT-5 Merge Center (split into analyze, prepare,
validate/health/contract, finalize/abort/cleanup: 4 × L); PR-1 Open PRs; PR-2 PR review + squash merge
(L); PER-1 Todos plugin; PER-2 Pomodoro (upstream shape incl. `focusTodoId`); UI-1 theme-pack data
plugin; SB-7 right sidebar; SB-8 view placement; ExtensionKit host + sample third-party extension (M).

### Phase 5 — Integrations
EXT-1 MCP manager (config editors for Claude/Codex (TOML)/OpenCode/Cursor/Gemini, registry search,
health, sync, backups) (3 × L); EXT-2 skills browser; EXT-4 agent library + economy agents; EXT-5
Graphify (CLI integration, graph view, snapshots) (L); EXT-6 ai-memory wiring; EXT-7 GSD Sync (L);
BR-3 Playwright MCP browser session; TERM-11 `alethe` CLI shim; SB-2 remaining (GitHub clone,
`.alethe/project.json` marker, stack detection); SB-4 export/import project config; SB-6 open in VS
Code/Finder/browser; SET-3 profiles UI; SET-4 backup/import/reset/logs (OSLog export); USE-4 crash
report; SET-7 onboarding (incl. import); SET-2 feature toggles; UI-7 toolbar configuration.

### Phase 6 — Orchestrator v2
ORC-2 port `orchestrator_core` (job model, workers, worktrees, approvals) with its tests as golden (3 × L);
`alethe-orchestrator-mcp` stdio target (M); ORC-1 board UI (L); ORC-3 scheduler, telemetry, planning
audit (L).

### Phase 7 — Peripherals
PER-7 remote control: `NWListener` HTTP+WS server, pairing QR (`CIQRCodeGenerator`), read-only/shell
input, device limits, Tailscale detection, the upstream PWA client bundled as a resource and adapted
(3 × L; reuses the upstream PWA client); PER-3 Spotify (OAuth via loopback) (M); PER-4 Discord Rich Presence (IPC socket) (S); PER-5
9router (M); SET-5 GitHub gist sync (M).

### Phase 8 — Release
Developer ID signing, `notarytool` + staple, Sparkle 2 + appcast, DMG (L); SET-8 updater UI + What's New
(M); performance audit (launch < 400 ms to first frame; idle CPU < 1% with 10 terminals; memory per
hibernated terminal) (M); accessibility audit (VoiceOver, keyboard-only, Reduce Motion/Transparency,
Increase Contrast) (M); extraction to the new repository with `git filter-repo --subdirectory-filter
AletheNative` (S).

## 8. Parity matrix

Status values: **Not started**, **In progress**, **Done**, **Replaced** (different native mechanism, same
user outcome), **Won't port** (with reason). All rows start at the baseline `75083e2`.

| ID | Feature | Phase | Status | Notes |
|---|---|---|---|---|
| HOME-1 | Home dashboard | P3 | Not started | ASCII background only if it passes the motion/accessibility rules |
| HOME-2 | Mini-terminal quick launch | P3 | Not started | |
| HOME-3 | Activity graph / time analytics / usage strip | P3 | Not started | |
| HOME-4 | Setup walkthrough | P3 | Not started | |
| HOME-5 | Notifications list | P3 | Not started | |
| WS-1 | Project containers | P1 | Not started | |
| WS-2 | Flat mode | P2 | Not started | |
| WS-3 | Layouts Auto/Spotlight/Sidebar/Custom | P1 (Auto), P2 | Not started | |
| WS-4 | Named project grids | P2 | Not started | |
| WS-5 | Tabs, closed tabs, history | P2 | Not started | |
| WS-6 | Markdown pane | P2 | Not started | |
| WS-7 | Image pane | P2 | Not started | |
| WS-8 | Video pane | P2 | Not started | AVKit |
| WS-9 | Diff pane | P2 | Not started | |
| WS-10 | Focus mode | P2 | Not started | |
| WS-11 | Add content | P2 | Not started | |
| WS-12 | Link viewer overlay | P2 | Not started | |
| WS-13 | Empty workspace launcher | P2 | Not started | |
| WS-14 | Disable terminal/project, suspend group | P2 | Not started | |
| TERM-1 | Real PTYs + process tree | P1 | Not started | PTYHost |
| TERM-2 | Sub-tabs lane | P2 | Not started | |
| TERM-3 | Terminal search | P0 spike, P2 | Not started | Ghostty search actions |
| TERM-4 | Smart copy/paste | P2 | Not started | |
| TERM-5 | Prompt history | P2 | Not started | |
| TERM-6 | Clickable links | P2 | Not started | |
| TERM-7 | Terminal themes/font | P1 | Not started | |
| TERM-8 | Restart / command-not-found overlays | P1 | Not started | |
| TERM-9 | Double ^C force-kill | P2 | Not started | |
| TERM-10 | Scrollback persistence + reattach | P2 | Not started | |
| TERM-11 | `alethe` CLI shim | P5 | Not started | |
| SB-1 | Project tree (Normal/Clean) | P1 | Not started | |
| SB-2 | New/edit project (clone, marker, git init, stack) | P1 (basic), P5 | Not started | |
| SB-3 | Groups (nested, suspend) | P1 | Not started | |
| SB-4 | Export/import project config | P5 | Not started | |
| SB-5 | Live chat title + busy/done glyph | P3 | Not started | |
| SB-6 | Open in VS Code / Finder / browser | P5 | Not started | `NSWorkspace` |
| SB-7 | Right sidebar | P4 | Not started | Inspector column |
| SB-8 | View placement | P4 | Not started | |
| AG-1 | 11 agent types | P1 (5), P3 | Not started | `wsl`: Won't port (Windows-only) |
| AG-2 | Unrestricted flags | P1 | Not started | |
| AG-3 | New-terminal modal | P1, P3 | Not started | |
| AG-4 | Launcher resolution + override | P1 | Not started | macOS paths only |
| AG-5 | Install/update/uninstall CLIs | P3 | Not started | |
| AG-6 | Enable/disable agents | P3 | Not started | |
| AG-7 | Claude ↔ Codex handoff | P3 | Not started | |
| AG-8 | Agent hook bridge | P3 | Not started | |
| AG-9 | Model discovery | P3 | Not started | |
| SE-1 | Session auto-resume (5 providers) | P1 (2), P3 | Not started | |
| SE-2 | Resume last session | P2 | Not started | |
| SE-3 | Claude history + recent chats | P3 | Not started | |
| SE-4 | Session/transcript cost | P3 | Not started | |
| GIT-1 | Git Control | P4 | Not started | Built-in plugin |
| GIT-2 | Commit graph | P4 | Not started | |
| GIT-3 | Incoming/outgoing | P4 | Not started | |
| GIT-4 | Worktree isolation | P4 | Not started | |
| GIT-5 | Merge Center | P4 | Not started | |
| PR-1 | Open PRs + send to Todo | P4 | Not started | `gh` CLI |
| PR-2 | PR review + squash merge | P4 | Not started | |
| FS-1 | File explorer + git badges | P4 | Not started | Quick Look |
| FS-2 | Folder browser | P1 | Not started | Replaced by `NSOpenPanel` |
| BR-1 | Web pane | P2 | Not started | WKWebView; CDP engine: Won't port |
| BR-2 | Agent page offer | P2 | Not started | |
| BR-3 | Playwright MCP browser session | P5 | Not started | |
| EXT-1 | MCP manager | P5 | Not started | |
| EXT-2 | Skills browser | P5 | Not started | |
| EXT-3 | Plugin system | P4 | Not started | Native `AlethePluginKit`; JS plugins: Won't port |
| EXT-4 | Agent library + economy agents | P5 | Not started | |
| EXT-5 | Graphify | P5 | Not started | |
| EXT-6 | ai-memory wiring | P5 | Not started | |
| EXT-7 | GSD Sync | P5 | Not started | |
| ORC-1 | Orchestrator board | P6 | Not started | |
| ORC-2 | Orchestrator MCP tools + core | P6 | Not started | Swift stdio binary |
| ORC-3 | Scheduler, telemetry, planning audit | P6 | Not started | |
| USE-1 | Usage pills + AI Usage + reset credit | P3 | Not started | |
| USE-2 | Activity tracking | P3 | Not started | |
| USE-3 | RAM control, hibernation, supervisor | P2 | Not started | |
| USE-4 | Crash report | P5 | Not started | MetricKit / diagnostic reports |
| UI-1 | Themes (16 + 4) | P0, P1, P4 | Not started | |
| UI-2 | Visual style normal/clean | P1 | Not started | |
| UI-3 | Motion preference | P1 | Not started | Also follows system Reduce Motion |
| UI-4 | App icon themes | P5 | Not started | `NSApp.applicationIconImage` |
| UI-5 | UI zoom | P1 | Not started | Font + metric scale only |
| UI-6 | Window opacity | — | Won't port | Win32-only upstream; Mac uses materials |
| UI-7 | Toolbar configuration | P5 | Not started | Native toolbar customization |
| UI-8 | i18n EN + pt-BR | P0, P1 | Not started | |
| SET-1 | Preferences | P1, ongoing | Not started | Settings scene |
| SET-2 | Feature toggles | P5 | Not started | |
| SET-3 | Profiles | P1 (base), P5 | Not started | |
| SET-4 | Backup/import/reset/logs | P5 | Not started | |
| SET-5 | GitHub gist sync | P7 | Not started | |
| SET-6 | Cloud sync | — | Won't port | Upstream server not shipped (localhost default); revisit if it ships |
| SET-7 | Onboarding + welcome | P5 | Not started | Includes Tauri import (P1-12) |
| SET-8 | Updater + What's New | P8 | Not started | Sparkle |
| SET-9 | Notifications | P3 | Not started | |
| SET-10 | Find/Jump | P2 | Not started | |
| SET-11 | Audit center | P5 | Replaced | OSLog + diagnostic export |
| SET-12 | Close confirmation | P2 | Not started | |
| SET-13 | Keyboard shortcuts | P1, ongoing | Not started | §6.3 |
| PER-1 | Todos | P4 | Not started | Built-in plugin |
| PER-2 | Pomodoro | P4 | Not started | |
| PER-3 | Spotify | P7 | Not started | |
| PER-4 | Discord Rich Presence | P7 | Not started | |
| PER-5 | 9router | P7 | Not started | |
| PER-6 | Dictation | P3 | Not started | Replaces Parakeet with Apple SpeechAnalyzer |
| PER-7 | Remote control | P7 | Not started | |
| EXP-1 | Agent Canvas POC + TokenHud | — | Won't port | Experimental upstream; revisit after v1 |
| EXP-2 | Agent Sandbox | — | Won't port | Disabled upstream |
| EXP-3 | Ghostty backend in Tauri | — | Replaced | Native terminal is the default |
| — | Windows-only code (ConPTY, registry, Job Objects, WebView2, `wsl`) | — | Won't port | Platform-specific |

## 9. Staying current with upstream

The native app shares no code with upstream, so "staying current" means **detecting and triaging**
upstream changes, not merging them.

1. `AletheNative/UPSTREAM_BASELINE` stores the last reviewed `origin/main` SHA.
2. `Scripts/upstream-watch.py` runs `git fetch` and diffs `baseline..origin/main` for: new or removed
   `#[tauri::command]` names in `src-tauri/src/lib.rs`; new keys in `src/lib/i18n/messages/en.ts`; new
   `docs/CHANGELOG.md` sections; new directories under `src/components/`; new fields in
   `src/lib/types.ts` (`ProjectsFile`, `Project`, `Terminal`, `Preferences`); schema version bumps in
   `projectsStore.migrations.ts`. It writes `AletheNative/upstream-reports/<date>-<sha>.md`; triage
   moves each item into §8 by hand (the script never edits this plan).
3. Cadence: at the start of every phase and weekly. Triage assigns each row a phase or "Won't port" and
   advances the baseline in its own commit.
4. Importer compatibility: when upstream bumps the `projects.json` version, add a fixture and extend
   `TauriImporter` in the next phase.
5. Strings only land with code; the orphan test prevents translated-but-unimplemented debt.

### 9.4 Extraction to the new repository
When the owner decides (Phase 8 or earlier): `git filter-repo --subdirectory-filter AletheNative` on a
fresh clone of `mac-native-v2`, producing a repository whose root is the native app with history. The
self-contained layout (ADR-7) makes this lossless.

## 10. Risks and mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| `HOST_MANAGED` exists only as a libghostty-spm patch | Terminal architecture | Built from pinned sources (P0-5); P0-6 gate; SwiftTerm fallback behind `TerminalEngine`; pin moves only with a re-run of the P0-6 checks |
| Volume of the port (~290 commands) | Schedule | Vertical phases; matrix as control; upstream tests ported as golden files |
| No Developer ID yet | No external distribution; Keychain prompts | Stable local identity; Keychain reads behind a dev flag; Phase 8 waits for the account (§11) |
| Comment-preserving TOML editing without a mature Swift library | Corrupting `~/.codex/config.toml` | Minimal table-level editor; golden tests from `toml_edit` cases; backup before write |
| ExtensionKit distribution/UX for third parties | Plugin API scope | Spike in P4; built-ins do not depend on it |
| Liquid Glass × custom themes | Legibility | Chrome tinted, content on tokens; per-theme contrast test; Reduce Transparency path |
| SwiftUI/AppKit key-routing regressions | Terminal usability | ADR-10; key-routing UI tests in CI from P0 |
| Scope creep (the first attempt's failure mode) | Depth vs breadth | Phase order fixed; showcase features only after their phase's depth items |
| Upstream keeps moving fast | Parity gap | §9 watch + weekly triage |
| Remote control exposes terminals on the network | Security | Pairing, read-only default, device limits, token expiry, LAN/Tailscale only, security review before release |

## 11. Owner decisions and open questions

Resolved (2026-09-22):
1. **Name:** the product stays **Alethe**. Bundle id **`com.kc1t.alethe.mac`** (distinct from the Tauri
   app's `com.kc1t.alethe`, so the two never share a data directory).
2. **Changelog:** `AletheNative/CHANGELOG.md` (the repository's `docs/CHANGELOG.md` stays the Tauri
   product's).
3. **Dictation:** Apple on-device speech (`SpeechAnalyzer`/`SpeechTranscriber`); Parakeet is not ported.
5. **License:** same as `main` — AGPL-3.0.
6. **Developer ID:** not available yet. Phase 0–7 use the stable local signing identity; Phase 8
   (notarization, Sparkle, public DMG) waits for the account.
7. **Remote control client:** reuse the upstream PWA, bundled as a resource.

4. **Third-party plugins channel:** **ExtensionKit** (for now). Each third-party plugin ships as an app
   extension inside its own signed app, runs out of process and sandboxed, and renders UI remotely.
   Built-ins (Git, Todos, Theme-pack) stay in-process on the same `AlethePluginKit` API. The P4 spike
   validates the ExtensionKit flow; in-process bundles are rejected unless the spike fails.
