# Tally — how many puzzles have been solved, and how fast: state that lives on
# the server and is shared by every visitor. Only `is server` code uses it.
unit module Tally;

my %TIMES;              # level => the seconds each solve took
my $LOCK = Lock.new;    # the server answers requests on parallel threads

#| Count one solve, and say how it compares with the others at its level.
sub tally-solve(Str $level, Int $seconds --> Hash) is export {
    my $l = $level eq 'easy' | 'medium' | 'hard' ?? $level !! 'other';
    my $s = ($seconds max 0) min 86400;
    $LOCK.protect: {
        my $times = %TIMES{$l} //= [];
        $times.shift if $times.elems >= 10_000;
        $times.push: $s;
        my $n = $times.elems;
        my $faster = $times.grep(* < $s).elems;
        %( count => $n,
           text  => $n == 1
               ?? "It is the first $l puzzle solved since this server started."
               !! "$n $l puzzles have been solved since this server started, "
                  ~ ($faster ?? "$faster of them faster." !! 'and none faster.') );
    }
}
