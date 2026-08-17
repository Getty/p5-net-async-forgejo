requires 'IO::Async::Notifier';
requires 'Future';
requires 'URI';
requires 'HTTP::Request';
requires 'Net::Async::HTTP';
requires 'WWW::Forgejo';

on test => sub {
    requires 'Test::More';
};