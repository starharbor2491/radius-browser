# Design decisions

The browser uses native typography, a shared spacing scale, one accent, and clear separation between trusted browser chrome and website content. Standard controls retain platform focus and contrast behavior.

CARP:

- Contrast: selected tabs, address focus, and primary confirmation actions carry the strongest emphasis; secondary metadata has lower emphasis without custom low-contrast text colors.
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

The implementation follows the [Karpathy-inspired guidelines](https://github.com/multica-ai/andrej-karpathy-skills): explicit scope, narrow modules, no unused engine abstraction, and behavior-based verification. The exact consulted skill is preserved in KARPATHY_GUIDELINES.md with its upstream MIT provenance.
