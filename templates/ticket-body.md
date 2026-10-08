## Description

{What this ticket is and why it's needed — one to two paragraphs.}

<!-- The one/two-sentence plain-English `summary` is a separate DB field, not part
     of this body — set it via `p_summary` on create; tend-ticket refreshes it.
     It becomes the Slack notification body for this ticket's lifecycle events. -->

## Source

<!-- Only when create-ticket read source docs and the ticket has no epic
     (with an epic, they go on the epic's planning_refs). One line per doc. -->

- PRD: {path or URL}
- Transcript: {path}

## Acceptance Criteria

- [ ] {Specific, testable outcome 1}
- [ ] {Specific, testable outcome 2}
- [ ] {Specific, testable outcome 3}
- [ ] {Tests pass for all new functionality}
- [ ] {Quality gate passes: lint, typecheck, test, build}

## Technical Notes

{Any technical context that helps implementation:}

- {Architecture considerations}
- {Related files or modules}
- {Database changes needed}
- {API contract changes}

## Blocked By

- {TICKET-ID} _(if any)_

## Out of Scope

{Explicitly noting what this ticket does NOT cover:}

- {Thing 1}

## Complexity Assessment

```
{N}pt {approach} · {file scope} · {change type} · {blast radius} risk · {confidence} confidence
```

<details>
<summary>Full assessment</summary>

| Field | Value |
|-------|-------|
| File Scope | {1 file, few files, many files, unknown} |
| Change Type | {patch, minor, major} |
| Modules | {list of affected codebase areas} |
| Blast Radius | {isolated, module, cross-cutting} |
| Reversibility | {trivial revert, revertable, difficult revert} |
| Requires Testing | {yes, no} |
| Needs Migration | {yes, no} |
| Established Pattern | {yes, no} |
| Confidence | {high, medium, low} |

</details>
