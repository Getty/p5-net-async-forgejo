# Net-Async-Forgejo House Rules

The shared house rules come from skilletor — bundle `getty-cpan-dist@getty`: engineering
discipline, the delegation lock, the publish gate, karr coordination, CPAN release. They load
as `.claude/rules/.local.*.md`; if they are missing, run `skilletor sync` and publish nothing
until they load. This file adds what is true only here, and wins where it differs.

## What this repo is

Async Forgejo API client for IO::Async — a thin transport layer over the sibling
`WWW::Forgejo`. Read first: the module's accessors, the verb methods in `::API`, and the
`WWW::Forgejo` methods being delegated to.

## Agent team

| Task | Agent |
|---|---|
| Implement / refactor / debug behavior-relevant code | `net-async-forgejo-worker` (default) |
| Commits, `Changes`, card → done, pre-release audit | `net-async-forgejo-release-manager` |
| Read-only research, audit, gap analysis | `net-async-forgejo-worker` ("read-only, change nothing") |

Behavior-relevant = runtime behavior, the public verb interface, the transport / delegation
seam, `configure`/`url`/`token` resolution, error handling, tests. Pure prose docs and Changes
notes are not.

## Release coupling — WWW::Forgejo, released together

This distribution is a thin async layer over the sibling **`WWW::Forgejo`** (local checkout
`../p5-www-forgejo`). They ship as **one coordinated release** — the cpanfile requires
`WWW::Forgejo` and the tests `use lib '../p5-www-forgejo/lib'`. Cross-repo work is a karr
ticket on the *other* repo's board — never a direct edit; you cannot touch `p5-www-forgejo`
from here.

> Note: `p5-www-forgejo` itself still needs its own house setup — that is its own repo's job,
> tracked as a ticket on this board (see backlog), not done from here.

## Hazards

- **The sibling must be present.** "Tests pass" is wrong if the `../p5-www-forgejo` sibling
  was missing at load.

## Perl / async specifics — reference, don't restate

Module loading, the not-Moo `IO::Async::Notifier` pattern, Future lifetime rules, the
delegation architecture, and dist.ini/release conventions live in skills
`net-async-forgejo-core`, `perl-io-async-future`, `getty-perl-core`, and
`perl-release-dist-ini` (force-loaded for `net-async-forgejo-*` agents).
