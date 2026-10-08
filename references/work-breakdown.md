# Work Breakdown Philosophy

How RiverRoot Studios sizes, sequences, and decomposes work.

---

## Core Principle

**One ticket = one branch = one PR = one squash commit on the integration branch.** An auditor can point at any ticket commit on the integration branch (`dev` where it exists, else `main` — see [Resolve Base Branch](common-operations.md#resolve-base-branch)) and follow it back to exactly one PR, which closes exactly one ticket, which describes exactly one unit of work. The chain never fans out; `main` receives it through a release merge.

---

## Vertical Slice Rule

Feature tickets include API routes, UI pages/components, and tests — not just one layer.

**Good:** "Add subscriber management with API, list page, detail page, and tests"
**Bad:** Three separate tickets for "Add subscriber API", "Add subscriber UI", "Add subscriber tests"

Only split by layer when the layers are genuinely independent and individually valuable (e.g., a pure infrastructure ticket that enables multiple future features).

---

## Sizing Rules

A ticket is the **largest coherent unit of work that produces a single reviewable PR.** A ticket can span multiple Claude Code sessions — what matters is that the PR is cohesive and reviewable, not that it fits in one session.

Each ticket = one PR = one CI run, so prefer fewer, bigger tickets over many small ones. Don't split work that naturally belongs together. AI handles large vertical slices well — a full feature with API, UI, and tests is one ticket, not three.

### Must Pass All Checks

- **One sentence test:** Can it be described in one sentence? If you need "and", it's probably two tickets — unless both parts serve the same user-facing feature
- **Working state test:** Does completing this ticket leave the codebase in a working state? If not, combine with its dependency or restructure as a vertical slice
- **Vertical slice test:** Is it a complete vertical slice, not a horizontal layer?
- **Reviewability test:** Would the final PR be reviewable as a single cohesive change? If the PR would touch so many independent concerns that a reviewer can't hold it in their head, split it. Size alone is not a reason to split

---

## Complexity Scale (Powers of 2)

Complexity points drive how the agent approaches the work — not just how big it is, but how to execute it.

| Points | Scope | Agent Approach | Files |
|--------|-------|----------------|-------|
| **1** | Config change, copy update, single-file fix | Direct execution, no planning | 1 |
| **2** | Well-scoped bug fix or small feature, clear requirements | Direct execution | 1-3 |
| **4** | Multi-file feature, needs codebase reading first | Plan, then execute | 3-8 |
| **8** | Full vertical feature — API + UI + tests, some design decisions | Plan + exploration, single session | 5-15 |
| **16** | Major feature spanning multiple modules, significant design surface | Plan + phased execution, may span sessions | 10-25 |
| **32** | Large vertical slice across the full stack, many integration points | Multi-session, self-review checkpoint between phases | 15-40+ |
| **64** | Very large vertical slice — review whether it's one concern or many | Plan carefully, ask user if splitting would help, self-review checkpoints | 30-60+ |

Tickets scoring 64 are large but not automatically too large. AI handles big vertical slices well. Ask the user whether they'd like to split — but don't require it. The question is whether the PR would be reviewable as one cohesive change, not whether the point count is high. Tickets scoring 32+ should use self-review checkpoints between implementation phases.

---

## Complexity Assessment

Each ticket carries a complexity assessment — a structured evaluation of what makes it complex. The assessment is generated during tending as a byproduct of codebase exploration (no extra token cost).

### Readable Compact Format

The assessment is summarized in one line, leading with the score:

```
4pt plan · few files · minor change · clear reqs · no open decisions · module risk · revertable · requires testing · established pattern
```

### Assessment Fields

| Field | Values | Who Scores It |
|-------|--------|---------------|
| File Scope | `1 file`, `few files`, `many files`, `unknown` | Agent (during tending) |
| Change Type | `patch`, `minor`, `major` | Agent (during tending) |
| Requirements | `clear`, `partial`, `open` | Human (on ticket creation) |
| Open Decisions | List of unresolved questions | Both — human lists known, agent surfaces missed |
| Modules | Areas of the codebase affected | Agent (during tending) |
| Blast Radius | `isolated`, `module`, `cross-cutting` | Agent (during tending) |
| Reversibility | `trivial revert`, `revertable`, `difficult revert` | Agent (during tending) |
| Requires Testing | `yes`, `no` | Agent (during tending) |
| Needs Migration | `yes`, `no` | Agent (during tending) |
| Established Pattern | `yes`, `no` — a pattern already exists in the codebase to follow | Agent (during tending) |
| Confidence | `high`, `medium`, `low` — how confident the agent is in its scoring | Agent (during tending) |

### How Complexity Maps to Signals

| Signal | Low (1-2) | Medium (4-8) | High (16-32) | Very High (64) |
|--------|-----------|------------|-------------|----------------|
| File Scope | 1-3 files | 3-15 files | 15-40 files | 40+ files across unrelated concerns |
| Change Type | patch | minor-major | major | major across multiple systems |
| Requirements | clear | clear/partial | partial | open |
| Open Decisions | none | 0-2 | 2-4 | 5+ |
| Established Pattern | yes | yes/partial | no | no |
| Blast Radius | isolated | module | cross-module | cross-cutting + external |

### Predicted vs Actual

Two Greenhouse properties track complexity over time:
- **Complexity** — set during tending (the prediction)
- **Actual Complexity** — set at merge (what it actually took)

If actual consistently exceeds predicted, the tending process needs calibration. If actual is consistently lower, tickets may be over-scoped. This comparison is free — it's one extra field in the merge update.

### Token Efficiency

Complexity scoring is **not** a separate analysis pass. It piggybacks on work already being done:

| Moment | What Gets Scored | Why It's Free |
|--------|-----------------|---------------|
| `create-ticket` creates ticket | Rough score from description only (Confidence: low) | No codebase reading needed |
| `tend-ticket` expands criteria | Full score from codebase exploration already done in Step 2 | Already reading those files |
| `work-ticket` plans | Refinement if scope differs from prediction | Already reading the codebase to plan |
| `review-pr` finalizes | Actual Complexity from what was actually changed | One extra property in existing update |

---

## Assignment Rules

1. **Assignee** — the user's choice. Ask who should own which tickets; "no preference" leaves a ticket unassigned, and `work-ticket` assigns whoever picks it up. A solo team assigns its one member without asking. Values are Team-table **Greenhouse** usernames (`${GREENHOUSE_TEAM_USERNAME}` for yourself), never a name, initials or GitHub login
2. **Reviewer** — never the assignee; see [conventions §Reviewer Rule](../skills/conventions/SKILL.md#reviewer-rule): none for a 1-row table, the other person for 2, asked for 3+
3. **Assignments aren't permanent** — anyone can pick up anyone's tickets

---

## Sequencing

1. **Infrastructure before features** — database tables before API routes before UI
2. **Dependencies first** — check the dependency graph, start from leaves
3. **High-risk first** — tackle unknowns early when there's time to adjust
4. **Quick wins to build momentum** — if two tickets are equal priority, do the faster one first

---

## When to Split

Splitting is the exception, not the default. **Default instinct: combine.** Only split when a clear boundary forces it. More than 3 tickets for a single feature is almost always over-decomposing. AI handles large vertical slices well — prefer 1-2 big tickets over 4-5 small ones.

Every ticket becomes a PR. Every PR requires a human reviewer. The more PRs in flight, the harder review coordination becomes. Fewer, bigger PRs is almost always better for the team.

| Signal | Action |
|--------|--------|
| Complexity is 64 | Ask the user if they want to split — 64pt is fine when the work is one cohesive concern |
| Scope grew during implementation | Stop. Add it to the [out-of-scope findings](common-operations.md#out-of-scope-findings) list. Finish current scope |
| Can't verify all changes in one review session | Split for reviewability |
| More than 5 files touching genuinely different concerns | Consider splitting by concern |
| Needs "and" to describe AND both parts serve different users/goals | Split |

---

## When NOT to Split

When in doubt, combine. A larger ticket is almost always better than two tickets with coordination overhead.

- Both sides of "and" are part of the same user-facing feature
- Splitting would leave the codebase in a broken state
- The ticket is complexity 16 or lower — at this scale, coordination overhead of multiple tickets exceeds the complexity of a single larger ticket
- The work is genuinely atomic (e.g., a database migration + the code that uses it)
- Narrow vertical slices of the same feature (e.g., "list view" and "detail view" of the same entity — combine them)
- Both tickets would be assigned to the same person anyway

---

## Scope Creep Rules

| Discovery | Test | Action |
|-----------|------|--------|
| Same user story | Would a user describe this and the ticket's goal in the same sentence? | Do it in the current ticket — this is expected for larger tickets |
| Different user story | Would this serve a different user need or workflow than the ticket describes? | Add it to the [out-of-scope findings](common-operations.md#out-of-scope-findings) list — a ticket is filed only when the user says yes |
| Changes the architectural approach | Does this invalidate assumptions the plan was built on? | Stop. Comment on ticket. Invoke `/replan` |

Never silently expand scope. If you find yourself doing more than the acceptance criteria specify, stop and evaluate.

---

## Traceability Chain

The normal path has no epic:

```
Ticket (Greenhouse) → Ticket Branch (off the integration branch) → Code + Tests →
PR → Squash into the integration branch → Release (integration branch → main, tag)
```

An epic exists only when planning explicitly asked for one ([conventions §Epic Usage](../skills/conventions/SKILL.md#epic-usage)). Then the chain gains an epic layer: `Epic (Greenhouse) → Epic Branch → …ticket PRs squash into the epic branch… → Final Epic PR → integration branch → Release`.

---

## Replanning Triggers

- After every 3-5 tickets completed in an epic
- Actual complexity diverged significantly from predicted (e.g., scored 4 but turned out to be 16)
- A ticket took significantly longer than expected
- New dependency discovered that changes the sequence
- Requirements changed from stakeholder input
- Implementation revealed the plan was wrong

When replanning, review all remaining tickets. Cancel obsolete ones, create new ones, adjust priorities and estimates. The plan is a living document.
