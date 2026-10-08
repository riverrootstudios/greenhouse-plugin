# Labeling Guide

How to assign labels to tickets and PRs. Labels are **additive** — once applied, they stay unless the ticket's scope changes.

---

## Ticket Labels (2-5 per ticket)

Labels make tickets discoverable and enable cross-cutting queries (e.g., "show me all `auth` work across projects"). Skills proactively assign labels based on what the work touches:

| Signal | Labels to Apply |
|--------|----------------|
| Touches `app/(auth)/` or auth logic | `auth` |
| Touches `app/api/` routes | `api`, `backend` |
| Touches React components or pages | `frontend`, `ux` |
| Creates/modifies Supabase migrations | `database`, `migration` |
| Adds/modifies RLS policies | `rls`, `database` |
| Touches Stripe integration | `payments` |
| Adds/modifies tests | `testing` |
| Touches email sending | `email` |
| Touches webhooks | `webhook` |
| Performance-focused work | `performance` |
| Security-focused work | `security` |
| Accessibility work | `accessibility` |
| DevOps/CI/CD work | `devops` |
| Analytics/tracking | `analytics` |
| Documentation changes | `docs` |

Labels are assigned once during `create-ticket` or `tend-ticket`. Downstream skills do not re-enrich labels. Aim for 2-5 labels per ticket.
