#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use lib 'lib';
use lib '../p5-www-forgejo/lib';

use Future;
use HTTP::Response;
use WWW::Forgejo::HTTPResponse;
use Net::Async::Forgejo::API;

# Proves that WWW::Forgejo::HTTPResponse->headers (WWW::Forgejo karr #1) is
# filled by the async transport, so header-driven logic such as X-Total-Count
# pagination works through the async path too.

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
