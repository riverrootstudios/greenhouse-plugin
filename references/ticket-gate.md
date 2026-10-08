# Reference: Ticket Gate

**Purpose:** No code reaches `main` without a Greenhouse ticket. This gate ensures traceability.

**Used by:** `work-ticket`, `open-pr`, and any time Claude Code is asked to write implementation code without a ticket reference.

**Does NOT trigger for:** Research, exploration, debugging, planning discussions, reading code to answer questions.

---

## Behavior

### Step 1: Check Current Context

Look for an active ticket ID in this order:

1. **Explicit reference** — user said a ticket ID (e.g., "RG-42")
2. **Branch name** — current git branch matches pattern `{initials}/{ticket-id}-*`
3. **Recent conversation** — a ticket was established earlier in this session

### Step 2: Validate in Greenhouse

If a ticket ID was found:

1. If you already hold this ticket's context from the calling skill (e.g. `work-ticket` handing off to `open-pr`), reuse it; otherwise `POST /rest/v1/rpc/get_ticket_context` with `{"p_display_id": "{ID}"}`
2. If the result is null, the ticket was not found — treat as no match
3. Check `result.status` — confirm the ticket is NOT `harvest` or `weeded`
4. If valid — return ticket context to calling skill

If ticket is `harvest` or `weeded`:
> "Ticket {ID} is already {status}. Want me to reopen it, or create a new ticket?"

### Step 3: Search for Match (if no ID found)

If the user described work but didn't reference a ticket:

1. Search for matching open tickets via PostgREST:
   ```
   GET /rest/v1/tickets?project_id=eq.{id}&status=not.in.(harvest,weeded)&or=(title.ilike.*{term}*,description.ilike.*{term}*)&select=display_id,title,status,priority,assignee&limit=10
   ```
2. If matches found — present them and ask for confirmation
3. If user confirms — use that ticket

### Step 4: Create New Ticket (if no match)

1. Tell the user: *"There's no ticket tracking this work. Want me to create one before we start?"*
2. If user confirms, gather: Title, Project, Type, Priority, Acceptance criteria
3. Assign labels per conventions (Labeling Philosophy)
4. Create via `POST /rest/v1/rpc/create_ticket` with status: `seeds`
5. Return ticket context to calling skill

---

## Error Handling

- **Greenhouse API unreachable:** Warn the user. Credentials resolve env → `~/.greenhouse/config` → plugin-shipped defaults, so this is usually a missing or expired personal token — suggest re-running `/greenhouse:setup` to reprovision it (not exporting env vars). Do not proceed without ticket tracking.
- **Config missing:** *"CLAUDE.md is missing the greenhouse config block (`project_id` / `project_key`). Add it by hand (copy the greenhouse repo's), or run `/greenhouse:health-check` to repair."*
- **User declines ticket creation:** Respect it for research/exploration. Block if they're asking for implementation code.
