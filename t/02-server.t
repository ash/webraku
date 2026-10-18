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
sub slow-double(Int $x) is server { sleep .4; $x * 2 }

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

{
    # Two pages at once. The log used to be one variable for the whole server,
    # and the second render emptied the first one's while it was still running.
    page '/slow', :title('Slow'), { p ~slow-double(4) }
    page '/plain', :title('Plain'), { p 'nothing to record' }
    my $slow = start { handle('GET', '/slow', {}, '') };
    sleep .1;
    handle('GET', '/plain', {}, '');
    my ($status, $type, $body) = await $slow;
    my $log = ($body ~~ / 'id="webraku-replay" type="application/json">' (<-[<]>*) /)[0].Str;
    is-it from-json($log).elems.Str, '1', 'a render keeps its log while another page renders';
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

# ---------- the request body limit, and the bundle's caching ----------
{
    my ($status, $type, $body, $cache) = handle('GET', '/_webraku/client.js', {}, '');
    is-it $status.Str, '200', 'the bundle is served';
    has-it ($cache // ''), 'immutable', 'and may be cached for good, since its URL changes on restart';
    my ($s2, $t2, $page) = handle('GET', '/', {}, '');
    has-it $page, '/_webraku/client.js?v=', 'the page asks for the bundle by its versioned URL';
}

# ---------- a mount point ----------
{
    webraku-base('/demo/');
    is-it url('/post/7'), '/demo/post/7', 'url() puts the base in front of a path';
    is-it url('x'),       '/demo/x',      'and of a relative one';
    my ($status, $type, $body) = handle('GET', '/demo/post/42', {}, '');
    is-it $status.Str, '200',              'a path under the base reaches its route';
    has-it $body, '<h1>post 42</h1>',      'with the base taken off';
    has-it $body, 'src="/demo/_webraku/client.js?v=', 'the bundle is asked for under the base';
    has-it $body, '<meta name="webraku-base" content="/demo">', 'and the page tells the browser where it is mounted';
    ($status, $type, $body) = handle('GET', '/demo', {}, '');
    has-it $body, '<h1>home</h1>',         'the base alone is the root';
    ($status, $type, $body) = handle('GET', '/post/42', {}, '');
    is-it $status.Str, '200',              'a proxy that strips the base is answered the same';
    ($status, $type, $body) = handle('POST', '/demo/_rpc/double', {}, '[5]');
    is-it from-json($body)<result>.Str, '10', 'a server sub is reachable under the base';
    webraku-base('');
    is-it url('/post/7'), '/post/7',       'with no base, url() changes nothing';
}

# ---------- the request, inside an `is server` sub ----------
{
    sub who-asks() is server { request().header('x-forwarded-for') // 'nobody' }
    my ($status, $type, $body) = handle('POST', '/_rpc/who-asks', { 'x-forwarded-for' => '203.0.113.7' }, '[]');
    is-it from-json($body)<result>, '203.0.113.7', 'request() is the request an `is server` sub is answering';
}

# ---------- two pages building at once ----------
{
    # The builders' stack of open parents was one array for the whole server,
    # and the server answers each request on a thread of its own: two renders at
    # once built into each other, and one page came out empty.
    # A opens its div and pauses; B opens its div and pauses longer; A wakes
    # and builds again while B's div is open.
    page '/nest-a', :title('A'), { div :class<a>, { p 'a1'; sleep .3; p 'a2' } }
    page '/nest-b', :title('B'), { div :class<b>, { sleep .4; p 'b1' } }
    my $pa = start { handle('GET', '/nest-a', {}, '') };
    sleep .1;
    my $pb = start { handle('GET', '/nest-b', {}, '') };
    my $a = (await $pa)[2];
    my $b = (await $pb)[2];
    has-it $a, '<div class="a"><p>a1</p><p>a2</p></div>', 'a page keeps its own tree while another builds';
    has-it $b, '<div class="b"><p>b1</p></div>', 'and the other page keeps its own';
}

say "1..$n";
say $bad ?? "# $bad of $n checks FAILED" !! "# all $n checks passed";
exit $bad ?? 1 !! 0;
