# Net-Async-Forgejo

Asynchronous Perl client for the REST API (`/api/v1`) of a
[Forgejo](https://forgejo.org) instance, built on
[IO::Async](https://metacpan.org/pod/IO::Async) and
[Net::Async::HTTP](https://metacpan.org/pod/Net::Async::HTTP). Every call
returns a [Future](https://metacpan.org/pod/Future), so nothing blocks.

`Net::Async::Forgejo` is a **thin transport layer**: request building,
authentication, JSON handling and error messages are delegated to the
sibling sync distribution `WWW::Forgejo`, which both distributions share.
That is why the two are released in lockstep — the async client uses the
sync one for everything that decides *what* a request looks like.

The distribution name is `Net-Async-Forgejo`; the client itself is
`Net::Async::Forgejo::API`. `Net::Async::Forgejo` is only a name holder.

## Installation

```bash
cpanm Net-Async-Forgejo
```

`https://` instances need
[IO::Async::SSL](https://metacpan.org/pod/IO::Async::SSL); without it the
client fails the Future with a clear message instead of dying on connect.

From a checkout:

```bash
cpanm --installdeps .
prove -l t/
```

## Synopsis

```perl
use IO::Async::Loop;
use Net::Async::Forgejo::API;

my $loop = IO::Async::Loop->new;

my $forgejo = Net::Async::Forgejo::API->new(
    url   => 'https://src.ci',          # instance root, no /api/v1
    token => $ENV{FORGEJO_TOKEN},      # personal access token
);
$loop->add($forgejo);

# GET /user - the current user
my $user = $forgejo->get('/user')->get;

# GET /user/repos - all pages, auto-paginated
my $repos = $forgejo->get('/user/repos')->get;

# POST /repos/{owner}/{repo}/issues - without blocking
$forgejo->post('/repos/myorg/myrepo/issues', {
    title => 'Bug report',
    body  => 'Description',
})->then(sub {
    my ($data) = @_;
    print "Created issue #" . $data->{number} . "\n";
    return Future->done;
})->get;

# A failure fails the Future instead of dying
$forgejo->get('/user')->else(sub {
    my ($failure) = @_;
    warn "Forgejo request failed: $failure";
    return Future->done;
})->get;
```

## Configuration

| Option | Meaning |
|---|---|
| `url` | Instance root URL, e.g. `https://src.ci` — without the `/api/v1` suffix, which is added for you. Falls back to `FORGEJO_URL`. |
| `token` | Personal access token, sent as `Authorization: token …`. Falls back to `FORGEJO_TOKEN`. |
| `timeout` | Seconds before a stalled request fails the Future. Default: 30. |
| `http` | A preconfigured `Net::Async::HTTP` instance, if you want your own connection pool, proxy or TLS setup. |

`url` and `token` can be changed later with `configure`; the change takes
effect for later requests, requests already in flight keep their old
credentials.

Accessors: `url`, `token`, `base_url` (the normalised `/api/v1` base),
`timeout`.

## API overview

The client speaks the Forgejo API by path — it is the transport, not a
second set of controllers. The sync distribution
[`WWW::Forgejo`](https://metacpan.org/pod/WWW::Forgejo) carries the
controllers and the entities; this one is what you use when the surrounding
program is already an IO::Async program.

| Method | Meaning |
|---|---|
| `get($path, %opts)` | GET; auto-paginates collections (see below) |
| `post($path, $body, %opts)` | POST with a JSON body |
| `put($path, $body, %opts)` | PUT with a JSON body |
| `patch($path, $body, %opts)` | PATCH with a JSON body |
| `delete($path, $body, %opts)` | DELETE, optionally with a body |

Common options: `params` (query parameters, a hashref), `upload` (multipart
upload: a file name on disk or raw bytes), `raw` (return the unparsed body
bytes).

`check($path, %opts)` is the exception to the "everything else is a path"
rule: it does a GET and answers `1` when the resource exists, `0` on a 404
and fails the Future on every other error — the same rule the sync client
applies. The plain-text `404 page not found` of a route the instance does
not have fails as well instead of reading as "no".

## Return values

A verb resolves to the parsed response: decoded JSON for a JSON response,
the raw bytes for `raw => 1`. A failing request fails the Future with the
message the sync client would have thrown, e.g.
`Forgejo API error: 404 page not found`.

`get` on a paginated collection resolves to the **whole** collection, not
just the first page — the same shape the server sent, with the collection
merged across pages.

## Paging

Forgejo reports the total size of a collection in the `X-Total-Count`
header, or in the envelope's `total_count`. When the server says the
response is truncated and you have not pinned a page yourself, the client
fetches the remaining pages in the background and resolves once everything
is collected.

- `page_size` — the number of items per request. Without it, the server's
  page size (the item count of the first page) is reused, so the
  `(page - 1) * limit` offsets stay aligned.
- `max_pages` — safety cap, default 100 pages.
- `params => { page => 2 }` — pins a page: no auto-pagination happens, you
  get exactly that page.

## Errors

Transport failures (connection refused, timeout, TLS problem) fail the
Future with the underlying reason. API errors (a non-2xx status) fail it
with `Forgejo API error: …`, including the message from the body when the
server sent one. Nothing dies in the background: an error inside a Future
chain is a failed Future, not an exception in your loop.

## Tests

```bash
prove -l t/
```

The test suite needs the sibling checkout of `WWW::Forgejo` next to this
one — the tests `use lib` it, because the async client delegates to it:

```bash
git clone <forgejo-sibling> ../p5-www-forgejo
```

## See also

- `WWW::Forgejo`, the synchronous client this distribution delegates to
- [Forgejo](https://forgejo.org)

## Author

Torsten Raudssus <getty@cpan.org>

## License

This software is Copyright (c) 2026 by Torsten Raudssus.

This is free software; you can redistribute it and/or modify it under the same
terms as the Perl 5 programming language system itself. See the `LICENSE` file.
