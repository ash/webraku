# Webraku::Route — the route table, shared by both halves.
#
# The server matches a request path against it; the browser matches
# `location.pathname` against the same table, built by the same `page` calls in
# the same program, and hydrates the one that answers. One implementation, so
# the two cannot drift apart — which for a framework whose whole claim is that
# the two renders agree is not a small thing.
unit module Webraku::Route;

class Route is export {
    has Str $.kind = 'page';     # 'page', 'api' or 'route'
    has @.methods;               # for a 'route': the methods it answers; empty = any
    has Str $.pattern;
    has @.segments;
    has &.body;
    has Str $.title = 'Webraku';

    #| The names of this route's variable segments, in order.
    #| A `:name` segment matches one segment; a `*name` segment, which may only
    #| come last, matches the rest of the path — one segment or more, joined
    #| with `/` again.
    method param-names() { @!segments.grep({ .starts-with(':') || .starts-with('*') }).map(*.substr(1)) }
}

sub split-path(Str $path --> List) is export { $path.split('/').grep(*.chars).List }

#| `%D0%BA` back into `к`. A path is matched segment by segment AFTER it is
#| split, so an encoded `/` (`%2F`) stays inside its segment and cannot invent
#| a route. This module is the browser's too, and the JavaScript target has no
#| Blob, so the UTF-8 is decoded by hand; a sequence that is not UTF-8 is left
#| as it came.
sub url-decode-segment(Str $s --> Str) is export {
    return $s unless $s.contains('%');
    my $out = '';
    my $i = 0;
    my $n = $s.chars;
    while $i < $n {
        my $c = $s.substr($i, 1);
        unless $c eq '%' && $i + 2 < $n + 1 && $s.substr($i + 1, 2) ~~ /^ <[0..9A..Fa..f]> ** 2 $/ {
            $out ~= $c;
            $i++;
            next;
        }
        # A run of %XX octets, decoded as one UTF-8 sequence.
        my @b;
        my $j = $i;
        while $j + 2 < $n + 1 && $s.substr($j, 1) eq '%' && $s.substr($j + 1, 2) ~~ /^ <[0..9A..Fa..f]> ** 2 $/ {
            @b.push: :16($s.substr($j + 1, 2));
            $j += 3;
        }
        my $text = utf8-octets(@b);
        $out ~= $text // $s.substr($i, $j - $i);
        $i = $j;
    }
    $out;
}

#| Octets as UTF-8 text, or Str when they are not UTF-8.
sub utf8-octets(@b --> Str) {
    my $out = '';
    my $k = 0;
    while $k < @b {
        my $x = @b[$k];
        my ($len, $cp) = $x < 0x80 ?? (1, $x)
                      !! $x +& 0xE0 == 0xC0 ?? (2, $x +& 0x1F)
                      !! $x +& 0xF0 == 0xE0 ?? (3, $x +& 0x0F)
                      !! $x +& 0xF8 == 0xF0 ?? (4, $x +& 0x07)
                      !! (0, 0);
        return Str if $len == 0 || $k + $len > @b;
        for 1 ..^ $len -> $m {
            my $y = @b[$k + $m];
            return Str unless $y +& 0xC0 == 0x80;
            $cp = ($cp +< 6) +| ($y +& 0x3F);
        }
        $out ~= chr($cp);
        $k += $len;
    }
    $out;
}

#| Match `$path` against `@routes`. Answers (route, params) or (Nil, {}).
sub match-route(@routes, Str $path, Str :$kind --> List) is export {
    my @want = split-path($path).map(&url-decode-segment);
    for @routes -> $r {
        next if $kind.defined && $r.kind ne $kind;
        my @seg = $r.segments;
        my $splat = @seg && @seg[*-1].starts-with('*');
        if $splat { next unless @want >= @seg }
        else      { next unless @seg == @want }
        my %params;
        my $ok = True;
        for ^@seg -> $i {
            if @seg[$i].starts-with('*')    { %params{@seg[$i].substr(1)} = @want[$i..*].join('/') }
            elsif @seg[$i].starts-with(':') { %params{@seg[$i].substr(1)} = @want[$i] }
            elsif @seg[$i] ne @want[$i]     { $ok = False; last }
        }
        return ($r, %params) if $ok;
    }
    (Nil, {});
}
