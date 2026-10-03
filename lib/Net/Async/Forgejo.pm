package Net::Async::Forgejo;

# ABSTRACT: Async Forgejo API client for IO::Async

use strict;
use warnings;

our $VERSION = '0.001';

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

    # Future-based API - all methods return Futures
    my $user = $forgejo->get('/user')->get;

    # List your repositories (all pages, see Net::Async::Forgejo::API)
    my $repos = $forgejo->get('/user/repos')->get;

    # Create an issue (non-blocking)
    $forgejo->post('/repos/myorg/myrepo/issues', {
        title => 'Bug report',
        body  => 'Description',
    })->then(sub {
        my ($data) = @_;
        print "Created issue #" . $data->{number} . "\n";
        return Future->done;
    })->get;

=head1 DESCRIPTION

C<Net::Async::Forgejo> is the distribution's name; the client itself is
L<Net::Async::Forgejo::API>, an async client for the Forgejo API built on
L<IO::Async>. This package carries no code of its own - construct
L<Net::Async::Forgejo::API> as shown above. All its HTTP methods return
L<Future> objects for non-blocking operation; API errors fail the Future.

Request building, authentication, and response parsing are delegated to
L<WWW::Forgejo>, so the same JSON handling, error messages, and logging
are available.

=head2 Architecture

This module extends L<IO::Async::Notifier> and uses L<Net::Async::HTTP> for
non-blocking HTTP communication. It delegates to L<WWW::Forgejo> for:
- Request building (URL encoding, auth headers)
- Response parsing (JSON decode, error handling)
- Logging via L<Log::Any>

=head1 SEE ALSO

L<Net::Async::Forgejo::API>, L<WWW::Forgejo>, L<IO::Async>, L<Future>

=cut