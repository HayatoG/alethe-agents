# Alethe for macOS — native rewrite plan (v2)

> Status: **Phase 2 in progress** (Phase 1 complete). Done: P2-1…P2-12 (P2-1…P2-5 tested; P2-6…P2-12
> compiled, tests not run). Manual checks owed: prompt redraw after resize (P2-3), image paste and
> drops (P2-5), prompt recall (P2-6), scrollback after relaunch (P2-7). Next: P2-13. Branch: `mac-native-v2` (created from `origin/main` @ `75083e2`, v1.7.0).
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
  `MSDisplayLink` (MIT, pinned `exact: 2.2.0`), Sparkle, Apple's `swift-markdown` + `swift-cmark`
  (Apache-2.0, pinned `exact: 0.9.0`, ADR-11). Anything else needs an ADR.

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

### ADR-11 — Markdown rendering: swift-markdown (owner decision, 2026-09-24)
- **Context:** the Markdown pane (WS-6, P2-9) renders READMEs and plans with GFM (tables, task
  lists, strikethrough) like upstream's react-markdown + remark-gfm, plus Mermaid diagrams.
- **Options:** (a) Apple's `swift-markdown` (cmark-gfm) parsed into blocks laid out in SwiftUI;
  (b) a small in-app GFM parser, no dependency; (c) a WKWebView with bundled marked.js + mermaid.js.
- **Decision:** (a). A spec-compliant parser maintained by Apple, no JavaScript in the app, theme
  tokens and text selection native. `AletheDocuments` owns the dependency; the rest of the app sees
  `MarkdownBlock`. Pinned `exact: 0.9.0` (its `swift-cmark` resolves to 0.9.0, in `Package.resolved`).
- **Consequences:** Mermaid blocks show as code until a web-based renderer exists (P2-12 brings
  WKWebView; revisit then). Raw HTML shows as source, as upstream (no rehype-raw).

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
| Shift+Tab, Ctrl+PgUp/PgDn | ⌥⌘← / ⌥⌘→ | Cycle terminals (Shift+Tab is left to the terminal; ⌥⌘↑/↓ went to prompt history in P2-6) |
| Ctrl+B | ⌃⌘S | Toggle sidebar (standard) |
| Ctrl + / − / 0 | ⌘+ / ⌘− / ⌘0 | UI zoom |
| Ctrl+E | ⌘E is "Use Selection for Find" on Mac → dictation uses Fn-Fn / ⌥⌘D | Dictation |
| Ctrl+Enter (git) | ⌘↩ | Commit |
| Ctrl+↑/↓ (prompt history) | ⌥⌘↑ / ⌥⌘↓ | Prompt history (P2-6; ⌃↑/⌃↓ belong to Mission Control) |
| — | ⌘↑ / ⌘↓ | Previous / next prompt mark (P2-3) |
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

**Test cadence (owner decision, 2026-09-22):** per task, run only what the change touches — the
affected package suites (`swift test --filter …`, all package tests are cheap), the affected UI test
classes (`Scripts/uitest.sh -only-testing:AletheUITests/<Class>`), the strings gate and the app build
when the project changes. Run the full suite (`Scripts/test.sh` + `Scripts/uitest.sh`, which includes
the real-mouse smoke scripts) every 3 tasks, at the end of each phase, and when a change reaches
widely shared code. Last full run: after P2-5 (2026-09-24, also the Phase 1 end-of-phase run): 159
package tests, 27 UI tests, both smoke scripts, all passing. `AppearanceTests
.testAppearanceControlsReceiveClicksAtThreeZoomLevels` failed once in the full run (the theme picker
did not appear after clicking the Appearance tab) and passed on a rerun: flaky, not a regression.

**UI-testing gotchas (learned in Phase 1):**
- XCUITest `typeText` drops lowercase "c" under the owner's Brazilian - Pro layout (real key events
  are fine) — tests avoid typing it.
- XCUITest's synthesized drags never reach AppKit `mouseDragged` nor start SwiftUI drag sessions:
  drags are covered by `Scripts/smoke/*.sh` with `Scripts/dev/mousedrag.swift` (real mouse events).
- A plain `NSView` is invisible to accessibility: set `setAccessibilityElement(true)` + a role before
  giving it an identifier.
- Manual checks: launch the Debug app with `-AletheDataRoot <tmp> -AletheUITestSeed <seed>`
  (`sidebar`, `terminals`, `panes`, `prompt`), drive it with `Scripts/dev/keypost.swift`, and capture
  only its window (`screencapture -l <window id>`); never send global System Events keystrokes.
- Localized strings with arguments: dotted key + positional placeholders (`%1$@`) through
  `String(format:)`; the strings gate rejects interpolated keys.
- A SwiftUI `Text` whose string changes keeps its old accessibility value, so tests (and VoiceOver)
  read stale text; give it `.id(value)`. Check a screenshot before blaming a "missed" click.
- The Settings window reopens on the last tab used, stored in the app's real defaults and shared by
  every test run: tests select their tab explicitly.

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
- [x] **P1-5 (M) New/edit project and group.** Name, color (tokens), folder, default cwd. *Parity:*
  SB-2 (basic), SB-3.
  *Done:* `Alethe/Editors/` — `EditorRequest` (held by `AppEnvironment.editorRequest`, presented as a
  sheet by `MainWindow`), `ProjectEditor` (folder field + Choose…, name auto-filled from the folder,
  color swatches, group picker; validation: name, existing folder, duplicate folder), `GroupEditor`
  (name, optional color, parent picker excluding itself and descendants), `ColorSwatchPicker`. File
  menu: New Project… (⌘N), New Group… (⇧⌘N), Add Project Folder… (⌘O); context menus: Edit Project…,
  Edit Group…, New Project in Group…, New Subgroup…. Editors register undo on the **main window's**
  undo manager (passed in by `MainWindow`; the sheet's own `\.undoManager` dies with the sheet) and
  focus their first field on appear. *Tests:* `AletheUITests/EditorTests` (3). Lesson: XCUITest
  `typeText` drops lowercase "c" under the Brazilian - Pro layout — real CGEvents reach the field
  (checked with `Scripts/dev/keypost.swift`), so UI tests avoid typing it.
- [x] **P1-6 (L) PaneHostView.** AppKit host with split layout (Auto), live resize, reorder, close,
  Motion springs, rubber-banding. *Tests:* U layout math (reuse GridMath), UI, HT. *Parity:* WS-1, WS-3
  (Auto).
  *Done:* `AletheModel/WorkspaceLayout.swift` — `AutoLayout.rows` (upstream `PaneArea` Auto: 1 full,
  2 side by side, then rows of two with an odd last pane spanning), `TrackMath` (weighted tracks,
  boundary drag clamped at a minimum, rubber-band injected as a function so the model does not
  depend on `AletheDesign`), `PaneGridGeometry` (pane frames + divider hit areas). App
  `Workspace/PaneHost/`: `PaneHostView` (open projects as containers sized by `containerWeights`,
  container dividers, click-to-focus through a local mouse monitor that lets the click through),
  `ContainerView` (SwiftUI header, Auto grid from `gridWeights[project]`, live split drag with
  rubber-band then a spring back on release, header drag-to-reorder with a lifted pane using the
  theme's `lg` shadow, empty-project state), `PaneView` (header, re-parented registry terminal,
  overlay only when needed), `DividerView`, `FrameAnimator` (critically damped `Motion.standard`
  spring on `NSView.displayLink`, interruptible, skipped under Reduce Motion), `PaneHostContext`.
  Close pane / close project are undoable; resizes and focus are not (as upstream).
  `PTYProcess.resizeCoalesced` sends only the last size of a burst (80 ms quiet) so a live drag is
  one SIGWINCH, not one per frame. *Tests:* `AutoLayoutTests`, `TrackMathTests`,
  `PaneGridGeometryTests`, `coalescedResizeAppliesOnlyTheLastSize`, UI `PaneHostTests` (layout, close
  + undo), `Scripts/smoke/pane-drag.sh` (real-mouse split resize, container resize, reorder — run by
  `uitest.sh`; XCUITest's synthesized drags never reach AppKit `mouseDragged`).
  *Follow-up (Phase 2, TERM):* zsh still leaves a `%`/prompt fragment after a resize because Ghostty
  cannot clear the old prompt without its shell integration (OSC 133 marks). In `HOST_MANAGED` mode
  Ghostty does not spawn the shell, so Alethe must inject the integration itself (ZDOTDIR for zsh,
  equivalents for bash/fish).
- [x] **P1-7 (L) Terminal panes.** `PTYHost` + Ghostty engine productionized: spawn, resize, restart,
  kill, exit handling, theme and font from the app theme. *Parity:* TERM-1, TERM-7, TERM-8.
  *Done:* `Alethe/Terminals/` — `TerminalRegistry` (one live `TerminalPaneView` per tab, owned outside
  the view tree so processes survive project switches; start via `AgentLauncher`, restart, close,
  prune deleted tabs, terminate all on quit, live theme + font updates; font = 13 pt × `uiScale`),
  `TerminalHost` (re-parents the registry's view; overlays for ended process → Restart, CLI not found
  → Choose CLI… (validated with `LauncherResolver.path(_:matches:)`, saved to `cliPaths`), spawn
  failure). `PTYProcess.terminate(grace:)` = SIGHUP to the group, SIGKILL after 2 s.
  `WorkspaceView` shows the selected project's focused pane (splits: P1-6); "New Terminal" menu in
  the project context menu and empty state (the full sheet is P1-9); tab rows get Restart / Close
  Terminal (`WorkspaceDocument.closeTab`, undoable). Claude session ids are only resumed when their
  transcript exists (`ClaudeTranscripts`), since a minted id with no message cannot be resumed.
  Ghostty's own "Process exited. Press any key" line is suppressed (the session is not `finish`ed).
  Localized strings with arguments use a dotted key + `String(format:)` with positional
  placeholders (the strings gate rejects interpolated keys). *Tests:* `terminateKillsAChildThatIgnoresHangup`,
  `closingTheLastTabClosesItsPane`, `ClaudeTranscriptsTests`, UI `TerminalTests.testShellLifecycle`;
  checked visually with Claude Code (theme, trust prompt, exit overlay, no orphan processes).
- [x] **P1-8 (M) AgentRegistry + launch.** Claude, Codex, OpenCode, Cursor, shell; launcher resolution
  (PATH, Homebrew, npm/pnpm/volta/fnm/asdf/mise), unrestricted flags, cwd. *Tests:* U, G (ported from
  `cli_resolver.rs` and `sessionLaunch` tests). *Parity:* AG-1 (subset), AG-2, AG-4.
  *Done:* new `AletheAgents` target (no Ghostty dependency): `AgentKind`/`AgentRegistry` (the only
  agent list), `AgentArguments` (port of `buildAgentLaunch`), `LauncherResolver` + `LauncherCache`
  (PATH, `~/.local/bin`, `~/.claude/local`, `~/.opencode/bin`, cargo, bun, npm-global,
  `NPM_CONFIG_PREFIX`, Volta, pnpm, mise, asdf, nvm/fnm newest first, Homebrew; overrides; hits
  re-checked on disk), `AgentLauncher` → `AgentCommand` (a `$SHELL -l -c` line that puts the CLI's
  folder first on PATH so `#!/usr/bin/env node` finds its node, scrubbed editor/Claude variables).
  `PreferencesDocument.cliPaths` holds overrides (Settings UI comes with AG-5/AG-6).
  `AppEnvironment.agentLauncher` composes it; `AgentCommand.ptyLaunch(size:)` feeds P1-7. 27 tests,
  including a real-shell quoting test; checked on this Mac with a minimal PATH (`claude --version`
  ran through `zsh -l`).
- [x] **P1-9 (M) New-terminal sheet.** Agent picker, folder, restricted/unrestricted, prompt; ⌘T.
  *Parity:* AG-3 (basic).
  *Done:* `Editors/NewTerminalSheet` (enabled agents as a radio group with agent colors, project
  picker, folder with validation + Choose…, unrestricted toggle showing the real flag and defaulting
  to `alwaysStartUnrestricted`, optional first prompt; `lastAgent` preselected). File › New
  Terminal… (⌘T) and New Terminal… on projects and empty containers (replaces P1-7's quick submenu).
  `AletheTerminal/PromptDelivery` ports upstream `sendInitialInput` + `deliverOpenCodePrompt`:
  ready after ≥ 1.5 s (OpenCode 4 s) and 700 ms of quiet or 4 s; bracketed paste + Enter (+ a late
  second Enter) for Claude/Codex/Cursor; OpenCode typed in 6-char chunks, confirmed on the rendered
  screen (letters/digits match, retype only into an empty box), Enter resent only while the screen
  is unchanged. The registry clears `initialPrompt` once sent so relaunch never resends it.
  *Tests:* `PromptDeliveryTests` (virtual clock), UI `TerminalTests.testNewTerminalSheet`; checked
  live: `/help` as first prompt opened Claude Code's help.
- [x] **P1-10 (M) Session resume for Claude and Codex.** Snapshot sessions from `~/.claude/projects` and
  `~/.codex/sessions`, bind to sub-tabs, resume on relaunch. *Tests:* G with fixture transcripts.
  *Parity:* SE-1 (subset).
  *Done:* `AletheAgents/SessionDiscovery` ports `snapshot_claude_sessions` (cwd folder encoding, exact
  then case-insensitive match) and `snapshot_codex_sessions` (recursive walk, first-line
  `session_meta` only, cwd compared after resolving symlinks so `/tmp` ≡ `/private/tmp`), plus
  `SessionClaims` (port of `sessionDiscovery.ts`: one owner tab per conversation, discovery binds only
  the single new unclaimed session). `SessionResume` holds the decisions: Claude resumes only with a
  transcript, Codex only while its rollout for that folder exists, others are trusted; a resumed
  agent exiting within 4 s is relaunched once without the id; new Codex sessions are polled every
  3 s ×10, then 15 s. `TerminalRegistry` snapshots Codex before the spawn, skips ids held by another
  tab, persists whatever id the process ends up with (minted, resumed, discovered or dropped) on the
  tab, and cancels discovery on close/restart. Also scrubs the parent Claude Code session variables
  (`CLAUDE_CODE_CHILD_SESSION` turns transcript saving off, which silently broke resume when Alethe
  was started from a Claude terminal).
  *Tests:* `SessionDiscoveryTests` (fixture homes: Claude folders, Codex rollouts with a 100 KB
  `session_meta`, symlinked cwd; claim ports of the upstream cases; retry window; poll schedule with a
  fake sleep; cancellation), UI `TerminalTests`. Checked live: relaunch ran `claude --resume <id>` and
  restored the conversation; a resume that fails exited in ~2 s and fell back to a fresh
  `--session-id`, saved on the tab. Codex not checked live (CLI not installed on this Mac).
  *Not ported yet:* Codex "active writer" conflict detection, session titles, hook-driven Claude id
  changes (`/clear`, `/resume` inside the CLI; AG-8).
- [x] **P1-11 (M) Themes + zoom + language in Settings.** Theme picker, UI zoom via `uiScale`, EN/pt-BR.
  *Tests:* HT at three zoom levels. *Parity:* UI-1, UI-5, UI-8.
  *Done:* Settings › Appearance (`Settings/AppearanceSettings`): the 16 built-in themes as swatch
  tiles in upstream picker order with upstream names/descriptions (`ThemeLabels`, tooltip = summary),
  applied live to every window and terminal; interface size with − / + / Actual Size (same rounding
  and 80–150 % bounds as the View menu); language System / English / Português (Brasil). Language is
  the app's own `AppleLanguages` default (`AletheFoundation/AppLanguage`: the key System Settings ›
  Language & Region › Applications writes too), so it applies at launch: Settings shows "Applies
  after restarting" + Restart Now (`App/AppRelaunch`: a helper shell waits for the app to quit and
  flush, then reopens it with the same arguments minus `-AppleLanguages`/`-AppleLocale`). Not in
  preferences.json: the language is app-wide, not per profile. Settings also follows the theme's
  light/dark scheme.
  *Tests:* `AppLanguageTests` (3); UI `AppearanceTests`: theme applies and survives a relaunch; HT at
  90 %, 100 % and 120 % (zoom in/out/reset, a theme tile, the language picker and its restart note).
  Checked live: launched in pt-BR the whole Settings window is Portuguese; Restart Now reopened the
  app with the data root kept and the language back to System.
- [x] **P1-12 (M) TauriImporter.** Read-only import of `projects.json` v9 (groups, projects, terminals,
  core preferences), summary sheet. *Tests:* G with anonymized fixtures, including the v2–v8 shapes the
  upstream migration accepts (import requires v9; older files show a clear message).
  *Done:* `AletheModel/TauriImport` reads v2–v9, not only v9: the imported fields (group tree, project,
  terminal and sub-tab basics, theme/zoom/language/agents) kept their shape across the upstream v2 → v9
  migrations, which only added fields the importer ignores. v1 shows "older" and anything above v9
  shows "newer". Groups are recreated parents first (same name under the same parent is reused, parent
  cycles become top-level); projects follow the sidebar order (`projectIds`, then `ungroupedOrder`),
  take their folder from `defaultCwd` or the first absolute terminal/tab cwd, and map hex colors to the
  nearest of the ten accents. Skipped and listed: archived projects, projects with no folder or already
  in the workspace, non-terminal panes, agents the native app does not run. Preferences (optional):
  theme, interface size, enabled agents, always unrestricted, CLI paths that exist on this Mac, and the
  language (app-wide, offers a restart). `TauriDataLocation` finds the Tauri profiles
  (`profiles.json` + `profiles/<id>/projects.json`, active first). File › Import from Alethe (Tauri)…
  (`Editors/TauriImportSheet`) previews a dry run on copies of the documents, then imports as one
  undoable change; the Tauri files are never written.
  *Tests (run and passing in the full run after P2-5):* `TauriImportTests` with
  anonymized v1/v2/v5/v7/v9/v10 fixtures (v9 import, idempotent re-import, existing folders, optional
  preferences, v7, v5 + v2, refused versions, hex color mapping, profile discovery); UI
  `TauriImportTests.testPreviewImportAndUndo` (`-AletheTauriProjectsFile` fixture).
- [x] **P1-13 (S) Changelog + phase review.** Update the parity matrix statuses; run upstream-watch.
  *Done:* `AletheNative/CHANGELOG.md` covers every Phase 1 task. Matrix (§8) updated: AG-2 Done, FS-2
  Replaced; SB-1, SB-2, SB-3, AG-1, AG-4, SET-1, SET-3, SET-13 Partial; UI-2 and UI-3 (never scheduled
  in a P1 task) moved to Phase 2. upstream-watch `75083e2..2f3e5ed`
  (`upstream-reports/2026-09-24-2f3e5ed.md`): 4 commits, no new commands, i18n keys, persisted
  fields or schema bump (still v9); the only user-facing change, the startup loading screen following
  the theme, has no native counterpart (the app draws its themed window at launch). Baseline advanced
  to `2f3e5ed`.
  *Phase 1 exit check:* features for every criterion are in (folders as projects, sidebar, the five
  agents in panes, restore on relaunch, both languages, all themes). Tests for P1-12 and
  the end-of-phase full run (owner decision 2026-09-24: tests only on request); both ran after P2-5
  and pass.

**Phase 1 exit criteria:** open existing folders as projects, organize them in the sidebar, run Claude/
Codex/OpenCode/Cursor/shell terminals in panes, quit and relaunch with everything restored, in both
languages and all themes.

### Phase 2 — Terminal and workspace depth
Order: terminal depth on the existing pane model first, then non-terminal pane kinds (one schema
bump, P2-8), then workspace navigation and layouts, then lifecycle and resources. Each task adds its
own `workspace.json` migration when it changes the shape. *Tests* list what the task must ship;
they run per the test cadence above.

- [x] **P2-1 (M) Sub-tabs lane.** Vertical lane on each pane (upstream `SubTabsLane`): switch, new
  sub-tab (agent picker reusing the New Terminal sheet), close (undoable), show/hide the lane per pane.
  *Tests:* U (tab operations), UI + HT (lane controls at three zoom levels). *Parity:* TERM-2.
  *Done:* `Pane.laneVisible` (optional, so v1 files decode unchanged: no migration) and
  `isLaneVisible` (upstream rule: always shown with several tabs). `WorkspaceOperations` gains
  `addTab`, `activateTab`, `tab(_:from:)`, `setLaneVisible`, `updatePane`, `paneHolding`; `closeTab`
  now shows the next tab, or the previous one when the last closes (upstream `closeSubTab`).
  `Workspace/PaneHost/SubTabsLane` (36 pt, `shapeTabsLane*` tokens): agent icon per tab, accent bar on
  the active one (muted when the pane is unfocused), close on hover when there is more than one tab,
  context menu Restart / Close, + at the bottom. `PaneView` lays it out left of the terminal, starts a
  tab's process when it is first shown and hands focus to the new terminal on a switch. The pane
  header's context menu and the sidebar tab menu add New Sub-tab… and Show/Hide Sub-tabs;
  `NewTerminalSheet(targetPane:)` is upstream's `NewSubTabModal` (no project picker, folder of the
  pane's active tab). Selecting a tab in the sidebar now shows it in its pane.
  *Deviations from upstream:* close does not ask first (it is undoable with ⌘Z); no rename or reorder
  (upstream has neither). No keyboard shortcut: upstream has none, and ⌃Tab / ⌘1…9 are taken (§6.3).
  *Tests (written 2026-09-24, run and passing in the full run after P2-5):* `SubTabOperationsTests` (8), UI
  `SubTabsTests` (switch/add/close/undo, lane visibility, HT at 90/100/120 %), seed `subtabs`.
- [x] **P2-2 (S) Double ^C force-kill.** Two ⌃C within the upstream window kill the process tree; an
  overlay offers restart. *Tests:* U (timing on a virtual clock), UI. *Parity:* TERM-9.
  *Done:* `AletheTerminal/ForceKill`: `DoubleInterrupt` (upstream 1.5 s window; the first ⌃C always
  reaches the program, anything typed in between starts over; ETX or the kitty keyboard `CSI 99;5u`)
  and `ProcessTree` (descendants from `sysctl(KERN_PROC_UID)`, SIGKILL children first, then the
  group: agents start workers in their own process groups). `TerminalPaneView` checks keyboard input
  before it reaches the PTY: the second ⌃C is swallowed, a yellow notice is printed (upstream's line,
  localized) and the tree is killed. `TerminalRegistry` records `.forceKilled` (overlay "Terminated
  with a double ⌃C." + Restart) and skips the early-exit fresh retry, which would otherwise relaunch
  a resumed agent killed within 4 s. Mac mapping: ⌃C only; ⌘C stays Copy.
  *Tests (written 2026-09-24, run and passing in the full run after P2-5):* `ForceKillTests` (7, one spawns a child that
  leaves its process group), UI `TerminalTests.testDoubleInterruptForceKills`.
- [x] **P2-3 (S) Shell integration marks.** OSC 133 prompt marks for zsh/bash/fish (injected rc, no
  user files touched) so resize reflows without the leftover prompt fragment and search/scroll can
  jump by prompt. *Tests:* U (sequence parser), manual resize check. *Parity:* TERM-1 (follow-up).
  *Done:* `AletheTerminal/ShellIntegration` ports libghostty's `shell_integration.zig` injection, which
  host-managed mode skips, onto the MIT integration GhosttyKit already bundles: zsh through `ZDOTDIR`
  (the user's own kept in `GHOSTTY_ZSH_ZDOTDIR`), bash through `--posix` + `ENV` (`GHOSTTY_BASH_*`
  contract, `HISTFILE` fix), `GHOSTTY_SHELL_FEATURES=cursor,title`. Applied by
  `ShellLaunch.loginShell` to interactive shells only; agents (`-c`) are untouched. The scripts emit
  OSC 133 A/B/C/D and OSC 7. New Terminal menu: Previous Prompt ⌘↑ / Next Prompt ⌘↓ on the focused
  terminal (`jump_to_prompt`; `AppEnvironment.focusedTerminal`, reused by P2-4).
  *Deviations:* no fish (GhosttyKit bundles no fish integration; Ghostty's own is GPL) and no
  macOS `/bin/bash` 3.2 (Ghostty skips it too). No sequence parser was needed: Ghostty parses the marks.
  *Tests (written 2026-09-24, run and passing in the full run after P2-5):* `ShellIntegrationTests` (5, one runs an
  interactive zsh and checks OSC 133 A and D). The manual resize check (prompt fragment gone) is owed
  with the other tests.
- [x] **P2-4 (L) Terminal search.** ⌘F find bar on Ghostty search actions: next/previous, match count,
  case toggle, highlight all, Esc closes. *Tests:* U, UI, HT. *Parity:* TERM-3.
  *Done:* GhosttyKit's wrapper drops Ghostty's search actions, so `Vendor/ghostty/patches/
  0001-search-delegate.patch` adds `TerminalSurfaceSearchDelegate` (start/end search, total,
  selected); `build.sh` applies `patches/*.patch` idempotently, on a fresh build and to an existing
  package. `AletheTerminal/TerminalSearch` (observable state + "n of m" status) and
  `TerminalPaneView` as the delegate: `showSearch`, `updateSearch` (`search:`), next/previous
  (`navigate_search`), `searchSelection`, `closeSearch` (`end_search`, focus back to the terminal).
  `Terminals/TerminalFindBar` sits over the terminal's top trailing corner (search as you type, ↩ / ⇧↩,
  Esc, count, buttons); `PaneView` follows the active tab's search through observation, so Ghostty's
  own ⌘F (`start_search`) opens the same bar. Terminal menu: Find… ⌘F, Find Next ⌘G, Find Previous
  ⇧⌘G, Use Selection for Find ⌘E.
  *Deviation:* no case toggle: Ghostty's search is always case-insensitive and has no option for it.
  Highlight all comes from Ghostty.
  *Tests (written 2026-09-24, run and passing in the full run after P2-5):* `TerminalSearchTests` (2), UI
  `TerminalSearchTests` (find/count/next/Esc; HT at 90/100/120 %).
- [x] **P2-5 (M) Smart copy/paste.** Paste images (saved to a temp file, path typed in), files from
  Finder (quoted paths), large text with bracketed paste; copy on select optional. *Tests:* U (payload
  mapping), UI. *Parity:* TERM-4.
  *Done:* Already native before this task (GhosttyKit + Ghostty): text paste with bracketed paste and
  newline handling, and files copied in Finder pasting as escaped paths. Added:
  `AletheTerminal/SmartPaste` (upstream priority files → image → text; paths escaped like Ghostty's
  macOS app, with upstream's trailing space; images saved as PNG under
  `$TMPDIR/Alethe/Pasted Images`, TIFF/JPEG/HEIC converted). `TerminalPaneView.pasteImageIfNeeded`
  pastes a saved image's path through `paste(text:)`; `Terminals/ImagePasteMonitor` (local key
  monitor installed at launch) routes ⌘V there only when a terminal has focus and the pasteboard holds
  just an image. The terminal accepts drops: Finder files paste as paths, dragged images are saved
  first, with an accent border while dragging.
  *Deviations:* paths are backslash-escaped, not double-quoted (the macOS convention Ghostty and
  Terminal use; upstream quotes for Windows). Edit › Paste clicked with the mouse still pastes text
  only (the monitor sees ⌘V). No copy on select (upstream has none; Ghostty's option can come with
  terminal settings).
  *Tests (written 2026-09-24, run and passing in the full run after P2-5):* `SmartPasteTests` (5). No UI test: the
  terminal's text is not readable through accessibility; image paste and drops are owed as a manual
  check.
- [x] **P2-6 (M) Prompt history.** Per-tab history of submitted prompts, ⌃↑/⌃↓ to recall, persisted per
  profile with a cap. *Tests:* U (port of upstream cases), UI. *Parity:* TERM-5.
  *Done:* `AletheTerminal/PromptHistory` ports `applyPromptHistoryInput` + `navigateHistory` (lines of
  2+ characters, no consecutive duplicates, last 50, pastes over 4 KiB never kept, ⌃U and backspace
  followed; recall writes ⌃U + the entry; past the newest comes an empty line), reusing the first
  attempt's port with two fixes: `"\r\n"` is one Swift `Character`, and escape sequences (arrow keys,
  Ghostty's bracketed-paste markers) are skipped instead of landing in the line as `[A`.
  `TerminalPaneView` records keyboard input on the session's write path and exposes `recallPrompt`;
  `AletheModel/PromptHistoryDocument` persists every tab's history in the profile's
  `prompt-history.json` (debounced atomic `DocumentModel`, pruned of closed tabs at load).
  Terminal menu: Older / Newer Prompt from History, ⌥⌘↑ / ⌥⌘↓.
  *Deviation:* ⌃↑/⌃↓ are Mission Control and App Exposé on macOS; the binding is ⌥⌘↑/⌥⌘↓ (§6.3).
  *Tests (written, not run — owner decision 2026-09-24):* `PromptHistoryTests` (7),
  `PromptHistoryDocumentTests` (1); package and app build compile. No UI test: the terminal's text is
  not readable through accessibility.
- [x] **P2-7 (L) Scrollback persistence + reattach.** Ring buffer flushed to `scrollback/<tab>.bin`
  (bounded, debounced, atomic), replayed on relaunch before the resumed process draws; clear
  scrollback action. *Tests:* U (file format, truncation), P (flush cost with 10 busy terminals).
  *Parity:* TERM-10.
  *Done:* `AletheTerminal/ScrollbackFile` follows upstream `pty.rs`: 4 MiB per terminal, output
  appended in 250 ms batches on a private serial queue, the file compacted to its last 4 MiB once it
  passes 8 MiB (appends stay appends; only compaction rewrites, atomically), `load` returns the tail.
  `TerminalPaneView(scrollback:)` replays the saved output into the session before the new process
  starts, then `replayReset` (leave the alternate screen, mouse reporting and bracketed paste off,
  cursor shown, colors reset) so a dead TUI's modes do not leak into the new process; every output
  chunk is appended. `TerminalRegistry` keeps one file per tab (ordering on one queue): restart clears
  it (upstream `restart_pty`), closing the tab deletes it, quitting flushes it. `AppEnvironment`
  removes files of tabs that no longer exist at launch. Terminal › Clear Scrollback ⌥⌘K (Ghostty
  `clear_screen` + the file).
  *Limits:* GhosttyKit buffers at most 1 MiB for a surface not yet attached, so a replay shows the last
  1 MiB of the saved 4 MiB. ⌘K stays free for Find/Jump (P2-25).
  *Tests (written, not run — owner decision 2026-09-24):* `ScrollbackFileTests` (4), P
  `ScrollbackFilePerformanceTests.testTenBusyTerminalsFlushCost` (10 terminals × 1 MiB). Manual check
  owed: quit with output on screen, relaunch, output is back above the new prompt.
- [x] **P2-8 (M) Pane kinds + Add Content.** Model v2: `Pane.content` (terminal | markdown | image | video
  | diff | web) with a migration from v1; Add Content sheet listing the kinds (unavailable kinds
  hidden until their task lands). *Tests:* U (migration golden), UI. *Parity:* WS-11.
  *Done:* `AletheModel/PaneContent` (upstream `PaneKind` minus `file`, `graphify`, `orchestrator`,
  which arrive with their features), stored as `{kind, path|url}`. `WorkspaceDocument` v2: the
  migration gives every v1 pane `content: {kind: terminal}` (the store backs the v1 file up first).
  Non-terminal panes have no tabs (`Pane.init` drops them, `addTab` refuses them, no lane);
  `addPane(to:content:)` adds one. `Editors/AddContentSheet` (File › Add Content… ⇧⌘A) lists
  `options`, empty until P2-9, so the menu item stays disabled rather than offering kinds that do not
  work yet.
  *Tests (written, not run — owner decision 2026-09-24):* `PaneContentTests` (3: round trip, v1
  golden migration through `DocumentStore`, content panes). UI test comes with P2-9, the first option.
- [x] **P2-9 (M) Markdown pane.** Rendered view of a file with live reload (`DispatchSource` file
  watch), edit/preview toggle, save. *Tests:* U (watcher), UI. *Parity:* WS-6.
  *Done:* new `AletheDocuments` target (ADR-11). `MarkdownBlocks` turns swift-markdown's tree into
  blocks (headings, paragraphs, standalone images, code, quotes, ordered/unordered/task lists, GFM
  tables with alignment, rules, raw HTML as source) with inline `AttributedString` (emphasis, strong,
  code, strikethrough, links); relative links and images resolve against the file's folder.
  `FileWatcher` (`DispatchSource`, coalesced, reopens after an atomic replace or delete).
  `MarkdownFile` (observable): parse off the main actor, reload on change but never over a draft,
  edit/save (atomic) /cancel. App: `Workspace/ContentPanes/` (`MarkdownBlocksView` with theme
  tokens and selectable text, `MarkdownPaneView` with header Reload / Copy Source / Edit / Save ⌘S /
  Cancel / Show in Finder / Close and drag-to-reorder, `ContentPaneRegistry` keeping one model per
  pane, pruned when panes go). `PaneView` hosts any non-terminal pane as one SwiftUI view.
  Add Content gains "README or Markdown" (file panel at the project folder), which enables ⇧⌘A.
  *Deviations:* Mermaid shows as a code block (ADR-11). Content panes are not listed in the sidebar
  yet (it lists terminal tabs); upstream lists them — with WS-11's remaining kinds.
  *Tests (written, not run — owner decision 2026-09-24):* `MarkdownBlocksTests` (5),
  `MarkdownFileTests` (4, incl. atomic replace twice), UI `MarkdownPaneTests` (render/edit/save/close
  + undo; HT at 90/100/120 %), seed `markdown`. Package, app and UI-test targets compile.
- [x] **P2-10 (S) Image and video panes.** Image with fit/actual size; video on AVKit. *Tests:* UI.
  *Parity:* WS-7, WS-8.
  *Done:* `PaneContent.forFile` ports upstream `classifyPaneKind` (video/image/Markdown extensions,
  `:line[:col]` suffix dropped; nil for other files) and `filePath`. `ContentPanes/ContentPaneHeader`
  is now shared by every file pane (icon, name, the pane's actions, Show in Finder, Close,
  drag-to-reorder); the Markdown pane moved onto it. `MediaPaneViews`: `ImagePaneView` (fitted, or
  actual size with scrolling; `ImageFile` rereads the bytes when the file changes, NSImage's URL
  cache would show the old one) and `VideoPaneView` (AVKit `VideoPlayer` with system controls; the
  `AVPlayer` lives in `ContentPaneRegistry`, so layout changes never restart playback, and it is
  paused when the pane goes). Add Content gains "Image or Video" (images and movies, kind by
  extension).
  *Tests (written, not run — owner decision 2026-09-24):* `PaneContentForFileTests` (2), UI
  `MediaPaneTests` (fit/actual/close, HT at 90/100/120 %), seed `media`. No UI test for video (no
  movie fixture); compiled.
- [x] **P2-11 (M) Diff pane.** `git diff` for the project or one file, unified/split, refresh.
  *Tests:* U (diff parser golden), UI. *Parity:* WS-9.
  *Done:* `PaneContent.diff(path:staged:)` (upstream `terminal.staged`; stored only when true).
  `AletheDocuments/GitDiff`: `GitDiff.run` (upstream `git_diff`: `git diff [--staged] [-- path]`, no
  color/pager/external diff, pipe drained before waiting, 2 MiB cap, binary and not-a-repository
  errors) and `DiffParser` (files, headers incl. renames, hunks with old/new line numbers, "\ No
  newline" notes; `split` pairs removals with the additions after them). `ContentPanes/DiffPaneView`
  + `DiffModel`: file and hunk headers, colored lines with both line numbers, unified or side by side
  (not persisted), working tree / staged toggle (persisted in the pane, not undoable), reload.
  Add Content gains "Git Changes" (the whole project, working tree).
  *Deviation:* side-by-side is native (upstream only shows the unified text).
  *Tests (written, not run — owner decision 2026-09-24):* `DiffParserTests` (3), `GitDiffTests` (real
  git in a temporary repository), UI `DiffPaneTests` (layouts, staged, close; HT at 90/100/120 %),
  seed `diff`. Compiled.
- [x] **P2-12 (L) Web pane.** WKWebView with tabs, address bar, back/forward/reload, resource modes,
  persisted URL. *Tests:* U (URL normalization port), UI, HT. *Parity:* BR-1.
  *Done:* `AletheModel/WebPane`: `WebAddress.normalize` (port of `normalizeBrowserUrl`),
  `WebResourceMode` with `hiddenEvictionDelay` (port of `browserHiddenEvictionDelay`: 1 s, 30 s,
  never; 0 under memory pressure) and `WebPaneOptions` (mode, JavaScript, zoom; upstream
  `BrowserPaneConfig` without the CDP engine), stored in `PaneContent.web(url:options:)` only when not
  default. App: `ContentPanes/WebPageModel` (a private WKWebView on a non-persistent data store,
  KVO-observed title / loading / back / forward, failures kept for an overlay, `target=_blank`
  opened in place, non-web schemes handed to the system; released after the mode's delay once hidden,
  recreated on the last address when shown) and `WebPaneView` (back, forward, reload/stop, address
  field with validation, Private badge, options menu: JavaScript, zoom, While Hidden mode; Open in
  Browser, Close; toolbar drag reorders). `ContentPaneRegistry` keeps the pages and releases hidden
  ones on a system memory-pressure event; the address a page settles on is persisted. Add Content
  gains "Website" (address prompt, localhost:3000 prefilled).
  *Deviation:* no tabs inside a web pane: upstream has none either (one page per pane).
  *Tests (written, not run — owner decision 2026-09-24):* `WebPaneTests` (5: URL and policy ports,
  options decoding), UI `WebPaneTests` (failure overlay, refused address, options, close; HT at
  90/100/120 %), seed `web` (closed local port, no network). Compiled.
- [ ] **P2-13 (M) Clickable links.** ⌘-click file/URL/image links in terminals: open in a pane of the
  right kind, in the web pane or the default browser. *Tests:* U (link detection port), UI.
  *Parity:* TERM-6.
- [ ] **P2-14 (S) Link viewer overlay.** Quick preview of a clicked file or URL without adding a pane.
  *Tests:* UI. *Parity:* WS-12.
- [ ] **P2-15 (S) Agent page offer.** When an agent prints a local server URL, offer to open it in a web
  pane. *Tests:* U (detection), UI. *Parity:* BR-2.
- [ ] **P2-16 (M) Container controls.** Collapse, fullscreen and reorder of project containers; isolate
  a pane. *Tests:* U, UI, HT; drag smoke script. *Parity:* WS-1.
- [ ] **P2-17 (M) Workspace tabs and history.** Tabs of open workspaces, reopen closed tab (⇧⌘T), back
  and forward (⌘[ / ⌘]). *Tests:* U (port of `workspaceNavigation` cases), UI. *Parity:* WS-5.
- [ ] **P2-18 (M) Spotlight and Sidebar layouts.** Layout picker per project; Auto stays the default.
  *Tests:* U (geometry), UI, HT. *Parity:* WS-3 (part).
- [ ] **P2-19 (L) Custom grid + layout designer.** Cell merge/split, drag handles, per-scope layout
  history. *Tests:* U (port of `gridLayout` cases), UI; drag smoke script. *Parity:* WS-3.
- [ ] **P2-20 (M) Named project grids.** Several grids per project, switch and assign panes.
  *Tests:* U, UI. *Parity:* WS-4.
- [ ] **P2-21 (S) Flat mode and focus mode.** Flat workspace (no containers) and a focus overlay on one
  pane. *Tests:* UI. *Parity:* WS-2, WS-10.
- [ ] **P2-22 (S) Empty workspace launcher.** Quick actions when nothing is open. *Tests:* UI, HT.
  *Parity:* WS-13.
- [ ] **P2-23 (M) Disable and suspend.** Disable a terminal or project, suspend a group (SIGSTOP/SIGCONT),
  shown in the sidebar. *Tests:* U, UI. *Parity:* WS-14, SB-3.
- [ ] **P2-24 (L) Resources: hibernation, priorities, RAM.** Memory per process tree, idle hibernation
  (scrollback kept, process resumed on focus), priorities, pressure handling, memory indicator.
  *Tests:* U (policy), P (memory per hibernated terminal). *Parity:* USE-3.
- [ ] **P2-25 (M) Find/Jump (⌘K).** Fuzzy search over projects, terminals and commands. *Tests:* U
  (ranking port), UI, HT. *Parity:* SET-10.
- [ ] **P2-26 (S) Resume last session and close confirmation.** Reopen the last workspace or start
  clean; confirm quitting with running agents. *Tests:* UI. *Parity:* SE-2, SET-12.
- [ ] **P2-27 (S) Visual style and motion.** Normal/clean style (sidebar Clean mode included) and the
  motion preference, which also follows Reduce Motion. *Tests:* UI, HT. *Parity:* UI-2, UI-3, SB-1.
- [ ] **P2-28 (S) Changelog + phase review.** Parity matrix statuses; run upstream-watch; full test run.

**Phase 2 exit criteria:** every terminal and workspace feature of the parity rows above works at
parity, terminals survive relaunch with their scrollback, and idle terminals hibernate.

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
| WS-1 | Project containers | P1 | Partial | Open many, resize, close (P1-6); collapse/fullscreen/reorder later |
| WS-2 | Flat mode | P2 | Not started | |
| WS-3 | Layouts Auto/Spotlight/Sidebar/Custom | P1 (Auto), P2 | Partial | Auto done (P1-6) |
| WS-4 | Named project grids | P2 | Not started | |
| WS-5 | Tabs, closed tabs, history | P2 | Not started | |
| WS-6 | Markdown pane | P2 | Done | P2-9; Mermaid as code (ADR-11) |
| WS-7 | Image pane | P2 | Done | P2-10 |
| WS-8 | Video pane | P2 | Done | P2-10; AVKit |
| WS-9 | Diff pane | P2 | Done | P2-11; side by side added |
| WS-10 | Focus mode | P2 | Not started | |
| WS-11 | Add content | P2 | Done | Markdown (P2-9), image/video (P2-10), Git changes (P2-11), website (P2-12); orchestration with ORC-1 |
| WS-12 | Link viewer overlay | P2 | Not started | |
| WS-13 | Empty workspace launcher | P2 | Not started | |
| WS-14 | Disable terminal/project, suspend group | P2 | Not started | |
| TERM-1 | Real PTYs + process tree | P1 | Partial | Spawn/resize/restart/kill done (P1-7); shell integration marks (P2-3); process-tree kill (P2-2); process-tree info later |
| TERM-2 | Sub-tabs lane | P2 | Done | P2-1; close is undoable instead of confirmed |
| TERM-3 | Terminal search | P0 spike, P2 | Done | P2-4; Ghostty search is case-insensitive only |
| TERM-4 | Smart copy/paste | P2 | Done | P2-5; paths backslash-escaped (macOS convention) |
| TERM-5 | Prompt history | P2 | Done | P2-6; ⌥⌘↑/⌥⌘↓ |
| TERM-6 | Clickable links | P2 | Not started | |
| TERM-7 | Terminal themes/font | P1 | Done | App theme + zoom-scaled font (P1-7) |
| TERM-8 | Restart / command-not-found overlays | P1 | Done | Install button comes with AG-5 |
| TERM-9 | Double ^C force-kill | P2 | Done | P2-2; kills the whole process tree |
| TERM-10 | Scrollback persistence + reattach | P2 | Done | P2-7; replay limited to the last 1 MiB by GhosttyKit |
| TERM-11 | `alethe` CLI shim | P5 | Not started | |
| SB-1 | Project tree (Normal/Clean) | P1 | Partial | Tree, reorder, drag and drop, context menus (P1-4); Clean mode with UI-2 |
| SB-2 | New/edit project (clone, marker, git init, stack) | P1 (basic), P5 | Partial | Name, color, folder, group (P1-5); clone, marker, git init, stack in P5 |
| SB-3 | Groups (nested, suspend) | P1, P2 | Partial | Nested groups (P1-4/P1-5); suspend comes with WS-14 |
| SB-4 | Export/import project config | P5 | Not started | |
| SB-5 | Live chat title + busy/done glyph | P3 | Not started | |
| SB-6 | Open in VS Code / Finder / browser | P5 | Not started | `NSWorkspace` |
| SB-7 | Right sidebar | P4 | Not started | Inspector column |
| SB-8 | View placement | P4 | Not started | |
| AG-1 | 11 agent types | P1 (5), P3 | Partial | Claude, Codex, OpenCode, Cursor, shell (P1-8); `wsl`: Won't port (Windows-only) |
| AG-2 | Unrestricted flags | P1 | Done | Launch support (P1-8); per-terminal toggle in the New Terminal sheet (P1-9) |
| AG-3 | New-terminal modal | P1, P3 | Partial | Basic sheet + first prompt (P1-9); grid picker, 9router, planner, repeat last in P3 |
| AG-4 | Launcher resolution + override | P1, P3 | Partial | Resolver + `cliPaths` (P1-8); Choose CLI… on a missing CLI (P1-7); Settings page with AG-5 |
| AG-5 | Install/update/uninstall CLIs | P3 | Not started | |
| AG-6 | Enable/disable agents | P3 | Not started | |
| AG-7 | Claude ↔ Codex handoff | P3 | Not started | |
| AG-8 | Agent hook bridge | P3 | Not started | |
| AG-9 | Model discovery | P3 | Not started | |
| SE-1 | Session auto-resume (5 providers) | P1 (2), P3 | Partial | Claude + Codex (P1-10); OpenCode, Antigravity, Cursor in P3 |
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
| FS-2 | Folder browser | P1 | Replaced | `NSOpenPanel` + Finder drops (P1-4, P1-5) |
| BR-1 | Web pane | P2 | Done | P2-12, WKWebView (private); CDP engine: Won't port |
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
| UI-1 | Themes (16 + 4) | P0, P1, P4 | Partial | 16 built-ins + picker (P1-11); theme packs in P4 |
| UI-2 | Visual style normal/clean | P2 | Not started | Moved from P1 at the Phase 1 review |
| UI-3 | Motion preference | P2 | Not started | Also follows system Reduce Motion; moved from P1 at the Phase 1 review |
| UI-4 | App icon themes | P5 | Not started | `NSApp.applicationIconImage` |
| UI-5 | UI zoom | P1 | Done | Font + metric scale only; View menu + Settings (P1-11) |
| UI-6 | Window opacity | — | Won't port | Win32-only upstream; Mac uses materials |
| UI-7 | Toolbar configuration | P5 | Not started | Native toolbar customization |
| UI-8 | i18n EN + pt-BR | P0, P1 | Done | String Catalogs (P0-4); language setting + relaunch (P1-11) |
| SET-1 | Preferences | P1, ongoing | Partial | Settings scene with Appearance (P1-1, P1-11); other panes land with their features |
| SET-2 | Feature toggles | P5 | Not started | |
| SET-3 | Profiles | P1 (base), P5 | Partial | Default profile + folder layout (P1-3); profile UI in P5 |
| SET-4 | Backup/import/reset/logs | P5 | Not started | |
| SET-5 | GitHub gist sync | P7 | Not started | |
| SET-6 | Cloud sync | — | Won't port | Upstream server not shipped (localhost default); revisit if it ships |
| SET-7 | Onboarding + welcome | P5 | Not started | Tauri import done as File menu item (P1-12); onboarding offers it in P5 |
| SET-8 | Updater + What's New | P8 | Not started | Sparkle |
| SET-9 | Notifications | P3 | Not started | |
| SET-10 | Find/Jump | P2 | Not started | |
| SET-11 | Audit center | P5 | Replaced | OSLog + diagnostic export |
| SET-12 | Close confirmation | P2 | Not started | |
| SET-13 | Keyboard shortcuts | P1, ongoing | Partial | ⌘N, ⇧⌘N, ⌘O, ⌘T, ⌘,, zoom, undo (P1-1…P1-9); §6.3 |
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
