# Rules — what makes a Sudoku grid right or wrong, for both halves.
#
# The page calls `clashes` on every keystroke, in the browser, to mark a digit
# that repeats in its row, column or box: no request, because the rule is in
# the browser's script. The server calls the same subs while it renders and
# while it checks a grid. One copy of the rules, so the two cannot disagree.
#
# Nothing here knows the answer to a puzzle. That is in Solver.rakumod, which
# only `is server` code uses, so it never reaches the browser.
unit module Rules;

#| The 20 peers of each cell: the others in its row, its column and its box.
my @PEERS = (^81).map(-> $i {
    my $r = $i div 9;
    my $c = $i % 9;
    my $br = $r div 3 * 3;
    my $bc = $c div 3 * 3;
    (|(^9).map({ $r * 9 + $_ }),
     |(^9).map({ $_ * 9 + $c }),
     |(^9).map({ ($br + $_ div 3) * 9 + $bc + $_ % 3 })).unique.grep(* != $i).List
});

sub peers(Int $i --> List) is export { @PEERS[$i] }

#| The cells holding a digit that one of their peers holds too.
sub clashes(@cells --> List) is export {
    (^81).grep(-> $i {
        my $d = @cells[$i];
        $d && @PEERS[$i].first({ @cells[$_] == $d }).defined
    }).List
}

#| How many cells have a digit.
sub filled(@cells --> Int) is export { @cells.grep(* != 0).elems }

#| A grid is 81 characters, a digit or `.` for an empty cell.
sub parse-grid(Str $s --> List) is export {
    $s.comb.map({ $_ eq '.' || $_ eq '0' ?? 0 !! .Int }).List
}
sub grid-string(@cells --> Str) is export { @cells.map({ $_ || '.' }).join }
