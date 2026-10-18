# Odyssey Finance

Native iOS personal finance app (SwiftUI, SwiftData, CloudKit) for a single user in Spain. No server. This repo is **public**, so every change must be safe to publish.

## Working principles
1. State assumptions; ask when a request has more than one reasonable reading.
2. Write the minimum code that solves the problem. No abstraction for a single caller; it's a single-user app, so no multi-tenant layers.
3. Touching 2+ files or adding a module: write a numbered plan with a verify step per task before editing.

## Commands
- Generate the Xcode project (never committed): `xcodegen generate`
- Core tests: `swift test --package-path Core`
- One suite: `swift test --package-path Core --filter CoreLogicTests.TransfersTests`
- Importer tests: `swift test --package-path Tools/ImportFromPostgres`
- iOS build (`swift test` doesn't compile `App/` or iOS-only `CoreSync` code, so run this too): `xcodebuild -project OdysseyFinance.xcodeproj -scheme OdysseyFinance -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO`
- Device build: same command with `-destination 'generic/platform=iOS' -allowProvisioningUpdates`
- Repo guards: `scripts/check-repo.sh [base-ref]`
- App icon: `python3 design/app-icon/make_icon.py` (needs `rsvg-convert` and Pillow)

CI (`.github/workflows/ci.yml`) runs the guards, both test suites and the iOS build, and reports them as one aggregate `CI` check.

## Layout
- `App/`: the SwiftUI target only. `Features/<Feature>/` views, `Intents/` App Intents, `Support/` theme, gates and runners. Besides `App.swift`, top-level `App/*.swift` files are `#if DEBUG` one-shot tools.
- `Core/Sources/`: the Swift package (iOS and macOS). `CoreModel` (`@Model` types, no logic) → `CoreIntegrations` (HTTP clients, JWT signing, Keychain) → `CoreLogic` (every business rule) → `CoreSync` (`CKSyncEngine`). Tests in `Core/Tests/<Target>Tests/`.
- `Tools/`: the finished one-shot Postgres → SwiftData migration.
- `Spec/`: frozen copy of the original Next.js app, the porting reference.
- `Vercel/`: static AASA and config for the bank-redirect host.
- `design/app-icon/`: icon generator and SVG sources.
- `docs/`: `ARCHITECTURE.md` (how it works) and `decisions.md` (settled choices).

## Rules
Each rule is yes/no. "Enforced by" says where; `review` means no machine check yet.

| # | Rule | Enforced by |
|---|---|---|
| 1 | Business logic lives in `Core/`; `App/` holds views and wiring | review |
| 2 | `Core/` builds for iOS and macOS; iOS-only APIs sit behind `#if os(iOS)` | CI tests on macOS |
| 3 | Money is `Decimal`; `Double` only for time intervals and chart plotting, never in `CoreModel` | guard (CoreModel), review |
| 4 | Never use SwiftData `#Unique`; composite uniqueness goes through `CoreSync` dedupe | guard |
| 5 | Delete with bare `ctx.delete`; cascades come from `@Relationship(deleteRule:)`; `CascadeTests` stays green | CI tests |
| 6 | Every `CoreLogic` change ships with tests in `Core/Tests` | review |
| 7 | UI saves reach CloudKit through `SaveObserver` on the main context; nothing observes the sync engine's context | review |
| 8 | Never edit `Spec/` | guard (per change) |
| 9 | No private keys, statements, stores, dumps or crash logs in git; keys live in the Keychain | `.gitignore` + guard |
| 10 | No real balances, amounts, merchants, people, account ids or record counts in code, fixtures, comments, commit messages or PR bodies | review |
| 11 | DEBUG one-shots are `#if DEBUG`, gated by an `OF*` env var, idempotent, and read live record ids from env vars or a Documents/ payload | review |
| 12 | Comments only when the why is non-obvious; no multi-paragraph docstrings | review |
| 13 | No AI attribution trailers in commit messages or PRs | guard (per change) |
| 14 | `*.xcodeproj` is generated: edit `project.yml`, then run `xcodegen generate` | `.gitignore` |
| 15 | Icon PNGs come from `design/app-icon/make_icon.py`; never edit them by hand | review |

## Read before changing
- Sync, bank sync, transfers, investments or automations: `docs/ARCHITECTURE.md`.
- Anything settled in `docs/decisions.md`: reopening one needs a new entry that supersedes it.
- Porting behaviour from the web app: the matching `Spec/lib/*.ts`.

## Gotchas
- In test files, `Category` collides with Objective-C's `Category`: write `CoreModel.Category`.
- One large `#Predicate` fails to type-check: build sub-predicates and combine them with `.evaluate` (see `TransactionFeed`). For optional relationships use `x.flatMap { … } ?? false`.
- Under es-ES a locale-bound numeric field reads "123.45" as 12345. Money fields are text parsed with `Transactions.parseAmount` / `parseSignedAmount`; holding quantities use `parseQuantity`.
- Unsigned builds trap at `CKContainer` init. Sync only starts when `CloudKitGate` sees an iCloud token.
- `UNUserNotificationCenterDelegate`: implement the completion-handler methods. The async variants crash when a notification is tapped.
- Schema changes: there is no `VersionedSchema`, so only additive optional attributes migrate automatically. Anything else needs a migration plan first.
- DEBUG builds open `DevData/financial.store` (a local copy of real data) when it exists. Never publish screenshots or logs from such a build.
