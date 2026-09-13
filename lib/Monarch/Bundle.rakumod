# Monarch::Bundle — assembling the browser program.
#
# `rakupp --target=js` takes ONE file and refuses `use` of a user module, so the
# client bundle is concatenated here: the framework's client half, then the
# application, with the `use` and `unit module` lines stripped. This is the same
# step the three `--target=js` showcases in the rakupp repository perform by
# hand. When the emitter learns to resolve `use`, this file becomes a call to it
# and nothing else changes.
#
# Two rewrites happen on the way, and they are the whole of what makes one file
# run in two places:
#
#   1. A sub marked `is server` has its BODY replaced by a call to the RPC stub,
#      so the browser never carries the server's code — nor its database
#      handle, its file paths, or its secrets.
#   2. `serve` at the end of the program is dropped, and a `mount` is appended
#      in its place.
unit module Monarch::Bundle;

#| Strip the lines a concatenated file must not carry: `unit module X;`,
#| `use <a Monarch module>;` and `use lib …`. A `use` of something else (`use
#| JS`) is kept, because the transpiler handles that one itself.
sub strip-uses(Str $src --> Str) is export {
    $src.lines.map(-> $line {
        $line ~~ / ^ \s* 'unit' \s+ 'module' \s /                      ?? ''
     !! $line ~~ / ^ \s* 'use' \s+ 'lib' /                             ?? ''
     !! $line ~~ / ^ \s* 'use' \s+ 'Monarch' [ '::' \w+ ]? \s* ';' /   ?? ''
     !! $line;
    }).join("\n");
}

#| Find every `sub NAME(...) is server { ... }` in the source and report
#| (name, signature-text, body-start, body-end) for each. Brace counting, with
#| the strings and comments that would otherwise fool it skipped.
sub server-subs(Str $src --> List) is export {
    my @out;
    my @c = $src.comb;
    my $i = 0;
    while $i < @c {
        # skip a comment to end of line
        if @c[$i] eq '#' { $i++; $i++ while $i < @c && @c[$i] ne "\n"; next }
        # skip a quoted string
        if @c[$i] eq "'" || @c[$i] eq '"' {
            my $q = @c[$i++];
            while $i < @c && @c[$i] ne $q { $i += @c[$i] eq '\\' ?? 2 !! 1 }
            $i++;
            next;
        }
        if @c[$i] eq 's' && $src.substr($i, 4) eq 'sub ' &&
           ($i == 0 || @c[$i - 1] !~~ /<[\w\-&]>/) {
            my $j = $i + 4;
            $j++ while $j < @c && @c[$j] eq ' ';
            my $nb = $j;
            $j++ while $j < @c && @c[$j] ~~ /<[\w\-]>/;
            my $name = $src.substr($nb, $j - $nb);
            # the signature and traits, up to the body's `{`
            my $k = $j;
            my $depth = 0;
            while $k < @c && !($depth == 0 && @c[$k] eq '{') {
                $depth++ if @c[$k] eq '(';
                $depth-- if @c[$k] eq ')';
                last if @c[$k] eq ';' && $depth == 0;
                $k++;
            }
            my $head = $src.substr($i, $k - $i);
            if $k < @c && @c[$k] eq '{' && $head.contains('is server') {
                my $d = 0;
                my $e = $k;
                while $e < @c {
                    $d++ if @c[$e] eq '{';
                    $d-- if @c[$e] eq '}';
                    last if $d == 0 && @c[$e] eq '}';
                    $e++;
                }
                @out.push: %( :$name, :head($head), :head-start($i), :body-start($k), :body-end($e) );
                $i = $e + 1;
                next;
            }
        }
        $i++;
    }
    @out.List;
}

#| Replace each `is server` body with a call to the RPC stub. The signature is
#| kept exactly as written, so the browser's call site still type-checks, and
#| the parameters are forwarded by name.
sub stub-server-subs(Str $src --> Str) is export {
    my @found = server-subs($src);
    return $src unless @found;
    my $out = $src;
    # Back to front, so an earlier replacement does not move a later offset.
    for @found.reverse -> %f {
        my $head = %f<head>;
        # `is server` is a trait this framework invents; the stub does not carry it.
        my $stub-head = $head.subst(/ \s* 'is' \s+ 'server' /, '');
        my @params = signature-params($head);
        my $body = '{ await monarch-call(' ~ "'" ~ %f<name> ~ "', [" ~ @params.join(', ') ~ ']) }';
        $out = $out.substr(0, %f<head-start>.Int)
             ~ $stub-head ~ $body
             ~ $out.substr(%f<body-end>.Int + 1);
    }
    $out;
}

#| The parameter variables of a signature, in order, as they must be passed on.
sub signature-params(Str $head --> List) is export {
    my $open = $head.index('(');
    return () unless $open.defined;
    my $depth = 0;
    my $close = $open;
    my @c = $head.comb;
    while $close < @c {
        $depth++ if @c[$close] eq '(';
        $depth-- if @c[$close] eq ')';
        last if $depth == 0 && @c[$close] eq ')';
        $close++;
    }
    my $sig = $head.substr($open + 1, $close - $open - 1);
    $sig.split(',').map({ ($_ ~~ / ('$' || '@' || '%') (<[\w\-]>+) / ) ?? ~$/ !! Str })
        .grep(*.defined).List;
}
