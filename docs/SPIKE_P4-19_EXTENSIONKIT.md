# Spike P4-19 — ExtensionKit for third-party plugins

Time-boxed spike (2026-09-25). Goal: confirm that ADR-9's choice (ExtensionKit app extensions for
third parties; in-process bundles rejected) is buildable on the current toolchain, and land the
pure-Swift host pieces that do not need an Xcode extension target.

Environment: macOS 27.0 (26A428), Xcode SDK `MacOSX27.0.sdk`, app deployment target macOS 26.

## Verdict

**ADR-9 holds.** Every API the design needs is public in the SDK, and the SDK now lets a host app
*declare its own* extension point in Swift (no private `.appextensionpoint` plist hacks). A
host + extension sketch covering declaration, discovery, remote scene, XPC and crash callback
typechecks against the SDK. What was **not** done in the time box: a real signed extension target,
an on-device load, and the UI tests (sample loads / crash contained). Those remain P4-19 follow-ups;
nothing found argues for falling back to in-process bundles.

## API availability (verified in the SDK swiftinterface/headers)

| Need | API | Availability |
|---|---|---|
| Host declares extension point | `@AppExtensionPoint.Definition static var x: AppExtensionPoint { Name(…); Scope(restriction: .none); UserInterface(true); EnhancedSecurity(true) }` | macOS 26.0 |
| Errors when the host did not declare it | `AppExtensionPoint.Error.hostMustDefineAppExtensionPoint`, `.hostMustBeApplicationOrAppExtension` | macOS 26.0 |
| Extension binds to host's point | `@AppExtensionPoint.Bind var extensionPoint { AppExtensionPoint.Identifier(host: "com.kc1t.alethe", name: "…") }` (on `AppExtension`) | macOS 26.2 (Bind with `Capabilities` also 26.2) |
| Discovery (observable) | `AppExtensionPoint.Monitor(appExtensionPoint:)` → `.identities`, `.state`, `@Observable` | macOS 26.0 |
| Discovery (legacy) | `AppExtensionIdentity.matching(appExtensionPointIDs:)` | macOS 13, **deprecated in 26** → use `Monitor` |
| User enable/disable UI | `EXAppExtensionBrowserViewController` (ExtensionKit header, NSViewController) | macOS 13+ |
| Remote UI | `EXHostViewController` + `.configuration = .init(appExtension:sceneID:)`; delegate `hostViewControllerDidActivate` / `hostViewControllerWillDeactivate(_:error:)`; extension side `AppExtensionSceneConfiguration` + `PrimitiveAppExtensionScene(id:)` | macOS 13+ |
| Non-UI command / storage channel | `AppExtensionProcess(configuration: .init(appExtensionIdentity:onInterruption:))` → `makeXPCConnection()` or `makeXPCSession()` (26.0); extension side `ConnectionHandler(onConnection:)` (26.0) or `accept(connection:)` | macOS 13 / 26 |
| Crash signal | `AppExtensionProcess.Configuration.onInterruption`, `hostViewControllerWillDeactivate(_:error:)`, XPC `interruptionHandler` | macOS 13+ |
| Declarative capabilities | `AppExtensionPoint.Capabilities` / `Capability` protocol | macOS 26.2 |

Typecheck evidence: a scratch file using `@Definition`, `Monitor`, `EXHostViewController`,
`AppExtensionProcess.makeXPCConnection()` and an `AppExtension` with `@Bind` passes
`swiftc -typecheck` at both `-target arm64-apple-macos26.2` and `26.0` (the `@Bind` extension type is
gated `@available(macOS 26.2, *)`).

## Findings / constraints

- **Deployment target.** The host side works on macOS 26.0. Extensions using `@Bind` to a
  host-defined point need **26.2**; third-party extensions can simply require 26.2. Alternative on
  26.0: the extension's Info.plist `EXAppExtensionAttributes.EXExtensionPointIdentifier`.
- **Scope.** `Scope(restriction: .none)` is what allows extensions shipped in *other* apps
  (third parties); the default `.application` restricts to extensions inside Alethe's own bundle.
- **Capabilities.** Apple's `AppExtensionPoint.Capabilities` are opaque protocol values, not a
  permission system. Alethe's own capabilities (`PluginCapability`) stay the source of truth:
  the extension declares them in its Info.plist (`AletheExtension.capabilities`), the host maps them
  strictly (unknown → reject) and enforces them on every XPC request. The first-enable prompt is
  Alethe UI, on top of the system's enable toggle in `EXAppExtensionBrowserViewController`.
- **Storage.** The extension is sandboxed and cannot reach Alethe's data; storage goes through the
  XPC connection to the host, which writes into the plugin's `PluginStorage` file under the
  `storage` capability. No shared app group needed.
- **Commands.** Command metadata (id, title) lives in the Info.plist so the palette can list them
  without launching the extension; invocation is an XPC call (`run(commandID:)`).

## Entitlements / signing

- **Host (Alethe):** no special entitlement to *host* extensions; the extension point is declared in
  code. The app is currently not sandboxed (only `device.audio-input`), which is fine for hosting.
  Must have a stable bundle id (`com.kc1t.alethe`) — `hostMustHaveBundleIdentifier`.
- **Extension:** must be sandboxed (`com.apple.security.app-sandbox`), live in `Contents/Extensions/`
  of a containing app, and be signed. Discovery requires LaunchServices registration of the
  containing app (launch it once, or `lsregister`), and the user must enable it (browser VC).
- **Dev signing:** `AletheNative/Scripts/dev-signing.sh` creates a self-signed "Alethe Dev Signing"
  identity. Good enough for local host + sample. **Open risk:** a self-signed extension from a
  different "team" may be refused by the system extension policy; production third-party extensions
  need Developer ID + notarization. To verify in the follow-up.

## Crash-isolation model

The extension runs in its own sandboxed process (spawned by ExtensionKit, not by Alethe).
A crash in it:
1. fires `onInterruption` / the XPC `interruptionHandler` and `hostViewControllerWillDeactivate`;
2. the host swaps the sidebar tab for an "Extension stopped — Reload" placeholder and fails pending
   XPC calls with an error;
3. the host process, PTYs and other plugins are unaffected (separate address space).
Policy to implement: restart on demand, auto-disable after N crashes in a window.

## Landed code

New package target `AletheExtensionHost` (depends only on `AlethePluginKit`; no Xcode/app changes):
- `ExtensionDescriptor` + `ExtensionCapabilityMapper` — map declared strings to `PluginCapability`
  strictly, check API compatibility, build a `PluginManifest` with `enabledByDefault: false`.
- `ExtensionConsentLedger` (Codable) — first-enable prompt, re-prompt only for the delta when an
  update asks for more, deny/forget, and `isAllowed(_:for:)` for XPC enforcement.
- Tests: `AletheExtensionHostTests`, 10 tests, green; `swift build` green.

## Next steps (to close P4-19)

1. Add a `SampleExtension` app + ExtensionKit extension target (26.2, `@Bind`, sandboxed) with one
   `PrimitiveAppExtensionScene(id: "sidebar", content:, onConnection:)` (the scene gets its own XPC connection), one command and a storage round trip.
2. In the app: `@Definition` the point (`alethe.sidebar-tab`, `Scope(.none)`, `UserInterface`),
   a `Monitor`-driven list in Settings > Plugins, `EXAppExtensionBrowserViewController` for
   system enablement, the consent sheet from `ExtensionConsentLedger`, and a SwiftUI
   `NSViewControllerRepresentable` around `EXHostViewController` as a sidebar tab.
3. Define the XPC protocol (`@objc` protocol or `XPCSession` Codable messages): `invokeCommand`,
   `storageGet/Set`, with host-side capability checks.
4. UI tests: sample loads and renders; `kill -9` of the extension process shows the placeholder and
   the app keeps running.
5. Verify the signing risk above, then record the outcome in ADR-9.

## Follow-up: host + sample landed (2026-09-25, round 19)

Owner rule for this round: **no tests were run** and the app was not launched; everything below is
verified by compiling and by inspecting the built bundles.

### What landed

- **App (host)** — `Alethe/Extensions/`:
  - `ExtensionPoint.swift`: `@AppExtensionPoint.Definition static var aletheSidebarTab` —
    `Name("sidebar-tab")`, `Scope(restriction: .none)`, `UserInterface(true)` (no
    `EnhancedSecurity`: it would require the hardened-process entitlements from every third party).
  - `ExtensionManager` (`@Observable`, owned by `AppEnvironment`): `AppExtensionPoint.Monitor`
    discovery (re-synced with `withObservationTracking`), one `AppExtensionProcess` +
    `makeXPCConnection()` per extension (manifest, commands, `onInterruption` → stopped), host
    storage served through `ExtensionRequestRouter` with `ExtensionHostState.isAllowed`, state in the
    profile's `extensions.json`.
  - Settings › Plugins › **Third-party extensions**: toggle per extension (disabled until the
    manifest arrives), consent sheet (first enable; re-prompt only for new capabilities; decline
    keeps it off), the extension's commands with their reply, "Manage Extensions…" presenting
    `EXAppExtensionBrowserViewController`, and a footer counting extensions awaiting system approval.
  - Right sidebar: active extensions with a `sidebarTab` add a tab rendered by `EXHostViewController`
    (scene `sidebar`); the scene's own connection (`makeXPCConnection()` in
    `hostViewControllerDidActivate`) also gets the host service. `hostViewControllerWillDeactivate`
    with an error, or the process's interruption, swaps in "The extension stopped" + Reload.
- **Packages**: new `AletheExtensionSDK` (Foundation only): point constants, `ExtensionManifestPayload`,
  `HostRequest`/`HostResponse`, JSON framing, `@objc` `AletheHostXPC` / `AletheExtensionXPC`.
  `AletheExtensionHost` adds `ExtensionHostState` (enable + ledger, persistence) and
  `ExtensionRequestRouter`; 10 more unit tests (compiled, not run).
- **Sample** — `AletheNative/Samples/AletheSampleExtension`: `AletheSample.app` (minimal sandboxed
  containing app, `com.kc1t.alethe.sample`) embedding `AletheSampleSidebar.appex`
  (`com.apple.product-type.extensionkit-extension`, sandboxed, macOS 26.2,
  `com.kc1t.alethe.sample.sidebar`) with `@AppExtensionPoint.Bind` →
  `Identifier(host: "com.kc1t.alethe.mac", name: "sidebar-tab")`, a SwiftUI tab, an
  "Increment Counter" command, a counter in host storage, and a DEBUG-only Crash button
  (`fatalError`). Shared scheme `AletheSample`; `AletheUITests` depends on it.
- **UI tests** (`AletheUITests/ExtensionKitTests.swift`, compiled with `build-for-testing`, not
  run): discovery in Settings, consent on first enable / after decline / not after a grant; tab
  renders, storage round trip, Crash → stopped state with Alethe still running, Reload.

### Findings while building

- **Host bundle id is `com.kc1t.alethe.mac`** (the spike text said `com.kc1t.alethe`, which is the
  Tauri app). The point's full id is `com.kc1t.alethe.mac.sidebar-tab`.
- **The host's point is only extracted with `EX_ENABLE_EXTENSION_POINT_GENERATION = YES`.** Without
  it, `@Definition` compiles (const values are emitted) but no `Contents/Extensions/Alethe.appexpt` is
  produced. With it the bundle carries `{com.kc1t.alethe.mac.sidebar-tab: {EXExtensionPointName,
  EXPresentsUserInterface: true, _EXScopeRestriction: none}}`.
- **`exutil generate-appextension-plist` is nondeterministic** (Xcode 27A266a): given several
  `.swiftconstvalues` inputs (one per Swift file, plus the string-catalog symbols) it drops the
  `@Bind` result in most runs and writes an empty dict; with the single file that holds the
  extension type it is stable. The sample therefore sets
  `EX_DISABLE_APPEXTENSION_ATTRIBUTES_GENERATION = YES` and states `EXAppExtensionAttributes /
  EXExtensionPointIdentifier` in `SidebarExtension-Info.plist` (the `@Bind` stays in code).
- **Manifest over XPC, not Info.plist.** `AppExtensionIdentity` exposes no bundle URL, so the host
  cannot read an `AletheExtension` Info.plist dictionary; the manifest (capabilities, commands, tab)
  comes from the extension's `manifest(reply:)` on its process connection. The process is sandboxed
  and gets no host service before consent (`isAllowed` requires enabled + granted).
- **Registration.** Debug builds accept `-AletheRegisterExtensionApp <path>` and call
  `LSRegisterURL` so UI tests find the sample without launching it.

### Still unverified (needs a run)

- That the self-signed "Alethe Dev Signing" extension is accepted by the extension policy and
  shows up in `Monitor.identities` (or only after approval in Manage Extensions — the UI tests
  assume no approval step; if one is needed they will fail at discovery).
- The remote scene's accessibility tree being visible to XCUITest (`sample.counter`,
  `sample.crash`), and `hostViewControllerWillDeactivate` reporting a non-nil error on a crash.
- Auto-disable after N crashes in a window (not implemented; Reload is manual).
