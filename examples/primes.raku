#!/usr/bin/env rakupp
# Server-side computation — the work happens on the server, and its result is
# in the HTML the browser receives.
#
#     webraku run examples/primes.raku --port=8793
#
# Two things to notice, and they are the point of the example:
#
#   `sieve` is marked `is server`. Its body is not in the browser bundle at all;
#   the browser has a stub that would fetch it. But it never fetches on the
#   first render: the server logged the call and its answer into the page, and
#   the browser replays that log. View the source and the numbers are there.
#
#   `/primes/:limit` is one route. Change the number in the address bar and the
#   server computes a different sieve. The page is server-rendered either way,
#   so it works with JavaScript switched off — and it is the same program.
use Webraku;

stylesheet q:to/CSS/;
    body { font: 16px/1.6 system-ui, sans-serif; margin: 0; background: #fbfaf7; color: #1d1d1b }
    main { max-width: 46rem; margin: 3rem auto; padding: 0 1.5rem }
    h1 { font-size: 1.5rem; margin: 0 0 .3rem }
    .sub { color: #777; margin: 0 0 2rem }
    .grid { display: flex; flex-wrap: wrap; gap: .35rem; margin: 1rem 0 2rem }
    .n { font-variant-numeric: tabular-nums; font-size: .85rem; padding: .2rem .45rem;
         border-radius: .25rem; background: #eceae4; color: #555; min-width: 2.2rem; text-align: center }
    .n.prime { background: #2f6f4f; color: #fff; font-weight: 600 }
    table.facts { border-collapse: collapse; margin: 1rem 0 2rem }
    table.facts td { padding: .3rem .9rem .3rem 0; border-bottom: 1px solid #e4e1da }
    table.facts td.k { color: #777 }
    table.facts td.v { font-variant-numeric: tabular-nums; font-weight: 600 }
    nav a { margin-right: 1rem }
    code { background: #eceae4; padding: .1rem .35rem; border-radius: .25rem; font-size: .9em }
    CSS

#| The sieve of Eratosthenes. On the server this runs; in the browser this
#| routine has no body at all, so the page never carries the algorithm — only
#| its answer, which the server wrote into the HTML.
sub sieve(Int $limit) is server {
    return [] if $limit < 2;
    my @composite = False xx ($limit + 1);
    my @primes;
    for 2 .. $limit -> $n {
        next if @composite[$n];
        @primes.push: $n;
        my $m = $n * $n;
        while $m <= $limit { @composite[$m] = True; $m += $n }
    }
    @primes;
}

#| How many twin pairs, and the largest gap. Also server-side, and also
#| answered from the log when the browser runs the same page code.
sub prime-facts(Int $limit) is server {
    my @p = sieve($limit);
    return %( count => 0, twins => 0, gap => 0, gap-at => 0, sum => 0 ) unless @p;
    my ($twins, $gap, $gap-at) = 0, 0, 0;
    for 1 ..^ @p.elems -> $i {
        my $d = @p[$i] - @p[$i - 1];
        $twins++ if $d == 2;
        if $d > $gap { $gap = $d; $gap-at = @p[$i - 1] }
    }
    %( count => @p.elems, :$twins, :$gap, :$gap-at, sum => @p.sum );
}

sub show(Int $limit) {
    my @primes = sieve($limit);
    my %facts  = prime-facts($limit);
    my %is-prime = @primes.map(* => True);

    main {
        h1 "Primes up to $limit";
        p "computed on the server, by the sieve of Eratosthenes", :class<sub>;

        nav {
            text 'try ';
            for 50, 100, 500, 1000 -> $n {
                a "$n", :href("/primes/$n");
            }
        }

        table :class<facts>, {
            for ('primes',     %facts<count>),
                ('twin pairs', %facts<twins>),
                ('largest gap', "%facts<gap> (after %facts<gap-at>)"),
                ('their sum',  %facts<sum>) -> ($k, $v)
            {
                tr { td $k, :class<k>; td ~$v, :class<v> }
            }
        }

        # Every number up to 100, so the sieve is visible rather than described.
        if $limit <= 400 {
            div :class<grid>, {
                for 2 .. $limit -> $n {
                    span ~$n, class => %is-prime{$n} ?? 'n prime' !! 'n';
                }
            }
        }

        p raw('The sieve is <code>sub sieve(Int $limit) is server</code>. '
              ~ 'Read the page source: the numbers are in the HTML, and the '
              ~ 'algorithm is not in the script.');
    }
}

page '/',              :title('Primes'), { show(100) }
page '/primes/:limit', :title('Primes'), -> $limit { show($limit.Int min 5000) }

serve;
