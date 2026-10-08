# Commit Conventions

Commit messages encode traceability. Every commit on `main` links back to exactly one ticket.

---

## Format

```
{type}: {description} [{ticket-id}]
```

### Examples

```
feat: add password reset flow [RR-42]
fix: prevent duplicate subscription creation on retry [RR-38]
chore: upgrade Supabase SDK to v2.49 [RR-15]
refactor: extract tenant middleware from API routes [RR-7]
test: add RLS policy tests for prescriptions table [RR-12]
docs: add API authentication guide [RR-50]
perf: lazy-load dashboard charts [RR-22]
ci: add preview deployment to PR workflow [RR-55]
hotfix: fix Stripe webhook signature validation [RR-41]
```

---

## Types

| Type | When to Use |
|------|------------|
| `feat` | New feature or capability |
| `fix` | Bug fix |
| `chore` | Maintenance, cleanup, dependency updates |
| `refactor` | Code restructuring with no behavior change |
| `test` | Adding or modifying tests only |
| `docs` | Documentation only |
| `style` | Formatting, whitespace, linting fixes (no logic change) |
| `perf` | Performance improvement |
| `ci` | CI/CD pipeline changes |
| `hotfix` | Urgent production fix |

---

## Rules

1. **One commit per PR on the integration branch** — squash merge enforced
2. **Ticket ID required** — the `[{TICKET-ID}]` suffix is mandatory
3. **Description in imperative mood** — "add", "fix", "update", not "added", "fixes", "updated"
4. **Keep it under 72 characters** — the full line including type and ticket ID
5. **No period at the end** — it's a title, not a sentence
6. **Lowercase description** — start with lowercase after the colon

---

## PR Title Convention

PR titles lead with the ticket ID for easy identification:

```
[{ticket-id}] #{number} {type}: {description}
```

Example: `[RR-7] #42 feat: add password reset flow`

The squash merge commit on `{base}` ([Resolve Base Branch](common-operations.md#resolve-base-branch)) uses the commit format above (without PR number or ticket prefix). Since we squash merge, the commit message format is what matters for traceability.

---

## Branch Naming

```
{initials}/{ticket-id}-{short-description}
```

- Initials: your lowercased `initials` from the Greenhouse directory (e.g., `dt`, `mb`) — see [conventions §Current user resolution](../skills/conventions/SKILL.md#current-user-resolution)
- Ticket ID: lowercase (e.g., `rr-42`)
- Description: lowercase, hyphenated, short enough to type from memory

### Examples

```
dk/rr-42-password-reset
mc/rr-15-supabase-upgrade
dk/rr-7-tenant-middleware
```
