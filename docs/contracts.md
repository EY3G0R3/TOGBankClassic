<!-- markdownlint-disable MD049 MD050 MD028 -->
<!-- Same reasoning as docs/AUDIT.md: this file quotes both sides verbatim and is append-only, so
     emphasis style is not one side's to normalise, and the request/response shape produces two
     adjacent blockquotes separated by a blank line (MD028) by construction. Both remedies
     markdownlint offers are edits to existing text in an append-only file, which writ's
     peer-review law refuses -- so the only moment this is fixable is at creation, which is now. -->
# Contracts -- TOGBankClassic

**The general channel between this repository and any other one.** Created 2026-09-08 during writ
onboarding: writ's three-filename list expects every repository to carry `docs/audit.md`,
`docs/contracts.md` and a harness contract, and this one was absent.

**An absent file is not a neutral state.** A session standing outside this repository may write
exactly one kind of file inside it -- a shared conversation -- and writ holds that permission as
an explicit list matched case-blind on the path suffix. A name not on the list is indistinguishable
from any other private file, and the write is refused. So while this file did not exist, a paired
repository had **no way to raise anything here at all**, and the absence looked exactly like
nobody having anything to say.

## Which file is which

| File | The conversation it carries | State |
| --- | --- | --- |
| [`docs/AUDIT.md`](AUDIT.md) | a review session raises findings; this repo answers in place | present |
| [`Tests/HARNESS_CONTRACT.md`](../Tests/HARNESS_CONTRACT.md) | what this addon needs from the WoWAPITesting harness, and the harness's replies | present, 7 items open, none answered |
| `docs/contracts.md` | **this file.** Any other repository that needs a channel | present, no threads yet |

**The harness contract is deliberately at `Tests/`, not `docs/`.** Around twenty WoW addons keep
it next to the suite it is about, and writ's list carries that spelling as a second entry. It is
not a mistake to be tidied, and moving it would take it off the list.

**A harness request does not belong in this file** and a request to any other repository does not
belong in the harness contract. Keep the two honest about which counterparty owns the answer.

## Likely counterparties

This addon depends on sibling repositories in the same fleet, any of which may need a channel:
**AceCommQueue-1.0**, **DeltaSync**, **ItemDB**, **LibAceGUIWidgets**, **VersionCheck-1.0**, and
**LibGuildRoster** (whose migration is in flight in the uncommitted v1.4.0 work). A contract with
one of those belongs here.

**Read [`docs/DEPENDENCY_CONTRACTS.md`](DEPENDENCY_CONTRACTS.md) and
[`docs/LIBRARY_CONTRACTS.md`](LIBRARY_CONTRACTS.md) before raising one.** Those are this repo's
own design notes about what it expects from its libraries -- they are **not** a channel, nobody
outside this repo reads them, and a requirement recorded only there has not been communicated to
anyone.

## The protocol

**Append-only, both directions, including your own earlier text.** Never edit, re-title, re-order
or move anything already here -- not what the other side wrote, and not what you wrote yourself.
The value is the whole thread: what was asked, why, what the answer was, and what shipped. **The
"why" in a request is usually the most valuable line in the file**, because it is the account of
what actually went wrong; rewriting the request destroys it.

**This file is a live working tree, and nobody is waiting on a commit.** Both sides append to it
and both sides read it there. A response is useful the moment it is written.

### Raising a request

Give it a heading with an id and a date, and state three things: **what** is needed, **why** --
the concrete failure that prompted it -- and the **exact contract** an implementation must meet.
A request whose "why" is a preference rather than a failure is hard to answer well.

```text
## TOGBANK-001 -- 2026-09-08 -- <one-line statement of what is needed>

**What:** ...
**Why:** the specific thing that broke, with a file:line or a reproduction.
**Contract:** what an implementation must guarantee, stated so it can be tested.
```

### Answering one

Append a block directly underneath the request. Do not edit the request:

```text
> **Response -- YYYY-MM-DD -- DELIVERED | DECLINED | PARTIAL | NOT A GAP.**
> What was implemented, and anywhere it differs from what was asked, said plainly.
```

**Disagreeing is useful and expected.** Say so in the response and leave the request standing. A
declined request is never deleted -- it keeps its reasoning so nobody re-raises it in six months.
What is not acceptable is silently changing the question so the answer looks better.

## Threads

_None yet. This file has carried no conversation._
