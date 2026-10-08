# Review Patterns — Recurring Feedback

Patterns observed from PR reviews. Loaded by `work-ticket` during self-review and `review-pr` during code review to prevent known issues from recurring.

**Two layers.** This file is the **shared baseline** every repo loads — edit it by hand, in the greenhouse repo, through a normal PR. Project-specific patterns live in each repo's own `.claude/review-patterns.md`, which `fix-review-feedback` Step 8.5 captures into automatically and `review-pr` / `work-ticket` load alongside this one. Captures never write here: in another repo this file is the installed plugin cache, where edits are never committed and vanish on refresh.

Last updated: 2026-10-07

---

## Patterns

<!-- Structure for new entries:

### {Pattern Name}
- **First seen:** PR #{number}, {TICKET-ID}
- **Severity:** REQUIRED | NOTED
- **Category:** Bug/Logic | Style/Convention | Architecture | Missing Test | Over-generation | Cohesion
- **What happened:** {brief description}
- **Prevention rule:** {concrete check the self-review should perform}

-->

### Production-only failures invisible to localhost verification
- **First seen:** PR #37, GH-59 (surfaced post-merge as GH-60)
- **Severity:** REQUIRED
- **Category:** Bug/Logic
- **What happened:** The corkboard shipped through local verification, CI, and two review rounds, then became unusable in production within seconds: tldraw's license enforcement only activates on HTTPS non-localhost domains, so no pre-merge check ever exercised it. The same blind spot covers any domain- or environment-gated behavior — third-party license checks, cookie `Secure`/`SameSite` behavior, CSP enforcement, OAuth redirect allowlists, CORS.
- **Prevention rule:** Before approving a PR that adds or upgrades a third-party *client-side* dependency, or touches domain-sensitive behavior (auth redirects, cookies, CSP, embedded SDKs): open the Vercel **preview deployment** and look at the feature for at least a minute — previews run on real HTTPS hostnames, so they surface what localhost structurally cannot. Check the browser console for new warnings/errors on the preview, not just locally. For SDKs, read the vendor's licensing/production-deployment page as part of dependency review.

### Multi-ID procedure inputs missing cross-FK validation
- **First seen:** PR #2 (tallgrass), RG-2
- **Severity:** REQUIRED
- **Category:** Bug/Logic
- **What happened:** `instructor.invite.create` accepted `{ class_id, term_id }` and authorized the caller against `class_id` via `assertInstructorOfClass`, but never checked that `term_id` actually belonged to `class_id`. A multi-class instructor could pair class A's id with class B's term, silently writing inconsistent `(class_id, term_id)` rows downstream that broke every join keyed on that pair. There was no FK constraint relating the two columns either.
- **Prevention rule:** When a procedure accepts two or more IDs that should be related (e.g., class_id + term_id, org_id + class_id, user_id + membership_id), explicitly verify the relationship in the procedure body — don't assume the client sends a consistent pair. A one-line `assertXBelongsToY` helper is usually the right shape. Cover it with a "mismatched pair → BAD_REQUEST" test.

### "Only under service-role" AC implemented without the actual gate
- **First seen:** PR #2 (tallgrass), RG-2
- **Severity:** REQUIRED
- **Category:** Architecture
- **What happened:** AC explicitly said `auth.bootstrap` "accepts role override only when called under service-role" + required a test "client-supplied role override is ignored when caller is not service-role." Implementation took whatever role the JWT client sent (Zod limited to `'student' | 'instructor'`) and used it to create a new `public.users` row — letting any mobile user self-provision as an instructor. The `ctx.isServiceRole` flag existed but was never checked. Trusting the transport-layer default (web hardcodes `'instructor'`, mobile hardcodes `'student'`) is not the same as enforcing it.
- **Prevention rule:** When an AC says "only when X" / "ignored when X" / "callable only under X" about a *runtime* condition, the procedure body must check that condition explicitly with a conditional — `if (!ctx.isServiceRole) throw …` or `if (!ctx.user.role === 'admin') throw …`. Defaulting + hoping the transport sends the right value is not enforcement. Write the AC-named test before merging.

### Query-param deep links to an uncontrolled component
- **First seen:** PR #10 (ridgeline), RG-11
- **Severity:** REQUIRED
- **Category:** Bug/Logic
- **What happened:** UI shipped `?tab=properties` deep links from sibling panels (and empty-state copy that assumed the user could land there), but the `<Tabs>` host stayed uncontrolled (`defaultValue="overview"`) with no URL handling. Clicking the deep links re-rendered on the same URL and the tab silently reset to the default. Pattern generalizes beyond Tabs — any uncontrolled Radix/shadcn primitive (Accordion, Dialog, Select) that other code "navigates to" via a query param has the same bug.
- **Prevention rule:** If any code path links to a component's state via `?param=value` (or expects deep-linking / shareable URLs / refresh persistence), the host component must be **controlled** (`value` + `onValueChange`) and bound to `useSearchParams()` with `router.replace(..., { scroll: false })` on change. Whitelist the incoming param against known values so garbage URLs fall back gracefully. Grep for inbound links (`?tab=`, `?section=`, `?view=`) when introducing or modifying any such host component.

### Deprecated function left in tree after the migration completed
- **First seen:** PR #10 (ridgeline), RG-11
- **Severity:** REQUIRED
- **Category:** Over-generation
- **What happened:** A scalar-returning `getBillingGroupForBillToCustomer` was marked `@deprecated` in favor of the array-shaped successor "for back-compat during the UX migration." By the time the PR was opened, the UX migration was complete and the deprecated function had zero call sites — but the definition (plus a multi-line block comment explaining the deprecation) was still in the file. CLAUDE.md is explicit: "if you are certain that something is unused, you can delete it completely."
- **Prevention rule:** Before opening a PR that contains a `@deprecated` marker, grep for call sites of the deprecated symbol within the same diff's scope. If the count is zero AND the deprecation was for a migration that this PR completes, **delete the symbol** — don't ship the deprecation tombstone. `@deprecated` only earns its keep when external/long-lived callers exist; in a single-repo migration that lands as one PR, there's no caller to protect.

### `FOR ALL` RLS policy overrides stricter per-operation policies
- **First seen:** Cut B migration (ridgeline, downstream)
- **Severity:** REQUIRED
- **Category:** Architecture
- **What happened:** A migration added a permissive `CREATE POLICY ... FOR ALL` on a tenant-scoped table alongside a more restrictive `FOR SELECT` policy intended to limit technician reads. Postgres evaluates RLS policies as a union — the `FOR ALL` policy applied to SELECT as well, so technicians could read rows the SELECT policy was supposed to deny. The bug was invisible at write time and only surfaced through manual testing of the technician path.
- **Prevention rule:** Never write `CREATE POLICY ... FOR ALL` when any of SELECT/INSERT/UPDATE/DELETE on the same table needs a different predicate. Split into one `CREATE POLICY` per operation that differs. `FOR ALL` is only safe when *every* operation truly shares the same predicate — and even then, explicit per-operation policies make reviewer intent clearer. Grep any new migration for `FOR ALL` and challenge each occurrence.

### Outdated dependency version selected over current latest stable
- **First seen:** Vite scaffold (ridgeline), Next.js 15.1.4 picked when 16.2.6 was current
- **Severity:** NOTED (REQUIRED if it gates a feature on a version-specific behavior)
- **Category:** Over-generation
- **What happened:** A new project was scaffolded with Next.js 15.1.4 — a version the assistant was familiar with — when 16.2.6 was the current latest stable. The user caught it on review; the fix was a same-day bump, but the principle generalizes: defaulting to a familiar-but-stale version means immediate tech debt and a second upgrade pass later. Separately, an unannounced TypeScript major bump in a different PR cascaded strictness errors and had to be reverted.
- **Prevention rule:** Before introducing a new dependency or bumping a major version, run `npm view {pkg} version` (or visit the npm page). Introductions: use latest stable unless there's a documented reason to pin lower. Major bumps (Next, React, TypeScript, Expo, Supabase JS): require explicit user confirmation before applying — they cascade breaking changes and lint rule churn through unrelated files.

### Tests restate the implementation instead of exercising behavior
- **First seen:** multiple autonomous implementation sessions (apr–jun 2026 report cohort)
- **Severity:** NOTED
- **Category:** Over-generation
- **What happened:** Autonomous implementations occasionally land with tests whose only assertions are `expect(mockFn).toHaveBeenCalledWith(...)` against every dependency the unit calls — the test passes only as long as the implementation calls happen in the exact order written, and fails on any refactor that doesn't change observable behavior. These tests inflate the diff, slow review, and provide no regression protection.
- **Prevention rule:** For every new test, ask: *"Would removing this test reduce coverage of any observable behavior?"* If the answer is no, delete it. Prefer behavioral tests at the public surface (component rendered, route handler invoked, RPC called through PostgREST) over mock-call assertions on the unit that owns the call. Mock-call assertions are appropriate at trust boundaries (third-party API, message queue) — never on a method the unit itself owns.

### `SECURITY DEFINER` RPC trusts a caller-supplied user/owner identifier
- **First seen:** PR #22 (greenhouse), GH-34 — both `tick_session_timer(p_owner TEXT)` and `log_ticket_change(p_actor TEXT, ...)`. Broader version of the "Only under service-role" pattern above.
- **Severity:** REQUIRED
- **Category:** Architecture
- **What happened:** `tick_session_timer(p_owner TEXT)` was created `SECURITY DEFINER` and granted to `authenticated`, accepting an arbitrary `p_owner` string and updating every running entry owned by that user. The function never verified `p_owner` was the caller's own username, so any authed user could `POST /rest/v1/rpc/tick_session_timer` with `{"p_owner": "<another-user>"}` and indefinitely block the sweep from closing that user's idle timers. The same shape existed in `log_ticket_change(p_actor TEXT, ...)` — an authed user could call the RPC with `p_actor = "<another-user>"` and poison the audit trail with forged attributions. `SECURITY DEFINER` bypasses RLS on the underlying table — the function body is the only enforcement point. Generalizes to any RPC parameter that names *which user/row* to act on, not just `role`.
- **Prevention rule:** Every `SECURITY DEFINER` function that takes a parameter naming a user/owner (`p_owner`, `p_user_id`, `p_actor`, `p_username`, `p_for_user`, etc.) must, inside the function body, resolve the caller's identity — `current_team_username()`, which covers web sessions (`auth.uid()`) and user-bound CLI keys (the `user_id` claim) — and `RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501'` when it is NULL or doesn't match. Gate the check on `current_setting('role', true) = 'authenticated'`: only `service_role` and `postgres` (migrations, seed, pgTAP fixtures) may bypass. CLI tokens are `authenticated` too — an `org_role` of `service` or `api_key` is a person's key, not a trusted backend, so it never bypasses (GH-107 removed exactly that bypass from `log_ticket_change`, which had let any CLI token log under any actor). When another parameter names a row (`p_ticket_id`), also check the row's org and project scope and answer out-of-scope with the same error as not-found. RLS on the underlying table is NOT a substitute — `SECURITY DEFINER` bypasses RLS by definition. Default mental model when reviewing a new `SECURITY DEFINER`: *"if this parameter were not the caller's own identifier, what damage could a malicious caller do?"* Any non-zero answer requires an in-body check. Cover the rejection case with a pgTAP `throws_ok` test.

### Seed data not in canonical format
- **First seen:** tallgrass/ridgeline seed scripts (non-E.164 phone numbers; consent assigned by random UUID ordering)
- **Severity:** REQUIRED
- **Category:** Bug/Logic
- **What happened:** Seed scripts inserted phone numbers like `"555-1234"` instead of E.164 (`"+15555551234"`), and assigned consent rows to whichever child the random `uuid_generate_v4()` happened to order first — producing rows that the production write path would have rejected or written differently. Downstream code that assumed canonical input broke on seeded data in ways it never would in production, masking real bugs and inventing fake ones.
- **Prevention rule:** Every value a seed script writes must pass through the **same validator the production write path uses** — Zod schemas, DB CHECK constraints, normalization helpers. If the production code calls `formatPhone(input)` before INSERT, the seed calls it too. Where ordering matters (consent → child, default → first row), assign by an explicit deterministic field (`created_at ASC`, an explicit `priority` int), never by UUID order. A seed that produces rows production would reject is broken, not "good enough for dev."

### Stated posture vs implemented posture (security claims especially)
- **First seen:** PR #134, RG-193
- **Severity:** REQUIRED
- **Category:** Style/Convention
- **What happened:** A gitleaks allowlist comment claimed the committed Firebase key was "application-restricted to our registered Android packages" while only the API restriction existed — the app/SHA-1 restriction was still a tracked follow-through. Same class hit twice in one PR: runbook sections earlier described a monitoring/approval model that was decided against. An auditor reading either would believe a control exists that doesn't.
- **Prevention rule:** Before committing, grep the diff's comments/docs for posture claims ("restricted", "gated", "requires approval", "alerts on", "encrypted", "verified") and check each against what is actually configured RIGHT NOW — not what is planned. If a control is pending, say "pending/tracked in {ticket}" explicitly. Aspirational statements belong in tickets, not in code comments or runbooks.

### A correct CI guard is silent when its run was skipped
- **First seen:** ridgeline PR #155, RG-87 (rounds 2 and 4); recurred on RG-309
- **Severity:** REQUIRED
- **Category:** Bug/Logic
- **What happened:** The PR was `CONFLICTING`, so GitHub skipped every `pull_request` run while `gh pr checks` kept reporting the last green one. Round 2 reviewed 17 unverified commits, including a migration dropping two columns and a table; in round 4 the green run predated a dev landing by six minutes. ridgeline already had a correct migration-order guard in CI — it never spoke because it never ran, so the collision surfaced in human review twice.
- **Prevention rule:** Never read CI status from `gh pr checks` alone. Compare the PR `headRefOid` with the latest completed run's `headSha` ([common-operations §CI on the Current Head](common-operations.md#ci-on-the-current-head)); a mismatch or a `CONFLICTING` PR means CI is unverified, which blocks.

### PR opened against the release branch instead of the integration branch
- **First seen:** PR #48, GH-67
- **Severity:** REQUIRED
- **Category:** Style/Convention
- **What happened:** GH-67 was implemented on a branch cut off `main` and the PR opened with `base: main`. In this repo ticket PRs land on `dev` and `main` only receives release roll-ups (#43, #46 are literally "roll dev into main"), so merging would have bypassed dev integration and shipped a migration to hosted ahead of the release flow. Nothing in the diff was wrong — the branch merged into `dev` cleanly and the migration still sorted last — but the whole review round was spent on a one-field metadata fix. The trap is that the base is inherited silently from wherever the branch was cut, so a correct implementation looks completely ready.
- **Prevention rule:** Before opening a PR, check the base explicitly against the repo's integration branch, not against whatever the branch was cut from: `git ls-remote --heads origin` for a `dev`, then confirm with `gh pr view {recent-ticket-pr} --json baseRefName`. If a `dev` exists, ticket PRs target it and `main` is reserved for release rolls. When cutting the branch, start from `origin/dev` so the default base is already right. Reviewers: read `baseRefName` as its own checklist line — it is invisible in the file diff. Note that `gh pr edit --base` silently no-ops on this repo (Projects-classic GraphQL error); retarget with `gh api -X PATCH repos/{owner}/{repo}/pulls/{n} -f base=dev`. If the retarget changes which commits the branch merges against, re-run the quality gate on the merged result rather than trusting the gate from the old base.

### Tool-behaviour claim in a comment generalized past what the tool does
- **First seen:** PR #64, GH-45
- **Severity:** REQUIRED
- **Category:** Style/Convention
- **What happened:** The ci.yml comment guarding the lint step said "disabling any react-hooks rule in a component makes the compiler skip that whole component." `babel-plugin-react-compiler@1.0.0` only bails on `DEFAULT_ESLINT_SUPPRESSIONS`, which is exactly `react-hooks/exhaustive-deps` and `react-hooks/rules-of-hooks`. The ticket's own tending had already found this (the 12 GH-36 disables never blinded the compiler), but the comment rounded the finding up to "any rule." A reader would either over-avoid harmless disables or, worse, trust the comment the day a narrower claim matters.
- **Prevention rule:** For every comment or doc line in the diff that states how a third-party tool behaves ("X makes Y skip", "Z ignores", "only runs when"), find the line in the installed package (`node_modules/.pnpm/{pkg}@{ver}/…/dist`) or the tended evidence that supports it, and scope the sentence to exactly that — name the specific rules/flags/versions rather than a category. If the claim came from an observed experiment, say what was observed. Related: *Stated posture vs implemented posture*, which covers the same drift for security controls.

### Follow-up ticket deferred past PR open
- **First seen:** PR #64, GH-45
- **Severity:** REQUIRED
- **Category:** Cohesion
- **What happened:** GH-45's `open_decisions` said to create the follow-up for the 23 compiler-bailout files *when the PR opened*, so the ci.yml "Known gap" comment could name it. Autonomous work-ticket instead listed it in the PR body and the completion comment as "proposed, not yet created," and the comment shipped naming a gap that nothing tracked. The review round then had to cover ticket creation, which needs a human approval gate the autonomous run had skipped past rather than stopped at.
- **Prevention rule:** Before `open-pr`, grep the ticket's `open_decisions`, `implementation_plan` and `implementation_notes` for follow-up actions ("follow-up ticket", "create … when", "ticket separately"). Each one is either created via `/greenhouse:create-ticket` before the PR opens — stopping at its approval gate, even in autonomous mode — or explicitly moved out of the ticket with the user's OK. Any code comment or doc that mentions a known gap must name its ticket ID (`tracked in GH-{N}`); "proposed" is not a tracking state.
