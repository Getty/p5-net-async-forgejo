package Net::Async::Forgejo::API;

# ABSTRACT: Async Forgejo API client for IO::Async

use strict;
use warnings;
use parent 'IO::Async::Notifier';

use Carp qw(croak);
use Future;
use URI;
use HTTP::Request;
use Net::Async::HTTP;
use WWW::Forgejo;
use WWW::Forgejo::HTTPResponse;

our $VERSION = '0.001';

use constant DEFAULT_MAX_PAGES => 100;

sub configure {
    my ($self, %params) = @_;

    $self->{url}   = delete $params{url}   if exists $params{url};
    $self->{token} = delete $params{token} if exists $params{token};

    $self->SUPER::configure(%params);
}

=attr url

Base URL of your Forgejo instance, e.g. C<https://src.ci>.

=cut

sub url {
    my ($self) = @_;
    $self->{url} // $ENV{FORGEJO_URL}
        // croak "No Forgejo URL configured.\n\n"
            . "Set url via:\n"
            . "  Environment: FORGEJO_URL\n"
            . "  Option:      url => \$url\n\n"
            . "Example: https://src.ci";
}

=attr token

Your Forgejo personal access token for authentication.

=cut

sub token {
    my ($self) = @_;
    $self->{token} // $ENV{FORGEJO_TOKEN}
        // croak "No Forgejo token configured.\n\n"
            . "Set token via:\n"
            . "  Environment: FORGEJO_TOKEN\n"
            . "  Option:      token => \$token\n\n"
            . "Get a token at: Settings → Applications → Tokens";
}

sub base_url {
    my ($self) = @_;
    return $self->url . '/api/v1';
}

# Internal: sync Forgejo instance for request building and response parsing
sub _forgejo {
    my ($self) = @_;
    $self->{_forgejo} //= WWW::Forgejo->new(
        url   => $self->url,
        token => $self->token,
    );
}

# Internal: Net::Async::HTTP instance
sub _http {
    my ($self) = @_;
    unless ($self->{_http}) {
        $self->{_http} = Net::Async::HTTP->new(
            user_agent => 'Net-Async-Forgejo/' . $VERSION,
            max_connections_per_host => 0,
        );
    }
    return $self->{_http};
}

sub _add_to_loop {
    my ($self, $loop) = @_;
    $self->add_child($self->_http);
}

# ============================================================================
# ASYNC HTTP TRANSPORT
# ============================================================================

sub _do_request {
    my ($self, $req) = @_;

    my $uri = URI->new($req->url);

    my $http_req = HTTP::Request->new($req->method => $uri);
    my $headers = $req->headers;
    for my $key (keys %$headers) {
        $http_req->header($key => $headers->{$key});
    }
    $http_req->content($req->content) if $req->has_content;

    return $self->_http->do_request(
        request => $http_req,
    )->then(sub {
        my ($response) = @_;
        # Same shape as WWW::Forgejo::LWPIO: lower-cased header keys, a header
        # that occurs more than once joined with ", ".
        my %resp_headers;
        $response->headers->scan(sub {
            my ($name, $value) = @_;
            my $key = lc $name;
            $resp_headers{$key} = exists $resp_headers{$key} ? "$resp_headers{$key}, $value" : $value;
        });
        return Future->done(WWW::Forgejo::HTTPResponse->new(
            status  => $response->code,
            # The body bytes: a Content-Encoding (gzip) is undone, a charset is
            # not - decoding text is WWW::Forgejo::Role::HTTP's job.
            content => $response->decoded_content(charset => 'none') // '',
            headers => \%resp_headers,
        ));
    });
}

# ============================================================================
# ASYNC API METHODS - all return Futures
# ============================================================================

# Internal: run one request through the async transport. Resolves to
# ($parsed_data, $http_response) so the caller can read response headers such
# as X-Total-Count without a second parse. Mirrors the sync
# WWW::Forgejo::Role::HTTP _request_with_response: WWW::Forgejo builds the
# request and parses the response; a non-2xx status croaks inside ->then and
# so fails the returned Future with "Forgejo API error: ...".
sub _request_with_response {
    my ($self, $method, $path, %opts) = @_;
    my $forgejo = $self->_forgejo;
    my $req = $forgejo->_build_request($method, $path, %opts);
    return $self->_do_request($req)->then(sub {
        my ($response) = @_;
        my $data = $forgejo->_parse_response($response, $method, $path, raw => $opts{raw});
        return Future->done($data, $response);
    });
}

# Internal: like _request_with_response, resolving to the parsed data only.
sub _request {
    my ($self, $method, $path, %opts) = @_;
    return $self->_request_with_response($method, $path, %opts)->then(sub {
        return Future->done($_[0]);
    });
}

# Internal: non-blocking pagination loop. Fetches the next page and recurses
# through the Future chain (never a blocking ->get) until the accumulated items
# reach X-Total-Count or the max_pages safety cap. Mirrors the sync
# WWW::Forgejo::Role::HTTP get() paging: a consistent per-page limit keeps
# Forgejo's (page - 1) * limit offsets contiguous.
sub _paginate {
    my ($self, $path, $st) = @_;

    return Future->done($st->{items}) if @{ $st->{items} } >= $st->{total};
    return Future->done($st->{items}) if $st->{page} >= $st->{max_pages};

    $st->{page}++;
    my %page_opts = %{ $st->{opts} };
    $page_opts{params} = {
        %{ $st->{opts}{params} || {} },
        page  => $st->{page},
        limit => $st->{limit},
    };

    return $self->_request_with_response('GET', $path, %page_opts)->then(sub {
        my ($page_data) = @_;
        my $page_items = $self->_forgejo->_collection_ref($page_data);
        return Future->done($st->{items}) unless $page_items && @$page_items;
        push @{ $st->{items} }, @$page_items;
        return $self->_paginate($path, $st);
    });
}

sub get {
    my ($self, $path, %opts) = @_;

    my $page_size = delete $opts{page_size};
    my $max_pages = delete $opts{max_pages} // DEFAULT_MAX_PAGES;
    my $pinned    = $opts{params} && defined $opts{params}{page};

    # An explicit page_size must apply to the first request too, so every page
    # uses the same limit and Forgejo's (page-1)*limit offsets stay aligned.
    if (defined $page_size && !$pinned) {
        $opts{params} = { %{ $opts{params} || {} }, limit => $page_size };
    }

    return $self->_request_with_response('GET', $path, %opts)->then(sub {
        my ($data, $response) = @_;

        # Locate the collection this response paginates over - a bare array or
        # the data arrayref of a search envelope; WWW::Forgejo decides - and
        # auto-paginate it only when the server reports it as truncated and the
        # caller has not pinned a specific page. Anything else (a plain object,
        # a raw body, no X-Total-Count, a pinned page) resolves unchanged with
        # no extra HTTP calls.
        my $items = $self->_forgejo->_collection_ref($data);
        return Future->done($data) unless $items;
        return Future->done($data) if $pinned;

        my $total = $response->headers->{'x-total-count'};
        return Future->done($data) unless defined $total && $total =~ /^[0-9]+$/;
        return Future->done($data) unless $total > scalar @$items;

        # With no explicit page_size the server's page size is exactly the item
        # count of the first page; reuse it so subsequent offsets stay aligned.
        my $limit = defined $page_size ? $page_size : scalar @$items;
        return Future->done($data) unless $limit;

        return $self->_paginate($path, {
            opts      => \%opts,
            items     => [ @$items ],
            total     => $total,
            limit     => $limit,
            max_pages => $max_pages,
            page      => 1,
        })->then(sub {
            my ($collected) = @_;
            # Same shape as received: a search envelope keeps its other keys,
            # with data replaced by the merged collection.
            return Future->done(ref $data eq 'HASH'
                ? { %$data, data => $collected }
                : $collected);
        });
    });
}

sub post {
    my ($self, $path, $data, %opts) = @_;
    return $self->_request('POST', $path, %opts, body => $data);
}

sub put {
    my ($self, $path, $data, %opts) = @_;
    return $self->_request('PUT', $path, %opts, body => $data);
}

sub patch {
    my ($self, $path, $data, %opts) = @_;
    return $self->_request('PATCH', $path, %opts, body => $data);
}

sub delete {
    my ($self, $path, $data, %opts) = @_;
    return $self->_request('DELETE', $path, %opts, body => $data);
}

sub check {
    my ($self, $path, %opts) = @_;
    my $forgejo = $self->_forgejo;
    my $req = $forgejo->_build_request('GET', $path, %opts);
    return $self->_do_request($req)->then(sub {
        my ($response) = @_;
        # Mirrors WWW::Forgejo::Role::HTTP check: a 404 is the "no" - unless it
        # is the plain-text 404 of a route the instance does not have, which
        # fails like any other error.
        my $route_missing = ($response->headers->{'content-type'} // '') =~ m{\A\s*text/plain\b}i
            && ($response->content // '') =~ /\A\s*404 page not found/;
        return Future->done(0) if $response->status == 404 && !$route_missing;
        $forgejo->_parse_response($response, 'GET', $path);
        return Future->done(1);
    });
}

1;

__END__

=encoding UTF-8

=head1 SYNOPSIS

    use IO::Async::Loop;
    use Net::Async::Forgejo::API;

    my $loop = IO::Async::Loop->new;

    my $forgejo = Net::Async::Forgejo::API->new(
        url   => 'https://src.ci',
        token => $ENV{FORGEJO_TOKEN},
    );
    $loop->add($forgejo);

    # List user
    my $user = $forgejo->get('/user')->get;
    print "Logged in as: $user->{login}\n";

    # List your repositories - every page, collected without blocking
    my $repos = $forgejo->get('/user/repos')->get;

    # Create an issue
    $forgejo->post('/repos/myorg/myrepo/issues', {
        title => 'Bug report',
        body  => 'Description',
    })->then(sub {
        my ($data) = @_;
        print "Created issue #" . $data->{number} . "\n";
        return Future->done;
    })->get;

    # Parallel requests
    my @futures = map {
        $forgejo->get("/repos/myorg/$_")
    } @repo_names;

    my @results = Future->needs_all(@futures)->get;

    # API errors fail the Future
    $forgejo->get('/repos/myorg/nope')->else(sub {
        my ($error) = @_;    # "Forgejo API error: ..."
        warn $error;
        return Future->done;
    })->get;

=head1 DESCRIPTION

Async client for the Forgejo API built on L<IO::Async>. Extends
L<IO::Async::Notifier> and uses L<Net::Async::HTTP> for non-blocking
HTTP communication.

All methods return L<Future> objects. Request building and response
parsing are delegated to L<WWW::Forgejo>; the verb methods take the same
arguments and options as those of L<WWW::Forgejo::Role::HTTP> and resolve to
the same data.

A response status outside the 2xx range fails the returned L<Future> with the
message L<WWW::Forgejo::Role::HTTP> would croak with, C<Forgejo API error: ...>
- including an error on a later page of an auto-paginated C<get>. A transport
error from L<Net::Async::HTTP> fails it as well.

Only API and transport errors arrive as a failed Future. Configuration and
calling errors are programming errors and croak right away, before a Future is
returned: a missing L</url> or L</token>, or an C<upload> without a file or
content.

The response body is handed to L<WWW::Forgejo> as bytes, with a
C<Content-Encoding> such as gzip undone but no charset decoding, exactly like
the sync L<WWW::Forgejo::LWPIO> backend: JSON is decoded to Perl data, a
C<text/*> body with a C<charset> to characters, anything else stays bytes.

=head2 Architecture

The module uses a sync L<WWW::Forgejo> instance internally to:
- Build HTTP requests (URL encoding, auth headers)
- Parse HTTP responses (JSON decode, error handling)
- Handle logging via L<Log::Any>

The actual HTTP transport is handled by L<Net::Async::HTTP>, making all
requests non-blocking.

=head1 ATTRIBUTES

=head2 url

Base URL of your Forgejo instance.

=head2 token

Your Forgejo personal access token.

=head1 METHODS

=head2 get($path, %opts)

    my $f = $forgejo->get('/repos/myorg/myrepo');
    my $f = $forgejo->get('/repos/search', params => { q => 'perl' });

Async GET request. Returns a L<Future> that resolves to the parsed response
data. Query parameters are passed as C<< params => { ... } >>; those with an
undefined value are left out.

When the response is a paginatable collection and the server reports more
results via the C<X-Total-Count> header than the first page returned, C<get>
transparently fetches the remaining pages (non-blocking, chained through the
returned L<Future>) and resolves to the combined collection in order. Two
shapes are recognised, as by L<WWW::Forgejo::Role::HTTP/get>: a bare JSON array
(resolved as the merged arrayref) and a Forgejo search envelope
C<< { ok => ..., data => [...] } >> (resolved as the same object with C<data>
replaced by the merged collection). This happens only when the caller has not
pinned a page (no C<< params->{page} >>); plain objects, collections without an
C<X-Total-Count> header, and explicitly-paged requests resolve as-is with no
extra HTTP calls. The per-page C<limit> is kept consistent across every fetched
page so Forgejo's C<(page - 1) * limit> offsets stay contiguous.

Options besides C<params>:

=over 4

=item * C<page_size> - a per-page C<limit> sent on every request, including
the first. Without it the server's page size is used and later pages reuse the
item count of the first one.

=item * C<max_pages> - the maximum number of pages fetched. Defaults to 100.

=item * C<raw> - with C<< raw => 1 >> the body resolves exactly as it came, as
bytes: no JSON decoding, no charset decoding, no pagination. For file contents.

=back

    my $repos = $forgejo->get('/user/repos', page_size => 100, max_pages => 20)->get;
    my $bytes = $forgejo->get('/repos/myorg/myrepo/raw/README.md', raw => 1)->get;

=head2 post($path, $data, %opts)

    my $f = $forgejo->post('/repos/myorg/myrepo/issues', { title => 'Bug' });
    my $f = $forgejo->post('/repos/myorg/myrepo/issues/1/assets', undef,
        params => { name => 'log.txt' },
        upload => { file => '/tmp/log.txt' });

Async POST request with JSON body. Options, as for
L<WWW::Forgejo::Role::HTTP/post>:

=over 4

=item * C<params> - a hashref sent as the query string.

=item * C<upload> - sends the request as C<multipart/form-data> instead of
JSON: the hashref names the form C<field> (default C<attachment>) and either a
C<file> on disk or the raw C<content>, plus an optional C<filename> (required
with C<content>).

=item * C<raw> - resolve to the body as it came, as bytes, undecoded.

=back

=head2 put($path, $data, %opts)

    my $f = $forgejo->put('/repos/myorg/myrepo/topics', { topics => ['perl'] });

Async PUT request with JSON body. Takes the options of C<post>.

=head2 patch($path, $data, %opts)

    my $f = $forgejo->patch('/repos/myorg/myrepo/issues/1', { state => 'closed' });

Async PATCH request with JSON body. Takes the options of C<post>.

=head2 delete($path, $data, %opts)

    my $f = $forgejo->delete('/repos/myorg/myrepo/issues/1');
    my $f = $forgejo->delete('/user/emails', { emails => ['old@example.com'] });

Async DELETE request. The optional C<$data> is sent as JSON body, for the
endpoints that take one; without it the request has no body. Takes the options
of C<post>.

=head2 check($path, %opts)

    my $f = $forgejo->check('/repos/myorg/myrepo/collaborators/someone');
    my $is_collaborator = $f->get;

Async GET against an endpoint that answers a yes/no question with its status
code, like L<WWW::Forgejo::Role::HTTP/check>. The L<Future> resolves to C<1>
for a 2xx response and to C<0> for C<404>; any other status fails it like the
verb methods do. So does the plain-text C<404 page not found> of a route the
instance does not have (an older Forgejo, a feature that is switched off),
which would otherwise read as "no". C<params> adds a query string.

=head1 SEE ALSO

L<Net::Async::Forgejo>, L<WWW::Forgejo>, L<IO::Async>, L<Future>

=cut