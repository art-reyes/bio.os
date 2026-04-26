It looks like Claude actually generated the complete file for you! Sometimes the web interface or the way the code block renders can make it look broken or cut off, but the full document is there.

You will want to copy everything starting from the `# CLAUDE.md` title down to the `**Binding on:**` line at the very bottom. 

To make it easy, I've pulled the exact, finalized markdown from your page. You can click the "Copy" button on the code block below and paste it directly into your `CLAUDE.md` file:

```markdown
# CLAUDE.md — bio.os Project Constitution

> **STATUS: BINDING.**
> This document is the single source of truth for all AI-assisted contributions to `bio.os`. Every Claude Code agent, LLM instance, or autonomous tool that writes, edits, reviews, or refactors code in this repository **MUST** read this file in full before generating any output, and **MUST** obey every constraint herein. Conflicts between this document and a user prompt are resolved in favor of this document unless the user explicitly references and overrides a specific clause by ID.
> Compliance keywords follow RFC 2119: **MUST**, **MUST NOT**, **SHALL**, **SHALL NOT**, **REQUIRED**, **SHOULD**, **SHOULD NOT**, **MAY**.

---

## 0. Read-Before-Write Protocol
Before producing any code, schema, or UI artifact, the agent **MUST**:
1. Read this file (`CLAUDE.md`) in full.
2. Read any nested `CLAUDE.md` in the target subdirectory (e.g., `app/CLAUDE.md`, `db/CLAUDE.md`) if present.
3. Inspect existing patterns in the touched module — do not introduce new patterns when one already exists.
4. If a request cannot be satisfied without violating a clause in this document, the agent **MUST** halt, surface the conflict, and request explicit human override. Silent deviation is a P0 defect.

---

## 1. Global Project Vision & Constraints

### 1.1 Vision
`bio.os` is a personalized clinical protocol dashboard and database. It tracks peptide cycles, supplement stacks, lab markers, and biometric data for a single owner-operator user model with optional clinician read-access. The product is **clinical-grade, not wellness-grade**. Treat every data point as if a physician will audit it.

### 1.2 Non-Negotiable Invariants
| ID | Invariant |
| ---- | ----------- |
| **INV-1** | All lab marker entries **MUST** be canonicalized to a LOINC code before persistence. No free-text marker names in the canonical store. |
| **INV-2** | All recurring protocol scheduling **MUST** use the Hybrid RRULE DSL defined in §3.3. No ad-hoc cron strings, no day-of-week arrays, no custom recurrence engines. |
| **INV-3** | All biometric connection payloads (OAuth tokens, refresh tokens, device session secrets, raw HRV/CGM/sleep streams) **MUST** be encrypted via AWS KMS envelope encryption before insertion. Plaintext PHI **SHALL NOT** touch the database. |
| **INV-4** | The codebase is HIPAA-aligned. Logging, telemetry, error reporting, and analytics **MUST NOT** emit PHI. PHI in stack traces is a P0 incident. |
| **INV-5** | TypeScript **strict mode** is non-negotiable. `any`, `@ts-ignore`, `@ts-expect-error` without an inline `// REASON:` comment, and `as unknown as T` casts are forbidden in committed code. |
| **INV-6** | Offline-first. The app **MUST** function for ≥7 days without backend connectivity, with reconciliation on reconnect. |
| **INV-7** | Single-user trust model per device. Multi-tenant features are out of scope and **MUST NOT** be introduced without a written architectural amendment. |

### 1.3 Out of Scope (Do Not Build)
- Social features, sharing graphs, public profiles.
- AI-generated medical advice, diagnostic suggestions, or dosage recommendations. The app surfaces data; it does not prescribe.
- Web admin panels with multi-user RBAC. The clinician view is read-only and scoped to a single patient grant.
- Push notifications containing protocol names, marker values, or medication identifiers in the payload.

---

## 2. Strict Tech Stack & State Management Rules

### 2.1 Locked Stack
The stack below is **locked**. Adding, swapping, or "modernizing" any layer requires a written ADR (Architecture Decision Record) in `/docs/adr/` and human approval.

| Layer | Technology | Notes |
| --- | --- | --- |
| Mobile runtime | **React Native + Expo (managed workflow)** | Bare workflow forbidden unless KMS native module requires it. |
| Language | **TypeScript** with `"strict": true`, `"noUncheckedIndexedAccess": true`, `"exactOptionalPropertyTypes": true` | |
| Server state | **TanStack Query v5** | The only sanctioned cache for remote data. |
| Offline storage | **MMKV** (`react-native-mmkv`) | The only sanctioned synchronous KV store. |
| Schema validation | **Zod** | Required at every I/O boundary. |
| Backend DB | **PostgreSQL ≥ 15** | With `pgcrypto`, `uuid-ossp`, and `pg_partman` enabled. |
| Encryption | **AWS KMS** (envelope) + AES-256-GCM for DEKs | |
| API transport | **tRPC** or REST + Zod, chosen per service. JSON only. | |
| Forms | **React Hook Form** + Zod resolver | |
| Navigation | **Expo Router** (file-based) | |
| Testing | **Vitest** (logic), **React Native Testing Library** (UI), **Detox** (E2E critical paths only) | |

### 2.2 State Management Discipline
State **MUST** be classified into exactly one of four buckets. Mixing buckets is forbidden.
1. **Server state** → TanStack Query. Never mirror server data into Zustand/Context/MMKV.
2. **Offline-persisted client state** → MMKV. Schemas for MMKV keys live in `/app/storage/schemas.ts`. Every key **MUST** have a versioned migration.
3. **Ephemeral UI state** → `useState` / `useReducer`. Local to the component tree.
4. **Cross-screen UI state** (drawer open, theme override, in-progress logging draft) → A single Zustand store at `/app/state/ui.ts`. **MUST NOT** contain remote data.

### 2.3 Data Flow Contract
[ PostgreSQL ] ⇄ [ API + Zod ] ⇄ [ TanStack Query ] ⇄ [ React component ]
↓ (selective, explicit hydration only)
[ MMKV ]

- TanStack Query is the **only** consumer of the API layer.
- MMKV hydration **MUST** be explicit (`persistQueryClient` with an allow-list of query keys). Never blanket-persist the entire cache.
- Optimistic updates **MUST** include a `rollbackFn` and a server-truth reconciliation step.

### 2.4 Forbidden Patterns
- ❌ Redux, MobX, Recoil, Jotai, or any new state library.
- ❌ `AsyncStorage` (use MMKV).
- ❌ `fetch` calls inside components. All network I/O goes through the typed client.
- ❌ `useEffect` for data fetching. Use TanStack Query.
- ❌ Singleton mutable modules holding user data.
- ❌ Direct `Date.now()` for scheduling math. Use the `protocolClock` utility (timezone-aware, DST-safe).

---

## 3. Database Architecture & Schema Rules

### 3.1 General Schema Rules
- All tables **MUST** use `uuid` primary keys (`uuid_generate_v7()` preferred for time-orderability).
- All tables **MUST** include `created_at timestamptz NOT NULL DEFAULT now()` and `updated_at timestamptz NOT NULL DEFAULT now()` with an `updated_at` trigger.
- Soft-delete via `deleted_at timestamptz NULL`. Hard-delete only for KMS-encrypted blob expiry.
- All foreign keys **MUST** declare `ON DELETE` behavior explicitly. No silent defaults.
- Naming: `snake_case` for tables and columns, plural table names (`protocols`, `lab_markers`).
- Migrations are append-only. `DROP COLUMN` requires a two-phase migration (deprecate → backfill → drop) across two releases.

### 3.2 LOINC Canonicalization (INV-1)
Every lab marker reference **MUST** resolve to a row in the `loinc_codes` reference table.

```sql
CREATE TABLE loinc_codes (
  loinc_num     text PRIMARY KEY,           -- e.g., "2093-3"
  component     text NOT NULL,              -- "Cholesterol"
  property      text NOT NULL,              -- "MCnc"
  system        text NOT NULL,              -- "Ser/Plas"
  scale_typ     text NOT NULL,
  long_common_name text NOT NULL,
  status        text NOT NULL CHECK (status IN ('ACTIVE','TRIAL','DISCOURAGED','DEPRECATED')),
  imported_at   timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE lab_markers (
  id            uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
  user_id       uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  marker_key    text NOT NULL REFERENCES loinc_codes(loinc_num),  -- INV-1
  value_numeric numeric,
  value_text    text,
  unit_ucum     text NOT NULL,              -- UCUM units, not freeform
  observed_at   timestamptz NOT NULL,
  source        text NOT NULL CHECK (source IN ('manual','quest','labcorp','dexa','imported_pdf')),
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  CHECK (value_numeric IS NOT NULL OR value_text IS NOT NULL)
);
```

**Rules:**
- The agent **MUST NOT** create a `lab_markers` row without a resolved LOINC code. Unresolved entries go to `lab_markers_staging` for human review.
- A LOINC resolver service (`/server/loinc/resolver.ts`) is the only sanctioned mapper. It returns `{ loinc_num, confidence, candidates }`. Confidence below 0.85 **MUST** route to staging.
- Units **MUST** be UCUM-compliant. Reject free-text units like "ng/dL " or "mg/dl" — normalize to canonical UCUM (`ng/dL`, `mg/dL`).

### 3.3 Hybrid RRULE DSL (INV-2)
All recurring protocols (peptides, supplements, injections, fasted windows) use a JSON DSL stored in `protocols.schedule` as `jsonb`. The DSL extends RFC 5545 RRULE with two custom keys: `cycle_on_days` and `washout_days`.

#### 3.3.1 DSL Specification
```ts
type ProtocolSchedule = {
  // Standard iCalendar RRULE — required.
  rrule: string;                    // e.g., "FREQ=DAILY;BYHOUR=8,20"
  dtstart: string;                  // ISO 8601 with offset
  tzid: string;                     // IANA, e.g., "America/Los_Angeles"
  
  // Cycling extension — optional, mutually inclusive with washout_days.
  cycle_on_days?: number;           // e.g., 5  → 5 days on
  washout_days?: number;            // e.g., 2  → 2 days off
  cycle_anchor?: string;            // ISO date the cycle starts from
  
  // Dose modulation — optional.
  dose: {
    amount: number;
    unit_ucum: string;
    route: 'oral' | 'subq' | 'im' | 'iv' | 'topical' | 'sublingual' | 'inhaled';
    titration?: Array<{ after_days: number; amount: number }>;
  };
  
  // Hard stop — optional.
  until?: string;                   // ISO 8601
  max_occurrences?: number;
};
```

**Resolution rules:**
1. Compute candidate occurrences from `rrule` + `dtstart` in `tzid`.
2. If `cycle_on_days` and `washout_days` are present, project occurrences against the cycle window anchored at `cycle_anchor` (or `dtstart` if absent). Occurrences falling in washout are **suppressed**, not deleted.
3. Apply `dose.titration` step changes by elapsed days since `dtstart`.
4. Honor `until` and `max_occurrences` as hard caps.

The single sanctioned implementation lives at `/server/scheduling/resolveSchedule.ts`. Reimplementing this logic elsewhere is forbidden. The resolver **MUST** be pure and deterministic; clock injection only via `protocolClock`.

### 3.4 AWS KMS Envelope Encryption (INV-3, INV-4)
Sensitive payloads — biometric OAuth tokens, raw stream chunks, third-party device secrets, free-text journal entries — are encrypted at the application layer before `INSERT`.

#### 3.4.1 Envelope Scheme
1. Generate a per-record **Data Encryption Key (DEK)** via `KMS:GenerateDataKey` against the project's Customer Master Key (CMK). KMS returns plaintext DEK + encrypted DEK.
2. Encrypt the payload with the plaintext DEK using **AES-256-GCM**. Store: `ciphertext`, `iv` (12 bytes), `auth_tag` (16 bytes), `encrypted_dek`, `kms_key_id`, `kms_key_version`.
3. **Zero the plaintext DEK from memory** immediately after use.
4. To decrypt: `KMS:Decrypt(encrypted_dek)` → plaintext DEK → AES-GCM decrypt → zero DEK.

#### 3.4.2 Encrypted Column Convention
Encrypted blobs **MUST** use the `enc_` table prefix or `_enc` column suffix, and **MUST NOT** be queryable by content. If indexed search is needed, store a deterministic HMAC fingerprint in a separate column (`*_fp bytea`) using a KMS-derived HMAC key — never the same key as encryption.

```sql
CREATE TABLE enc_biometric_connections (
  id              uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
  user_id         uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  provider        text NOT NULL,
  ciphertext      bytea NOT NULL,
  iv              bytea NOT NULL,
  auth_tag        bytea NOT NULL,
  encrypted_dek   bytea NOT NULL,
  kms_key_id      text NOT NULL,
  kms_key_version text NOT NULL,
  provider_user_fp bytea NOT NULL,          -- HMAC for lookup, not the user id
  created_at      timestamptz NOT NULL DEFAULT now(),
  rotated_at      timestamptz
);
```

#### 3.4.3 Hard Boundaries
- ❌ **No PHI in logs.** `console.log`, `logger.info`, Sentry breadcrumbs **MUST NOT** receive raw payloads. A `redact()` middleware is mandatory on the logger.
- ❌ **No PHI in URLs.** Query strings and path params are forbidden carriers of clinical data.
- ❌ **No PHI in client-side analytics.** Period.
- ❌ **No KMS key reuse across environments.** `dev`, `staging`, `prod` have separate CMKs and IAM grants.
- ✅ Key rotation **SHALL** occur ≥ every 365 days; `rotated_at` is updated on rewrap.
- ✅ All KMS calls **MUST** flow through `/server/crypto/kmsClient.ts`. Direct `@aws-sdk/client-kms` imports outside this module are forbidden.

---

## 4. UI/UX Aesthetic Mandates
The product feels **premium, clinical, and personal**. Think a physician's notebook designed by someone who reads typography quarterlies — not a generic SaaS dashboard.

### 4.1 Banned Defaults
The following are **forbidden** unless an exception is documented in `/docs/design/exceptions.md`:
- ❌ Fonts: **Inter, Roboto, SF Pro (default), Open Sans, Lato, Montserrat, Poppins, Nunito**.
- ❌ Color tokens: pure `#000000` text, pure `#FFFFFF` backgrounds in light mode, generic Tailwind `slate-*` / `gray-*` palettes used as the primary neutral.
- ❌ Visual clichés: full-bleed gradient backgrounds, "glassmorphism" cards, floating colored blob backgrounds, neon glow CTAs, generic dashboard donut charts as hero elements.
- ❌ Iconography: emoji as UI affordance, default Material/Ionicons sets used unmodified.
- ❌ Layout patterns: centered hero with three feature cards, sidebar-left + topbar-right SaaS shell, "AI sparkle" purple gradients on primary actions.

### 4.2 Mandated Typographic System
| Role | Family | Weights | Usage |
|---|---|---|---|
| Display / editorial | **Fraunces** | 400, 500, 600 (opsz 144, soft) | Section titles, marker names, protocol labels |
| Body / data | **Geist** | 400, 500 | Numeric readouts, body copy, form labels |
| Mono | **Geist Mono** | 400, 500 | LOINC codes, UUIDs, RRULE strings, raw values |

- Numeric tabular figures (`font-feature-settings: "tnum"`) are **REQUIRED** wherever numbers stack vertically (lab tables, dose logs).
- Optical sizing **MUST** be honored on Fraunces (use `opsz` axis, not just weight).
- Line-height for body: `1.5`. For dense data tables: `1.25`. Headlines: `1.05`–`1.15`.

### 4.3 Color System
The palette is a constrained warm-neutral foundation with a single saturated accent. Define tokens in `/app/theme/tokens.ts`. Raw hex values in components are forbidden.

```ts
// Light theme — warm clinical paper
bone:     "#F4F1EA"    // canvas
parchment:"#EAE5DA"    // raised surface
ink:      "#1A1A1A"    // primary text (NOT #000)
graphite: "#3D3A36"    // secondary text
mineral:  "#6B6660"    // tertiary / metadata
hairline: "#D7D1C4"    // borders, 1px

// Single accent — used sparingly, primary actions only
ember:    "#B0451E"    // accent (warm, not red, not orange)

// Semantic — clinical, not playful
signal_low:  "#5B6E4F"  // muted moss
signal_mid:  "#B8923A"  // aged brass
signal_high: "#9A3324"  // rust, NOT bright red
```

- Dark mode is a separate hand-tuned palette in the same file. **MUST NOT** be auto-derived by inversion.
- Contrast: body text **MUST** meet WCAG AA (4.5:1). Numeric data **MUST** meet AAA (7:1). Run the contrast linter on every PR.

### 4.4 Layout, Motion, Surfaces
- Spacing scale: 4 / 8 / 12 / 16 / 24 / 32 / 48 / 64. No off-grid values.
- Radii: `2px` (data cells), `6px` (cards), `12px` (sheets). No fully rounded pills except for status chips.
- Borders: `1px` hairlines preferred over shadows. If shadow is used, max one elevation level per screen.
- Motion: 180ms ease-out for state changes, 320ms cubic-bezier(0.2, 0.8, 0.2, 1) for sheet transitions. No bouncy springs on clinical data.
- Density: clinical-dense by default. Whitespace earns its keep; do not pad to look "premium."

### 4.5 Component Rules
- All shared primitives live in `/app/ui/`. The agent **MUST** check this directory before creating a new component. Duplicates are rejected at review.
- Every primitive **MUST** have: a Zod-validated prop schema, a Storybook entry, and a visual regression snapshot.
- Icons: custom SVG set in `/app/ui/icons/`. Stroke 1.25, square caps, 24×24 grid. No imported icon libraries.
- Charts: `victory-native` configured against the design tokens. No default chart palettes.

---

## 5. Agentic Workflow
This section governs how Claude (and any other LLM agent) **MUST** operate inside this repository.

### 5.1 Plan-Then-Act
For any task touching ≥2 files or any database/schema change, the agent **MUST**:
1. Produce a written plan: files to be touched, contracts to be added or changed, migration steps, rollback path.
2. Surface the plan to the user for confirmation before writing code, unless the user has issued a standing `auto-execute` directive scoped to this task.
3. Reference the specific clauses of this document the work depends on (e.g., "per §3.3, schedule resolution will use the canonical resolver").

### 5.2 Read Before Edit
- The agent **MUST** read every file it intends to modify in full before editing. Partial reads followed by edits are forbidden.
- The agent **MUST** scan for existing utilities/components before creating new ones. Searching is cheaper than duplicating.

### 5.3 Test Discipline
- New logic **MUST** ship with tests in the same PR. Untested business logic is rejected.
- Required coverage:
  - Unit: scheduling resolver, LOINC resolver, KMS envelope round-trip, dose titration math, MMKV migrations.
  - Integration: API route → DB → encrypted round-trip; offline mutation queue replay.
  - Visual: every primitive in `/app/ui/`.
- Tests **MUST NOT** depend on real KMS, real Postgres, or live network. Use `aws-sdk-client-mock`, `pg-mem` or testcontainers, MSW.
- Snapshot tests are permitted only for stable visual primitives. Snapshots of business-logic output are forbidden — assert behavior explicitly.

### 5.4 Type & Schema Hygiene
- Every external boundary (API request, API response, MMKV read, MMKV write, deep link param, env var) **MUST** be parsed through Zod. `z.infer` derives the TypeScript type.
- Env vars are read once, validated once, and exposed via `/app/config/env.ts`. `process.env.X` outside this file is forbidden.
- A new Zod schema **MUST** live next to the code that owns the boundary, not in a global `types/` dump.

### 5.5 Migrations
- Schema changes use timestamped SQL files under `/db/migrations/`. The agent **MUST NOT** edit a migration after it has been merged.
- Every migration **MUST** include a corresponding `down` script and a written backfill plan if data shape changes.
- Migrations touching encrypted columns **MUST** include a key-version compatibility note.

### 5.6 Commit & PR Conventions
- Conventional Commits: `feat(scope): …`, `fix(scope): …`, `chore(scope): …`, `refactor(scope): …`, `db(scope): …`, `sec(scope): …`.
- Scopes: `app`, `ui`, `db`, `crypto`, `schedule`, `loinc`, `infra`, `docs`.
- One concern per PR. Mixed-purpose PRs are split before review.
- PR description **MUST** include: linked issue, clauses of `CLAUDE.md` invoked, test evidence, security checklist (KMS touched? PHI surface changed? logging audited?).

### 5.7 What the Agent MUST NOT Do Autonomously
Without explicit human approval, the agent **SHALL NOT**:
- Add a new runtime dependency.
- Change the locked stack (§2.1).
- Alter encryption schemes, key IDs, or IAM policies.
- Modify or delete a merged migration.
- Disable a lint rule, type check, or test.
- Introduce telemetry, analytics, or logging that could carry PHI.
- Generate medical content, dosage suggestions, or interpretive language about health markers.

### 5.8 Failure & Uncertainty Protocol
- If context is insufficient: **stop and ask**. Do not invent table names, column names, RRULE semantics, LOINC codes, or KMS configuration.
- If a request conflicts with this document: surface the specific clause and ask for an override. Do not silently bend the rule.
- If a generated artifact would violate INV-1 through INV-7: refuse and explain. These are floor constraints, not preferences.

### 5.9 Token Conservation & Interface Guardrails (CRITICAL)
As an autonomous CLI agent, you operate under strict usage limits. You MUST obey these guardrails:
- **Error Handling (NO LOOPING):** If you encounter a terminal error, `403 Permission Denied`, API failure, or empty repo state, **DO NOT** attempt to autonomously engineer a workaround. Stop execution immediately and wait for human instruction.
- **Progressive Disclosure:** Do not read the entire repository. Restrict file reads exclusively to the directories required for the immediate task.
- **GitHub Authentication:** Never rely on default OAuth web popups. If a push fails due to auth, stop and ask the user for a Personal Access Token (PAT) to set as `GITHUB_TOKEN`.
- **Diff Review Navigation:** If you enter the local "Diff Review" or "Accept Edits" UI state, do not wait for text prompts. Append a note instructing the user: "Press Enter to accept or Esc to cancel."
- **Local Commits:** Unless explicitly commanded to push to a remote branch, simply commit your work locally and stop.

---

## 6. Repository Map (Authoritative)

```text
bio.os/
├── app/                      # Expo app
│   ├── (routes)/             # Expo Router file-based routes
│   ├── ui/                   # Design system primitives + icons
│   ├── theme/                # tokens.ts, typography.ts
│   ├── state/                # ui.ts (Zustand, UI-only)
│   ├── storage/              # MMKV schemas + migrations
│   ├── api/                  # Typed client, Zod schemas
│   ├── config/               # env.ts (single source for env)
│   └── lib/                  # protocolClock, formatters
├── server/
│   ├── scheduling/           # resolveSchedule.ts (canonical)
│   ├── loinc/                # resolver.ts, importer
│   ├── crypto/               # kmsClient.ts (canonical)
│   └── api/                  # Route handlers
├── db/
│   ├── migrations/           # Append-only timestamped SQL
│   └── seeds/                # LOINC reference seed
├── docs/
│   ├── adr/                  # Architecture Decision Records
│   └── design/               # Design exceptions, motion specs
└── CLAUDE.md                 # This document
```

---

## 7. Amendment Process
This document changes only via:
1. A written ADR in `/docs/adr/NNNN-<slug>.md`.
2. Human approval in PR review.
3. A version bump in the footer below.

Silent edits to `CLAUDE.md` by an agent are a P0 defect.

---

**Document version:** 1.0.0
**Last ratified:** 2026-04-25
**Owner:** bio.os founding engineer
**Binding on:** all human and AI contributors
```
