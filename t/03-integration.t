use strict;
use warnings;
use Test::More;
use lib 'lib';
use lib '../p5-www-forgejo/lib';

use IO::Async::Loop;
use Net::Async::Forgejo::API;
use WWW::Forgejo;

my $loop = IO::Async::Loop->new;

my $forgejo = Net::Async::Forgejo::API->new(
    url   => 'https://src.ci',
    token => 'test',
);

$loop->add($forgejo);

pass "Both modules load in same process";
ok(defined($Net::Async::Forgejo::API::VERSION), "Net::Async::Forgejo::API has version");
ok(defined($WWW::Forgejo::VERSION), "WWW::Forgejo has version");

# Verify sync Forgejo is used internally
my $sync = $forgejo->_forgejo;
isa_ok($sync, 'WWW::Forgejo');

# Verify auth header format is correct
my %headers;
$sync->_set_auth(\%headers);
is($headers{Authorization}, 'token test', 'Auth header format correct');

# Verify URL encoding for repos paths
my $req = $sync->_build_request('GET', '/repos/owner/my-repo');
like($req->url, qr{/repos/owner/my-repo$}, 'Simple repo path works');

# WWW::Forgejo's single-encoding contract (its t/05-urlencode.t): the
# controllers percent-encode each variable path segment exactly once, and
# _build_request passes the assembled path through verbatim - only query
# params are encoded there. An already-encoded path must therefore arrive
# unchanged; encoding it again would turn a controller's %20 into %2520.
$req = $sync->_build_request('GET', '/repos/my%20org/my%20repo');
like($req->url, qr{/repos/my%20org/my%20repo$},
    'Already-encoded path is passed through verbatim (encoded once, by the caller)');

done_testing;