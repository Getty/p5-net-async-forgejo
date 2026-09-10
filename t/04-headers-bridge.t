use strict;
use warnings;
use Test::More;
use lib 'lib';
# Sibling checkout. Defaults to the standard main sibling like the other tests;
# FORGEJO_SIBLING_LIB lets the paired phase2 checkout be loaded for verification
# without editing this file (an in-script `use lib` cannot be overridden by
# PERL5LIB, so the override has to live here).
use lib ($ENV{FORGEJO_SIBLING_LIB} // '../p5-www-forgejo/lib');

use Future;
use HTTP::Response;
use WWW::Forgejo::HTTPResponse;
use Net::Async::Forgejo::API;

# This proves the paired feature of WWW::Forgejo karr #1 (HTTPResponse->headers,
# commit 1083fa8) surfaces through the async transport. That attribute lives on
# the unreleased phase2-forgejo branch; the main sibling has no headers accessor,
# so skip loudly there until the coordinated phase2 -> main landing (karr #2).
plan skip_all =>
      "paired WWW::Forgejo feature absent: WWW::Forgejo::HTTPResponse has no "
    . "headers attribute (sibling on main). Coordinated phase2 -> main landing "
    . "pending (karr #2). Set FORGEJO_SIBLING_LIB to the phase2 lib to run."
    unless WWW::Forgejo::HTTPResponse->can('headers');

# Fake Net::Async::HTTP: returns a canned HTTP::Response through the same
# ->do_request(request => ...) -> Future interface the real transport uses.
# Offline, no loop, no network.
package FakeHTTP {
    sub new {
        my ($class, %args) = @_;
        bless { responder => $args{responder}, requests => [] }, $class;
    }
    sub do_request {
        my ($self, %args) = @_;
        push @{ $self->{requests} }, $args{request};
        return $self->{responder}->($args{request});
    }
}

package main;

my $api = Net::Async::Forgejo::API->new(
    url   => 'https://src.ci',
    token => 'test-token',
);

# A real HTTP::Response with a mixed-case X-Total-Count header. _do_request must
# scan it into the HTTPResponse `headers` hash with lower-cased keys.
my $http_resp = HTTP::Response->new(
    200, 'OK',
    [ 'X-Total-Count' => 7, 'Content-Type' => 'application/json' ],
    '{"login":"testuser","id":1}',
);
$api->{_http} = FakeHTTP->new(responder => sub { Future->done($http_resp) });

subtest '_do_request bridges response headers into HTTPResponse' => sub {
    my $req  = $api->_forgejo->_build_request('GET', '/user');
    my $resp = $api->_do_request($req)->get;

    isa_ok($resp, 'WWW::Forgejo::HTTPResponse',
        'transport yields a WWW::Forgejo::HTTPResponse');
    is($resp->status, 200, 'status code passed through');

    is($resp->headers->{'x-total-count'}, 7,
        'X-Total-Count reaches HTTPResponse under a lower-cased key');
    ok(exists $resp->headers->{'content-type'},
        'Content-Type is present as content-type (lower-cased)');
    ok(!exists $resp->headers->{'X-Total-Count'},
        'the original mixed-case key is not present (keys are lower-cased)');
};

subtest 'header-carrying HTTPResponse still parses end to end' => sub {
    my $data = $api->get('/user')->get;
    is(ref $data, 'HASH', 'single-object GET parses to a hashref');
    is($data->{login}, 'testuser', 'body decoded through the async path');
};

done_testing;
