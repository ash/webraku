# Monarch::Server — HTTP/1.1 on nothing but IO::Socket::INET.
#
# No dependencies. One thread per connection, which is the shape `rakus` has
# been serving with on both engines; a request is parsed into a Request object,
# matched against the registered pages and endpoints, and answered.
#
# What it answers with:
#   page   — the element tree the block builds, wrapped in a document shell that
#            carries the client bundle and the replay log.
#   api    — the block's return value, as JSON.
#   rpc    — one `is server` sub, called with the arguments the browser sent.
#   static — a file from a directory.
unit module Monarch::Server;

use Monarch::HTML;
use Monarch::JSON;
use Monarch::Route;

# ---------- the request ----------

class Request is export {
    has Str $.method;
    has Str $.path;
    has %.query;
    has %.headers;
    has %.params;           # the named segments of the matched route
    has Str $.body = '';
    method header(Str $n) { %!headers{$n.lc} }
    method cookie(Str $n) {
        my $c = self.header('cookie') // return Str;
        for $c.split(';') -> $pair {
            my ($k, $v) = $pair.trim.split('=', 2);
            return $v // '' if $k eq $n;
        }
        Str;
    }
}

#| The request being served, inside a page or api block.
our $REQUEST is export = Request;

# ---------- the route table ----------

my @ROUTES;
my %RPC;                    # name => the `is server` sub
my @STATIC;                 # (url-prefix, directory)
my $CLIENT-JS = '';         # the bundle, set by `serve`
my $DEV = False;
my $VERSION = ~now.Int;     # the dev watcher's reload token

#| Register a page. The path may carry named segments — `/post/:id` — which are
#| bound to the block's parameters in order.
sub page(Str $pattern, &body, Str :$title = 'Monarch') is export {
    @ROUTES.push: Route.new(kind => 'page', :$pattern, segments => split-path($pattern), :&body, :$title);
}

#| Register a JSON endpoint. The block's return value is the response body.
sub api(Str $pattern, &body) is export {
    @ROUTES.push: Route.new(kind => 'api', :$pattern, segments => split-path($pattern), :&body, title => '');
}

#| Serve files under `$dir` at the URL prefix `$prefix`.
sub static(Str $prefix, Str $dir) is export { @STATIC.push: ($prefix, $dir) }

#| Register an `is server` sub so the browser can call it. `serve` does this for
#| every one the program declares; a program may also do it by hand.
sub server-sub(Str $name, &code) is export { %RPC{$name} = &code }

# The `is server` routines, in declaration order. The trait lives in Monarch.rakumod
# — it has to, so an application's `sub … is server` can see it — but the list
# belongs here, where `serve` publishes it and `record-call` fills the log.
# Registering at DECLARATION and not in `serve` is what lets `handle` answer an
# `/_rpc/` call with no port and no server started — which is how t/02-server.t
# checks the whole endpoint.
my @SERVER-SUBS;
sub monarch-register(Routine $r) is export {
    @SERVER-SUBS.push: $r;
    %RPC{$r.name} = $r;
}
sub monarch-server-subs() is export { @SERVER-SUBS }

# The sources Monarch::Client hands out in the browser. On the server they are
# empty and already finished, for the same reason an element's events are: a
# `whenever every(1) { … }` in a page body must not keep the render waiting.
sub every(Real $seconds --> Supply) is export { Supply.from-list() }
sub after(Real $seconds --> Supply) is export { Supply.from-list() }

#| Replacing a list of children is a browser action. On the server the page is
#| rendered once, so the block simply builds into the parent.
sub render-list(Element $parent, &body) is export {
    $parent.kids = [];
    $parent.text = Str;
    with-parent($parent, &body);
    $parent;
}

sub routes() is export { @ROUTES }
sub rpc-table() is export { %RPC }

# ---------- the document shell ----------

#| Wrap a built tree in a page. The replay log is embedded as JSON so that the
#| browser's first render needs no network: every `is server` call the server
#| made while rendering is answered from it.
sub document(Str $title, Str $body-html, Str $replay, Str :$css = '' --> Str) is export {
    my $dev-script = $DEV ?? qq:to/DEV/ !! '';
        <script>
        (function () \{
          var v = "$VERSION";
          setInterval(function () \{
            fetch("/_monarch/version").then(function (r) \{ return r.text() \})
              .then(function (t) \{ if (t.trim() !== v) location.reload() \});
          \}, 700);
        \})();
        </script>
        DEV

    qq:to/HTML/;
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>{escape-html($title)}</title>
    <style>{$css}</style>
    </head>
    <body>
    {$body-html}
    <script id="monarch-replay" type="application/json">{$replay}</script>
    <script src="/_monarch/client.js"></script>
    {$dev-script}
    </body>
    </html>
    HTML
}

# ---------- the replay log ----------
#
# While a page renders, every `is server` call is recorded. The browser replays
# the log instead of making the same calls again, so the first client render
# matches the server's without a round trip. Recording is per-render, and the
# server is one-thread-per-connection, so the log is a dynamic variable.

my $LOG;   # the Array being filled by the render in progress, or Nil

#| Call an `is server` sub and record it. The server calls its subs through
#| here; the browser's stub reads the recording.
sub record-call(Str $name, @args, \result) is export {
    $LOG.push: %( :$name, :args(@args.Array), result => result ) if $LOG.defined;
    result;
}

sub start-log()  { $LOG = []; }
sub finish-log(--> Str) { my $j = to-json($LOG // []); $LOG = Nil; $j }

# ---------- rendering a page ----------

sub render-page(Route $r, %params, Request $req --> Str) {
    start-log();
    my $root = Element.new(tag => 'div', attrs => { id => 'monarch-root' });
    {
        my $*MONARCH-REQUEST = $req;
        $REQUEST = $req;
        my @args = $r.param-names.map({ %params{$_} });
        with-parent($root, { $r.body.(|@args) });
    }
    my $replay = finish-log();
    document($r.title, $root.html, $replay, css => monarch-css());
}

my $CSS = '';
sub stylesheet(Str $css) is export { $CSS = $css }
sub monarch-css(--> Str) { $CSS }

# ---------- HTTP ----------

my %REASON = 200 => 'OK', 204 => 'No Content', 302 => 'Found', 400 => 'Bad Request',
             404 => 'Not Found', 405 => 'Method Not Allowed', 500 => 'Internal Server Error';

my %MIME = html => 'text/html; charset=utf-8', js => 'text/javascript; charset=utf-8',
           css => 'text/css; charset=utf-8', json => 'application/json; charset=utf-8',
           svg => 'image/svg+xml', png => 'image/png', jpg => 'image/jpeg',
           gif => 'image/gif', ico => 'image/x-icon', txt => 'text/plain; charset=utf-8',
           woff2 => 'font/woff2', map => 'application/json';

sub url-decode(Str $s is copy --> Str) {
    $s = $s.subst('+', ' ', :g);
    $s ~~ s:g/ '%' (<[0..9A..Fa..f]> ** 2) /{ chr(:16(~$0)) }/;
    $s;
}

sub parse-query(Str $qs --> Hash) {
    my %q;
    for $qs.split('&').grep(*.chars) -> $pair {
        my ($k, $v) = $pair.split('=', 2);
        %q{url-decode($k)} = url-decode($v // '');
    }
    %q;
}

#| Answer one request. A pure function of the request and the route table: it
#| touches no socket, so what the server answers can be tested with no port.
sub handle(Str $method, Str $target, %headers, Str $body --> List) is export {
    my ($path, $qs) = $target.split('?', 2);
    my %query = parse-query($qs // '');
    my $req = Request.new(:$method, :$path, :%query, :%headers, :$body);

    return (200, 'text/plain; charset=utf-8', $VERSION) if $path eq '/_monarch/version';
    return (200, %MIME<js>, $CLIENT-JS)                 if $path eq '/_monarch/client.js';

    # an `is server` call from the browser
    if $path.starts-with('/_rpc/') {
        my $name = $path.substr(6);
        # `my &fn = %RPC{$name} orelse …` looks tidier and is not portable: Rakudo
        # type-checks the assignment before `orelse` can act, and an unknown name
        # dies instead of answering 404.
        my $fn = %RPC{$name};
        return (404, %MIME<json>, to-json(%( error => "no server sub '$name'" ))) unless $fn;
        my @args = try from-json($body || '[]').list;
        return (400, %MIME<json>, to-json(%( error => 'the arguments must be a JSON array' ))) without @args;
        my $result = try $fn(|@args);
        return (500, %MIME<json>, to-json(%( error => ~$! ))) if $!;
        return (200, %MIME<json>, to-json(%( :$result )));
    }

    for @STATIC -> ($prefix, $dir) {
        next unless $path.starts-with($prefix);
        my $rel = $path.substr($prefix.chars).subst(/^ '/' /, '');
        return (403, %MIME<txt>, 'no') if $rel.contains('..');
        my $file = $dir.IO.add($rel);
        next unless $file.f;
        return (200, %MIME{$file.extension} // 'application/octet-stream', $file.slurp);
    }

    my ($route, %params) = match-route(@ROUTES, $path);
    without $route {
        return (404, %MIME<html>, document('Not found',
            '<h1>404</h1><p>' ~ escape-html($path) ~ ' is not a route this program declares.</p>', '[]'));
    }
    return (405, %MIME<txt>, 'method not allowed') unless $method eq 'GET' | 'POST' | 'HEAD';

    $req.params = %params;
    if $route.kind eq 'api' {
        my @args = $route.param-names.map({ %params{$_} });
        $REQUEST = $req;
        my $out = try $route.body.(|@args);
        return (500, %MIME<json>, to-json(%( error => ~$! ))) if $!;
        return (200, %MIME<json>, to-json($out));
    }
    my $html = try render-page($route, %params, $req);
    if $! {
        my $why = ~$!;
        return (500, %MIME<html>, document('Error',
            '<h1>500</h1><pre>' ~ escape-html($why) ~ '</pre>', '[]')) ;
    }
    (200, %MIME<html>, $html);
}

sub read-request($conn --> Str) {
    my $buf = '';
    while $buf !~~ / "\r\n\r\n" | "\n\n" / {
        my $chunk = $conn.recv(:bin) // last;
        last unless $chunk.bytes;
        $buf ~= $chunk.decode('utf8-c8');
        last if $buf.chars > 1_000_000;
    }
    $buf;
}

sub serve-one($conn, Bool :$log = True) is export {
    my $raw = read-request($conn);
    return unless $raw.chars;
    my ($head, $body) = $raw.split(/ "\r\n\r\n" | "\n\n" /, 2);
    my @lines = $head.lines;
    my ($method, $target) = (@lines[0] // '').split(/\s+/);
    return unless $method && $target;
    my %headers;
    for @lines[1..*] -> $l {
        my ($k, $v) = $l.split(':', 2);
        %headers{$k.lc.trim} = ($v // '').trim if $v.defined;
    }
    # A body longer than the first packet needs the rest of it.
    $body //= '';
    my $len = (%headers<content-length> // 0).Int;
    while $body.encode('utf8-c8').bytes < $len {
        my $chunk = $conn.recv(:bin) // last;
        last unless $chunk.bytes;
        $body ~= $chunk.decode('utf8-c8');
    }

    my ($status, $type, $text) = handle($method, $target, %headers, $body);
    my $bytes = $text.encode('utf8-c8');
    note sprintf('  %d %-4s %s', $status, $method, $target) if $log;
    $conn.write: (
        "HTTP/1.1 $status {%REASON{$status} // 'OK'}\r\n" ~
        "Content-Type: $type\r\n" ~
        "Content-Length: {$bytes.bytes}\r\n" ~
        "Cache-Control: no-store\r\n" ~
        "Connection: close\r\n\r\n"
    ).encode('utf8-c8') ~ ($method eq 'HEAD' ?? ''.encode !! $bytes);
    $conn.close;
}

#| Start the server. `$client-js` is the transpiled bundle, served at
#| /_monarch/client.js and referenced by every page.
sub serve(Int :$port is copy = 8080, Str :$host = '127.0.0.1', Str :$client-js is copy = '',
          Bool :$dev is copy = False, Bool :$log = True) is export {
    # `monarch run` builds the bundle and names it here, so that the program
    # itself carries no build concern: an application's last line is `serve;`
    # whether it was started by the tool or by hand.
    with %*ENV<MONARCH_CLIENT_JS_FILE> -> $f {
        $client-js = $f.IO.slurp if !$client-js && $f.IO.e;
    }
    $port = +$_ with %*ENV<MONARCH_PORT>;
    $dev  = True if %*ENV<MONARCH_DEV>;
    $CLIENT-JS = $client-js;
    $DEV = $dev;
    my $listener = IO::Socket::INET.new(:localhost($host), :localport($port), :listen);
    note "monarch: http://$host:$port/" ~ ($dev ?? '  (dev: the page reloads when the program changes)' !! '');
    note "monarch: {@ROUTES.elems} routes, {%RPC.elems} server subs, client bundle {$client-js.chars} chars";
    loop {
        my $conn = $listener.accept;
        start {
            my $r = try serve-one($conn, :$log);
            note "monarch: $!" if $!;
        }
    }
}
