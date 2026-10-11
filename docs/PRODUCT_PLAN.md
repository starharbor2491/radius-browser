# Radius — unified product and implementation plan

**Radius is a native macOS browser that works immediately, but lets ordinary users install, remove, replace, and visually customize its parts—including the browser engine.**

The merged direction is to keep Gemini’s **SwiftUI/AppKit interface, system WebKit integration, and optional Chromium installation**, while adding the **GUI-first module management, deep visual customization, compatibility handling, and recovery system** from the earlier plan.

The complexity belongs inside Radius. Users should never need a terminal, configuration files, or knowledge of browser architecture.

> **A complete Mac browser by default. A browser you can rebuild through its interface.**

---

## 1. The default experience

### Install it and start browsing

Radius should open with a finished interface: tabs, an address bar, bookmarks, history, downloads, private browsing, and sensible security settings.

**WebKit should be the default engine**, accessed through Apple’s `WKWebView` integration. This avoids an additional engine download for basic browsing; `WKWebView` is Apple’s platform-native view for embedding web content. [Apple Developer](https://developer.apple.com/documentation/webkit/wkwebview?utm_source=chatgpt.com)

First launch should provide an optional import flow and two straightforward actions:

**Start browsing** opens the default WebKit configuration.

**Set up Chrome extensions** installs the Chromium engine package, explains its storage requirements, and offers to make it the default for future browsing.

There should be no mandatory engine questionnaire. Someone who does not care about modularity should still get a usable browser.

For offline installation, provide a complete installer containing Chromium and the default modules. This should install the same Radius application—not create a separate product edition.

### Keep the application interface independent of its engines

Settings, the module manager, the theme editor, and the recovery interface should be native views. They must remain functional when Chromium is absent or a browsing engine crashes.

**Uninstalling an engine must not uninstall the interface needed to install another one.**

---

## 2. Define modularity in terms users understand

Radius should present understandable features, not a list of internal libraries.

| Category | Examples | User controls |
|---|---|---|
| **Features** | Notes, translation, reader mode, screenshots, sync, start-page widgets | Install, configure, disable, uninstall. |
| **Interface components** | Tab systems, sidebars, bookmark panels, toolbars, download panels | Add, remove, rearrange, replace. |
| **Feature providers** | Password managers, bookmark managers, download managers, search providers | Select a replacement and migrate supported data. |
| **Appearance** | Themes, icon packs, layout presets, animation styles | Preview, apply, edit, share, remove. |
| **Browser engines** | System WebKit integration, Chromium, future supported engines | Install, select, update, switch, remove. |
| **Advanced components** | Compatible storage, networking, or engine-internal providers | Replace through guided interfaces where genuine alternatives exist. |

### Hide, disable, and uninstall are separate operations

**Hide** removes a component from the layout.

**Disable** stops its operation while retaining its installation and settings.

**Uninstall** removes its package and stops its execution. Radius should separately offer to keep or delete its saved data.

Removing a bookmarks button should not delete bookmarks. Removing a bookmark provider should initiate an explicit data-migration or deletion flow.

Default optional features should be installed as real packages, not permanently embedded functionality with an “uninstall” button that only hides them.

### Required functions need a replacement flow

Some roles are necessary for a functioning browser. Their implementations should still be replaceable.

Removing an optional notes module can happen immediately. Removing the active engine should show:

> **Choose a replacement engine**  
> Radius needs an engine to display websites. Select another installed engine or install one before removing this package.

A small native bootstrap and recovery layer should remain available. It should be open-source and updated with the application, rather than treated as an ordinary removable feature.

That is the practical boundary: **most features are removable; essential roles are replaceable; recovery remains accessible.**

---

## 3. Organize customization around three native screens

### Modules

The module center should have **Discover**, **Installed**, and **Updates** views.

Each listing should show its purpose, screenshots where useful, publisher, source code, requested permissions, disk usage, engine compatibility, and restart requirements.

The ordinary flow should be:

**Find a module → preview it → install it → approve relevant permissions → use it.**

Radius should resolve compatible dependencies automatically. Users should see consequences, not package-manager errors.

For example:

> **Install Tree Tabs?**  
> This replaces your current tab interface. Your open tabs and workspaces will be preserved.

Or:

> **Remove this download manager?**  
> Two downloads are still running. You can finish them first or move supported downloads to another installed manager.

Installing a module should not require a Radius account. Additional community catalogs and local packages should be addable through graphical controls, with clear publisher and trust information.

### Customize

This should be a visual editor for layout and appearance, described below.

### Settings

Settings should cover browsing behavior, profiles, privacy, permissions, engines, and installed-module preferences.

Modules should contribute settings through a consistent native interface. Users should not encounter a different configuration-file format for every feature.

An **Advanced components** section can expose lower-level choices. “Advanced” should mean more information—not mandatory command-line work.

---

## 4. Build a genuinely visual layout and theme editor

### Native should not mean fixed

Use native Mac controls and window behavior, but do not lock users into one arrangement.

The layout editor should let users select browser components, drag them between supported regions, resize them, change their behavior, or remove them. Equivalent keyboard controls should be available.

| Area | Planned customization |
|---|---|
| **Tabs** | Horizontal, vertical, or tree-based interfaces; top, bottom, or side placement; grouping and pinned sections. |
| **Navigation** | Address-bar placement and width; movable navigation buttons; compact and expanded arrangements. |
| **Toolbars** | Multiple toolbars, custom button groups, extension actions, separators, overflow menus. |
| **Sidebars** | Left or right placement, adjustable widths, multiple panels, collapsing and automatic hiding. |
| **Workspace** | Split views, pane arrangement, workspace-specific layouts, optional distraction-free modes. |
| **Menus and start pages** | Reordered commands, shortcuts, installed widgets, custom arrangements. |

Preserve standard macOS window behavior and a reliable route back to settings. Customization should not make the application impossible to operate.

Security-sensitive information—such as the active site identity and permission prompts—must remain distinguishable from website content.

### Separate appearance from arrangement

A **theme** changes appearance.

A **layout** changes arrangement.

A **module** adds or replaces functionality.

A **setup pack** combines selected themes, layouts, and modules.

Changing a color scheme should not move someone’s tabs. Installing a sidebar layout should not force its author’s fonts or background.

### Theme controls

The graphical theme editor should cover colors, fonts, interface density, spacing, borders, corner shapes, shadows, transparency, icons, and animations.

Allow component-specific styling, such as compact tabs with a larger address bar. Include light and dark variants, reduced-motion settings, contrast warnings, and visible keyboard focus.

**No CSS should be required for the advertised customization features.** An optional advanced editor can exist, but it must not compensate for an incomplete graphical editor.

### Preview, undo, and sharing

Every layout or theme change should support preview and undo. Users should be able to save named configurations and restore a known-good layout.

Shared setup packs should contain appearance and configuration—not passwords, cookies, browsing history, or other private data. Required modules and permissions should be shown before installation.

Ordinary themes should be declarative data, not executable code with access to browsing activity.

---

## 5. Treat Chrome extensions as a product requirement

### The Chromium package needs more than Blink

The downloadable package should include the Chromium browser infrastructure necessary for extensions, not merely a Blink-based page renderer. Chromium explicitly distinguishes its page-rendering `content` layer from browser features such as extensions. [Chromium Git Repositories](https://chromium.googlesource.com/chromium/src/%2B/HEAD/content/README.md?utm_source=chatgpt.com)

The user-facing name can be:

**Chromium engine — Chrome extension support**

However, that label should appear only after the shipped integration passes compatibility testing.

### CEF is an implementation candidate, not a compatibility guarantee

Evaluate **CEF’s Chrome runtime** first. The CEF project documents extension installation through its Chrome runtime and separately tracks programmatic extension-management functionality. That means native extension installation and management need to be verified, rather than assumed to come from embedding CEF. [GitHub](https://github.com/chromiumembedded/cef/issues/3450)

The decision should be explicit:

**Use CEF when it supports the required experience. Maintain a more browser-level Chromium integration where necessary. Do not weaken extension compatibility merely to keep the embedding layer simple.**

### What compatibility must include

Test installation, updates, permissions, content scripts, background execution, toolbar actions, popups, side panels, extension storage, and the browser APIs Radius intends to support. These are distinct parts of Chrome’s extension platform. [Chrome for Developers](https://developer.chrome.com/docs/extensions/reference/api?utm_source=chatgpt.com)

Chrome Web Store installation must be tested end to end. A release that only supports unpacking extensions manually into developer mode does not meet the intended consumer experience.

Start with a defined Manifest V3 compatibility target and publish limitations. Do not promise that every extension works without evidence.

### Customization must preserve extension interfaces

Moving an extension button into a sidebar should not break its popup. Replacing Radius’s download panel should not silently break extensions that use download APIs.

Separate visible interface components from the services behind them. Where removing an underlying service affects extensions, explain the effect and offer a replacement.

### Make engine scope visible

The extension manager should show whether an extension works with the current engine, only with Chromium, or is unsupported.

WebKit extension support can be a separate workstream: Apple now exposes `WKWebExtensionController` and related APIs on supported macOS versions. Their existence is not evidence of complete Chrome-extension compatibility. [Apple Developer](https://developer.apple.com/documentation/webkit/wkwebextensioncontroller?utm_source=chatgpt.com)

Initially, engine selection should default to a profile or workspace. Chromium extensions should operate within the compatible browsing contexts to which they have permission—not gain silent access to unrelated WebKit or private contexts.

---

## 6. Make engine switching easy—but technically honest

### The consumer flow

Provide **Settings → Browsing engines** and a tab action called **Reopen with another engine**.

The engine manager should show installation status, disk usage, extension compatibility, supported features, and update status. Installing another engine should look like installing another module.

Allow choosing a default engine and optional profile or workspace preferences. Advanced site rules can come later, without becoming necessary for everyday use.

### Replace the “instant state transplant” design

Gemini’s snapshot-and-cookie sequence should not be the implementation promise. WebKit’s snapshot API produces an image; it is not an export of the running page’s JavaScript state. Website data is managed through separate WebKit facilities. [Apple Developer](https://developer.apple.com/documentation/webkit/wkwebview/takesnapshot%28with%3Acompletionhandler%3A%29?utm_source=chatgpt.com)

The correct operation is **reopen the page in a new browsing context while preserving the surrounding Radius tab**.

Radius should retain the tab’s placement, workspace, and safe navigation information. It may use a temporary image for visual continuity, but the new engine must load the page normally.

Before switching, explain:

> **Reopen this page with Chromium?**  
> The page will reload. Unsaved work may be lost, and you may need to sign in again.

Do not automatically copy cookies into a universal database, replay form submissions, or transfer authentication state between engines.

Supported credential or website-data migration should be a separate, explicitly authorized feature. Switching engines should not quietly merge privacy boundaries.

Related windows and popups that depend on shared execution behavior should remain within a compatible engine context.

### What “remove WebKit” means

Radius can stop using or remove its own WebKit integration package. It should not attempt to remove Apple’s system framework.

Similarly, switching complete engines does not make their internal JavaScript runtimes, layout systems, and networking stacks individually interchangeable. Those are separate replacement capabilities that must be implemented and tested.

---

## 7. Use a native architecture that supports the product

### Recommended stack

Use **Swift with Swift 6 concurrency checking**, **SwiftUI**, and **AppKit**.

AppKit should handle demanding window, input, menu, focus, and view-hosting requirements. SwiftUI should handle settings, module management, visual editors, and suitable interface composition. Apple documents supported integration between the two frameworks. [Apple Developer](https://developer.apple.com/videos/play/wwdc2022/10075/?utm_source=chatgpt.com)

This provides a native foundation; it does **not** automatically guarantee superior performance or battery life. Those remain measured engineering goals.

| Layer | Responsibility |
|---|---|
| **Native shell** | Windows, commands, layout rendering, customization, settings, accessibility. |
| **Module runtime** | Installation, dependency resolution, permissions, activation, updates, removal, recovery. |
| **Browser services** | Profiles, tabs, workspaces, bookmarks, history, downloads, credentials, extension integration. |
| **Data service** | Radius-owned persistent state, transactions, migrations, export, and provider replacement. |
| **Engine adapters and hosts** | WebKit integration, Chromium integration, future engine packages. |
| **macOS integration** | Platform windowing, security services, graphics, file access, and process communication. |

The shell should depend on Radius’s engine interfaces rather than Chromium-specific or WebKit-specific objects.

### Three module implementation types

**Declarative modules** should cover themes, layouts, menus, and other data-driven customization.

**Behavior modules** should supply feature logic through constrained runtime interfaces, with native settings and presentation supplied through Radius’s UI system.

**Native system packages** should cover engines and other components that genuinely need native integration. These require stronger trust, signing, lifecycle, and restart handling.

Do not treat loading arbitrary SwiftUI classes into the main process as a security boundary. Nor should every small feature require its own permanently running process.

### Chromium hosting is a substantial integration task

CEF’s macOS architecture involves a framework, helper application bundles, and sandbox initialization—not simply replacing one SwiftUI view with a built-in `CEFWebView`. Any such view would be a Radius-authored wrapper. [Chromium Embedded](https://chromiumembedded.github.io/cef/general_usage.html?utm_source=chatgpt.com)

The preferred target should isolate Chromium execution in a dedicated host arrangement while preserving Chromium’s renderer isolation.

Use authenticated IPC for control messages. XPC provides interprocess communication; IOSurface provides buffers that can be shared across processes. Neither automatically supplies the complete input, accessibility, windowing, and presentation bridge Radius needs. [Apple Developer](https://developer.apple.com/documentation/foundation/nsxpcconnection?utm_source=chatgpt.com)

Prototype that bridge early, including text input, VoiceOver, popups, fullscreen, drag-and-drop, media, and multiple displays. Choose the supported hosting arrangement based on those results—not on an assumption that “XPC” makes view embedding trivial.

---

## 8. Keep shared browser data separate from website execution state

### Radius-owned data

Use an actor-backed SQLite service for bookmarks, history, workspace definitions, tab descriptions, layout configurations, module selections, and preferences.

Choose one initial persistence implementation. Do not stack SwiftData, Core Data, and custom SQLite abstractions merely to include all three technologies.

Swift actors can help isolate mutable state, but the data layer still needs transactions, migration rules, cancellation handling, and coordination across processes. Swift’s concurrency documentation describes isolation as the basis of its data-race protections. [Swift.org](https://www.swift.org/migration/documentation/swift-6-concurrency-migration-guide/dataracesafety/?utm_source=chatgpt.com)

### Engine-owned website data

Cookies, site databases, caches, service-worker state, and related engine data should remain in appropriately separated engine/profile stores unless a specific shared provider has been designed to preserve the required behavior.

The browser data layer should coordinate these stores, not pretend they are interchangeable SQLite tables.

Deleting a profile should offer clear, comprehensive removal across its engines and modules.

### Correct the encryption model

Use **Keychain** for passwords, tokens, and cryptographic keys. Use **CryptoKit** for explicit cryptographic operations. Use Secure Enclave-backed keys where appropriate for the chosen protection and recovery model; the Secure Enclave is not a general-purpose database for browser state. [Apple Developer](https://developer.apple.com/documentation/security/keychain-services?utm_source=chatgpt.com)

“SQLite encrypted via CryptoKit” is not a complete implementation design.

Where full encryption of Radius’s metadata database is required, use a deliberate encrypted-database implementation, such as the open-source SQLCipher Community codebase. SQLCipher provides transparent SQLite database encryption. [Zetetic](https://www.zetetic.net/sqlcipher/?utm_source=chatgpt.com)

Do not imply that encrypting Radius’s metadata automatically encrypts every engine-owned file. Document those protections separately.

Keep cloud synchronization off by default. A sync module should be optional, uninstallable, and explicit about what it sends and where.

---

## 9. Design installation, trust, and recovery together

### Prefer direct, signed, notarized distribution

A downloadable native-module ecosystem fits direct distribution better than a Mac App Store-first strategy. Apple’s Mac App Store rules restrict downloading additional code that adds functionality or significantly changes the reviewed application. Apple separately provides Developer ID signing and notarization for software distributed outside the store. [Apple Developer](https://developer.apple.com/app-store/review/guidelines/)

This should still be a normal graphical installation. Users should not need to disable Gatekeeper, weaken system protection, or run shell commands.

### Do not modify the signed application casually

Install removable packages into managed locations using a packaging arrangement validated on clean Macs. Avoid a design that requires editing the signed main application bundle whenever a feature changes.

For native packages, verify publisher identity, integrity, compatibility, and the applicable platform trust requirements before activation.

Apple’s hardened runtime enables library validation by default, which constrains loading third-party libraries into a process. Do not globally weaken the main browser merely to make plugins easier to load. [Apple Developer](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.disable-library-validation?utm_source=chatgpt.com)

Prefer separate execution for third-party native functionality where feasible. A theme should never need engine-level privileges.

### Updates should preserve user choices

Radius should stage and verify updates before activation, retain recoverable configurations, and request approval for new permissions.

Updates must not reinstall optional features that the user intentionally removed. They must not replace a custom layout with the default one.

Recovery should restore a working configuration without automatically downgrading to a known-vulnerable engine.

### Recovery must be native and engine-independent

Provide a graphical repair mode that can disable a failing module, restore a previous layout, select another engine, or repair an interrupted update.

A failed customization should end in a repair screen—not instructions to locate a hidden configuration directory.

---

## 10. Make the open-source boundary explicit

All Radius-authored code and official distributed module implementations should be open-source. Publish the engine patches, build recipes, package manifests, source provenance, and tests needed to reproduce and audit releases.

Apple-provided operating-system frameworks remain platform dependencies; the project should not imply that a native macOS application makes the underlying operating system part of Radius’s open-source distribution.

Use **MPL-2.0** for Radius-authored application and engine-integration code, with permissively licensed interface definitions and SDK examples where appropriate. Preserve upstream dependency licenses.

Keep branding policy separate from source licensing. MPL does not grant rights to contributors’ trademarks; it is not a substitute for a Radius trademark policy. [Mozilla](https://www.mozilla.org/MPL/2.0/?utm_source=chatgpt.com)

Third-party Chrome extensions may have different licenses and maintainers. Their compatibility with Radius should not imply they are open-source or audited by the Radius project.

### Preserve the deeper modularity goal without mislabeling it

The initial product should provide genuinely interchangeable **complete engines**.

An optional future engine package can expose independently replaceable internal components through the same graphical module system. Those choices should appear only when tested compatible implementations exist.

**Do not label a setting or policy hook as a replaceable engine subsystem.** Equally, do not require a normal user to assemble a rendering pipeline just to browse.

---

## 11. Build in an order that tests the hardest assumptions early

| Stage | Deliverable | Acceptance criterion |
|---|---|---|
| **0. Integration proofs** | Native WebKit view, Chromium-hosting prototype, extension-installation proof, signed downloadable-package proof. | The difficult integration paths work on clean Macs before the product depends on them. |
| **1. Complete native browser** | Windows, tabs, navigation, profiles, history, bookmarks, downloads, private browsing, basic accessibility. | Radius is usable without customization. |
| **2. Real module management** | Graphical installation, removal, replacement, permissions, updates, and recovery. | Optional packages are actually removed; supported replacements preserve relevant data. |
| **3. Visual customization** | Layout editor, theme editor, presets, undo, native module settings, setup sharing. | Nontechnical users can substantially change Radius without writing code. |
| **4. Consumer-ready dual engines** | Guided Chromium installation, extension management, engine selection, controlled reopening, compatibility notices. | Engine installation and switching need no manual repair or developer mode. |
| **5. Hardened release** | Security review, failure testing, update recovery, performance testing, clean installation and removal. | The shipped configurations meet documented correctness, isolation, and usability requirements. |
| **6. Ecosystem expansion** | Additional feature providers, community catalogs, further engines, supported lower-level replacements. | New implementations work through the same public contracts and graphical workflows. |

Maintain engine security updates as an ongoing release responsibility, not a final polishing task.

Measure startup, memory, interaction latency, idle CPU use, graphics performance, and energy consumption. Compare equivalent workloads rather than assuming the native shell automatically makes every configuration lightweight.

### The release-defining usability test

A person who never uses a terminal should be able to install Radius, import browser data, install a different tab system, rearrange the interface, edit a theme, install a Chrome extension, add or remove Chromium, and recover from an unwanted customization.

The technical tests should independently confirm that removed modules stop executing, engine data remains separated, extension permissions are respected, and the native recovery interface survives engine failure.

---

## Final product definition

**Radius should combine a native Mac application with an app-like module ecosystem: WebKit for immediate browsing, optional Chromium for Chrome-extension compatibility, deeply editable layouts and themes, and guided replacement of major browser features.**

The native shell is the foundation. Modules are the user-facing product. Engine interchangeability is a real capability—not a developer-only build option.

**Users decide what their browser contains and how it behaves. Radius handles installation, compatibility, security, and recovery.**