# Checkpoint Handoff

The format for pausing interactive work at a phase or milestone boundary.

**Used by:** `work-ticket` (Step 6, interactive mode), `tend-ticket` (collaborative pauses).

---

## Why this exists

When a user picks interactive over autonomous, **the breaks are the product.** They chose to stay in the loop, which means each pause has to give them something to act on — otherwise interactive mode degrades into autonomous mode with extra confirmations, and "done, continue?" wastes the one thing they asked for.

A handoff is not a status report. It answers three questions the user is actually holding:

1. Is what just landed what I wanted?
2. Is there anything I need to know or decide before we go further?
3. Can I see it working with my own eyes right now?

---

## When to emit one

At **every** phase or milestone boundary in interactive mode — regardless of ticket complexity. A 2pt ticket with two phases gets two handoffs. Do not scale this down for small tickets: the user picked interactive knowing the size, and a skipped handoff is the one they needed.

Also emit one when:
- Work is pausing for the session (see [Status Updates](../skills/work-ticket/SKILL.md) — also post a Greenhouse comment)
- A phase finished but its verification is blocked (say so, and say what's blocking)
- Scope changed mid-phase (the handoff is where you surface it)

**Do not** emit one in autonomous mode. Autonomous posts implementation notes to Greenhouse instead and reports once at the end.

---

## The format

```
## ✅ Phase {N} done — {short name} ({commit sha})

**What landed:** {what now works that didn't before, in concrete terms}

**Files:** {links to the files that changed}

**Things to be aware of:**
- {surprises, assumptions, deferred items, anything you did to their environment}

**Where to poke around:** {specific route, command, or page}

**Next: Phase {N+1}** — {one line}. {Explicit yes/no ask}
```

### Section rules

**What landed** — describe the *change in capability*, not the work performed. "Brainstorm saves now persist; the 500 is gone" beats "modified createBrainstormNote to include org_id." Never restate acceptance criteria back at the user; they wrote them. If tests ran, give the actual number (`161/161 green`), not "tests pass."

**Files** — link them so they're clickable. Group by area when a phase spans layers (web / database / plugin).

**Things to be aware of** — the highest-value section, and the one most often skipped. Include:
- Anything you changed about their environment or machine (stopped a service, freed a port, touched a global config)
- Anything you did to their working tree they didn't ask for (staged, unstaged, or reverted a file)
- Assumptions made where the ticket was silent
- Things deliberately deferred, and to where
- Anything that surprised you — a wrong doc, a fragile pattern, an unexpected failure. If you hit it, they'll hit it
- Decisions that are now hard to reverse

If this section is empty, look harder. It is rarely genuinely empty. If it truly is, say "nothing surprising" rather than omitting the heading.

**Where to poke around** — pick the target by what the phase actually touched:

| Phase touched | Give them |
|---|---|
| Frontend / UI | The concrete route or page (`http://localhost:3000/time`), plus what to look at once there |
| API / backend | The `curl` or the UI flow that exercises it end to end |
| Database / migration | The verification command (`supabase test db`, a `psql` `\d` on the changed table) |
| Plugin skills / prose | The invocation that exercises the new behavior — and warn that the plugin cache needs a refresh first |
| Config, tooling, CI | The command that proves it, or say plainly that there's nothing to see and why |

Never write "check the UI" or "verify it works." If a phase genuinely has nothing observable, say that outright — an honest "nothing to see here, it's verified by the pgTAP above" is more useful than a vague gesture.

**Next** — name the next phase in one line and end with a real question. The user should be able to answer in one word.

---

## Declaring phases up front

Interactive mode declares the phase boundaries **during plan presentation in Step 3**, before any code is written. The user should know where the breaks will fall while they're still approving the plan — a phase list that appears one phase at a time gives them no chance to say "don't stop there, stop here."

Include in the plan:
- Each phase's name and one-line scope
- What will be verifiable at each boundary
- Which phases have nothing observable (so a quiet handoff isn't a surprise)

If the plan changes mid-implementation, say so at the next handoff and restate the remaining phases.

---

## Anti-patterns

| Anti-pattern | Why it fails |
|---|---|
| "Phase 1 complete. Continue?" | Nothing to act on. This is the failure mode this reference exists to prevent |
| Restating acceptance criteria as accomplishments | The user wrote them; echoing them proves nothing |
| "All tests pass" | Give the count and the command. Unverifiable claims are worse than no claim |
| "Check the UI to confirm" | Which page? Looking at what? |
| Omitting *Things to be aware of* because the phase went smoothly | Smooth phases still contain assumptions and environment changes |
| Burying something you changed on their machine | The one thing they cannot discover on their own. Always surface it |
| Emitting the handoff, then continuing without waiting | The pause is the point |
