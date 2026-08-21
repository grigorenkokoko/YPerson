# YPerson User-Value Roadmap

> **Execution:** implement each linked subsystem plan with strict TDD where runnable tests are allowed, temporary Foundation harnesses for pure iOS logic, fresh Release builds, and an independent review before integration.

**Goal:** Replace the remaining demonstration-only paths with a reliable loop users can repeat: create a good-looking card, exchange/import it, keep people useful, and understand failures.

**Approved sources of truth:** `AppSpec.md`, `AppPrivacy.yml`, `Design/design-spec.md`, and the approved card-template design at `docs/superpowers/specs/2026-08-20-yperson-card-templates-design.md` on `codex/card-templates`.

## Priority order

| Wave | User outcome | Scope | Exit gate |
| --- | --- | --- | --- |
| 1 — now | A card can be styled, imported, and safely written to Contacts | Finish card-template verification; fix Contacts matching/selection/update; support compatible vCard QR/photo import | Full backend suite, temporary Swift harnesses, Release simulator build, task review |
| 2 | Exchange controls tell the truth | Wire private-field consent into the exported payload; replace the fake short-code example with a real server-issued code or relabel the long token honestly; persist audio state | Round-trip contract tests and relaunch checks |
| 3 | Saved people remain useful after an owner changes data | Propagate owner-originated field changes through a stable Contacts link, implement local/server connection deletion, and surface sync state and retry | Backend deletion/update tests plus end-to-end simulator inspection |
| 4 | Notifications create an action, not a demo | Remove the fictional local notification; implement real APNs sending and deep-link review/block actions | Staging push evidence and notification-extension inspection |
| 5 | Cards feel personal and release blockers are explicit | Real avatar selection/rendering, editable tagline, durable audio greeting, production configuration and device/release checklist | Clean-install and relaunch evidence, device checks, release manifest remains honest |

## Parallel wave 1

Three isolated branches/worktrees run without overlapping ownership:

1. `codex/card-templates` — complete the already approved template plan and final verification.
2. `codex/contacts-reconciliation` — execute `2026-08-20-yperson-contacts-reconciliation.md`.
3. `codex/vcard-import` — execute `2026-08-20-yperson-vcard-import.md`.

Integration happens only after each stream has its own evidence and review. The integration branch is `codex/user-value-hardening`; the user's staged PersonalDebug/signing files in the main checkout are out of scope and must not be modified.

## Global constraints

- Preserve the clean-install empty state and Debug-only reviewer fixtures.
- Never transmit picker-imported system contacts, raw photos, camera frames, coordinates, Face ID data, or local meeting notes.
- Do not add iOS XCTest/UI-test targets to this standalone app.
- Keep iOS 15+, portrait-only iPhone support and all three existing extensions building.
- Keep `meetingPlace` local-only and do not broaden backend payloads without updating `AppSpec.md` and `AppPrivacy.yml`.
- Do not claim device, APNs, signing, production-backend, archive, or release readiness without direct evidence.

## Recorded ruling

`AppSpec.md` and `AppPrivacy.yml` require a confirmed card payload found in Photos to synchronize, but the current backend can synchronize only a YPerson card tied to an authenticated owner/exchange token. A third-party vCard has neither. Wave 1 therefore keeps a parsed vCard local-only and preserves cloud claim for genuine YPerson payloads that carry a valid token. This is the privacy-minimizing behavior and avoids inventing ownership of third-party contact data. Cost if this ruling is wrong: vCards will not receive cloud backup/update semantics until a separately approved backend import contract and corresponding retention/deletion model exist; this remains an explicit conformance blocker to resolve before release.

## Completion definition

Wave 1 is complete only when all three streams are integrated, the complete backend suite passes in an environment-independent way, a fresh Release simulator build succeeds without app-owned warnings, and remaining manual/device checks are reported as pending rather than inferred.
