package Net::Async::Forgejo::API;

# ABSTRACT: Async Forgejo API client for IO::Async

use strict;
use warnings;
use parent 'IO::Async::Notifier';

use Carp qw(croak);
use Future;
use URI;
use HTTP::Request;
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
        require Net::Async::HTTP;
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
        my %resp_headers;
        $response->headers->scan(sub { my ($k, $v) = @_; $resp_headers{lc $k} = $v });
        return Future->done(WWW::Forgejo::HTTPResponse->new(
            status  => $response->code,
            content => $response->decoded_content // $response->content // '',
            headers => \%resp_headers,
        ));
    });
}

# ============================================================================
# ASYNC API METHODS - all return Futures
# ============================================================================

# Internal: run one GET page through the async transport. Resolves to
# ($parsed_data, $http_response) so the caller can read response headers such
# as X-Total-Count without a second parse.
sub _get_page {
    my ($self, $path, %opts) = @_;
    my $forgejo = $self->_forgejo;
    my $req = $forgejo->_build_request('GET', $path, %opts);
    return $self->_do_request($req)->then(sub {
        my ($response) = @_;
        my $data = $forgejo->_parse_response($response, 'GET', $path);
        return Future->done($data, $response);
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

    return $self->_get_page($path, %page_opts)->then(sub {
        my ($page_data) = @_;
        return Future->done($st->{items})
            unless ref $page_data eq 'ARRAY' && @$page_data;
        push @{ $st->{items} }, @$page_data;
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

    return $self->_get_page($path, %opts)->then(sub {
        my ($data, $response) = @_;

        # Auto-paginate only bare arrays the server reports as truncated, and
        # only when the caller has not pinned a specific page. Single objects,
        # arrays without X-Total-Count, and explicitly-paged requests are
        # returned unchanged with no extra HTTP calls.
        return Future->done($data) unless ref $data eq 'ARRAY';
        return Future->done($data) if $pinned;

        my $total = $response->headers->{'x-total-count'};
        return Future->done($data) unless defined $total && $total =~ /^[0-9]+$/;
        return Future->done($data) unless $total > scalar @$data;

        # With no explicit page_size the server's page size is exactly the item
        # count of the first page; reuse it so subsequent offsets stay aligned.
        my $limit = defined $page_size ? $page_size : scalar @$data;
        return Future->done($data) unless $limit;

        return $self->_paginate($path, {
            opts      => \%opts,
            items     => [ @$data ],
            total     => $total,
            limit     => $limit,
            max_pages => $max_pages,
            page      => 1,
        });
    });
}

sub post {
    my ($self, $path, $data) = @_;
    my $forgejo = $self->_forgejo;
    my $req = $forgejo->_build_request('POST', $path, body => $data);
    return $self->_do_request($req)->then(sub {
        my ($response) = @_;
        return Future->done($forgejo->_parse_response($response, 'POST', $path));
    });
}

sub put {
    my ($self, $path, $data) = @_;
    my $forgejo = $self->_forgejo;
    my $req = $forgejo->_build_request('PUT', $path, body => $data);
    return $self->_do_request($req)->then(sub {
        my ($response) = @_;
        return Future->done($forgejo->_parse_response($response, 'PUT', $path));
    });
}

sub patch {
    my ($self, $path, $data) = @_;
    my $forgejo = $self->_forgejo;
    my $req = $forgejo->_build_request('PATCH', $path, body => $data);
    return $self->_do_request($req)->then(sub {
        my ($response) = @_;
        return Future->done($forgejo->_parse_response($response, 'PATCH', $path));
    });
}

sub delete {
    my ($self, $path) = @_;
    my $forgejo = $self->_forgejo;
    my $req = $forgejo->_build_request('DELETE', $path);
    return $self->_do_request($req)->then(sub {
        my ($response) = @_;
        return Future->done($forgejo->_parse_response($response, 'DELETE', $path));
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

    # List repositories (non-blocking)
    my $repos = $forgejo->get('/repos')->get;

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

    my @results = Future->wait_all(@futures)->get;

=head1 DESCRIPTION

Async client for the Forgejo API built on L<IO::Async>. Extends
L<IO::Async::Notifier> and uses L<Net::Async::HTTP> for non-blocking
HTTP communication.

All methods return L<Future> objects. Request building and response
parsing are delegated to L<WWW::Forgejo>.

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

Async GET request. Returns a L<Future> that resolves to the parsed JSON
response data. Query parameters are passed as C<< params => { ... } >>.

When the response is a JSON array and the server reports more results via the
C<X-Total-Count> header than the first page returned, C<get> transparently
fetches the remaining pages (non-blocking, chained through the returned
L<Future>) and resolves to the combined arrayref in order. This mirrors the
sync L<WWW::Forgejo> C<get> and happens only when the caller has not pinned a
page (no C<< params->{page} >>); single-object responses, arrays without an
C<X-Total-Count> header, and explicitly-paged requests resolve as-is with no
extra HTTP calls. The per-page C<limit> is kept consistent across every fetched
page so Forgejo's C<(page - 1) * limit> offsets stay contiguous.

Two options tune the pagination: C<page_size> forces a per-page C<limit> on
every request (including the first); C<max_pages> caps the number of pages
fetched (default 100).

    my $repos = $forgejo->get('/repos', page_size => 100, max_pages => 20)->get;

=head2 post($path, $data)

    my $f = $forgejo->post('/repos/myorg/myrepo/issues', { title => 'Bug' });

Async POST request with JSON body.

=head2 put($path, $data)

    my $f = $forgejo->put('/repos/myorg/myrepo/settings', { ... });

Async PUT request with JSON body.

=head2 patch($path, $data)

    my $f = $forgejo->patch('/repos/myorg/myrepo/issues/1', { ... });

Async PATCH request with JSON body.

=head2 delete($path)

    my $f = $forgejo->delete('/repos/myorg/myrepo/issues/1');

Async DELETE request.

=head1 SEE ALSO

L<Net::Async::Forgejo>, L<WWW::Forgejo>, L<IO::Async>, L<Future>

=cut