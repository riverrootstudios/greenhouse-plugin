# Pre-PR Checklist

Shared quality gate loaded by `work-ticket` (self-review) and `review-pr` (code review). Both skills evaluate the same checklist so nothing passes self-review but fails code review.

Each item is tagged `[REQUIRED]` or `[NOTED]` to eliminate ambiguity when consumed by AI reviewers. `[REQUIRED]` findings block merge; `[NOTED]` findings are informational only.

Run against `git diff {base}...HEAD`, `{base}` from [Resolve Base Branch](common-operations.md#resolve-base-branch) (the integration branch, or the epic branch for a planned epic).

---

## 1. Acceptance Criteria Mapping

For each acceptance criterion from the Greenhouse ticket:

| Criterion | Status | Evidence |
|-----------|--------|----------|
| {criterion text} | Met / Not Met | {file:line or test name} |

- **Met** — specific file:line implements the criterion
- **Not Met** `[REQUIRED]` — criterion cannot be mapped to code; do not proceed until resolved
- If the criterion specifies a Given/When/Then behavior, verify a test exercises that exact scenario `[REQUIRED]`

---

## 2. RIVERROOT Standards

- [ ] `[REQUIRED]` No `any` types, no `@ts-ignore`
- [ ] `[REQUIRED]` Zod validation on all external inputs (forms, API routes, Server Actions)
- [ ] `[REQUIRED]` App Router conventions followed (path-based routing, not query params for views)
- [ ] `[REQUIRED]` Server Actions for mutations (not REST API routes, unless justified)
- [ ] `[REQUIRED]` Correct Supabase client (`createServerClient` on server, `createBrowserClient` on client)
- [ ] `[REQUIRED]` RLS enabled on every new table with at least one policy + `tenant_id` denormalized
- [ ] `[REQUIRED]` RLS policies split by operation — no `CREATE POLICY ... FOR ALL` when SELECT/INSERT/UPDATE/DELETE need different predicates
- [ ] `[REQUIRED]` Every new/modified `SECURITY DEFINER` function that takes a user/owner identifier parameter (`p_owner`, `p_user_id`, `p_actor`, etc.) resolves the caller with `current_team_username()` (web sessions via `auth.uid()`, CLI tokens via the `user_id` claim) and raises `forbidden` (42501) when it is NULL or differs from that parameter — under role `authenticated`, CLI tokens included; see the review-patterns entry, with a `throws_ok` pgTAP test for the rejection case. `SECURITY DEFINER` bypasses RLS by definition — the function body is the only enforcement point.
- [ ] `[REQUIRED]` All new/modified migrations applied locally via `supabase db reset`; `supabase test db` is green
- [ ] `[REQUIRED]` localStorage used only for ephemeral UI state (form drafts, sidebar collapsed)
- [ ] `[REQUIRED]` Business logic tested with descriptive test names
- [ ] `[REQUIRED]` Every new test exercises observable behavior — no tests whose only assertion is `expect(mockFn).toHaveBeenCalledWith(...)` against a unit-owned call (those just restate the implementation)

---

## 3. Security Surface

- [ ] `[REQUIRED]` No secrets or API keys in source code or committed `.env`
- [ ] `[REQUIRED]` No PII in logs or error messages
- [ ] `[REQUIRED]` Auth check before any data operation in API routes and Server Actions
- [ ] `[REQUIRED]` CORS restricted to known origins (never `*` in production)

---

## 4. AI Over-Generation Scan

Flag and simplify any of these patterns — ask "Is this the simplest solution? Would Dan or mb write this by hand?"

- [ ] `[REQUIRED]` Error handling for cases that can't happen (dead code)
- [ ] `[REQUIRED]` Utility/helper created for a one-time operation (premature abstraction)
- [ ] `[REQUIRED]` `useEffect` for data that could be a Server Component
- [ ] `[REQUIRED]` API route for a simple Supabase table read (use client directly)
- [ ] `[REQUIRED]` Comments explaining obvious code (noise — delete)
- [ ] `[REQUIRED]` Exhaustive type guards for internal data (trust your own types)
- [ ] `[REQUIRED]` New package for something built into the platform (see Dependency Hygiene in engineering-conventions.md)
- [ ] `[REQUIRED]` Any newly-added or version-bumped dependency is at the current latest stable, or carries a comment explaining the pin (see Library Version Selection in engineering-conventions.md)

---

## 5. Simplicity Scan

Flag these complexity signals — each one needs justification or refactoring:

- [ ] `[REQUIRED]` New global state for data only one component uses
- [ ] `[REQUIRED]` Custom hook wrapping a single built-in hook
- [ ] `[REQUIRED]` New API route that calls one Supabase table (use client directly)
- [ ] `[REQUIRED]` Utility function used in exactly one place (inline it)
- [ ] `[REQUIRED]` Multiple abstraction layers for a simple operation
- [ ] `[REQUIRED]` "We might need this later" code (build for now, refactor when needed)

---

## 6. Direction Drift

- [ ] `[REQUIRED]` New code follows patterns already established in the codebase
- [ ] `[REQUIRED]` No new dependency, pattern, or abstraction introduced without discussion
- [ ] `[REQUIRED]` If a new pattern is introduced, old pattern migration is scoped or deferred to a follow-up ticket

---

## 7. Commit Discipline

- [ ] `[REQUIRED]` No `console.log`, `debugger`, or temporary logging
- [ ] `[REQUIRED]` No commented-out code (git preserves history)
- [ ] `[REQUIRED]` No `TODO` comments not linked to a Greenhouse ticket
- [ ] `[NOTED]` No unrelated formatting changes mixed with logic changes
- [ ] `[REQUIRED]` `git diff --staged` reviewed — every line read before committing
