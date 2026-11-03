#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use lib 'lib';
use lib '../p5-www-forgejo/lib';

use IO::Async::Loop;
use IO::Socket::INET;
use Time::HiRes qw(time);
use Net::Async::Forgejo::API;

subtest 'configure drops cached credentials (karr #7)' => sub {
    my $f = Net::Async::Forgejo::API->new(url => 'https://src.ci', token => 'old');
    is $f->_forgejo->token, 'old';
    $f->configure(token => 'new', url => 'https://other.example');
    is $f->_forgejo->token, 'new', 'token';
    is $f->_forgejo->base_url, 'https://other.example/api/v1', 'url';
};

subtest 'url and base_url delegate to WWW::Forgejo (karr #8)' => sub {
    for my $u ('https://src.ci/', 'https://src.ci/api/v1', 'https://src.ci/api/v1/') {
        my $f = Net::Async::Forgejo::API->new(url => $u, token => 't');
        is $f->base_url, 'https://src.ci/api/v1', "base_url for $u";
        is $f->base_url, $f->_forgejo->base_url, 'same as internal client';
    }
};

subtest 'timeout default and configure key (karr #6)' => sub {
    my $f = Net::Async::Forgejo::API->new(url => 'http://x', token => 't');
    is $f->timeout, 30, 'default';
    is $f->_http->{timeout}, 30, 'default transport';
    my $g = Net::Async::Forgejo::API->new(url => 'http://x', token => 't', timeout => 5);
    is $g->_http->{timeout}, 5, 'custom';
};

subtest 'http key injects transport (karr #6)' => sub {
    my $fake = bless {}, 'FakeHTTP';
    {
        package FakeHTTP;
        sub do_request { Future->done(HTTP::Response->new(200, 'OK', ['Content-Type' => 'application/json'], '{"a":1}')) }
    }
    require HTTP::Response;
    my $f = Net::Async::Forgejo::API->new(url => 'http://x', token => 't', http => $fake);
    my $loop = IO::Async::Loop->new;
    $loop->add($f);
    is_deeply $f->get('/user')->get, { a => 1 };
};

subtest 'stalled server fails the Future (karr #6)' => sub {
    my $srv = IO::Socket::INET->new(Listen => 5, LocalAddr => '127.0.0.1', LocalPort => 0)
        or plan skip_all => "no listen socket: $!";
    my $port = $srv->sockport;
    my $loop = IO::Async::Loop->new;
    my $f = Net::Async::Forgejo::API->new(url => "http://127.0.0.1:$port", token => 't', timeout => 1);
    $loop->add($f);
    my $t0 = time;
    my $fut = $f->get('/user');
    $loop->await($fut);
    ok $fut->is_failed, 'failed';
    ok time - $t0 < 5, 'within seconds';
};

subtest 'https without IO::Async::SSL fails at once (karr #9)' => sub {
    local @INC = (sub {
        my (undef, $file) = @_;
        die "Can't locate $file in \@INC (hidden)\n" if $file eq 'IO/Async/SSL.pm';
        return;
    }, @INC);
    local $INC{'IO/Async/SSL.pm'};
    delete $INC{'IO/Async/SSL.pm'};
    my $f = Net::Async::Forgejo::API->new(url => 'https://src.ci', token => 't');
    my $loop = IO::Async::Loop->new;
    $loop->add($f);
    my $fut = $f->get('/user');
    ok $fut->is_failed, 'failed immediately';
    like(($fut->failure)[0], qr/IO::Async::SSL/, 'names the module');
};

done_testing;
