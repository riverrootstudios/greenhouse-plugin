# Engineering Conventions

Patterns to follow and anti-patterns to avoid. Loaded by `tend-ticket` and `work-ticket` during architectural risk scans.

---

## Navigation & Routing

**Rule:** Use path-based routing for all page navigation. Never use query params to drive which page or view is shown.

| Pattern | Verdict |
|---------|---------|
| `app/(dashboard)/settings/page.tsx` → `/settings` | ✓ Correct |
| `router.push('/settings')` | ✓ Correct |
| `?page=settings` or `?view=profile` to switch pages | ✗ Wrong |
| `useSearchParams()` to determine which component renders | ✗ Wrong |

**Why it matters:** Query-param routing breaks browser navigation (back/forward), breaks refresh, and breaks deep-linking. Next.js App Router provides path-based routing for free — use it.

**When query params are appropriate:** Filtering, sorting, and pagination within a page (e.g., `?status=open&sort=created`). Never for determining which page renders.

---

## Client-Side State

**Rule:** localStorage is for ephemeral UI state only. Never store user data, server state, preferences, or session info there.

| What to store | Where |
|---------------|-------|
| Server data (users, tickets, posts) | Server Components / React Query / SWR |
| Auth session | Supabase Auth (managed) |
| User preferences (theme, language) | Database — `user_preferences` table |
| Form drafts (saved across tabs) | localStorage — acceptable |
| UI state that survives refresh (sidebar collapsed) | localStorage — acceptable |
| Cached API responses | React Query / SWR — not localStorage |

**Why it matters:** localStorage is not secure, not synced across devices, not server-rendered, and not invalidated on logout. Data stored there leaks between sessions and breaks SSR hydration.

**Signals of misuse:** `localStorage.setItem` with user IDs, tokens, server-fetched objects, or anything that should be in the database.

---

## Database Security (RLS)

**Rule:** Every new table must have Row Level Security enabled and at least one policy before any application code queries it.

**Checklist for every new table:**
- [ ] `ALTER TABLE {table} ENABLE ROW LEVEL SECURITY;`
- [ ] At least one SELECT policy (who can read rows?)
- [ ] INSERT / UPDATE / DELETE policies as needed
- [ ] `tenant_id` denormalized on every tenant-scoped table (RLS needs it on every row)
- [ ] Service role bypasses RLS — never expose the service role key to the client

**Why it matters:** Without RLS, PostgREST exposes all rows to any authenticated user. A missing policy is a data breach waiting to happen, not a future optimization.

**Signals of missing RLS:** New migration file adds a table but no `ENABLE ROW LEVEL SECURITY` or `CREATE POLICY` statements.

**Writing RLS policies:**

- **Split by operation.** Write a separate `CREATE POLICY` for each of SELECT, INSERT, UPDATE, DELETE that needs different rules — never `FOR ALL`. A permissive `FOR ALL` silently overrides stricter per-operation policies and produces hidden authorization bugs. (Seen in the Cut B migration: a `FOR ALL` policy let technicians SELECT rows that the dedicated SELECT policy was supposed to deny.) `FOR ALL` is only acceptable when every operation truly shares the same predicate — and even then, splitting makes the intent reviewable.
- **Apply locally before declaring done.** Run `supabase db reset` and exercise the affected paths end-to-end. An unapplied migration is not a finished feature. `supabase test db` should be green before the PR opens.

**Signals of misuse:** any `CREATE POLICY ... FOR ALL` in a migration that also has narrower intent on individual operations; an RLS-touching PR opened without evidence of `supabase db reset` running clean.

---

## Framework Primitives vs Custom Solutions

**Rule:** Always reach for what the framework already provides before building something custom.

| Need | Use this | Not this |
|------|----------|----------|
| Page navigation | `next/navigation` `router.push()` | Custom history management |
| Auth | Supabase Auth | Custom JWT / session handling |
| Form validation | Zod + React Hook Form | Custom validators |
| Data fetching (client) | React Query / SWR | Custom fetch + useState |
| Global state | Zustand | Custom Context + reducer |
| UI components | shadcn/ui (Radix) | Custom accessible components |
| Rate limiting | Vercel WAF / Upstash | Custom middleware counter |
| Cron/scheduled work | Vercel Cron | Custom job queue |
| Full-text search | PostgreSQL `tsvector` | Elasticsearch / Algolia (premature) |

**Why it matters:** Custom solutions have more code, more bugs, more maintenance, and less community support. The cost of "just building it ourselves" compounds over time.

**Signal:** A new abstraction or utility that re-implements something the tech stack already handles.

---

## Complexity Signals

Flag these patterns — they often indicate unnecessary complexity creeping in:

| Signal | Ask |
|--------|-----|
| New global state for data that only one component uses | Can this be local state or a prop? |
| Custom hook that wraps a single built-in hook | Is the wrapper adding anything? |
| New API route that only calls one Supabase table | Can this be a direct Supabase client query? |
| New utility function used in exactly one place | Can this just be inlined? |
| Multiple layers of abstraction for a simple operation | What does each layer actually add? |
| "We might need this later" code | Build for now, refactor when needed |

---

## Direction Drift

**Rule:** New code should follow patterns already established in the codebase. Introducing a new pattern is a deliberate architectural decision, not a default.

**Before introducing a new pattern, ask:**
1. Is there already a pattern in the codebase for this?
2. If introducing a new one, does the team agree this is the better approach going forward?
3. Will the old pattern need to be migrated? If so, is that in scope?

**Examples of drift:**
- Using `fetch()` directly when the project uses React Query
- Adding a REST API route when the project uses Server Actions for mutations
- Using `context` for state when the project uses Zustand
- Adding a new CSS approach when the project uses Tailwind

---

## Security Surface Checklist

Quick scan for common security mistakes:

- [ ] No secrets or API keys in source code or `.env` committed to git
- [ ] Zod validation on all external inputs (forms, API routes, Server Actions)
- [ ] No PII in logs or error messages
- [ ] Auth check before any data operation in API routes and Server Actions
- [ ] CORS restricted to known origins — never `*` in production
- [ ] Rate limiting on auth and public-facing endpoints

---

## Error Handling

**Rule:** Handle errors at the right layer. Don't handle what you can't recover from. Never swallow errors silently.

| Situation | Pattern |
|-----------|---------|
| User input is invalid | Validate with Zod, return typed error to the caller |
| External API fails | Catch at the boundary, return a typed result, log with context |
| Unexpected error | Let it propagate — don't catch and ignore |
| Database error | Catch at the repository/action layer, never in the component |
| Auth failure | Return 401/403 from the route handler, not a 200 with an error field |

**Prefer typed results over exceptions for expected failures:**
```ts
// Good — caller knows what can go wrong
type Result<T> = { ok: true; data: T } | { ok: false; error: string }

// Bad — caller must know to try/catch
function doThing(): T { throw new Error('...') }
```

**Never do this:**
```ts
try { ... } catch (e) {} // silently swallowed
try { ... } catch (e) { console.log(e) } // logged but not handled
```

**Signal:** A catch block that doesn't re-throw, return an error, or take a recovery action.

---

## Naming & Readability

**Rule:** Code is read far more than it is written. Optimize for the reader.

### Functions
- One function, one job. If you need "and" to describe it, split it.
- Name functions after what they do, not how they do it: `getUserById` not `fetchFromDBByPrimaryKey`
- Boolean functions start with `is`, `has`, `can`, `should`: `isAuthenticated`, `hasPermission`
- Max ~30 lines per function. If it's longer, it probably has more than one job.

### Variables
- Name after what it represents, not its type: `userId` not `str`, `tickets` not `arr`
- Avoid abbreviations except universal ones (`id`, `url`, `api`, `ctx`)
- Loop variables: use meaningful names (`ticket`, `user`) not `item`, `x`, `i` (unless it's truly a numeric index)

### Components
- Name after what it renders: `TicketCard`, `UserAvatar`, not `Card2`, `MyComponent`
- Props: use descriptive names — `onSubmit` not `handler`, `isLoading` not `loading`

### Files
- Lowercase, hyphenated: `ticket-card.tsx`, `use-auth.ts`
- Co-locate related files: test next to source, types next to usage
- One component per file (except tiny co-located subcomponents)

---

## Dependency Hygiene

**Rule:** Every new dependency is a long-term maintenance commitment. Evaluate before adding.

**Before `pnpm add {package}`, ask:**
1. Is this already solved by the tech stack? (e.g., don't add `axios` when `fetch` exists, don't add `lodash` for one utility)
2. Is this package actively maintained? (last commit, open issues, npm downloads)
3. What's the bundle size impact? (`bundlephobia.com`)
4. Does it have TypeScript types?
5. Is a smaller focused package available? (prefer `date-fns` over `moment`, `zod` over `joi`)

**Never add a package to:**
- Format a date (use `Intl.DateTimeFormat`)
- Generate a UUID (use `crypto.randomUUID()`)
- Deep clone an object (use `structuredClone()`)
- Check if an array includes a value

**Signal:** `pnpm add` during implementation without prior design decision.

---

## Library Version Selection

**Rule:** When introducing or upgrading a dependency, use the **latest stable** version. Don't default to a familiar older version just because it's the one you've used before.

**Before `pnpm add {pkg}` or bumping a major version:**

1. Check the package's current latest: `npm view {pkg} version` (or visit the npm page / package homepage).
2. If introducing: pick `latest` unless there's a documented reason to pin lower (peer-dep constraint, known regression).
3. If bumping a major version (Next, React, TypeScript, Expo, Supabase JS, etc.): **confirm with the user first**. Major bumps cascade strictness errors, lint rule changes, and breaking-API rewrites through the codebase — they're never a "while I'm at it" change.

**Why it matters:** Defaulting to a stale-but-familiar version (e.g., Next 15.x when 16.x is current) means immediate tech debt and a second bump later. Unannounced major bumps have caused full reverts in past sessions (TypeScript strictness cascade, React lifecycle changes).

**Signals of misuse:**
- A new dep added at a version that isn't the current `latest`, with no comment explaining the pin.
- A `package.json` major-version bump bundled into an unrelated feature PR.
- A new project scaffolded with a version older than the latest stable framework release.

---

## Commit Discipline

**Rule:** Each commit represents a coherent, working change. The diff tells a story.

**Never commit:**
- `console.log`, `debugger`, or temporary logging added during development
- Commented-out code (delete it — git history preserves it)
- Partial work that leaves the app in a broken state
- `TODO` comments that aren't linked to a Greenhouse ticket
- Unrelated formatting changes mixed with logic changes

**Commit message tells the why, not the what:**
```
# Good — tells why
feat: skip invoice sync when status is already final [GH-15]

# Bad — the diff already shows "what"
feat: add if statement to invoice sync [GH-15]
```

**Staged review before every commit:** `git diff --staged` — read every line before committing.

---

## Test Discipline

**Rule:** Tests describe behavior, not implementation. A test that fails only when an implementation file is edited — without the observable behavior changing — is bloat.

**Don't write:**

- Tests that mock every dependency the unit calls and then assert "the mock was called with X" — that just restates the implementation and breaks on any refactor.
- A test for every internal helper when the public-facing behavior is already covered by an integration test at the surface.
- Snapshot tests on rendered output that re-baseline on every cosmetic change. They protect nothing and review-blind the diff.
- A new test file alongside a small refactor "for symmetry" when the behavior under the refactor was already covered.

**Do write:**

- Behavioral / integration tests at the public surface of the unit (component as rendered, route handler called with a real request, RPC invoked through PostgREST).
- Tests for each edge case the acceptance criteria enumerates (empty input, null, boundary value, error path, network failure).
- A regression test for every bug fixed — one test per re-occurrence prevented.

**After an autonomous implementation, self-review for test bloat before committing.** Ask each test: *"Would removing this test reduce coverage of any observable behavior?"* If the answer is no, delete it.

**Signals of misuse:**

- `expect(mockFn).toHaveBeenCalledWith(...)` is the *only* assertion in a test of the unit that owns the call.
- Test file has more lines than the file under test, with no edge-case justification.
- A test re-baselines a snapshot on every PR that touches the rendered component.

---

## AI-Assisted Development

**Rule:** You are responsible for every line you ship, regardless of whether an AI wrote it.

### Before accepting AI-generated code
- Read it completely. If you don't understand it, don't ship it.
- Ask: does this match the conventions in this file and `riverroot.md`?
- Ask: is this the simplest solution, or did the AI over-engineer it?
- Ask: does this introduce a new dependency, pattern, or abstraction that wasn't discussed?

### Common AI over-generation patterns to watch for
| Pattern | Problem |
|---------|---------|
| Adds error handling for cases that can't happen | Dead code, false confidence |
| Creates a utility/helper for a one-time operation | Premature abstraction |
| Adds a `useEffect` for data that could be a Server Component | Unnecessary client-side complexity |
| Generates an API route for a simple DB read | Use Supabase client directly |
| Adds comments explaining obvious code | Noise — delete them |
| Generates exhaustive type guards for internal data | Trust your own types |
| Suggests a package for something built into the platform | See Dependency Hygiene above |

### The scope check
AI moves fast. Verify the diff stays within the ticket's acceptance criteria before committing. If the implementation touched more files or changed more behavior than the ticket describes, stop and evaluate — don't just ship it because it works.
