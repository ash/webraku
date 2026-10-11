#!/usr/bin/env rakupp
# Webraku::Bundle — which lines of an application reach the browser's program.
# Pure text work, so it runs identically under Raku++ and Rakudo.
use lib $?FILE.IO.parent.parent.add('lib').Str;
use Webraku::Bundle;

my $n = 0;
my $bad = 0;
sub is-it($got, $want, Str $desc) {
    $n++;
    if $got eq $want { say "ok $n - $desc" }
    else { $bad++; say "not ok $n - $desc"; say "#      got: $got"; say "# expected: $want" }
}

# An application directory with two modules beside it: one the browser's code
# calls, one only an `is server` body calls.
my $dir = $*TMPDIR.add("webraku-bundle-t-$*PID");
$dir.mkdir;
END { if $dir.e { .unlink for $dir.dir; $dir.rmdir } }
$dir.add('Shared.rakumod').spurt: "unit module Shared;\nsub shape-of(\$x) is export \{ \$x * 2 \}\nsub helper() \{ 1 \}\n";
$dir.add('Secret.rakumod').spurt: "unit module Secret;\nsub read-db(\$k) is export \{ \$k \}\n";

is-it module-exports($dir.add('Shared.rakumod')).join(','), 'shape-of', 'module-exports: the `is export` subs only';

my $app = q:to/APP/;
    use Webraku;
    use lib $?FILE.IO.parent.Str;
    use Shared;
    use Secret;
    sub load($k) is server { read-db($k) }
    page '/', { p ~shape-of(load('x')) }
    APP

my $client = stub-server-subs($app);
my $out = strip-uses($client, beside => $dir, client => $client);
is-it ?$out.contains('use Shared;'), 'True', 'a module the browser code calls is kept';
is-it ?$out.contains('use Secret;'), 'False', 'a module only an `is server` body calls is left out';
is-it ?$out.contains('use lib'), 'False', '`use lib` is left out';
is-it ?$out.contains('use Webraku;'), 'False', 'the framework\'s own `use` is left out';
is-it ?$out.contains("webraku-call('load'"), 'True', 'the server sub is a stub';

# a name only as part of a longer one does not count as a call
my $near = "use Secret;\nsub read-db-cached() \{ 1 \}\nread-db-cached();\n";
is-it ?strip-uses($near, beside => $dir, client => $near).contains('use Secret;'), 'False',
    'read-db-cached is not a call to read-db';

say "1..$n";
say $bad ?? "# $bad of $n checks FAILED" !! "# all $n checks passed";
exit $bad ?? 1 !! 0;
