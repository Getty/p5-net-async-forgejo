#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
use Test::More;
binmode Test::More->builder->$_, ':encoding(UTF-8)'
    for qw( output failure_output todo_output );
use lib 'lib';
use lib '../p5-www-forgejo/lib';

use Encode qw(encode);
use Future;
use HTTP::Response;
use IO::Compress::Gzip qw(gzip $GzipError);
use Net::Async::Forgejo::API;

# _do_request must hand the body on the way WWW::Forgejo::LWPIO does: as bytes,
# with a Content-Encoding (gzip) undone but no charset decoding - that is
# WWW::Forgejo::Role::HTTP::_decode_text's job. A header that occurs more than
# once is joined with ", ". Offline: Net::Async::HTTP is replaced by a fake.

package FakeHTTP {
    sub new {
        my ($class, %args) = @_;
        bless { responder => $args{responder} }, $class;
    }
    sub do_request {
        my ($self, %args) = @_;
        return Future->done($self->{responder}->($args{request}));
    }
}

package main;

sub api_returning {
    my ($resp) = @_;
    my $api = Net::Async::Forgejo::API->new(url => 'https://src.ci', token => 't');
    $api->{_http} = FakeHTTP->new(responder => sub { $resp });
    return $api;
}

sub response {
    my ($headers, $body) = @_;
    return HTTP::Response->new(200, 'OK', $headers, $body);
}

my $text = "Grüße € ✓";
my $utf8 = encode('UTF-8', $text);

subtest 'UTF-8 JSON body decodes once, to characters' => sub {
    my $api = api_returning(response(
        [ 'Content-Type' => 'application/json; charset=utf-8' ],
        encode('UTF-8', qq({"title":"$text"})),
    ));
    my $data = $api->get('/repos/o/r/issues/1')->get;
    is($data->{title}, $text, 'non-ASCII title arrives as the original characters');
};

subtest 'gzip Content-Encoding is undone' => sub {
    my $json = encode('UTF-8', qq({"title":"$text"}));
    gzip(\$json => \my $zipped) or die $GzipError;
    my $api = api_returning(response(
        [ 'Content-Type' => 'application/json', 'Content-Encoding' => 'gzip' ],
        $zipped,
    ));
    my $data = $api->get('/repos/o/r/issues/1')->get;
    is($data->{title}, $text, 'gzipped JSON body unpacked and decoded');
};

subtest 'text/plain with a charset becomes characters' => sub {
    my $api = api_returning(response(
        [ 'Content-Type' => 'text/plain; charset=ISO-8859-1' ],
        "Gr\xFC\xDFe",
    ));
    my $data = $api->get('/markdown/raw')->get;
    is($data, "Grüße", 'Latin-1 text decoded from its declared charset');
};

subtest 'a body without a charset stays bytes' => sub {
    my $api = api_returning(response([ 'Content-Type' => 'text/plain' ], $utf8));
    my $data = $api->get('/some/text')->get;
    ok(!utf8::is_utf8($data), 'no character decoding without a charset');
    is($data, $utf8, 'the bytes that came');
};

subtest 'response transport keeps bytes for the parser' => sub {
    my $api = api_returning(response(
        [ 'Content-Type' => 'text/plain; charset=utf-8' ],
        $utf8,
    ));
    my $req  = $api->_forgejo->_build_request('GET', '/some/text');
    my $resp = $api->_do_request($req)->get;
    ok(!utf8::is_utf8($resp->content), 'HTTPResponse content is bytes');
    is($resp->content, $utf8, 'charset not decoded by the transport');
};

subtest 'a repeated response header is joined with ", "' => sub {
    my $api = api_returning(response(
        [
            'Content-Type' => 'application/json',
            'Link'         => '<https://src.ci/api/v1/x?page=2>; rel="next"',
            'Link'         => '<https://src.ci/api/v1/x?page=5>; rel="last"',
        ],
        '{}',
    ));
    my $req  = $api->_forgejo->_build_request('GET', '/x');
    my $resp = $api->_do_request($req)->get;
    is($resp->headers->{link},
        '<https://src.ci/api/v1/x?page=2>; rel="next", <https://src.ci/api/v1/x?page=5>; rel="last"',
        'both values kept, in order, like WWW::Forgejo::LWPIO');
};

done_testing;
