#!/usr/bin/env rakupp
# Builders on several threads at once, as a server builds pages: each thread's
# tree must hold its own elements and nothing else. With one parent stack for
# the module, eight threads built into each other's lists and none came out
# whole.
use lib $?FILE.IO.parent.parent.add('lib').Str;
use Webraku::HTML;

my $n = 0;
my $bad = 0;
sub is-it($got, $want, Str $desc) {
    $n++;
    if $got eq $want { say "ok $n - $desc" }
    else { $bad++; say "not ok $n - $desc"; say "#      got: $got"; say "# expected: $want" }
}

for ^3 -> $round {
    my @p = (^8).map: -> $t {
        start {
            my $ul = ul {
                for ^50 -> $i { li "t$t-$i"; sleep 0 if $i %% 10 }
                div { span "inner-$t" }
            };
            $ul.kids.grep(Element).grep({ .tag eq 'li' && .text.starts-with("t$t-") }).elems == 50
                && $ul.kids.elems == 51
                && $ul.kids[50].kids[0].text eq "inner-$t";
        }
    };
    is-it (await @p).grep(*.so).elems, 8, "round {$round + 1}: eight threads build eight whole trees";
}
is-it current-parent().defined, False, 'and leave no parent open';

say "1..$n";
say $bad ?? "# $bad of $n checks FAILED" !! "# all $n checks passed";
exit $bad ?? 1 !! 0;
