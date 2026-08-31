---
name: net-async-forgejo-core
description: "Use when working on Net::Async::Forgejo — the async IO::Async Forgejo client. Delegation architecture (thin async layer over WWW::Forgejo), configure/url/token + ENV convention, the Future-based verb interface, and the boundary of what belongs here vs. in WWW::Forgejo."
user-invocable: false
allowed-tools: Read, Grep, Glob
model: sonnet
---

# Net::Async::Forgejo — async Forgejo client

An `IO::Async`-native client for the Forgejo API. It is deliberately **thin**: it
owns only the non-blocking HTTP transport. Everything domain-specific — request
building, auth, JSON, error handling, logging — is delegated to the sibling sync
distribution `WWW::Forgejo` (repo `p5-www-forgejo`).

The generic async lifetime rules (retain in-flight Futures, `delete` keys before
`SUPER::configure`, defaults in `configure` not `new`) live in skill
`perl-io-async-future` and are not repeated here.

## Not Moo

This distribution is plain `use parent 'IO::Async::Notifier'` — no Moo, no Moose.
`IO::Async::Notifier` owns construction; do not reach for accessor generators or
role composition. Attributes are hand-written accessors reading `$self->{...}`.

## Modules

- **`Net::Async::Forgejo`** — the documented public name, a thin façade / SYNOPSIS
  carrier. Version + POD only today.
- **`Net::Async::Forgejo::API`** — the working class. `parent IO::Async::Notifier`,
  holds the transport and the verb methods.

## The delegation architecture — the whole point

`::API` composes two collaborators and glues them with `Net::Async::HTTP`:

- **`WWW::Forgejo`** (sync, lazy-built as `$self->_forgejo`) does everything that
  is *about Forgejo*: `_build_request($method, $path, %params)` returns a request
  object (URL encoding, auth headers), and `_parse_response($resp, $method, $path)`
  turns a response into decoded data with error handling and `Log::Any` logging.
- **`Net::Async::HTTP`** (lazy `$self->_http`, added as a child in `_add_to_loop`)
  does the *non-blocking transport only*.

Every verb method follows one shape: ask `_forgejo` to build the request, run it
through `_do_request` (async), then hand the raw response back to `_forgejo` to
parse. The async layer never inspects a URL, a header, or a JSON body itself.

```perl
sub get {
    my ($self, $path, %params) = @_;
    my $forgejo = $self->_forgejo;
    my $req = $forgejo->_build_request('GET', $path, %params);
    return $self->_do_request($req)->then(sub {
        return Future->done($forgejo->_parse_response($_[0], 'GET', $path));
    });
}
```

### WWW::Forgejo::HTTPResponse — the bridge value object

The two worlds meet on one type. `_do_request` converts the live
`HTTP::Response` from `Net::Async::HTTP` into a `WWW::Forgejo::HTTPResponse`
(`status`, `content`, `headers` with **lower-cased** header keys) before handing
it to `_parse_response`. This is exactly the object `WWW::Forgejo`'s own sync IO
backend produces, so both distributions share one parse path. When you add a verb
or touch transport, you produce a `WWW::Forgejo::HTTPResponse` — never a raw
`HTTP::Response` — at the seam.

## Config convention: configure + url/token + ENV fallback

`configure` pulls `url` and `token` out of `%params` (with `exists`/`delete`)
before chaining `SUPER::configure`. The accessors resolve in a fixed order:

1. explicit value (`$self->{url}` / `$self->{token}`)
2. environment (`$ENV{FORGEJO_URL}` / `$ENV{FORGEJO_TOKEN}`)
3. `croak` with a help message naming both ways to set it

`base_url` is `url . '/api/v1'`. Keep this three-step order and the ENV names
exact — tests and users depend on `FORGEJO_URL` / `FORGEJO_TOKEN`.

## The verb interface — all return Futures

`get($path, %params)`, `post/put/patch($path, $data)`, `delete($path)`. Each
returns a `Future` resolving to parsed response data. `post`/`put`/`patch` pass
the payload as `body => $data` to `_build_request`. Adding an endpoint verb means
copying this shape, not adding logic — if you find yourself decoding JSON or
formatting a path in `::API`, it belongs in `WWW::Forgejo` instead.

## The boundary — what lives where

| Belongs in `Net::Async::Forgejo` (here) | Belongs in `WWW::Forgejo` (sibling) |
|---|---|
| Non-blocking transport via `Net::Async::HTTP` | URL/path building, encoding |
| Notifier lifecycle (`configure`, `_add_to_loop`) | Auth header construction |
| Turning `HTTP::Response` → `HTTPResponse` | JSON encode/decode |
| The Future-returning verb signatures | Error handling, `Log::Any` logging |
| `url`/`token`/ENV resolution (mirrors the sync client) | The `HTTPResponse` value object itself |

A change that touches "what Forgejo expects" is almost always a `WWW::Forgejo`
change surfaced here as a coordinated release — not new logic in this repo.

## Release coupling

This distribution cannot move without `WWW::Forgejo`; they are released together.
The tests load it via `use lib '../p5-www-forgejo/lib'`. Local state is the only
truth — CPAN lag is never a blocker. Details in `.claude/rules/`.
