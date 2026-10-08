# Compliance Guide

How the Greenhouse workflow maps to SOC 2 and IEC 62304 requirements. This is a mapping, not a certification: the workflow produces evidence an auditor can use, and passing an audit still depends on your own controls, policies and auditor. The skills named below run when you invoke them — nothing outside them blocks a change that skips the workflow (that is your branch protection's job).

---

## SOC 2 (All Projects)

SOC 2 Type II asks for demonstrable controls for security, availability, and change management. For change management, the workflow's traceability chain is the evidence.

### Change Management Controls

| SOC 2 Control | How the Workflow Maps to It | Checked By |
|---------------|-----------------------------|------------|
| Changes are authorized before implementation | Every code change requires a Greenhouse ticket | `open-pr` (ticket gate, [ticket-gate.md](ticket-gate.md)) |
| Changes are tested before deployment | Quality gate runs lint, typecheck, test, build | `open-pr`, `work-ticket` |
| Changes are reviewed by someone other than the author | PR approval required before merge | `review-pr` verdict, `merge-pr` (lands only approved PRs), plus your repo's branch protection |
| Changes are traceable from requirement to deployment | Ticket → Plan → Branch → PR → Merge → Release chain | All skills |
| Change history is maintained | Greenhouse ticket has full audit trail (comments, status changes, timestamps) | Greenhouse comments table |

### Evidence Chain

For any commit on `main`, an auditor can trace:

1. **Requirement** → Greenhouse ticket with acceptance criteria
2. **Design rationale** → Implementation plan posted to ticket before coding
3. **Implementation** → Branch linked to ticket, PR linked to ticket
4. **Testing** → CI pipeline results on PR
5. **Review** → PR approval with reviewer identity and timestamp
6. **Deployment** → Merge commit with ticket ID, release record

### Key Properties for Audit

- `Ticket.implementation_plan` — design rationale (pre-implementation)
- `Ticket.implementation_notes` — decisions made during implementation
- `Ticket.started_at` / `Ticket.completed_at` — work timeline
- `PR.Review SLA Met` — review timeliness
- `PR.Merge Commit` — exact code deployed

---

## IEC 62304 (Medical-Device Projects)

IEC 62304 is the international standard for medical device software lifecycle processes. A project building Class B software (software that could contribute to a hazardous situation) can use the mapping below to produce the documentation the standard asks for.

### Required Documentation

| IEC 62304 Clause | Artifact | Produced By |
|-----------------|----------|-------------------|
| 5.1 Software Development Planning | Epic + ticket breakdown | `/create-ticket` |
| 5.2 Software Requirements Analysis | Acceptance criteria on tickets | `/tend-ticket` |
| 5.3 Software Architectural Design | Implementation plan on ticket | `/work-ticket` |
| 5.5 Software Integration and Integration Testing | Test results in CI | Quality gate |
| 5.6 Software System Testing | Test coverage report | `/review-pr` |
| 5.7 Software Release | Release record with changelog | `/release` |
| 6.1 Software Maintenance Plan | Ticket types: bug, tech_debt | `/create-ticket` |
| 8.1 Software Configuration Management | Git history, branch protection | Git workflow |
| 8.2 Change Control | Ticket → PR → Review → Merge chain | All skills |
| 9.1 Problem Resolution | Bug tickets with root cause analysis | Ticket workflow |

### Additional Requirements for IEC 62304 Tickets

When a ticket has the `iec_62304` compliance tag:

1. **Implementation plan is mandatory** — must be posted before coding begins
2. **Implementation notes must be filled** — decisions, deviations, rationale
3. **Tests must cover all acceptance criteria** — verified by `/review-pr`
4. **Risk analysis reference** — ticket should note if it affects any identified risks
5. **Traceability matrix entry** — ticket links requirement → design → code → test

### Compliance Check Additions

`review-pr` runs [compliance-check.md](compliance-check.md) on tickets tagged `soc2`, `iec_62304`, `hipaa` or `pii`, and reports these as findings in its verdict:

- Implementation plan exists and is non-empty
- Implementation notes exist and are non-empty
- Test files exist that cover the changed code
- No PII in logs (for `hipaa`/`pii` tagged tickets)
- RLS policies cover any new database tables (for `hipaa`/`pii` tagged tickets)

---

## HIPAA Considerations

For tickets tagged with `hipaa` or `pii`:

1. **No PII in logs** — structured logging must exclude patient data
2. **RLS enforced** — every new table with patient data must have RLS policies
3. **Encryption at rest** — Supabase handles this, but verify for any custom storage
4. **Access audit trail** — Supabase auth logs + application logging
5. **Minimum necessary** — API responses should only include fields needed by the client

---

## Compliance Tag Reference

| Tag | Applies To | Extra Requirements |
|-----|-----------|-------------------|
| `soc2` | All projects | Standard traceability chain |
| `iec_62304` | Medical-device projects | Full documentation chain, risk traceability |
| `hipaa` | Projects handling PHI | PHI handling, encryption, access controls |
| `pii` | Any project | Personal data handling, RLS, no PII in logs |

---

## Audit Preparation

To prepare for an audit, use `/dashboard` filtered by compliance tags. The dashboard shows:

- All tickets with compliance tags and their full lifecycle
- Any gaps in the traceability chain (missing plans, missing reviews, missing tests)
- Timeline of changes with reviewer attribution

The `/health-check` skill verifies that Greenhouse and GitHub are consistent — no orphaned PRs, no tickets stuck in wrong states.
