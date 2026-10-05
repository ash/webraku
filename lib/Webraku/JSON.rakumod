# Webraku::JSON — the JSON the framework needs, and no more.
#
# The framework has no dependencies, so it carries its own. It is small on
# purpose: what crosses between the server and the browser is plain data —
# numbers, strings, booleans, arrays, hashes, Nil — which is exactly the
# marshalling table `use JS` states, and exactly what JSON describes.
#
# It runs on both engines and under `--target=js`, where it is what the RPC
# stub encodes its arguments with. (The browser could use its own JSON.parse
# through `use JS`; one implementation on both sides is one thing to be wrong.)
unit module Webraku::JSON;

# ---------- writing ----------

sub json-escape(Str $s --> Str) is export {
    my $out = $s.trans(['\\', '"', "\n", "\r", "\t", "\b", "\f"]
                    => ['\\\\', '\\"', '\\n', '\\r', '\\t', '\\b', '\\f']);
    # The control characters below 0x20 that have no short escape, and the two
    # line separators, which are legal in JSON but not in a JavaScript string
    # literal — a page embeds this text in a <script>.
    $out.=subst(/<[\x00..\x07\x0b\x0e..\x1f\x2028\x2029]>/, { sprintf('\u%04x', $/.Str.ord) }, :g);
    # `</script>` inside the embedded replay log would close the tag.
    $out.subst('</', '<\\/', :g);
}

multi sub to-json(Nil     --> Str) is export { 'null' }
multi sub to-json(Any:U   --> Str) is export { 'null' }
multi sub to-json(Bool:D $b --> Str) is export { $b ?? 'true' !! 'false' }
multi sub to-json(Int:D  $i --> Str) is export { $i.Str }
multi sub to-json(Rat:D  $r --> Str) is export { $r.Num.Str }
multi sub to-json(Num:D  $n --> Str) is export { $n == $n.Int ?? $n.Int.Str !! $n.Str }
multi sub to-json(Str:D  $s --> Str) is export { '"' ~ json-escape($s) ~ '"' }
multi sub to-json(Positional:D $a --> Str) is export { '[' ~ $a.map({ to-json($_) }).join(',') ~ ']' }
multi sub to-json(Associative:D $h --> Str) is export {
    '{' ~ $h.keys.sort.map({ '"' ~ json-escape($_.Str) ~ '":' ~ to-json($h{$_}) }).join(',') ~ '}'
}
multi sub to-json(Pair:D $p --> Str) is export { '{"' ~ json-escape($p.key.Str) ~ '":' ~ to-json($p.value) ~ '}' }
multi sub to-json(Any:D  $x --> Str) is export { to-json($x.Str) }

# ---------- reading ----------

class X::JSON is Exception {
    has Str $.reason;
    has Int $.at;
    method message() { "JSON: $!reason at character $!at" }
}

#| Parse JSON text. Objects become Hashes, arrays Arrays, `null` Nil.
sub from-json(Str $text) is export {
    my @c = $text.comb;
    my $i = 0;

    sub fail-at(Str $why) { die X::JSON.new(reason => $why, at => $i) }
    sub ws() { $i++ while $i < @c && @c[$i] eq ' ' | "\t" | "\n" | "\r" }
    sub lit(Str $word, $value) {
        fail-at("expected $word") unless $text.substr($i, $word.chars) eq $word;
        $i += $word.chars;
        $value;
    }
    sub string() {
        fail-at('expected a string') unless @c[$i] eq '"';
        $i++;
        my $out = '';
        while $i < @c && @c[$i] ne '"' {
            if @c[$i] eq '\\' {
                $i++;
                my $e = @c[$i++];
                $out ~= $e eq 'n' ?? "\n" !! $e eq 't' ?? "\t" !! $e eq 'r' ?? "\r"
                     !! $e eq 'b' ?? "\b" !! $e eq 'f' ?? "\f"
                     !! $e eq 'u' ?? do { my $h = $text.substr($i, 4); $i += 4; chr(:16($h)) }
                     !! $e;
            }
            else { $out ~= @c[$i++] }
        }
        fail-at('unterminated string') unless $i < @c;
        $i++;
        $out;
    }
    sub number() {
        my $b = $i;
        $i++ if @c[$i] eq '-';
        $i++ while $i < @c && @c[$i] ~~ /<[0..9]>/;
        my $float = False;
        if $i < @c && @c[$i] eq '.' { $float = True; $i++; $i++ while $i < @c && @c[$i] ~~ /<[0..9]>/ }
        if $i < @c && @c[$i] eq 'e' | 'E' {
            $float = True; $i++;
            $i++ if $i < @c && (@c[$i] eq '+' | '-');
            $i++ while $i < @c && @c[$i] ~~ /<[0..9]>/;
        }
        my $lex = $text.substr($b, $i - $b);
        fail-at('expected a number') unless $lex.chars;
        $float ?? $lex.Num !! $lex.Int;
    }
    sub value() {
        ws();
        fail-at('unexpected end of input') unless $i < @c;
        given @c[$i] {
            when '{' {
                $i++;
                my %h;
                ws();
                if @c[$i] eq '}' { $i++; return %h }
                loop {
                    ws();
                    my $k = string();
                    ws();
                    fail-at("expected ':'") unless @c[$i] eq ':';
                    $i++;
                    %h{$k} = value();
                    ws();
                    if    @c[$i] eq ',' { $i++ }
                    elsif @c[$i] eq '}' { $i++; last }
                    else { fail-at("expected ',' or '}'") }
                }
                %h;
            }
            when '[' {
                $i++;
                my @a;
                ws();
                if @c[$i] eq ']' { $i++; return @a }
                loop {
                    @a.push: value();
                    ws();
                    if    @c[$i] eq ',' { $i++ }
                    elsif @c[$i] eq ']' { $i++; last }
                    else { fail-at("expected ',' or ']'") }
                }
                @a;
            }
            when '"' { string() }
            when 't' { lit('true', True) }
            when 'f' { lit('false', False) }
            when 'n' { lit('null', Nil) }
            default  { number() }
        }
    }

    my $v = value();
    ws();
    fail-at('trailing text') if $i < @c;
    $v;
}
