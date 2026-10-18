#!/usr/bin/env rakupp
# run.raku — the Webraku demos as one site.
#
#     rakupp demo/run.raku                     build every demo, run each on its port
#     rakupp demo/run.raku --proxy=8080        …and serve them all on one port, for a try
#     rakupp demo/run.raku --only=sudoku,hub   a few of them
#     rakupp demo/run.raku caddy webraku.raku.online    print the Caddyfile
#
# demos.txt says what runs where. Each demo is its own process: a Webraku
# program owns its routes and its `is server` subs, and one that dies takes no
# other with it. Each is started with WEBRAKU_BASE set to its mount, so it
# answers under `/sudoku/` and writes its links and its bundle's URL there; the
# proxy in front leaves the path as it is.
#
# A demo that stops is started again, after a second, doubling up to a minute
# while it keeps stopping.
use lib $?FILE.IO.parent.Str;
use Demos;

my $ROOT  = $?FILE.IO.parent.parent;
my $LIB   = $ROOT.add('lib');
my $TOOL  = $ROOT.add('bin/webraku');

sub bundle-of(IO::Path $app --> IO::Path) {
    $app.parent.add($app.basename.subst(/ '.raku' $ /, '') ~ '.client.js')
}

#| Build one demo's browser half, as `webraku build` does.
sub build(%d --> Bool) {
    my $app = $ROOT.add(%d<app>);
    my $p = run $*EXECUTABLE, $TOOL, 'build', $app, :out, :err;
    my $out = $p.out.slurp(:close);
    my $err = $p.err.slurp(:close);
    note "[%d<name>] {$out.trim || $err.trim}";
    $p.exitcode == 0
}

#| Run one demo, and start it again whenever it stops.
sub supervise(%d, Str $host) {
    my $app = $ROOT.add(%d<app>);
    my $wait = 1;
    loop {
        my $t0 = now;
        my %env = %*ENV;
        %env<WEBRAKU_PORT> = ~%d<port>;
        %env<WEBRAKU_HOST> = $host;
        %env<WEBRAKU_BASE> = %d<mount>;
        %env<WEBRAKU_CLIENT_JS_FILE> = ~bundle-of($app);
        my $p = Proc::Async.new($*EXECUTABLE, '-I', ~$LIB, ~$app);
        $p.stdout.lines.tap: -> $l { say  "[%d<name>] $l" };
        $p.stderr.lines.tap: -> $l { note "[%d<name>] $l" };
        my $r = await $p.start(:ENV(%env));
        $wait = now - $t0 > 60 ?? 1 !! ($wait * 2) min 60;
        note "[%d<name>] stopped with exit code {$r.exitcode}; starting again in {$wait} s";
        sleep $wait;
    }
}

# ---------- a proxy, for trying the site on one port ----------
#
# Not for production — Caddy or nginx does that, with TLS. Enough to click
# from the hub into each demo on a laptop: it picks the demo by the longest
# mount the path starts with, passes the request on unchanged but for
# `Connection: close` and `X-Forwarded-For`, and relays the answer.

sub read-head($conn --> List) {
    my $buf = Buf.new;
    until (my $at = find-blank($buf)).defined {
        my $chunk = $conn.recv(:bin) // last;
        last unless $chunk.bytes;
        $buf ~= $chunk;
        return (Nil, Buf.new) if $buf.bytes > 65536;
    }
    return (Nil, Buf.new) without $at;
    ($buf.subbuf(0, $at).decode('latin-1'), $buf.subbuf($at + 4))
}

sub find-blank(Buf $b) {
    for 0 .. $b.bytes - 4 -> $i {
        return $i if $b[$i] == 13 && $b[$i + 1] == 10 && $b[$i + 2] == 13 && $b[$i + 3] == 10;
    }
    Nil
}

sub proxy-one($conn, @demos) {
    my ($head, $rest) = read-head($conn);
    without $head { $conn.close; return }
    my @lines = $head.split("\r\n");
    my ($method, $target) = @lines[0].words;
    my $path = $target.split('?')[0];
    my $d = @demos.grep({ !.<mount> || $path eq .<mount> || $path.starts-with(.<mount> ~ '/') })
                  .max(*<mount>.chars);
    if $d<mount> && $path eq $d<mount> {
        $conn.write: "HTTP/1.1 301 Moved Permanently\r\nLocation: {$d<mount>}/\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".encode;
        $conn.close;
        return;
    }
    my @keep = @lines[1..*].grep({ !.lc.starts-with('connection:') });
    my $len = (@keep.first(*.lc.starts-with('content-length:')) // 'x: 0').split(':')[1].trim.Int;
    my $body = $rest;
    while $body.bytes < $len {
        my $chunk = $conn.recv(:bin) // last;
        last unless $chunk.bytes;
        $body ~= $chunk;
    }
    my $up = IO::Socket::INET.new(:host<127.0.0.1>, :port($d<port>));
    $up.write: ("$method $target HTTP/1.1\r\n" ~ @keep.join("\r\n")
               ~ "\r\nX-Forwarded-For: 127.0.0.1\r\nConnection: close\r\n\r\n").encode('latin-1') ~ $body;
    while $up.recv(:bin) -> $chunk {
        last unless $chunk.bytes;
        $conn.write: $chunk;
    }
    $up.close;
    $conn.close;
}

sub proxy(Int $port, @demos) {
    my $listener = IO::Socket::INET.new(:localhost<127.0.0.1>, :localport($port), :listen);
    note "proxy: http://127.0.0.1:$port/ — " ~ @demos.map({ "{.<mount> || '/'} → {.<port>}" }).join(', ');
    loop {
        my $conn = $listener.accept;
        start {
            try proxy-one($conn, @demos);
            note "proxy: $!" if $!;
        }
    }
}

# ---------- the commands ----------

multi sub MAIN(Str :$only = '', Str :$host = '127.0.0.1', Int :$proxy, Bool :$no-build = False) {
    my @demos = read-demos($ROOT.add('demo/demos.txt'));
    @demos = @demos.grep({ .<name> eq any($only.split(',')) }) if $only;
    die "run.raku: no demo matches '$only'" unless @demos;
    # One build at a time: each is a full transpile, and a small server is
    # better off doing them in turn.
    unless $no-build {
        for @demos -> %d { build(%d) or die "run.raku: %d<name> did not build" }
    }
    my @runs = @demos.map(-> %d { start supervise(%d, $host) });
    @runs.push: start proxy($proxy, @demos) if $proxy;
    await @runs;
}

#| The Caddyfile for serving the demos at `$domain`. Caddy fetches and renews
#| the certificate itself, and compresses the answers; the bundles are about
#| half a megabyte each before that.
multi sub MAIN('caddy', Str $domain) {
    my @demos = read-demos($ROOT.add('demo/demos.txt'));
    say "# The Webraku demos at $domain — generated by `rakupp demo/run.raku caddy $domain`";
    say "# from demo/demos.txt. Each demo strips its own mount, so the path is passed on as it is.";
    say "$domain \{";
    say "    encode zstd gzip";
    for @demos.grep(*<mount>) -> %d {
        say '';
        say "    redir %d<mount> %d<mount>/ permanent";
        say "    handle %d<mount>/* \{";
        say "        reverse_proxy 127.0.0.1:%d<port>";
        say "    }";
    }
    with @demos.first({ !.<mount> }) -> %d {
        say '';
        say "    handle \{";
        say "        reverse_proxy 127.0.0.1:%d<port>";
        say "    }";
    }
    say "}";
}
