---
target: whole app (lib/presentation)
total_score: 30
p0_count: 0
p1_count: 2
timestamp: 2026-07-09T18-37-19Z
slug: lib-presentation
---
# Whole-App Design Critique

**Target:** `lib/presentation`  
**Baseline:** `origin/main` at `75cd6ae3`

## Design Health Score

| # | Heuristic | Score | Key Issue |
|---|-----------|------:|-----------|
| 1 | Visibility of System Status | 3 | Connection, loading, and session states are strong; ordinary transfer progress and reconnect recovery are less persistent. |
| 2 | Match System / Real World | 3 | The terminal vocabulary fits expert users, but Connections, windows, sessions, and AI Sessions overlap without a clear model. |
| 3 | User Control and Freedom | 3 | Back, cancel, unsaved-change guards, and safe host-key rejection are strong; destructive mux actions and connection recovery lack undo or direct alternatives. |
| 4 | Consistency and Standards | 4 | Shared themes, mono titles, hairline surfaces, branded async states, and responsive navigation form a coherent system. |
| 5 | Error Prevention | 3 | Destructive confirmations and safe security defaults are good; PIN setup advances at four digits although completion requires six. |
| 6 | Recognition Rather Than Recall | 3 | Main navigation is labeled, but Port Forwards, terminal gestures, and recent agent sessions are hidden behind contextual disclosures. |
| 7 | Flexibility and Efficiency | 4 | Snippets, presets, modifier keys, gestures, themes, favorites, SFTP, and MonkeyMux provide excellent expert acceleration. |
| 8 | Aesthetic and Minimalist Design | 3 | The core is quiet and work-first; dense menus and generic utility/settings surfaces weaken hierarchy. |
| 9 | Error Recovery | 2 | The first-connect failure dialog preserves a useful log but offers only Close, with no Retry or Edit Host path. |
| 10 | Help and Documentation | 2 | Inline field help is useful, but there is no discoverable gesture/shortcut guide or searchable task help. |
| **Total** | | **30/40** | **Good — a strong product identity with several high-impact usability gaps.** |

## Anti-Patterns Verdict

### LLM assessment

This does **not** look AI-generated. MonkeySSH has a committed identity: JetBrains Mono as the display voice, the cursor-block mark, restrained near-black layering, branded loading/empty/error states, and a terminal/MonkeyMux composition built around real work. It avoids gradient text, glassmorphism, decorative motion, side-stripe accents, and repetitive card grids.

Generic Material residue remains in long forms, Settings, and Upgrade. Terminal-driven themes can also erase Signal Teal and produce pale cream/salmon accents in the current store screenshots, weakening the app's distinctive signal and drifting toward an explicit anti-reference.

### Deterministic scan

The bundled detector returned `[]` with exit code 0 for `lib/presentation`. This is **not a clean bill of health**: all 65 target files are Dart, and the detector's scannable extension set excludes `.dart`. It provided no usable Flutter findings, rule names, or locations, and produced no false positives to evaluate.

### Visual overlays

No reliable user-visible overlay is available. MonkeySSH is a native Flutter target with no Flutter web entry page, so there was no browser-rendered app surface on which to preflight mutation or inject the detector. Current committed iPhone/iPad and Android store screenshots were used as visual evidence instead.

## Overall Impression

MonkeySSH feels like a credible professional SSH client, especially once a user reaches the terminal and MonkeyMux. The terminal is the visual peak, the app chrome recedes correctly, and security decisions are unusually well explained. The biggest opportunity is to make the surrounding shell match the quality of the core: enforce accessibility across derived themes, shorten recovery after connection failure, and expose the fastest route back to an agent session.

## Cognitive Load

**Moderate: three of eight checks fail.**

- **Chunking:** Settings presents nine long sections in a single scroll, and terminal configuration exposes many consecutive controls.
- **Minimal choices:** the host context menu reaches seven actions (`home_screen.dart:1402-1486`), the SFTP action sheet reaches seven (`sftp_screen.dart:1604-1697`), and terminal overflow exposes several top-level actions plus submenus (`terminal_screen.dart:10562-10643`).
- **Progressive disclosure:** advanced host configuration is handled well, but Port Forwards, gestures, and AI session history are hidden rather than intentionally introduced.

Single focus, grouping, visual hierarchy, one-decision-at-a-time setup, and preservation of task context are generally strong.

## Emotional Journey

- **Setup and unlock:** calm, serious, and trust-building. Biometric guidance and private-by-default language work; the four-digit Next/six-digit completion mismatch creates an avoidable early wobble.
- **Connection:** the live log and stage feedback are excellent reassurance. Failure is the emotional low point because the narrative ends with only Close.
- **Terminal and MonkeyMux:** the product's peak. The user's work dominates, active/waiting states are glanceable, and bottom/side navigation adapts without crowding the terminal.
- **SFTP and utilities:** capable but less composed, especially on wide screens and in long action sheets.
- **End state:** returning to Hosts after the final disconnect is functional but abrupt; there is little closure or direct “resume later” reassurance.

## What's Working

1. **The work is genuinely the loudest thing.** Terminal and editor content own the screen while MonkeyMux remains available through adaptive bottom or side navigation.
2. **Trust is visible.** Host-key replacement, imported-command review, encrypted transfers, opt-in telemetry, and unsaved-change protection use serious language and safe defaults.
3. **Expert efficiency is exceptional.** Direct connection, persistent sessions, snippets, completion, modifier keys, SFTP context, presets, and window navigation support real remote development rather than a toy terminal workflow.

## Priority Issues

### 1. **P1 — Accessibility has no reliable floor across terminal-driven themes**

**Why it matters:** The theme accepts a terminal cursor as the primary accent at only 2.5:1 contrast (`lib/app/theme.dart:567-606`), then uses that primary as text for tabs and text buttons. Hint text further reduces the secondary color to alpha 150 (`lib/app/theme.dart:245-267`). The MonkeyMux close action is 30×30 and immediately destructive (`lib/presentation/widgets/tmux_expandable_bar.dart:1867-1885`). These directly violate the product's WCAG AA and 44-point target commitments.

**Fix:** Resolve separate surface and text accent roles; clamp text accents and muted text to 4.5:1 on their actual backgrounds; remove low-alpha body/hint styling; enforce 44×44 interactive targets; add confirmation or short undo for closing a remote window; test at 200% text scale in default, light, and representative terminal-derived themes.

**Suggested command:** `/impeccable audit lib/presentation`

### 2. **P1 — First-connect failure is a recovery cul-de-sac**

**Why it matters:** The connection dialog gives excellent live context, but after failure it offers only Close (`lib/presentation/widgets/connection_attempt_dialog.dart:61-158`). A mobile user under pressure must dismiss it, find the host again, infer whether to edit credentials, and repeat the flow.

**Fix:** Preserve the connection log and offer stage-aware actions: **Retry**, **Edit Host**, and **Close**. Identify whether failure occurred during networking, host-key verification, authentication, or startup. Keep entered configuration and return focus to the exact field that needs attention.

**Suggested command:** `/impeccable harden connection failures`

### 3. **P2 — The fastest route back to an agent session is too deeply disclosed**

**Why it matters:** Primary navigation exposes Hosts, Connections, Keys, and Snippets (`lib/presentation/screens/home_screen.dart:487-513`), while Port Forwards has routes but no normal top-level entry. Recent AI sessions sit under a connected host's expanded window list and a second AI Sessions disclosure (`lib/presentation/screens/home_screen.dart:3653-3744`). This weakens the promise of reaching the right agent session in seconds.

**Fix:** Add a direct **Resume latest agent** action to relevant host/connection rows. Clarify the IA around **Hosts / Sessions / Tools / Settings**, grouping Keys, Snippets, and Port Forwards under Tools if testing confirms that model. Preserve the current direct Connections path for users who already know it.

**Suggested command:** `/impeccable shape primary navigation and resume flow`

### 4. **P2 — Mobile creation and form completion ignore the thumb zone**

**Why it matters:** Add Host, New Folder, and Add Snippet live in top panel headers (`lib/presentation/screens/home_screen.dart:881-890,2401-2416`), and host Save/Test actions appear only after a long form. SFTP already demonstrates the correct bottom-FAB precedent. The current placement contradicts the product's first design principle: one-handed by default.

**Fix:** Use a mobile FAB or sticky bottom action bar for creation and Save/Test; retain header actions on wide layouts. Move secondary terminal controls from the crowded top-right bar into a thumb-reachable sheet while keeping the most frequent control visible.

**Suggested command:** `/impeccable adapt mobile primary actions`

### 5. **P2 — Dense action menus slow both recognition and expert flow**

**Why it matters:** Host, SFTP, and terminal menus exceed the four-item working-memory threshold. Destructive, management, sharing, and primary task actions compete in one flat list, increasing scan time and mis-tap risk.

**Fix:** Promote the two or three contextually primary actions, group secondary actions into clearly labeled sections or submenus, and isolate destructive actions. Add a concise gesture/shortcut guide so power features become learnable instead of remaining hidden.

**Suggested command:** `/impeccable distill action menus and shortcuts`

## Persona Red Flags

**Alex — impatient power user:** The terminal accelerators are excellent, but Alex still scans seven-item host and SFTP menus, cannot invoke a global command surface, and must expand multiple disclosures to reach recent AI sessions. The hidden Port Forwards route breaks recognition.

**Sam — accessibility-dependent user:** Sam encounters primary-as-text colors that may be only 2.5:1, low-alpha hints, a 30×30 destructive close target, and custom terminal controls whose mobile tooltips may not provide complete screen-reader guidance. Status badges correctly pair icons and text, which is a strong foundation.

**Casey — distracted mobile user:** Casey benefits from bottom navigation, the MonkeyMux sheet, and the SFTP FAB, then must reach top-right for Add Host/Add Snippet and multiple terminal controls. A failed first connection provides no immediate recovery, creating a high-abandonment interruption.

**Rin — remote agentic developer:** Rin reconnects between meetings to reach the agent waiting for input. Active connections and MonkeyMux work well once found, but recent-agent history is nested and connection failure returns Rin to manual diagnosis. Low-contrast muted labels are particularly costly in the glance-and-go, possibly sunlit context described by the product.

## Minor Observations

- PIN setup advances at four digits although the copy and completion logic require six (`lib/presentation/screens/auth_setup_screen.dart:220-272` and `:70-79`).
- The selected Snippets filter in current store imagery reads closer to disabled than selected.
- Terminal-derived cream/salmon accents obscure the Signal Teal identity in flagship screenshots.
- SFTP breadcrumbs collapse deep paths effectively, but can hide too much location context.
- Wide Snippets and SFTP layouts stretch rows across large canvases rather than introducing list/detail composition.
- Settings is coherent but visually becomes a long stock `ListTile` catalogue.

## Questions to Consider

1. If “back in the right agent session in seconds” is the promise, should **Resume latest** be visible before opening a connection?
2. Should terminal palettes recolor all app chrome, or should navigation and trust cues retain a contrast-safe Signal Teal identity?
3. Can the app keep expert density while reducing each decision point to two or three primary actions?
4. What should the safe primary recovery from connection failure be: Retry, Edit Host, or a stage-specific recommendation?
