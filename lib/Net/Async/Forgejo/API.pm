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

sub get {
    my ($self, $path, %params) = @_;
    my $forgejo = $self->_forgejo;
    my $req = $forgejo->_build_request('GET', $path, %params);
    return $self->_do_request($req)->then(sub {
        my ($response) = @_;
        return Future->done($forgejo->_parse_response($response, 'GET', $path));
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

=head2 get($path, %params)

    my $f = $forgejo->get('/repos/myorg/myrepo');

Async GET request. Returns a L<Future> that resolves to the parsed JSON
response data.

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