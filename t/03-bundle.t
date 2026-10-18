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

# a name in prose — a comment, or the text of a string — is not a call
my $prose = q:to/APP/;
    use Secret;
    # read-db is server-side
    p raw('<code>read-db</code> stays on the server');
    p "and so does read-db, says {shape-of(1)}";
    APP
is-it ?strip-uses($prose, beside => $dir, client => $prose).contains('use Secret;'), 'False',
    'a name mentioned in a comment or a string does not keep its module';
my $interp = "use Secret;\np \"value: \{read-db('k')\}\";\n";
is-it ?strip-uses($interp, beside => $dir, client => $interp).contains('use Secret;'), 'True',
    Q[a call inside a string's {…} block does];
my $amp = "use Secret;\np \"value: \&read-db('k')\";\n";
is-it ?strip-uses($amp, beside => $dir, client => $amp).contains('use Secret;'), 'True',
    'and so does an interpolated &call';
is-it code-only("say 'a # b'; # gone\nmy \$x = 1;"), "say ''; \nmy \$x = 1;", 'code-only blanks string text and comments';
is-it code-only("sub isn't-it() \{ 'x' \}"), "sub isn't-it() \{ '' \}", 'an apostrophe inside a name is not a quote';

# an array parameter goes to the server as one argument, not spread out
my $arr = "sub names(\@cps, \%opt, \$n) is server \{ \@cps.elems \}\n";
is-it ?stub-server-subs($arr).contains("webraku-call('names', [\$(\@cps), \$(\%opt), \$n])"), 'True',
    'an @ or % parameter is passed itemized';

say "1..$n";
say $bad ?? "# $bad of $n checks FAILED" !! "# all $n checks passed";
exit $bad ?? 1 !! 0;
