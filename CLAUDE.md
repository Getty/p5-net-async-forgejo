# Net::Async::Forgejo

Async `IO::Async` client for the Forgejo API. `Net::Async::Forgejo::API` extends
`IO::Async::Notifier`, drives non-blocking HTTP via `Net::Async::HTTP`, and returns
`Future`s. It is a **thin transport layer**: request building, auth, JSON, and error
handling are delegated to the sibling sync distribution `WWW::Forgejo`
(`../p5-www-forgejo`), with which it is released in lockstep.

## Build / test

```bash
prove -l t/     # requires the ../p5-www-forgejo sibling checkout (tests `use lib` it)
dzil test       # full distribution ([@Author::GETTY] bundle)
dzil build
```

## Delegation

Delegate behavior-relevant code to the right agent instead of touching it yourself —
the delegation lock and the publish gate are shared house rules (skilletor bundle
`getty-cpan-dist@getty`); lanes and the release coupling are in
`.claude/rules/net-async-forgejo-rules.md`.

| Task | Agent |
|---|---|
| Implement / refactor / debug behavior-relevant code | `net-async-forgejo-worker` (default) |
| Commits, `Changes`, card → done, pre-release audit | `net-async-forgejo-release-manager` |

The agents carry their skills via `briefing.skills` (see `.claude/agents/`); the main
agent delegates rather than loading them. Skill sources live under `.claude/skills/`
(`net-async-forgejo-core` plus the shared skills skilletor installs). The delegation lock is a shared
house rule (bundle `getty-cpan-dist@getty`); repo-specific house rules:
`.claude/rules/net-async-forgejo-rules.md`.
