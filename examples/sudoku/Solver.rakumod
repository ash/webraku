# Solver — the server's half of the Sudoku example: it solves, and it makes
# new puzzles.
#
# Only `is server` subs call it, so the bundler leaves `use Solver` out of the
# browser's script, and this file with it. A visitor who reads the page's
# JavaScript finds the rules (Rules.rakumod) and no way to the answer: the
# solution of the puzzle on the screen exists only on the server.
unit module Solver;

use Rules;

# Which box each cell is in, and how many bits each 9-bit mask has set.
my @BOX = (^81).map({ ($_ div 27) * 3 + ($_ % 9) div 3 });
my @POP = (^512).map({ .base(2).comb('1').elems });

#| Search for solutions, at most `$limit` of them. Answers `(count, first
#| solution)`; the solution is an empty list when there is none. `:shuffle`
#| tries the digits in a random order, which is how a fresh full grid is made.
#|
#| Depth-first, always on the empty cell with the fewest candidates, and
#| candidates kept as bit masks per row, column and box.
sub solve-grid(@cells, Int :$limit = 1, Bool :$shuffle = False --> List) is export {
    my int @g = @cells;
    my int @row = 0 xx 9;
    my int @col = 0 xx 9;
    my int @box = 0 xx 9;
    for ^81 -> $i {
        my $d = @g[$i];
        next unless $d;
        my $bit = 1 +< ($d - 1);
        # a given that clashes with another has no solution at all
        return (0, ()) if (@row[$i div 9] +| @col[$i % 9] +| @box[@BOX[$i]]) +& $bit;
        @row[$i div 9] +|= $bit;
        @col[$i % 9]   +|= $bit;
        @box[@BOX[$i]] +|= $bit;
    }

    my $count = 0;
    my @solution;
    my int $i;
    my int $m;
    my int $n;
    sub go() {
        my int $best = -1;
        my int $best-n = 10;
        my int $best-m = 0;
        $i = 0;
        while $i < 81 {
            if @g[$i] == 0 {
                $m = 511 +& +^(@row[$i div 9] +| @col[$i % 9] +| @box[@BOX[$i]]);
                $n = @POP[$m];
                if $n < $best-n {
                    $best = $i;
                    $best-n = $n;
                    $best-m = $m;
                    last if $n < 2;
                }
            }
            $i = $i + 1;
        }
        if $best < 0 {
            $count++;
            @solution = @g.List unless @solution;
            return;
        }
        return unless $best-n;
        my @digits = (1..9).grep({ $best-m +& (1 +< ($_ - 1)) });
        @digits = @digits.pick(*) if $shuffle;
        my $r = $best div 9;
        my $c = $best % 9;
        my $b = @BOX[$best];
        for @digits -> $d {
            my $bit = 1 +< ($d - 1);
            @g[$best] = $d;
            @row[$r] +|= $bit; @col[$c] +|= $bit; @box[$b] +|= $bit;
            go();
            @g[$best] = 0;
            @row[$r] +^= $bit; @col[$c] +^= $bit; @box[$b] +^= $bit;
            return if $count >= $limit;
        }
    }
    go();
    ($count, @solution.List)
}

#| A new puzzle with exactly one solution, as a grid string. A random full
#| grid is made, then digits are taken away in pairs that mirror through the
#| centre, as long as the solution stays unique, until `$clues` remain or no
#| pair can go. `:single` then tries the cells one at a time, which gives up
#| the symmetry to go further: that is what a hard puzzle needs.
sub make-puzzle(Int $clues, Bool :$single = False --> Str) is export {
    my @p = solve-grid((0 xx 81), :shuffle)[1].list;
    my $left = 81;
    for (^41).pick(*) -> $i {
        last if $left <= $clues;
        my $j = 80 - $i;
        my ($a, $b) = @p[$i], @p[$j];
        @p[$i] = 0;
        @p[$j] = 0;
        my ($count) = solve-grid(@p, :limit(2));
        if $count == 1 {
            $left -= $i == $j ?? 1 !! 2;
        }
        else {
            @p[$i] = $a;
            @p[$j] = $b;
        }
    }
    if $single {
        for (^81).pick(*) -> $i {
            last if $left <= $clues;
            next unless @p[$i];
            my $a = @p[$i];
            @p[$i] = 0;
            my ($count) = solve-grid(@p, :limit(2));
            if $count == 1 { $left-- } else { @p[$i] = $a }
        }
    }
    grid-string(@p)
}

#| The candidates of each empty cell, as lists of digits, given the digits the
#| grid has now.
sub candidates(@cells --> List) is export {
    (^81).map(-> $i {
        @cells[$i] ?? () !! do {
            my %seen = peers($i).map({ @cells[$_] => True });
            (1..9).grep({ !%seen{$_} }).List
        }
    }).List
}
