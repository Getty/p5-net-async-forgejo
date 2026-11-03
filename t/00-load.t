#!/usr/bin/env perl
use strict;
use warnings;

use lib 'lib';
use lib '../p5-www-forgejo/lib';

use Test::More;

use WWW::Forgejo;
use Net::Async::Forgejo;
use Net::Async::Forgejo::API;

pass "WWW::Forgejo loads";
pass "Net::Async::Forgejo loads";
pass "Net::Async::Forgejo::API loads";

done_testing;