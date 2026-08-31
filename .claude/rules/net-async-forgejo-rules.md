# Net-Async-Forgejo House Rules

Apply to every task in this repository unless explicitly overridden. Bias: caution
over speed on non-trivial work; use judgment on trivial tasks. Loaded automatically
at launch (same priority as `CLAUDE.md`). Subagents get their discipline from the
skills force-loaded via `briefing.skills` — this file is for the orchestrating agent.

## Engineering discipline

1. **Think before coding** — State assumptions. When uncertain, ask rather than
   guess. Push back when a simpler approach exists. Stop when confused; name what's
   unclear.
2. **Simplicity first** — Minimum code that solves the problem. Nothing speculative.
3. **Surgical changes** — Touch only what you must. Don't "improve" adjacent code or
   formatting. Match existing style.
4. **Read before you write** — Before new code, read the module's accessors, the
   verb methods in `::API`, and the `WWW::Forgejo` methods being delegated to.
5. **Tests verify intent** — Reproduce a bug before fixing it; leave a regression
   test behind. A test that can't fail when the logic changes is wrong.
6. **Fail loud** — "Done" is wrong if anything was skipped. "Tests pass" is wrong if
   any were skipped or if the `../p5-www-forgejo` sibling was missing at load.

## Delegation

This rule depends on whether the Agent/Task tool is available to you.

- **You can spawn subagents** (orchestrating main agent): Do NOT touch
  behavior-relevant code yourself — delegate to `net-async-forgejo-worker`. Your
  lane: coordinate, inspect, plan, review diffs, run tests, manage git, edit
  non-behavioral docs. Why: only the `net-async-forgejo-*` agents get their skills
  force-loaded via `briefing.skills`; you get no briefing.

  | Task | Agent |
  |---|---|
  | Implement / refactor / debug behavior-relevant code | `net-async-forgejo-worker` (default) |
  | Pre-release audit | `net-async-forgejo-release-checker` |

- **You cannot spawn subagents** (you ARE a `net-async-forgejo-*` agent): The lock
  does not apply — implement, refactor, debug, and test per these rules.

Behavior-relevant = runtime behavior, the public verb interface, the transport /
delegation seam, `configure`/`url`/`token` resolution, error handling, tests. Pure
prose docs and Changes notes are not.

## Coordination — karr board (always in scope)

Ticket coordination is the orchestrating agent's job, so `karr` is always in scope —
don't invoke the `kanban-issues-karr-cli` skill first, just use it. Git-native
kanban; state lives in `refs/karr/*`; this repo has its own board.

- `karr list --compact` / `karr board` — open work · `karr show ID` — detail
- `karr create "Title" --priority high --body '…'` — new ticket
- `karr move ID in-progress --claim NAME` · `karr handoff ID --claim NAME --note "…"`

**Serialize board mutations when fanning out.** Keep implementation parallel if you
like, but loop `karr move`/`handoff`/`sync` sequentially — N landing at once is a
resource event that has OOM-rebooted a host, not a cheap command.

## Release coupling — WWW::Forgejo, released together

This distribution is a thin async layer over the sibling **`WWW::Forgejo`** (local
checkout `../p5-www-forgejo`). They ship as **one coordinated release** — the
cpanfile requires `WWW::Forgejo` and the tests `use lib '../p5-www-forgejo/lib'`.
**Only the local state counts; a CPAN-release lag of `WWW::Forgejo` is never a
blocker and never a ticket.** Cross-repo work is a karr ticket on the *other* repo's
board — never a direct edit; you cannot touch `p5-www-forgejo` from here.

> Note: `p5-www-forgejo` itself still needs its own house setup — that is its own
> repo's job, tracked as a ticket on this board (see backlog), not done from here.

## Release — never without permission

`dzil test` / `dzil build` / `prove -l t/` are fine anytime. `dzil release` and any
upload/deploy are STRICTLY forbidden without the maintainer's explicit go-ahead —
even if a plan lists "release" as the next step. For anything heading toward
release: stop and ask.

## Perl / async specifics — reference, don't restate

Module loading, the not-Moo `IO::Async::Notifier` pattern, Future lifetime rules,
the delegation architecture, and dist.ini/release conventions live in skills
`net-async-forgejo-core`, `perl-io-async-future`, `getty-perl-core`, and
`perl-release-dist-ini` (force-loaded for `net-async-forgejo-*` agents). Do not
duplicate that content here.
