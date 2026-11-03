requires 'Carp';
requires 'Future';
requires 'HTTP::Request';
requires 'IO::Async::Notifier';
requires 'Net::Async::HTTP';
requires 'URI';
requires 'WWW::Forgejo', '0.001';

# https:// instance URLs need it; plain-http instances do not, and Forgejo
# often runs without TLS inside a private network.
recommends 'IO::Async::SSL';

on test => sub {
    requires 'Encode';
    requires 'HTTP::Response';
    requires 'IO::Async::Loop';
    requires 'IO::Compress::Gzip';
    requires 'JSON::MaybeXS';
    requires 'Test::More';
};
