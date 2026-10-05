#!/usr/bin/env rakupp
# Webraku::Server and Webraku::JSON. `handle` is a pure function of the request
# and the route table, so everything the server ANSWERS is checked here with no
# port and no network.
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

# ---------- JSON ----------
is-it to-json(42),                     '42',                'an Int';
is-it to-json('a "b"'),                '"a \\"b\\""',       'a string with a quote';
is-it to-json(True),                   'true',              'a Bool';
is-it to-json(Nil),                    'null',              'Nil';
is-it to-json([1, 'a', True]),         '[1,"a",true]',      'an array';
is-it to-json(%(b => 2, a => 1)),      '{"a":1,"b":2}',     'a hash, keys sorted';
is-it to-json('</script>'),            '"<\\/script>"',     'a closing tag cannot escape the script it is embedded in';
is-it from-json('[1,2,3]').join(','),  '1,2,3',             'parsing an array';
is-it from-json('{"a":1}')<a>.Str,     '1',                 'parsing an object';
is-it from-json('"a\\nb"'),            "a\nb",              'a string escape';
is-it from-json('-1.5e2').Str,         '-150',              'a float with an exponent';
{
    my $round = %(x => [1, %(y => 'z & "q"')], n => -3, ok => False);
    is-it from-json(to-json($round)).&to-json, to-json($round), 'a round trip is identical';
}

# ---------- routes ----------
page '/',            :title('Home'), { h1 'home' }
page '/post/:id',    :title('Post'), -> $id { h1 "post $id" }
api  '/api/sum/:a/:b',               -> $a, $b { %( sum => $a.Int + $b.Int ) }

sub double(Int $x) is server { $x * 2 }

{
    my ($status, $type, $body) = handle('GET', '/', {}, '');
    is-it $status.Str, '200',                       'the root route answers 200';
    has-it $type, 'text/html',                      'and it is HTML';
    has-it $body, '<title>Home</title>',            'the title comes from the route';
    has-it $body, '<h1>home</h1>',                  'the page body is rendered into it';
    has-it $body, '<div id="webraku-root">',        'the tree is wrapped for the browser to find';
    has-it $body, 'id="webraku-replay"',            'and the replay log is embedded';
}
{
    my ($status, $type, $body) = handle('GET', '/post/42', {}, '');
    is-it $status.Str, '200',              'a route with a named segment answers';
    has-it $body, '<h1>post 42</h1>',      'and its parameter reaches the block';
}
{
    my ($status, $type, $body) = handle('GET', '/api/sum/3/4', {}, '');
    is-it $status.Str, '200',      'an api route answers';
    has-it $type, 'application/json', 'as JSON';
    is-it from-json($body)<sum>.Str, '7', 'and its return value is the body';
}
{
    my ($status, $type, $body) = handle('GET', '/nope', {}, '');
    is-it $status.Str, '404', 'an unknown path is 404';
    has-it $body, '/nope',    'and the page names it';
}
{
    my ($status, $type, $body) = handle('PUT', '/', {}, '');
    is-it $status.Str, '405', 'an unsupported method is 405';
}

# ---------- the replay log ----------
{
    page '/twice', :title('Twice'), { p ~double(21) }
    my ($status, $type, $body) = handle('GET', '/twice', {}, '');
    has-it $body, '<p>42</p>', 'an `is server` sub runs on the server';
    my $log = ($body ~~ / 'id="webraku-replay" type="application/json">' (<-[<]>*) /)[0].Str;
    my @entries = from-json($log).list;
    is-it @entries.elems.Str, '1',             'the call was recorded once';
    is-it @entries[0]<name>,  'double',        'under its own name';
    is-it @entries[0]<args>.join(','), '21',   'with its arguments';
    is-it @entries[0]<result>.Str, '42',       'and its answer, for the browser to replay';
}

# ---------- the RPC endpoint ----------
{
    my ($status, $type, $body) = handle('POST', '/_rpc/double', {}, '[21]');
    is-it $status.Str, '200',               'a server sub is reachable over HTTP';
    is-it from-json($body)<result>.Str, '42', 'and answers its return value';
}
{
    my ($status, $type, $body) = handle('POST', '/_rpc/nosuch', {}, '[]');
    is-it $status.Str, '404', 'an unknown server sub is 404';
}

# ---------- the query string ----------
{
    page '/q', :title('Q'), { p 'x' }
    my ($status, $type, $body) = handle('GET', '/q?a=1&b=hello%20there', {}, '');
    is-it $status.Str, '200', 'a query string does not disturb the route match';
}

say "1..$n";
say $bad ?? "# $bad of $n checks FAILED" !! "# all $n checks passed";
exit $bad ?? 1 !! 0;
