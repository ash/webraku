# Monarch::Route — the route table, shared by both halves.
#
# The server matches a request path against it; the browser matches
# `location.pathname` against the same table, built by the same `page` calls in
# the same program, and hydrates the one that answers. One implementation, so
# the two cannot drift apart — which for a framework whose whole claim is that
# the two renders agree is not a small thing.
unit module Monarch::Route;

class Route is export {
    has Str $.kind = 'page';     # 'page' or 'api'
    has Str $.pattern;
    has @.segments;
    has &.body;
    has Str $.title = 'Monarch';

    #| The names of this route's variable segments, in order.
    method param-names() { @!segments.grep(*.starts-with(':')).map(*.substr(1)) }
}

sub split-path(Str $path --> List) is export { $path.split('/').grep(*.chars).List }

#| Match `$path` against `@routes`. Answers (route, params) or (Nil, {}).
sub match-route(@routes, Str $path, Str :$kind --> List) is export {
    my @want = split-path($path);
    for @routes -> $r {
        next if $kind.defined && $r.kind ne $kind;
        my @seg = $r.segments;
        next unless @seg == @want;
        my %params;
        my $ok = True;
        for ^@seg -> $i {
            if @seg[$i].starts-with(':') { %params{@seg[$i].substr(1)} = @want[$i] }
            elsif @seg[$i] ne @want[$i]  { $ok = False; last }
        }
        return ($r, %params) if $ok;
    }
    (Nil, {});
}
