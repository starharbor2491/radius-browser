# Radius installation and updates

The consumer installer contains the same `Radius.app` in every configuration. WebKit is always available. Chromium disk images additionally include an architecture-specific sealed engine package; all disk images include the default module payloads for offline installation. Existing module removals, layout, and browser data live outside the app bundle and survive replacement.

## Graphical installation

The disk image opens in Finder and contains Radius, an Applications shortcut, and installation instructions. Drag Radius into Applications and open it. An existing official signed Radius app can use **Settings → Browsing engines → Installation and updates** to check official releases or import a local disk image/complete application. A download shows progress and can be cancelled. A verified candidate is staged before **Restart and install** becomes available. The staged record survives a relaunch and is verified again; ordinary quitting does not activate it until you choose Restart and install. Cancelling that quit clears the activation request.

Installing/removing Chromium replaces the complete signed application after Radius quits. This avoids changing a running signed app or changing CEF's framework/helper paths beneath live renderers. Engine removal requires reopening Chromium tabs with WebKit before saving and quitting. Profiles, addresses, tab organization, custom layouts, installed module choices, and engine website data are kept; sign-in contexts and unsaved forms do not transfer between engines.

If the current app is on a disk image, translocated, or in an unwritable folder, the native folder picker offers a writable installation folder such as the user's Applications directory. No shell command, Gatekeeper exception, quarantine removal, or privilege helper is required.

## Trust and activation

The initial official app must be obtained from the publisher's trusted release page. Subsequent installation derives its publisher Team ID from the currently signed application. A downloaded catalog is only a list of candidates: its claims never authorize execution. Radius checks the downloaded disk image's declared bounded size and SHA-256, mounts it read-only, then checks the contained and copied application independently:

- Developer ID Application certificate, Apple certificate anchor, same publisher Team ID, and Radius bundle identifier;
- notarization requirement and strict nested code/signatures for every architecture;
- bundle contents and internal-only symbolic links, bounded package bytes/file count;
- version/build and security epoch sealed into the signed application, executable architecture, and matching Chrome-style engine manifest;
- no older application build or security epoch than either the running app or the installed destination/previously accepted floor.

Each CPU architecture has its own separately signed updater executable, including when Radius runs under Rosetta. The updater verifies its source and destination and signals readiness before the browser closes engines, then waits for the running app's PID to exit. A cancelled quit terminates this owned waiting process. It copies to a sibling on the destination volume and checks the copy again, then renames the previous and candidate bundles using an on-disk journal. Failed verification or activation keeps/restores the previous app without launching an older backup as a new candidate. Recovery validates the expected destination and paired UUID paths before touching an interrupted transaction. A first installation can complete a fully verified candidate after an interrupted rename. The security floor advances only after successful activation; adding a newer engine does not invalidate the old app before replacement. No browser data is part of this transaction.

Development builds have ad-hoc code integrity but no authenticated Developer ID publisher. Their consumer installation controls remain unavailable. There is no user-facing trust override or test verifier in the installation service.

## Production build pipeline

The manually dispatched **Build signed consumer installers** workflow tests and builds WebKit universal, Chromium Apple silicon, and Chromium Intel installers from the same source/build number. All native leaves and nested containers are signed before the host. Hardened runtime permits JIT only in Chromium processes, and camera/audio input in the browser/capture processes. It does not disable library validation. The workflow notarizes/staples the application, creates/signs/notarizes/staples its disk image, assesses it with Gatekeeper, and records its exact bytes/SHA-256. Optional publishing uploads all three verified installers and a bounded release catalog together.

Repository secrets required:

| Secret | Purpose |
| --- | --- |
| `RADIUS_SIGNING_IDENTITY` | Full `Developer ID Application: …` identity name |
| `RADIUS_SIGNING_CERTIFICATE_BASE64` | Base64 PKCS#12 signing certificate/private key |
| `RADIUS_SIGNING_CERTIFICATE_PASSWORD` | PKCS#12 password |
| `RADIUS_NOTARY_KEY_BASE64` | Base64 App Store Connect notarization `.p8` key |
| `RADIUS_NOTARY_KEY_ID` | Key ID |
| `RADIUS_NOTARY_ISSUER` | Issuer UUID |

Credentials use an ephemeral CI keychain and files that are removed in an always-run cleanup step. Local trusted builds can use `RADIUS_SIGNING_IDENTITY` with an existing keychain identity, and `RADIUS_NOTARY_PROFILE` with a stored notary profile. `RADIUS_BUILD_NUMBER`, `RADIUS_VERSION`, and `RADIUS_SECURITY_EPOCH` are sealed into `Contents/Resources/Distribution.json` before signing. The security epoch is monotonic and at least the pinned Chromium major; publish all variants with the same accepted epoch so removing Chromium does not permit an old engine to return.

`python3 scripts/package-release.py --development` creates a concrete Finder disk image for an ad-hoc local build. It is labeled unnotarized, never emits a consumer catalog entry, and cannot be installed through the trusted consumer updater.

## Verification and current credential boundary

Portable tests exercise successful replacement with preserved user data, bad candidate rollback, activation failure rollback, interrupted replacement recovery, interrupted first installation, forged journal rejection, catalog origin/size policy, architecture mismatch, and build/security downgrade rejection. Native tests parse the notarization requirement and reject development-signed publisher identity. Post-build native fixtures clone the actual signed Radius app, execute the same rename transaction with an explicit test-only integrity verifier, and confirm damaged copies cannot replace it. The consumer service and helper always use the production trust verifier.

Developer ID/notarization credentials are not configured in this workspace. The production workflow deliberately fails before building an unsigned consumer installer if credentials are missing. Actual notarized installation, clean-Mac TCC/media behavior, Gatekeeper assessment, helper restart and rollback acceptance therefore require the publisher's real signing credentials and a clean Mac; development fixture results do not certify those unavailable checks.
