# Reference: Compliance Check

**Purpose:** Verify the full traceability chain before a PR is merged. Nothing reaches `main` without meeting compliance requirements.

**Used by:** `review-pr` before executing the squash merge.

---

## Behavior

### Step 1: Read PR Description

```bash
gh pr view --json title,body,number,reviewDecision,statusCheckRollup,headRefName
```

Confirm the PR body contains a Greenhouse ticket reference in the format `Implements {TICKET-ID}` (e.g., `Implements RG-42`).

If missing: *"PR description doesn't reference a Greenhouse ticket. Add `Implements {TICKET-ID}` to the PR body before merging."*

### Step 2: Look Up Ticket in Greenhouse

1. Extract ticket ID from PR description
2. If you already hold this ticket's context from the calling skill (`review-pr` Step 1), reuse it; otherwise `POST /rest/v1/rpc/get_ticket_context` with `{"p_display_id": "{ID}"}`

Verify:
- Result is non-null (ticket exists)
- `result.status` is `in_review` — if not, warn: *"Ticket {ID} is in {status}, expected in_review. Update status first?"*

### Step 3: Verify Acceptance Criteria Exist

Check that `result.acceptance_criteria` is non-null and non-empty.

If empty: *"Ticket {ID} has no acceptance criteria. This is required for compliance. Add criteria before merging."*

### Step 4: Verify PR Approval

```bash
gh pr view {number} --json reviewDecision
```

Check that `reviewDecision` is `APPROVED`.

If not approved: *"PR #{number} hasn't been approved. Request a review before merging."*

### Step 5: Verify CI Passing

```bash
gh pr checks {number}
```

All required checks must pass.

If failing: *"CI is failing on PR #{number}. Fix the failures before merging."* List the failing checks.

### Step 6: Compliance Tag Checks

Check `result.compliance_tags` array from the ticket context.

#### For `iec_62304` or `soc2` tagged tickets:

1. **Implementation Plan exists** — `result.implementation_plan` is non-null and non-empty
   - If empty: *"IEC 62304/SOC2 requires an implementation plan. Post one to the ticket before merging."*

2. **Implementation Notes filled** — `result.implementation_notes` is non-null and non-empty
   - If empty: *"IEC 62304/SOC2 requires implementation notes documenting decisions made during development."*

3. **Tests cover changes** — check that the PR includes test files
   ```bash
   gh pr diff {number} --name-only | grep -E '\.(test|spec)\.(ts|tsx|js|jsx)$'
   ```
   - If no test files changed: *"No test files in this PR. IEC 62304 requires test coverage for changes. Add tests or explain why they're not needed."*

#### For `hipaa` or `pii` tagged tickets:

1. **No PII in logs** — scan diff for common logging patterns that might include PII
   ```bash
   gh pr diff {number} | grep -E '(console\.(log|info|warn|error)|logger\.)'
   ```
   - Flag any log statements that reference user data fields (email, name, phone, address, ssn, etc.)

2. **RLS policies** — if new tables are created in migrations, verify RLS is enabled
   ```bash
   gh pr diff {number} | grep -E 'CREATE TABLE'
   ```
   - If new tables found, check for corresponding `ALTER TABLE ... ENABLE ROW LEVEL SECURITY` and `CREATE POLICY`

### Step 7: Verify Commit Message Format

Check that the PR title (which becomes the squash commit message) follows the convention:

```
{type}: {description} [{ticket-id}]
```

Valid types: `feat`, `fix`, `chore`, `refactor`, `test`, `docs`, `style`, `perf`, `ci`, `hotfix`

If format is wrong: *"PR title doesn't match commit convention. Expected format: `{type}: {description} [{TICKET-ID}]`"*

---

## Results

### All Checks Pass

Return green light to `review-pr`:

```
Greenhouse ticket: RG-42 — "Add password reset flow"
Status: in_review
Acceptance criteria: present (5 items)
PR approval: approved by mc
CI: all checks passing
Compliance: soc2 requirements met
Commit message: follows convention

Ready to merge.
```

### Any Check Fails

Block the merge. Report all failures at once (don't stop at the first):

```
MERGE BLOCKED — 2 issues found:

1. Implementation notes are empty
   → IEC 62304 requires implementation notes. Post decisions and rationale to the ticket.

2. No test files in PR
   → IEC 62304 requires test coverage. Add tests or document why they're not needed.

Fix these issues, then ask me to merge again.
```

---

## Error Handling

- **Greenhouse unreachable:** Block merge. *"Can't verify compliance — Greenhouse API is unavailable. Fix the connection and retry."*
- **Ticket not found in Greenhouse:** Block merge. *"Can't find ticket {ID} in Greenhouse. Verify the ticket ID in the PR description."*
- **GitHub API errors:** Block merge. *"Can't verify PR status — GitHub API error. Retry or check manually."*
