# Design decisions

The browser uses native typography, a shared spacing scale, one accent, and clear separation between trusted browser chrome and website content. Standard controls retain platform focus and contrast behavior.

CARP:

- Contrast: selected tabs, address focus, and primary confirmation actions carry the strongest emphasis; secondary metadata has lower emphasis with paired custom surfaces, contrast feedback and system Increase Contrast overrides.
- Alignment: navigation shares a horizontal baseline, settings use a single label/control column, and sidebar lists have consistent leading edges.
- Repetition: the same icon button, sheet heading, spacing, form patterns, and action order recur throughout the app.
- Proximity: page actions stay near the address; package permission descriptions stay beside installation controls; appearance and arrangement use distinct settings groups.

[Laws of UX](https://lawsofux.com/) inform these choices:

- [Jakob's Law](https://lawsofux.com/jakobs-law/): familiar address, navigation, tabs, shortcuts, destination pickers and Mac window behavior.
- [Fitts's Law](https://lawsofux.com/fittss-law/): consistently sized toolbar targets and space between actions. Compact mode reduces spacing while maintaining a clear target.
- [Hick's Law](https://lawsofux.com/hicks-law/): customization categories and progressive module details; browsing starts without an engine questionnaire.
- [Law of Proximity](https://lawsofux.com/law-of-proximity/): grouped controls and nearby permission explanations.
- [Doherty Threshold](https://lawsofux.com/doherty-threshold/): native views respond locally; disk saves are debounced and actor-isolated; progress is shown for page loads and reader extraction.

Material and Liquid Glass presets adapt color and native material treatment while preserving the same information hierarchy. They do not claim to implement every part of Google's or Apple's design systems. Liquid Glass uses native translucent materials supported on macOS 14 rather than requiring a newer system API.

Tree tabs use disclosure controls and indentation. Split panes use a visible active-pane indicator; keyboard focus, the address, and page actions follow that pane. Appearance previews do not create browsing tabs, and applying colors preserves a window's choice to return to one pane. Engine changes warn before a normal reload and identify the active engine in the status bar.

Resource providers share a native metric presentation. Replacement validates the candidate package before stopping the old worker and enabling the new package, and leaves unrelated saved data intact. Package descriptions distinguish an executable worker from a bounded behavior or declarative package and describe actual access without implying an OS sandbox. Reader uses a short-lived worker with bounded input/output; the native sheet remains responsive and extraction stops when its package is disabled or removed.

The implementation follows the [Karpathy-inspired guidelines](https://github.com/multica-ai/andrej-karpathy-skills): explicit scope, narrow modules, minimal interfaces used by both engines, and behavior-based verification. The exact consulted skill is preserved in KARPATHY_GUIDELINES.md with its upstream MIT provenance.

The advanced editor uses disclosure groups so typography, surfaces and per-component overrides do not crowd basic choices. Toolbar controls have equivalent drag, region-menu and keyboard reorder actions. Wide layouts retain usable page space; the second panel collapses on narrow windows with an explanation in the browser menu. Chrome panes show one native Chrome address/navigation toolbar, while trusted Radius settings and recovery remain available outside it. Setup previews enumerate missing requirements and approved activation/replacement consequences.
