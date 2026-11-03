#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use lib 'lib';
use lib '../p5-www-forgejo/lib';
use Net::Async::Forgejo::API;

subtest 'construction' => sub {
    my $api = Net::Async::Forgejo::API->new(
        url   => 'https://src.ci',
        token => 'test-token',
    );
    isa_ok($api, 'Net::Async::Forgejo::API');
    is($api->url, 'https://src.ci');
    is($api->token, 'test-token');
};

subtest 'ENV defaults' => sub {
    local $ENV{FORGEJO_URL} = 'https://env.example';
    local $ENV{FORGEJO_TOKEN} = 'env-token';
    my $api = Net::Async::Forgejo::API->new;
    is($api->url, 'https://env.example');
    is($api->token, 'env-token');
};

subtest 'auth error url' => sub {
    delete $ENV{FORGEJO_URL};
    delete $ENV{FORGEJO_TOKEN};
    eval { Net::Async::Forgejo::API->new->url };
    like($@, qr/FORGEJO_URL/i);
};

subtest 'auth error token' => sub {
    local $ENV{FORGEJO_URL} = 'https://src.ci';
    delete $ENV{FORGEJO_TOKEN};
    eval { Net::Async::Forgejo::API->new->token };
    like($@, qr/FORGEJO_TOKEN/i);
};

subtest 'base_url' => sub {
    my $api = Net::Async::Forgejo::API->new(
        url   => 'https://src.ci',
        token => 'test',
    );
    is($api->base_url, 'https://src.ci/api/v1');
};

subtest '_forgejo sync client' => sub {
    my $api = Net::Async::Forgejo::API->new(
        url   => 'https://src.ci',
        token => 'test',
    );
    my $sync = $api->_forgejo;
    isa_ok($sync, 'WWW::Forgejo');
    is($sync->url, 'https://src.ci');
    is($sync->token, 'test');
};

done_testing;