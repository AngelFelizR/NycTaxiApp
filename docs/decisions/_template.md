# NNNN. <decision in one sentence, past tense or nominalised>

- Status: Proposed | Accepted | Superseded by NNNN | Deprecated
- Date: YYYY-MM-DD
- Phase: <n> (<master document section(s)>)
- Relates to: ADR-0xx (master document §18) | none

## Context

What was being decided, with the facts that made it a decision rather than a
default. Cite the master document section by number when it constrains the
choice. Say what the alternatives had going for them, not just against them --
a decision nobody could have disagreed with does not need an ADR.

## Decision

What is now true, in one sentence that could be quoted on its own, followed by
whatever detail is needed to implement it without re-reading this file.

## Alternatives

Every option that was genuinely considered, and **why each was rejected**.
This section is mandatory: an ADR without it records a conclusion instead of a
reasoning, and the next person will re-litigate the same tradeoff.

- **<alternative>** -- rejected because <the concrete cost>.
- **Do nothing** -- if that was a real option.

## Consequences

What gets worse, what has to be done because of this, and — importantly —
which divergences it creates with the master document. Divergences are
annotated in `CHANGELOG.md`, never fixed in the document (see AGENTS,
"Fuente de verdad").

- **Follow-ups:** …
- **Divergences:** §x.x says …, we do … — annotated in `CHANGELOG.md`.
