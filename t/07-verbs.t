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
use JSON::MaybeXS qw(decode_json);
use URI;
use Net::Async::Forgejo::API;

# The verb methods follow the signatures of WWW::Forgejo::Role::HTTP:
# get($path, %opts), post/put/patch/delete($path, $data, %opts), check($path,
# %opts). Offline: Net::Async::HTTP is replaced by a fake that records every
# outgoing HTTP::Request and answers with a canned HTTP::Response.

package FakeHTTP {
    sub new {
        my ($class, %args) = @_;
        bless { responder => $args{responder}, requests => [] }, $class;
    }
    sub do_request {
        my ($self, %args) = @_;
        push @{ $self->{requests} }, $args{request};
        return Future->done($self->{responder}->($args{request}));
    }
}

package main;

sub fake_api {
    my ($status, $headers, $body) = @_;
    my $api  = Net::Async::Forgejo::API->new(url => 'https://src.ci', token => 't');
    my $http = FakeHTTP->new(responder => sub {
        HTTP::Response->new($status, 'X', $headers, $body);
    });
    $api->{_http} = $http;
    return ($api, $http);
}

sub json_api { fake_api(200, [ 'Content-Type' => 'application/json' ], '{"ok":1}') }

sub query_of { my %q = URI->new($_[0]->uri)->query_form; \%q }

# ---------------------------------------------------------------------------
# get: raw
# ---------------------------------------------------------------------------

subtest 'get raw => 1 returns the body as bytes, not decoded' => sub {
    my ($api) = fake_api(200,
        [ 'Content-Type' => 'application/json', 'X-Total-Count' => 99 ],
        '[{"id":1}]');
    my $data = $api->get('/repos/o/r/raw/list.json', raw => 1)->get;
    is($data, '[{"id":1}]', 'JSON body handed back as the string that came');
};

subtest 'get raw => 1 leaves a charset alone' => sub {
    my $bytes = encode('UTF-8', "Grüße");
    my ($api) = fake_api(200, [ 'Content-Type' => 'text/plain; charset=utf-8' ], $bytes);
    my $data = $api->get('/repos/o/r/raw/README', raw => 1)->get;
    ok(!utf8::is_utf8($data), 'no character decoding');
    is($data, $bytes, 'file bytes exactly as stored');
};

# ---------------------------------------------------------------------------
# post/put/patch/delete($path, $data, %opts)
# ---------------------------------------------------------------------------

subtest 'post sends the JSON body and params as query string' => sub {
    my ($api, $http) = json_api();
    my $data = $api->post('/repos/o/r/issues', { title => 'Bug' },
        params => { sudo => 'other' })->get;
    is_deeply($data, { ok => 1 }, 'response parsed');
    my $req = $http->{requests}[0];
    is($req->method, 'POST', 'POST');
    is_deeply(query_of($req), { sudo => 'other' }, 'params became the query string');
    is_deeply(decode_json($req->content), { title => 'Bug' }, 'JSON body sent');
};

for my $verb (qw( put patch )) {
    subtest "$verb takes params like post" => sub {
        my ($api, $http) = json_api();
        $api->$verb('/x', { a => 1 }, params => { b => 2 })->get;
        my $req = $http->{requests}[0];
        is($req->method, uc $verb, uc $verb);
        is_deeply(query_of($req), { b => 2 }, 'query string');
        is_deeply(decode_json($req->content), { a => 1 }, 'JSON body');
    };
}

subtest 'post with upload sends multipart/form-data' => sub {
    my ($api, $http) = json_api();
    $api->post('/repos/o/r/issues/1/assets', undef,
        params => { name => 'notes.txt' },
        upload => { content => 'file body', filename => 'notes.txt' })->get;
    my $req = $http->{requests}[0];
    like($req->header('Content-Type'), qr{\Amultipart/form-data;\s*boundary=},
        'Content-Type carries the multipart boundary');
    like($req->content, qr/name="attachment"; filename="notes.txt"/,
        'default form field and filename');
    like($req->content, qr/file body/, 'file content in the body');
    is_deeply(query_of($req), { name => 'notes.txt' }, 'params still the query string');
};

subtest 'delete sends a body only when data is given' => sub {
    my ($api, $http) = fake_api(204, [], '');
    my $data = $api->delete('/repos/o/r/issues/1/labels/2')->get;
    ok(!defined $data, 'empty body resolves to undef');
    is($http->{requests}[0]->method, 'DELETE', 'DELETE');
    is($http->{requests}[0]->content, '', 'no body without data');

    $api->delete('/user/emails', { emails => ['old@example.com'] }, params => { x => 1 })->get;
    my $req = $http->{requests}[1];
    is_deeply(decode_json($req->content), { emails => ['old@example.com'] }, 'JSON body with data');
    is_deeply(query_of($req), { x => 1 }, 'params as query string');
};

subtest 'post raw => 1 returns the body undecoded' => sub {
    my ($api) = fake_api(200, [ 'Content-Type' => 'application/json' ], '{"a":1}');
    is($api->post('/x', { a => 1 }, raw => 1)->get, '{"a":1}', 'raw string');
};

# ---------------------------------------------------------------------------
# check($path, %opts)
# ---------------------------------------------------------------------------

subtest 'check: 2xx is 1, 404 is 0' => sub {
    my ($api, $http) = fake_api(204, [], '');
    is($api->check('/repos/o/r/collaborators/u', params => { x => 1 })->get, 1, '204 -> 1');
    is($http->{requests}[0]->method, 'GET', 'check is a GET');
    is_deeply(query_of($http->{requests}[0]), { x => 1 }, 'params passed on');

    ($api) = fake_api(404, [ 'Content-Type' => 'application/json' ],
        '{"message":"user is not a collaborator"}');
    is($api->check('/repos/o/r/collaborators/u')->get, 0, '404 -> 0');

    ($api) = fake_api(404, [], '');
    is($api->check('/repos/o/r/collaborators/u')->get, 0, 'empty 404 -> 0');
};

subtest 'check: a missing route fails like any other error' => sub {
    my ($api) = fake_api(404, [ 'Content-Type' => 'text/plain; charset=utf-8' ],
        "404 page not found\n");
    my $f = $api->check('/repos/o/r/feature-not-here');
    $f->await;
    ok($f->is_failed, 'plain-text 404 of a missing route fails the Future');
    like(scalar $f->failure, qr/\AForgejo API error: 404 page not found/,
        'with the API error message');
};

subtest 'check: other statuses fail' => sub {
    my ($api) = fake_api(500, [ 'Content-Type' => 'application/json' ],
        '{"message":"boom"}');
    my $f = $api->check('/x');
    $f->await;
    ok($f->is_failed, '500 fails the Future');
    like(scalar $f->failure, qr/\AForgejo API error: boom/, 'message from the body');
};

# ---------------------------------------------------------------------------
# errors
# ---------------------------------------------------------------------------

subtest 'API errors fail the Future with "Forgejo API error: ..."' => sub {
    for my $verb (qw( get post put patch delete )) {
        my ($api) = fake_api(422, [ 'Content-Type' => 'application/json' ],
            '{"message":"invalid input"}');
        my $f = $api->$verb('/x', ($verb eq 'get' ? () : ({ a => 1 })));
        $f->await;
        ok($f->is_failed, "$verb: Future failed");
        like(scalar $f->failure, qr/\AForgejo API error: invalid input/,
            "$verb: message from the JSON error body");
    }
};

done_testing;
