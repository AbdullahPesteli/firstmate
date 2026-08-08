# Pi Calm mode

Calm is a Pi-only conversation presentation toggle.
It is off by default, and the last `/calm` choice persists for the effective Firstmate home across Pi session starts and resumes.

While Calm is active and an agent run is under way, Calm hides Pi's built-in `Working...` row and shows a small two-row animated boat in its place, and no separate Calm status row is added.
The water fills the usable width in standard ANSI blue and the complete boat is standard ANSI yellow.
The boat is deliberately calm: it moves one column every 880ms, while the water ripples on its own faster cadence so the surface stays alive between boat steps.
Its mainsail is directional, showing `<|` while travelling right and `|>` while travelling left, and it flips on the exact frame the boat turns at either edge.
Every resize reflows the sprite without wrapping, and it disappears when the run settles, aborts, or fails.
Within one Pi session and Calm extension lifetime, the next working period resumes the boat from its last rendered column and travel direction rather than restarting at the left edge.
Hidden elapsed time does not advance the animation, and a resize while hidden clamps the frozen boat to the new width without changing its valid travel direction.
A fresh Pi session or new Calm extension lifetime starts at the normal initial position.
Very narrow terminals fall back to a smaller deterministic sprite.
While Calm is off, Pi's stock working row is left exactly as Pi renders it.
Calm hides collapsed thinking labels, the shells for the Pi built-in tool names Calm owns, the `fm_watch_arm_pi` tool shell, canonically classified Firstmate operational user rows, and the single no-action acknowledgement row that answers one.
The operational inputs remain ordinary user-role messages, while Pi's transcript layout renders their complete rows at zero height.
When an operational input's specific event needs no action but still requires a reply, Firstmate answers with the exact routine acknowledgement AGENTS.md section 9 defines, and Calm collapses that assistant row to zero height as well, so a burst of terminal or long-idle notifications cannot accumulate visible acknowledgement rows.
That collapse is bound to the typed operational-input provenance and the exact acknowledgement text together, never the text alone: a captain-authored message, a real outcome such as a PR URL, a decision, a failure, and any superficially similar sentence in ordinary conversation all stay visible, as does the acknowledgement whenever Calm is off or in stock `/export` and `/share` rendering.
The session-start nudge remains on its existing non-displayed custom-message path.

Outside Pi's same-name built-in override collision described below, Calm changes presentation only.
Calm's built-in wrappers preserve Pi's execution behavior, and input delivery, ordering, model context, session storage, diagnostics, and `/export` and `/share` operation remain unchanged.
Every hidden Firstmate input remains available to the model and in serialized session data and exported artifacts.
Legacy operational custom messages remain in session data and Pi's sidebar tree, although the main HTML transcript may omit them.
Toggling Calm off restores ordinary rendering, and `Ctrl+O` expansion state is preserved.

Pi's supported presentation API does not expose a global transcript filter.
Expanded reasoning and its reserved spacing, built-in tool images, user-bash rows, skill and summary rows, generic status notices, and arbitrary custom-tool or extension rows remain visible.
These are supported-API boundaries rather than hidden-content failures.

## Pi compatibility

Calm has no numeric Pi version minimum or maximum and never refuses Pi solely because its version is newer than a previously verified version.
The collapsed-thinking and operational-user-row presentation adapters probe the exact Pi API seam they patch when Calm loads.
If Pi removes one of those seams, Calm logs a diagnostic naming the unavailable adapter and skips only that adapter; `/calm`, the other adapter, and unrelated Pi extensions remain available.

Calm's built-in tool presentation (`bash`, `read`, `edit`, `write`, `grep`, `find`, `ls`) shares Pi's single, unmerged override slot per name with any other extension that overrides the same tool.
While the persisted Calm preference is off, Calm registers none of those overrides and therefore contests no built-in tool name.
The first time Calm turns on in a session that started off, it claims every built-in name no other extension already owns, leaves every contested tool intact and callable, and displays a prominent warning naming the tools it skipped.
Tool-call rows already on screen before that first toggle do not retroactively collapse; later rows for the names Calm claimed use Calm presentation.
When a session starts or reloads with Calm already on, Calm must instead register all seven overrides synchronously so Pi can render restored rows with them.
Pi provides no ownership check early enough for that load-time path, and the first registrant wins the complete tool definition.
If the other extension wins, a session-start console diagnostic names the tool and winning extension; if Calm wins, Pi does not expose the losing registration, so the other extension's override is unavailable and cannot be named.

[`calm-mode-feasibility.md`](calm-mode-feasibility.md) owns the version-scoped renderer taxonomy, built-in override constraints, and empirical evidence.
[`configuration.md`](configuration.md#pi-calm-preference-configcalm) owns the persisted preference file and resolution rules.
`.pi/extensions/lib/fm-calm-visibility.ts` owns the visibility policy, the operational-input provenance, and the acknowledgement literal; `.pi/extensions/lib/fm-calm-operational-user-layout.ts` owns the zero-height operational-user row adapter and records that provenance; `.pi/extensions/lib/fm-calm-assistant-layout.ts` owns the collapsed-thinking adapter and the acknowledgement-row collapse; and `.pi/extensions/lib/fm-calm-working-ship.ts` owns the animated working presentation.

Regression entry points:

```sh
tests/fm-calm-pi-extension.test.sh
tests/fm-pi-primary-types.test.sh
FM_PI_LIVE_E2E=1 tests/fm-pi-primary-live-e2e.test.sh
```
