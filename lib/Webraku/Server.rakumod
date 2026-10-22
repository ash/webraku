# Webraku::Server — HTTP/1.1 on nothing but IO::Socket::INET.
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
#   route  — whatever the block returns: a Response, a whole document built
#            with the builders, or a string of HTML. No shell, no client
#            script: the block owns the response.
unit module Webraku::Server;

use Webraku::HTML;
use Webraku::JSON;
use Webraku::Route;

# ---------- the request ----------

class Request is export {
    has Str $.method;
    has Str $.path;
    has %.query;
    has %.headers;
    has %.params;           # the named segments of the matched route
    has Str $.body = '';
    #| The body as it arrived, bytes and all: what a file upload is read from.
    method raw(--> Blob) { $*WEBRAKU-RAW-BODY // $!body.encode('utf8-c8') }
    method header(Str $n) { %!headers{$n.lc} }
    method cookie(Str $n) {
        my $c = self.header('cookie') // return Str;
        for $c.split(';') -> $pair {
            my ($k, $v) = $pair.trim.split('=', 2);
            return $v // '' if $k eq $n;
        }
        Str;
    }
    #| Every cookie the request carries.
    method cookies(--> Hash) {
        my %c;
        for (self.header('cookie') // '').split(';') -> $pair {
            my ($k, $v) = $pair.trim.split('=', 2);
            %c{$k} = $v // '' if $k;
        }
        %c;
    }
    method host(--> Str) { (self.header('host') // '').subst(/':' \d+ $/, '') }
    #| The fields of a form POSTed as `application/x-www-form-urlencoded`. A
    #| name that comes more than once (`tag=a&tag=b`) keeps every value, in an
    #| Array; any other name maps to its one Str.
    method form(--> Hash) {
        my %f;
        return %f unless (self.header('content-type') // '').starts-with('application/x-www-form-urlencoded');
        for $!body.split('&').grep(*.chars) -> $pair {
            my ($k, $v) = $pair.split('=', 2);
            $k = url-decode($k);
            $v = url-decode($v // '');
            if %f{$k}:exists {
                %f{$k} = [|(%f{$k} ~~ Array ?? %f{$k}.list !! %f{$k}), $v];
            }
            else { %f{$k} = $v }
        }
        %f;
    }
}

#| What a handler answers with when the default — 200, HTML, no headers — is
#| not what it means: a redirect, a 404 with a page, a feed, a file, a cookie.
#| `body` is a Str (sent as UTF-8) or a Blob (sent as it is). `headers` is a
#| list of pairs rather than a hash, so that two `Set-Cookie`s can both go out.
class Response is export {
    has Int $.status = 200;
    has Str $.type = 'text/html; charset=utf-8';
    has $.body = '';
    has @.headers;
}

#| `response 'text', :type<text/plain>`, `response $html, :status(404)`.
sub response($body = '', Int :$status = 200, Str :$type = 'text/html; charset=utf-8', :@headers --> Response) is export {
    Response.new(:$status, :$type, :$body, :@headers);
}

#| A redirect to `$to`. 302 by default; a permanent move is `:status(301)`.
sub redirect(Str $to, Int :$status = 302, :@headers --> Response) is export {
    Response.new(:$status, type => 'text/html; charset=utf-8',
                 body => '<a href="' ~ escape-attr($to) ~ '">moved</a>',
                 headers => (Location => $to, |@headers));
}


#| The request being served, inside a page or api block.
our $REQUEST is export = Request;

#| The request being served, wherever the server is running the program's
#| code for it: a page, a route, an api block, or an `is server` sub the
#| browser called. Each request has its own, where `$REQUEST` is one variable
#| that requests answered at the same time overwrite.
sub request(--> Request) is export { $*WEBRAKU-REQUEST // $REQUEST }

# ---------- the route table ----------

my @ROUTES;
my %RPC;                    # name => the `is server` sub
my @STATIC;                 # (url-prefix, directory)
my &FALLBACK;               # answers what no route matches
my $CLIENT-JS = '';         # the bundle, set by `serve`
my $DEV = False;
my $VERSION = ~now.Int;     # the dev watcher's reload token, and the bundle's cache key
my $BASE = '';              # the path the application is mounted under, '' for the root
my $MAX-BODY = 1_000_000;   # bytes; a longer request body is answered 413 unread

#| Register a page. The path may carry named segments — `/post/:id` — which are
#| bound to the block's parameters in order.
sub page(Str $pattern, &body, Str :$title = 'Webraku') is export {
    @ROUTES.push: Route.new(kind => 'page', :$pattern, segments => split-path($pattern), :&body, :$title);
}

#| Register a JSON endpoint. The block's return value is the response body.
sub api(Str $pattern, &body) is export {
    @ROUTES.push: Route.new(kind => 'api', :$pattern, segments => split-path($pattern), :&body, title => '');
}

#| Register a handler that owns its response. The block gets the route's
#| parameters, as a page's does, and returns a `Response`, an `Element` (a
#| whole document, when it is `html`), or a Str of HTML. `:methods` limits it,
#| as in `route '/login', :methods<POST>, { … }`.
sub route(Str $pattern, &body, :$methods --> Route) is export {
    my $r = Route.new(kind => 'route', :$pattern, segments => split-path($pattern), :&body,
                      title => '', methods => ($methods // ()).list.map(*.uc).Array);
    @ROUTES.push: $r;
    $r;
}

#| What to answer when no route matches. The block gets the path, and its
#| answer is treated as a `route`'s is; a bare Str or Element goes out as 404.
sub fallback(&body) is export { &FALLBACK = &body }

#| Serve files under `$dir` at the URL prefix `$prefix`.
sub static(Str $prefix, Str $dir) is export { @STATIC.push: ($prefix, $dir) }

#| Register an `is server` sub so the browser can call it. `serve` does this for
#| every one the program declares; a program may also do it by hand.
sub server-sub(Str $name, &code) is export { %RPC{$name} = &code }

# The `is server` routines, in declaration order. The trait lives in Webraku.rakumod
# — it has to, so an application's `sub … is server` can see it — but the list
# belongs here, where `serve` publishes it and `record-call` fills the log.
# Registering at DECLARATION and not in `serve` is what lets `handle` answer an
# `/_rpc/` call with no port and no server started — which is how t/02-server.t
# checks the whole endpoint.
my @SERVER-SUBS;
sub webraku-register(Routine $r) is export {
    @SERVER-SUBS.push: $r;
    %RPC{$r.name} = $r;
}
sub webraku-server-subs() is export { @SERVER-SUBS }

# The sources Webraku::Client hands out in the browser. On the server they are
# empty and already finished, for the same reason an element's events are: a
# `whenever every(1) { … }` in a page body must not keep the render waiting.
sub every(Real $seconds --> Supply) is export { Supply.from-list() }
sub after(Real $seconds --> Supply) is export { Supply.from-list() }

#| The browser's global object, for what the builders do not cover:
#| `window().history.replaceState(…)`, `window().navigator.clipboard.writeText($s)`.
#| There is no browser on the server, so it answers a stand-in that takes any
#| call and does nothing: a page body runs there only to render, and its
#| handlers never run there at all.
class NoWindow {
    method FALLBACK($, |) { self }
    method AT-KEY($)      { self }
    method Bool(--> False) { }
    method Str(--> '')     { }
}
sub window() is export { NoWindow }

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

# ---------- the mount point ----------
#
# An application can live under a path rather than at the root of its host:
# `web.raku.online/sudoku/` is one program and `/wavelet/` another, each
# behind the same proxy. The routes stay written from `/` — a program does not
# know where it will be mounted — and the base is set from outside, by
# `serve :base</sudoku>` or WEBRAKU_BASE. A request that arrives with the base
# still on is answered as if it had not, so the proxy may strip it or not.

sub normalize-base(Str $b --> Str) {
    my $s = $b.trim.subst(/ '/'+ $ /, '');
    $s && !$s.starts-with('/') ?? "/$s" !! $s;
}

#| Set the mount point. `serve` calls this; a test may call it directly.
sub webraku-base(Str $b) is export { $BASE = normalize-base($b) }

#| Set the longest request body read, in bytes. `serve :max-body` calls this;
#| a test may call it directly.
sub webraku-max-body(Int $n) is export { $MAX-BODY = $n }

#| A path inside this application, as the browser must ask for it: `url('/char/41')`
#| is `/char/41` at the root and `/unicode/char/41` under `/unicode`. The
#| browser half has the same sub, reading the base the page carries.
sub url(Str $path = '/' --> Str) is export {
    $BASE ~ ($path.starts-with('/') ?? $path !! "/$path");
}

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
            fetch("$BASE/_webraku/version").then(function (r) \{ return r.text() \})
              .then(function (t) \{ if (t.trim() !== v) location.reload() \});
          \}, 700);
        \})();
        </script>
        DEV

    # The bundle's URL carries the server's start time: it is cached for good
    # (see `handle`), and a restart, which is what a new build needs, asks for
    # a new one.
    qq:to/HTML/;
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <meta name="webraku-base" content="{escape-html($BASE)}">
    <title>{escape-html($title)}</title>
    <style>{$css}</style>
    </head>
    <body>
    {$body-html}
    <script id="webraku-replay" type="application/json">{$replay}</script>
    <script src="{escape-html($BASE)}/_webraku/client.js?v=$VERSION"></script>
    {$dev-script}
    </body>
    </html>
    HTML
}

# ---------- the replay log ----------
#
# While a page renders, every `is server` call is recorded. The browser replays
# the log instead of making the same calls again, so the first client render
# matches the server's without a round trip.
#
# The log is a dynamic variable, declared by the render that fills it. It used
# to be one variable for the whole server, and the server answers each
# connection on a thread of its own: two pages rendering at once then emptied
# each other's log, and a page whose `is server` calls took a second lost its
# log to any request that arrived in that second. An RPC call from the browser
# runs outside any render, sees no log, and records nothing.

#| Call an `is server` sub and record it. The server calls its subs through
#| here; the browser's stub reads the recording.
sub record-call(Str $name, @args, \result) is export {
    my $log = $*WEBRAKU-LOG // Nil;
    $log.push: %( :$name, :args(@args.Array), result => result ) if $log ~~ Array;
    result;
}

# ---------- rendering a page ----------

sub render-page(Route $r, %params, Request $req --> Str) {
    my $*WEBRAKU-LOG = [];
    my $*WEBRAKU-STACK = [];
    my $root = Element.new(tag => 'div', attrs => { id => 'webraku-root' });
    {
        my $*WEBRAKU-REQUEST = $req;
        $REQUEST = $req;
        my @args = $r.param-names.map({ %params{$_} });
        with-parent($root, { $r.body.(|@args) });
    }
    my $replay = to-json($*WEBRAKU-LOG);
    document($r.title, $root.html, $replay, css => webraku-css());
}

my $CSS = '';
sub stylesheet(Str $css) is export { $CSS = $css }
sub webraku-css(--> Str) { $CSS }

# ---------- HTTP ----------

my %REASON = 200 => 'OK', 204 => 'No Content', 301 => 'Moved Permanently', 302 => 'Found',
             303 => 'See Other', 304 => 'Not Modified', 400 => 'Bad Request', 401 => 'Unauthorized',
             403 => 'Forbidden', 404 => 'Not Found', 405 => 'Method Not Allowed',
             410 => 'Gone', 413 => 'Payload Too Large', 500 => 'Internal Server Error';

my %MIME = html => 'text/html; charset=utf-8', js => 'text/javascript; charset=utf-8',
           css => 'text/css; charset=utf-8', json => 'application/json; charset=utf-8',
           svg => 'image/svg+xml', png => 'image/png', jpg => 'image/jpeg',
           gif => 'image/gif', ico => 'image/x-icon', txt => 'text/plain; charset=utf-8',
           woff2 => 'font/woff2', map => 'application/json',
           jpeg => 'image/jpeg', webp => 'image/webp', svgz => 'image/svg+xml',
           bmp => 'image/bmp', tif => 'image/tiff', tiff => 'image/tiff',
           woff => 'font/woff', ttf => 'font/ttf', otf => 'font/otf', eot => 'application/vnd.ms-fontobject',
           pdf => 'application/pdf', zip => 'application/zip', gz => 'application/gzip',
           xml => 'application/xml; charset=utf-8', rss => 'application/rss+xml; charset=utf-8',
           mp3 => 'audio/mpeg', ogg => 'audio/ogg', wav => 'audio/wav', m4a => 'audio/mp4',
           mp4 => 'video/mp4', webm => 'video/webm', mov => 'video/quicktime',
           doc => 'application/msword', ppt => 'application/vnd.ms-powerpoint',
           xls => 'application/vnd.ms-excel', csv => 'text/csv; charset=utf-8',
           md => 'text/plain; charset=utf-8', raku => 'text/plain; charset=utf-8',
           pl => 'text/plain; charset=utf-8', py => 'text/plain; charset=utf-8';

#| The MIME type for a file name, by its extension.
sub mime-type(Str $name --> Str) is export {
    %MIME{$name.IO.extension.lc} // 'application/octet-stream';
}

#| What a `route` or `fallback` block returned, as (status, type, body, headers).
sub answer($out, Int :$status = 200 --> List) {
    given $out {
        when Response { return (.status, .type, .body, .headers.List) }
        when Element  {
            my $html = .html;
            $html = "<!DOCTYPE html>\n" ~ $html if .tag eq 'html';
            return ($status, %MIME<html>, $html, ());
        }
        when Raw      { return ($status, %MIME<html>, .html, ()) }
        default       { return ($status, %MIME<html>, ($_ // '').Str, ()) }
    }
}

#| A query or form value: `+` is a space, and each run of %XX octets is UTF-8,
#| as browsers send it, read the way a path segment is.
sub url-decode(Str $s --> Str) {
    url-decode-segment($s.subst('+', ' ', :g));
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
#|
#| The answer is (status, type, body, headers): the body is a Str or, for a
#| file, a Blob, and the headers are a list of pairs beyond the two every
#| response carries.
sub handle(Str $method, Str $target, %headers, Str $body --> List) is export {
    my ($path, $qs) = $target.split('?', 2);
    if $BASE && ($path eq $BASE || $path.starts-with("$BASE/")) {
        $path = $path.substr($BASE.chars) || '/';
    }
    my %query = parse-query($qs // '');
    my $req = Request.new(:$method, :$path, :%query, :%headers, :$body);
    my $*WEBRAKU-REQUEST = $req;

    return (200, 'text/plain; charset=utf-8', $VERSION) if $path eq '/_webraku/version';
    return (200, %MIME<js>, $CLIENT-JS, ('Cache-Control' => 'public, max-age=31536000, immutable',))
        if $path eq '/_webraku/client.js' && !$DEV;
    return (200, %MIME<js>, $CLIENT-JS)                 if $path eq '/_webraku/client.js';

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
        my $*WEBRAKU-REQUEST = $req;
        my $result = try $fn(|@args);
        return (500, %MIME<json>, to-json(%( error => ~$! ))) if $!;
        return (200, %MIME<json>, to-json(%( :$result )));
    }

    # A file is read as bytes: an image slurped as text is an image no longer.
    # The path is decoded first, so a file whose name is not ASCII is found.
    for @STATIC -> ($prefix, $dir) {
        next unless $path.starts-with($prefix);
        my $rel = split-path($path.substr($prefix.chars)).map(&url-decode-segment).join('/');
        return (403, %MIME<txt>, 'no', ()) if $rel.split('/').grep('..') || $rel.contains("\0");
        my $file = $dir.IO.add($rel);
        # A directory answers with its index.html, as a web server's would; and
        # without its trailing slash it is redirected to it, or the page's
        # relative links would resolve one level too high.
        if $file.d && $file.add('index.html').f {
            return (301, %MIME<html>, '', ('Location' => $path ~ '/' ~ ($qs ?? "?$qs" !! ''),))
                unless $path.ends-with('/');
            $file = $file.add('index.html');
        }
        next unless $file.f;
        return (200, mime-type($file.basename), $file.slurp(:bin),
                ('Cache-Control' => 'public, max-age=86400',));
    }

    my ($route, %params) = match-route(@ROUTES, $path);
    without $route {
        if &FALLBACK {
            my $out = try FALLBACK($path);
            return (500, %MIME<html>, document('Error', '<h1>500</h1><pre>' ~ escape-html(~$!) ~ '</pre>', '[]'), ()) if $!;
            return answer($out, status => 404);
        }
        return (404, %MIME<html>, document('Not found',
            '<h1>404</h1><p>' ~ escape-html($path) ~ ' is not a route this program declares.</p>', '[]'), ());
    }
    return (405, %MIME<txt>, 'method not allowed', ()) unless $method eq 'GET' | 'POST' | 'HEAD';

    $req.params = %params;
    if $route.kind eq 'route' {
        return (405, %MIME<txt>, 'method not allowed', ())
            if $route.methods && $method ne any($route.methods) && !($method eq 'HEAD' && 'GET' eq any($route.methods));
        my @args = $route.param-names.map({ %params{$_} });
        $REQUEST = $req;
        my $out = try $route.body.(|@args);
        if $! {
            my $why = $!.message ~ "\n" ~ ($!.backtrace.Str // '');
            note "webraku: $method $target: {$!.message}";
            return (500, %MIME<html>, document('Error', '<h1>500</h1><pre>' ~ escape-html($why) ~ '</pre>', '[]'), ());
        }
        return answer($out);
    }
    if $route.kind eq 'api' {
        my @args = $route.param-names.map({ %params{$_} });
        $REQUEST = $req;
        my $*WEBRAKU-REQUEST = $req;
        my $out = try $route.body.(|@args);
        return (500, %MIME<json>, to-json(%( error => ~$! )), ()) if $!;
        return answer($out) if $out ~~ Response;
        return (200, %MIME<json>, to-json($out), ());
    }
    my $html = try render-page($route, %params, $req);
    if $! {
        my $why = ~$!;
        return (500, %MIME<html>, document('Error',
            '<h1>500</h1><pre>' ~ escape-html($why) ~ '</pre>', '[]'), ()) ;
    }
    (200, %MIME<html>, $html, ());
}

#| Read the head of a request, and the body after it, as BYTES: a body is only
#| text when its type says so, and an uploaded image decoded chunk by chunk
#| is an image no longer. Answers (head text, body bytes).
sub read-request($conn) {
    my $buf = Buf.new;
    loop {
        # latin-1 maps each byte to one character and back, but "\r\n" is ONE
        # character in a Raku string, so a position in the text is not a
        # position in the bytes: the split is done in the text and each half
        # encoded back.
        my $text = $buf.decode('latin-1');
        for "\r\n\r\n", "\n\n" -> $sep {
            with $text.index($sep) -> $i {
                return ($text.substr(0, $i).encode('latin-1').decode('utf8-c8'),
                        Buf.new($text.substr($i + $sep.chars).encode('latin-1')));
            }
        }
        last if $buf.bytes > 1_000_000;
        my $chunk = $conn.recv(:bin) // last;
        last unless $chunk.bytes;
        $buf.append: $chunk;
    }
    ('', Buf.new);
}

sub serve-one($conn, Bool :$log = True) is export {
    my ($head-text, $body-bytes) = read-request($conn);
    return unless $head-text.chars;
    my @lines = $head-text.lines;
    my ($method, $target) = (@lines[0] // '').split(/\s+/);
    return unless $method && $target;
    my %headers;
    for @lines[1..*] -> $l {
        my ($k, $v) = $l.split(':', 2);
        %headers{$k.lc.trim} = ($v // '').trim if $v.defined;
    }
    # A body longer than the first packet needs the rest of it — up to a limit,
    # since the length is the client's word.
    my $len = (try (%headers<content-length> // '0').Int) // 0;
    if $len > $MAX-BODY {
        $conn.write: "HTTP/1.1 413 Payload Too Large\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".encode;
        $conn.close;
        note sprintf('  413 %-4s %s', $method, $target) if $log;
        return;
    }
    while $body-bytes.bytes < $len {
        my $chunk = $conn.recv(:bin) // last;
        last unless $chunk.bytes;
        $body-bytes.append: $chunk;
    }
    my $body = $body-bytes.decode('utf8-c8');
    my $*WEBRAKU-RAW-BODY = $body-bytes;
    my ($status, $type, $text, $extra) = handle($method, $target, %headers, $body);
    my $bytes = $text ~~ Blob ?? $text !! $text.Str.encode('utf8-c8');
    my @extra = ($extra // ()).list;
    note sprintf('  %d %-4s %s', $status, $method, $target) if $log;
    my $head = "HTTP/1.1 $status {%REASON{$status} // 'OK'}\r\n" ~
        "Content-Type: $type\r\n" ~
        "Content-Length: {$bytes.bytes}\r\n";
    $head ~= "Cache-Control: no-store\r\n" unless @extra.first(*.key.lc eq 'cache-control');
    # A header value is one line: a stray CR or LF in it would start a header
    # the handler never wrote.
    $head ~= "{.key}: {.value.Str.subst(/<[\r\n]>/, '', :g)}\r\n" for @extra;
    $head ~= "Connection: close\r\n\r\n";
    $conn.write: $head.encode('utf8-c8') ~ ($method eq 'HEAD' ?? Blob.new !! $bytes);
    $conn.close;
}

#| Start the server. `$client-js` is the transpiled bundle, served at
#| /_webraku/client.js and referenced by every page. `$base` mounts the
#| application under a path (see `url`).
#|
#| `:workers` bounds how many requests are answered at once: that many threads
#| take connections from a queue. The default, 0, answers each connection on a
#| thread of its own. `:max-body` is the longest request body read, in bytes,
#| a megabyte unless it is set (or WEBRAKU_MAX_BODY is); a longer one is
#| answered 413 unread. An application that takes uploads raises it.
sub serve(Int :$port is copy = 8080, Str :$host is copy = '127.0.0.1', Str :$client-js is copy = '',
          Bool :$dev is copy = False, Bool :$log = True, Str :$base is copy = '', Int :$workers = 0,
          Int :$max-body is copy) is export {
    # `webraku run` builds the bundle and names it here, so that the program
    # itself carries no build concern: an application's last line is `serve;`
    # whether it was started by the tool or by hand.
    with %*ENV<WEBRAKU_CLIENT_JS_FILE> -> $f {
        $client-js = $f.IO.slurp if !$client-js && $f.IO.e;
    }
    $port = +$_ with %*ENV<WEBRAKU_PORT>;
    $host = $_  with %*ENV<WEBRAKU_HOST>;
    $base = $_  with %*ENV<WEBRAKU_BASE>;
    $max-body = +$_ with %*ENV<WEBRAKU_MAX_BODY>;
    $dev  = True if %*ENV<WEBRAKU_DEV>;
    $CLIENT-JS = $client-js;
    $DEV = $dev;
    webraku-base($base);
    webraku-max-body($_) with $max-body;
    my $listener = IO::Socket::INET.new(:localhost($host), :localport($port), :listen);
    note "webraku: http://$host:$port$BASE/" ~ ($dev ?? '  (dev: the page reloads when the program changes)' !! '');
    note "webraku: {@ROUTES.elems} routes, {%RPC.elems} server subs, client bundle {$client-js.chars} chars";
    if $workers > 0 {
        my $queue = Channel.new;
        for ^$workers {
            start {
                loop {
                    my $conn = $queue.receive;
                    my $r = try serve-one($conn, :$log);
                    note "webraku: $!" if $!;
                }
            }
        }
        loop { $queue.send: $listener.accept }
    }
    loop {
        my $conn = $listener.accept;
        start {
            my $r = try serve-one($conn, :$log);
            note "webraku: $!" if $!;
        }
    }
}
