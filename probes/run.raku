#!/usr/bin/env rakupp
# Runs the probes PLAN.md cites, on every engine that is present, and says
# which of them agree. Every probe carries a marker string that only the
# intended code path prints, so a silent no-op cannot pass as agreement.
#
#   rakupp probes/run.raku                # Rakudo from RAKUDO or /opt/homebrew/bin/raku,
#                                         # rakupp = the engine running this script
#   RAKUDO=/path/to/raku rakupp probes/run.raku
#
# bun runs the --target=js rows (RAKUPP_JS=node picks node instead). bun is the
# default because it runs an ES module `.js` without consulting a package.json,
# which is what makes node's answer depend on where the file happens to sit.

my $here   = $?FILE.IO.parent;
my $rakupp = $*EXECUTABLE.Str;
my $rakudo = %*ENV<RAKUDO> // '/opt/homebrew/bin/raku';
my $host   = %*ENV<RAKUPP_JS> // 'bun';
# `-r` is node's spelling for "load this first"; bun calls it `--preload`.
my $preload = $host.contains('node') ?? '-r' !! '--preload';
my $stub   = $here.add('dom-stub.js').absolute;
my $tmp    = $*TMPDIR.add('rakuact-probes');
$tmp.mkdir;

sub out(*@cmd) {
    my $p = run |@cmd, :out, :err;
    my $o = $p.out.slurp(:close) ~ $p.err.slurp(:close);
    $o.trim;
}

# name => (file, marker, [engines])
my @probes =
    '01 builders → HTML string'  => ('01-builders.raku',      'P1-BUILDERS', <rakudo rakupp js>),
    '03 *%named slurpy'          => ('03-slurpy-named.raku',  'E: 1',        <rakudo rakupp js>),
    '04 `div` as a declared sub' => ('04-div-term.raku',      'div(txt)',    <rakudo rakupp>),
    '05 `tr { }` as a declared sub' => ('05-tr-term.raku',    'tr(&1)',      <rakudo rakupp>),
;

my $rakudo-ok = $rakudo.IO.x;
say "rakupp: $rakupp";
say "rakudo: " ~ ($rakudo-ok ?? $rakudo !! "$rakudo (not found — its column is skipped)");
say '';

for @probes -> (:key($name), :value(($file, $marker, @engines))) {
    my $src = $here.add($file).Str;
    my %got;
    %got<rakudo> = out($rakudo, $src) if 'rakudo' ∈ @engines && $rakudo-ok;
    %got<rakupp> = out($rakupp, $src) if 'rakupp' ∈ @engines;
    if 'js' ∈ @engines {
        my $js = $tmp.add($file.subst(/ '.raku' $ /, '.js')).Str;
        my $t = out($rakupp, '--target=js', '--standalone', $src, '-o', $js);
        %got<js> = $js.IO.e ?? out($host, $js) !! "TRANSPILE REFUSED: $t";
    }
    say "== $name";
    for <rakudo rakupp js> -> $e {
        next unless %got{$e}:exists;
        my $o = %got{$e};
        my $line = $o.lines.first(*.contains($marker)) // $o.lines.head // '';
        my $verdict = $o.contains($marker) ?? 'ok  ' !! 'FAIL';
        printf "   %-6s %s  %s\n", $e, $verdict, $line.substr(0, 90);
    }
    if %got<rakudo>:exists && %got<rakupp>:exists {
        say "   rakudo and rakupp " ~ (%got<rakudo> eq %got<rakupp> ?? 'agree byte for byte' !! 'DIFFER');
    }
    if %got<js>:exists && %got<rakupp>:exists {
        say "   rakupp and js     " ~ (%got<js> eq %got<rakupp> ?? 'agree byte for byte' !! 'DIFFER');
    }
}

# 02 needs a DOM: the host with the stand-in preloaded. The marker proves the click
# path ran (clicked 2 times), not just that the script loaded.
say "== 02 client: DOM builders, click → Supply → react/whenever → reconcile";
my $src = $here.add('02-client.raku').Str;
my $js  = $tmp.add('02-client.js').Str;
my $t = out($rakupp, '--target=js', '--standalone', $src, '-o', $js);
if $js.IO.e {
    my $o = out($host, $preload, $stub, $js);
    my $ok = $o.contains('after clicks: clicked 2 times') && $o.contains('P3B-DOM <div id="app">');
    printf "   %-6s %s  %s\n", 'js', $ok ?? 'ok  ' !! 'FAIL', $o.lines.head // '';
}
else {
    say "   js     FAIL  transpile refused: $t";
}
