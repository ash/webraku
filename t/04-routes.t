#!/usr/bin/env rakupp
# Handlers that own their response: `route`, `Response`, `redirect`, `fallback`,
# splat and encoded segments, forms, cookies, and files served as bytes.
use lib $?FILE.IO.parent.parent.add('lib').Str;
use Webraku;

my $n = 0;
my $bad = 0;
sub is-it($got, $want, Str $desc) {
    $n++;
    if $got eq $want { say "ok $n - $desc" }
    else { $bad++; say "not ok $n - $desc"; say "#      got: $got"; say "# expected: $want" }
}
sub has-it($got, $want, Str $desc) {
    $n++;
    if $got.contains($want) { say "ok $n - $desc" }
    else { $bad++; say "not ok $n - $desc"; say "#      got: $got"; say "# expected to contain: $want" }
}

route '/doc', { html :lang<en>, { head { title 'Doc' }; body :class<home>, { h1 'hi' } } }
route '/text', { response 'plain', :type('text/plain; charset=utf-8') }
route '/old', { redirect '/new', :status(301) }
route '/cookie', { response 'ok', headers => ('Set-Cookie' => 'a=1', 'Set-Cookie' => 'b=2') }
route '/cat/*path', -> $path { "cat:$path" }
route '/tag/:slug', -> $slug { "tag:$slug" }
route '/form', :methods<POST>, { my %f = request.form; "name={%f<name>};tags={%f<tag>.join('+')}" }
route '/who', { "host={request.host};c={request.cookies<sid> // ''}" }
fallback -> $path { response "nothing at $path", :status(404) }

{
    my ($status, $type, $body, $headers) = handle('GET', '/doc', {}, '');
    is-it $status.Str, '200', 'a route answers 200';
    is-it $body.substr(0, 15), '<!DOCTYPE html>', 'a whole document gets its doctype';
    has-it $body, '<body class="home"><h1>hi</h1></body>', 'and is the tree the block built, with no shell';
    is-it $body.contains('webraku-root'), False, 'nothing is wrapped around it';
}
{
    my ($status, $type, $body) = handle('GET', '/text', {}, '');
    is-it $type, 'text/plain; charset=utf-8', 'a Response sets the type';
    is-it $body, 'plain', 'and the body';
}
{
    my ($status, $type, $body, $headers) = handle('GET', '/old', {}, '');
    is-it $status.Str, '301', 'a redirect has its status';
    is-it $headers.first(*.key eq 'Location').value, '/new', 'and its Location';
}
{
    my ($status, $type, $body, $headers) = handle('GET', '/cookie', {}, '');
    is-it $headers.grep(*.key eq 'Set-Cookie').elems.Str, '2', 'two headers of one name both go out';
}
{
    my ($status, $type, $body) = handle('GET', '/cat/a/b/c/', {}, '');
    is-it $body, 'cat:a/b/c', 'a splat takes the rest of the path';
    ($status, $type, $body) = handle('GET', '/cat', {}, '');
    is-it $status.Str, '404', 'but at least one segment of it';
}
{
    my ($status, $type, $body) = handle('GET', '/tag/%D0%BA%D0%BE%D1%82/', {}, '');
    is-it $body, 'tag:кот', 'an encoded segment arrives decoded';
    ($status, $type, $body) = handle('GET', '/tag/a%2Fb', {}, '');
    is-it $body, 'tag:a/b', 'and an encoded slash stays inside its segment';
}
{
    my %h = 'content-type' => 'application/x-www-form-urlencoded';
    my ($status, $type, $body) = handle('POST', '/form', %h, 'name=A+B%21&tag=x&tag=y');
    is-it $body, 'name=A B!;tags=x+y', 'a form is parsed, and a repeated name keeps every value';
    ($status, $type, $body) = handle('GET', '/form', {}, '');
    is-it $status.Str, '405', 'a route limited to POST refuses GET';
}
{
    my ($status, $type, $body) = handle('GET', '/who', { host => 'example.com:8080', cookie => 'x=1; sid=abc' }, '');
    is-it $body, 'host=example.com;c=abc', 'the request is reachable, with its host and cookies';
}
{
    my ($status, $type, $body) = handle('GET', '/nowhere', {}, '');
    is-it $status.Str, '404', 'the fallback answers what no route matches';
    is-it $body, 'nothing at /nowhere', 'with what it returned';
}
{
    my $dir = $*TMPDIR.add("webraku-static-$*PID");
    $dir.mkdir;
    $dir.add('сова.bin').spurt: Blob.new(0, 255, 128, 10, 13, 0);
    static '/files', $dir.Str;
    my ($status, $type, $body, $headers) = handle('GET', '/files/%D1%81%D0%BE%D0%B2%D0%B0.bin', {}, '');
    is-it $status.Str, '200', 'a file whose name is not ASCII is found';
    is-it ($body ~~ Blob).Str, 'True', 'and served as bytes';
    is-it $body.list.join(','), '0,255,128,10,13,0', 'every one of them';
    ($status, $type, $body) = handle('GET', '/files/../x', {}, '');
    is-it $status.Str, '403', 'a path out of the directory is refused';
    $dir.add('сова.bin').unlink; $dir.rmdir;
}

say "1..$n";
say $bad ?? "# $bad of $n checks FAILED" !! "# all $n checks passed";
exit $bad ?? 1 !! 0;
