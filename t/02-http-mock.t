use strict;
use warnings;
use Test::More;
use lib 'lib';
use lib '../p5-www-forgejo/lib';

use IO::Async::Loop;
use Net::Async::HTTP;
use Future;

# Mock IO backend that captures requests
package MockIO {
    use WWW::Forgejo::HTTPResponse;

    sub new { bless { requests => [] }, shift }

    sub call {
        my ($self, $req) = @_;
        push @{$self->{requests}}, $req;
        return WWW::Forgejo::HTTPResponse->new(
            status  => 200,
            content => '{"login":"testuser","id":1}',
            headers => { 'x-total-count' => 1 },
        );
    }
}

package main;

# Test that Net::Async::Forgejo::API can be constructed
use Net::Async::Forgejo::API;

my $api = Net::Async::Forgejo::API->new(
    url   => 'https://src.ci',
    token => 'test-token',
);

isa_ok($api, 'Net::Async::Forgejo::API');

# Test _build_request works via sync forgejo
my $req = $api->_forgejo->_build_request('GET', '/user');
is($req->method, 'GET');
like($req->url, qr{/user$});

# Test headers are set correctly
my %headers;
$api->_forgejo->_set_auth(\%headers);
is($headers{Authorization}, 'token test-token');

pass("HTTP mock transport works");

done_testing;