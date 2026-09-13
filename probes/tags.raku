#!/usr/bin/env rakupp
# Which HTML tag names can be bare builder subs? For every tag in the HTML
# living standard, declare `sub <tag>(*@k, *%a)` and call it in the three
# shapes the framework uses — `tag "txt", :id<x>`, `tag { … }`,
# `tag :id<y>, { … }` — on Rakudo and on rakupp. A tag passes on an engine
# when all three calls reach the sub.
#
#   rakupp probes/tags.raku            # prints the failures per engine

my $rakupp = $*EXECUTABLE.Str;
my $rakudo = %*ENV<RAKUDO> // '/opt/homebrew/bin/raku';
my $tmp    = $*TMPDIR.add('rakuact-tags');
$tmp.mkdir;

my @tags = <a abbr address area article aside audio b base bdi bdo blockquote
    body br button canvas caption cite code col colgroup data datalist dd del
    details dfn dialog div dl dt em embed fieldset figcaption figure footer
    form h1 h2 h3 h4 h5 h6 head header hgroup hr html i iframe img input ins
    kbd label legend li link main map mark menu meta meter nav noscript object
    ol optgroup option output p param picture pre progress q rp rt ruby s samp
    script search section select slot small source span strong style sub
    summary sup table tbody td template textarea tfoot th thead time title tr
    track u ul var video wbr>;

sub program(Str $t) {
    qq:to/END/;
    sub $t\(*\@k, *\%a) \{ "$t\(" ~ \@k.map(\{ \$_ ~~ Callable ?? "&" !! \$_ }).join(",") ~ ")" }
    say $t "txt", :id<x>;
    say $t \{ 1 };
    say $t :id<y>, \{ 1 };
    END
}

my %fail;
for @tags -> $t {
    my $f = $tmp.add("$t.raku");
    $f.spurt: program($t);
    my $want = "$t\(txt)\n$t\(&)\n$t\(&)";
    for rakudo => $rakudo, rakupp => $rakupp -> (:key($engine), :value($exe)) {
        next unless $exe.IO.x;
        my $p = run $exe, $f.Str, :out, :err;
        my $got = $p.out.slurp(:close).trim;
        $p.err.slurp(:close);
        %fail{$engine}.push($t) unless $got eq $want;
    }
}
say "{@tags.elems} tags, three call shapes each";
for <rakudo rakupp> -> $e {
    say "$e: " ~ (%fail{$e} ?? "fails on {%fail{$e}.join(' ')}" !! 'every tag passes');
}
