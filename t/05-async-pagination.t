#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use lib 'lib';
use lib '../p5-www-forgejo/lib';

use Future;
use HTTP::Response;
use JSON::MaybeXS qw(encode_json);
use URI;
use IO::Async::Loop;
use WWW::Forgejo::HTTPResponse;
use Net::Async::Forgejo::API;

# Async pagination mirrors WWW::Forgejo::Role::HTTP get (WWW::Forgejo karr #5):
# auto-pagination via X-Total-Count from HTTPResponse->headers, over a bare
# array or the data arrayref of a search envelope.

# Offline fake transport. The responder is handed the outgoing HTTP::Request so a
# test can serve different pages by ?page= / ?limit= and record the offsets asked.
package FakeHTTP {
    sub new {
        my ($class, %args) = @_;
        bless { responder => $args{responder} }, $class;
    }
    sub do_request {
        my ($self, %args) = @_;
        return $self->{responder}->($args{request});
    }
}

package main;

sub page_response {
    my ($items, $total, %opt) = @_;
    my @headers = ('Content-Type' => 'application/json');
    push @headers, ('X-Total-Count' => $total) unless $opt{no_total};
    return HTTP::Response->new(200, 'OK', \@headers, encode_json($items));
}

sub new_api {
    Net::Async::Forgejo::API->new(url => 'https://src.ci', token => 't');
}

# Record the page/limit of every request so offset alignment can be asserted.
sub query_of {
    my ($req) = @_;
    my %q = URI->new($req->url)->query_form;
    return \%q;
}

subtest 'server-paged list: all pages merged in order, offsets aligned' => sub {
    my @reqs;
    my %pages = (
        1 => [ { id => 1 }, { id => 2 } ],
        2 => [ { id => 3 }, { id => 4 } ],
        3 => [ { id => 5 } ],
    );
    my $api = new_api();
    $api->{_http} = FakeHTTP->new(responder => sub {
        my $q = query_of($_[0]);
        push @reqs, $q;
        my $page = $q->{page} // 1;
        return Future->done(page_response($pages{$page} // [], 5));
    });

    my $result = $api->get('/repos/o/r/issues')->get;

    is(scalar @$result, 5, 'all 5 items collected across pages');
    is_deeply([ map { $_->{id} } @$result ], [ 1, 2, 3, 4, 5 ],
        'pages concatenated in order');

    is(scalar @reqs, 3, 'exactly three page requests issued');
    ok(!defined $reqs[0]{page}, 'first request carries no explicit page');
    is($reqs[1]{page}, 2, 'second request is page 2');
    is($reqs[1]{limit}, 2, 'page 2 limit == first-page size (offset aligned)');
    is($reqs[2]{page}, 3, 'third request is page 3');
    is($reqs[2]{limit}, 2, 'page 3 limit == first-page size (offset aligned)');
};

subtest 'explicit page_size forces the limit on every request incl. the first' => sub {
    my @reqs;
    my %pages = (
        1 => [ { id => 1 }, { id => 2 } ],
        2 => [ { id => 3 } ],
    );
    my $api = new_api();
    $api->{_http} = FakeHTTP->new(responder => sub {
        my $q = query_of($_[0]);
        push @reqs, $q;
        my $page = $q->{page} // 1;
        return Future->done(page_response($pages{$page} // [], 3));
    });

    my $result = $api->get('/repos/o/r/issues', page_size => 2)->get;

    is_deeply([ map { $_->{id} } @$result ], [ 1, 2, 3 ], 'all pages merged');
    is($reqs[0]{limit}, 2, 'first request already carries the forced limit');
    is($reqs[1]{page}, 2, 'second request is page 2');
    is($reqs[1]{limit}, 2, 'second request keeps the same limit');
};

subtest 'max_pages caps the number of pages fetched' => sub {
    my @reqs;
    my $api = new_api();
    $api->{_http} = FakeHTTP->new(responder => sub {
        my $q = query_of($_[0]);
        push @reqs, $q;
        # Always claim a large total and hand back 2 items per page.
        return Future->done(page_response([ { id => 1 }, { id => 2 } ], 1000));
    });

    my $result = $api->get('/repos/o/r/issues', max_pages => 2)->get;

    is(scalar @reqs, 2, 'stopped after max_pages requests despite a huge total');
    is(scalar @$result, 4, 'only the fetched pages are returned');
};

subtest 'pinned page returns just that page, no extra requests' => sub {
    my @reqs;
    my $api = new_api();
    $api->{_http} = FakeHTTP->new(responder => sub {
        push @reqs, query_of($_[0]);
        return Future->done(page_response([ { id => 3 }, { id => 4 } ], 100));
    });

    my $result = $api->get('/repos/o/r/issues', params => { page => 2 })->get;

    is(scalar @reqs, 1, 'pinned page issues exactly one request');
    is($reqs[0]{page}, 2, 'the pinned page is honoured');
    is_deeply([ map { $_->{id} } @$result ], [ 3, 4 ], 'only that page returned');
};

subtest 'single-object response is returned unchanged' => sub {
    my @reqs;
    my $api = new_api();
    $api->{_http} = FakeHTTP->new(responder => sub {
        push @reqs, query_of($_[0]);
        return Future->done(
            HTTP::Response->new(200, 'OK',
                [ 'Content-Type' => 'application/json', 'X-Total-Count' => 99 ],
                '{"id":1}')
        );
    });

    my $result = $api->get('/user')->get;
    is(ref $result, 'HASH', 'hashref passed straight through');
    is(scalar @reqs, 1, 'no pagination attempted for a non-array body');
};

subtest 'array without X-Total-Count is returned unchanged' => sub {
    my @reqs;
    my $api = new_api();
    $api->{_http} = FakeHTTP->new(responder => sub {
        push @reqs, query_of($_[0]);
        return Future->done(page_response([ { id => 1 }, { id => 2 } ], undef, no_total => 1));
    });

    my $result = $api->get('/repos/o/r/issues')->get;
    is(scalar @$result, 2, 'array returned as-is');
    is(scalar @reqs, 1, 'no extra requests without an X-Total-Count header');
};

subtest 'total not greater than first page: no extra requests' => sub {
    my @reqs;
    my $api = new_api();
    $api->{_http} = FakeHTTP->new(responder => sub {
        push @reqs, query_of($_[0]);
        return Future->done(page_response([ { id => 1 }, { id => 2 } ], 2));
    });

    my $result = $api->get('/repos/o/r/issues')->get;
    is(scalar @$result, 2, 'complete first page returned');
    is(scalar @reqs, 1, 'nothing more fetched when total == items already held');
};

subtest 'search envelope: data pages merged, envelope shape kept' => sub {
    my @reqs;
    my %pages = (
        1 => [ { id => 1 }, { id => 2 } ],
        2 => [ { id => 3 }, { id => 4 } ],
        3 => [ { id => 5 } ],
    );
    my $api = new_api();
    $api->{_http} = FakeHTTP->new(responder => sub {
        my $q = query_of($_[0]);
        push @reqs, $q;
        my $page = $q->{page} // 1;
        return Future->done(page_response({ ok => JSON::MaybeXS::true(),
            data => $pages{$page} // [] }, 5));
    });

    my $result = $api->get('/repos/search', params => { q => 'x' })->get;

    is(ref $result, 'HASH', 'still the envelope object');
    ok($result->{ok}, 'other envelope keys kept');
    is_deeply([ map { $_->{id} } @{ $result->{data} } ], [ 1, 2, 3, 4, 5 ],
        'data holds every page, in order');
    is(scalar @reqs, 3, 'three page requests');
    is($reqs[1]{page}, 2, 'second request is page 2');
    is($reqs[1]{limit}, 2, 'limit == first-page size');
    is($reqs[2]{q}, 'x', 'caller params kept on follow-up pages');
};

subtest 'envelope without X-Total-Count is returned unchanged' => sub {
    my @reqs;
    my $api = new_api();
    $api->{_http} = FakeHTTP->new(responder => sub {
        push @reqs, query_of($_[0]);
        return Future->done(page_response({ ok => 1, data => [ { id => 1 } ] },
            undef, no_total => 1));
    });

    my $result = $api->get('/repos/search')->get;
    is_deeply($result, { ok => 1, data => [ { id => 1 } ] }, 'as it came');
    is(scalar @reqs, 1, 'no extra requests');
};

subtest 'an error on a follow-up page fails the Future' => sub {
    my $api = new_api();
    $api->{_http} = FakeHTTP->new(responder => sub {
        my $page = query_of($_[0])->{page} // 1;
        return Future->done($page == 1
            ? page_response([ { id => 1 }, { id => 2 } ], 5)
            : HTTP::Response->new(500, 'Internal Server Error',
                [ 'Content-Type' => 'application/json' ],
                '{"message":"database is locked"}'));
    });

    my $f = $api->get('/repos/o/r/issues');
    $f->await;
    ok($f->is_failed, 'the whole get fails');
    like(scalar $f->failure, qr/\AForgejo API error: database is locked/,
        'with the API error of the failing page');
};

subtest 'non-blocking: chain resolves across real loop turns' => sub {
    my $loop = IO::Async::Loop->new;
    my %pages = (
        1 => [ { id => 1 }, { id => 2 } ],
        2 => [ { id => 3 } ],
    );
    my $api = new_api();
    $api->{_http} = FakeHTTP->new(responder => sub {
        my $q = query_of($_[0]);
        my $page = $q->{page} // 1;
        # Defer to a later loop tick to prove the client never blocks on ->get.
        return $loop->delay_future(after => 0)
            ->then(sub { Future->done(page_response($pages{$page} // [], 3)) });
    });

    my $f = $api->get('/repos/o/r/issues');
    isa_ok($f, 'Future', 'get returns a Future');
    ok(!$f->is_ready, 'Future is still pending — transport deferred to the loop');

    my $result = $f->get;   # drives the loop until the whole chain resolves
    is_deeply([ map { $_->{id} } @$result ], [ 1, 2, 3 ],
        'pages merged across deferred loop turns');
};

# Actions runs envelope (WWW::Forgejo karr #22): the runs sit under
# workflow_runs and Forgejo 15 sends the total only as total_count in the body.
sub runs_response {
    my ($runs, $total, %headers) = @_;
    return HTTP::Response->new(200, 'OK',
        [ 'Content-Type' => 'application/json', %headers ],
        encode_json({ total_count => $total, workflow_runs => $runs }));
}

subtest 'runs envelope: pages merged by body total_count, shape kept' => sub {
    my @reqs;
    my %pages = (
        1 => [ { id => 1 }, { id => 2 } ],
        2 => [ { id => 3 } ],
    );
    my $api = new_api();
    $api->{_http} = FakeHTTP->new(responder => sub {
        my $q = query_of($_[0]);
        push @reqs, $q;
        return Future->done(runs_response($pages{ $q->{page} // 1 } // [], 3));
    });

    my $result = $api->get('/repos/o/r/actions/runs')->get;

    is(ref $result, 'HASH', 'envelope shape kept');
    is($result->{total_count}, 3, 'other envelope keys kept');
    is_deeply([ map { $_->{id} } @{ $result->{workflow_runs} } ], [ 1, 2, 3 ],
        'workflow_runs replaced by the merged collection');
    is(scalar @reqs, 2, 'two page requests');
    is($reqs[1]{page}, 2, 'second request is page 2');
    is($reqs[1]{limit}, 2, 'limit == first-page size (offset aligned)');
};

subtest 'runs envelope: pinned page and complete total issue no extra requests' => sub {
    my @reqs;
    my $api = new_api();
    $api->{_http} = FakeHTTP->new(responder => sub {
        push @reqs, query_of($_[0]);
        return Future->done(runs_response([ { id => 1 }, { id => 2 } ], 100));
    });

    my $pinned = $api->get('/repos/o/r/actions/runs', params => { page => 2 })->get;
    is(scalar @reqs, 1, 'pinned page: one request');
    is(scalar @{ $pinned->{workflow_runs} }, 2, 'pinned page returned as is');

    @reqs = ();
    $api->{_http} = FakeHTTP->new(responder => sub {
        push @reqs, query_of($_[0]);
        return Future->done(runs_response([ { id => 1 }, { id => 2 } ], 2));
    });
    my $all = $api->get('/repos/o/r/actions/runs')->get;
    is(scalar @reqs, 1, 'total_count == items: one request');
    is(scalar @{ $all->{workflow_runs} }, 2, 'returned unchanged');
};

subtest 'runs envelope: X-Total-Count header wins over body total_count' => sub {
    my @reqs;
    my $api = new_api();
    $api->{_http} = FakeHTTP->new(responder => sub {
        my $q = query_of($_[0]);
        push @reqs, $q;
        return Future->done($q->{page}
            ? runs_response([ { id => 3 } ], 2, 'X-Total-Count' => 3)
            : runs_response([ { id => 1 }, { id => 2 } ], 2, 'X-Total-Count' => 3));
    });

    my $result = $api->get('/repos/o/r/actions/runs')->get;

    is(scalar @reqs, 2, 'header total (3) drove a second request despite body total_count 2');
    is(scalar @{ $result->{workflow_runs} }, 3, 'all runs collected');
};

done_testing;
