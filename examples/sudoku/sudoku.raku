#!/usr/bin/env rakupp
# Sudoku — the rules in the browser, the answer on the server.
#
#     webraku run examples/sudoku/sudoku.raku --port=8801
#
# Two modules sit beside this file, and the split between them is the point:
#
#   Rules.rakumod is what makes a grid right or wrong. The page calls `clashes`
#   on every keystroke to mark a repeated digit, so it has to be in the
#   browser, and it is: the bundler keeps `use Rules` because the browser's
#   code calls what it exports. The server uses the same subs.
#
#   Solver.rakumod finds solutions and makes puzzles. Only the `is server` subs
#   below call it, so it stays on the server, and the solution of the puzzle on
#   the screen is never sent: a hint or a check is a question the server
#   answers, not a lookup in the page.
#
# A full grid with no clashes needs no question at all. The puzzle has one
# solution, so that grid is it, and the browser says "solved" by itself.
use Webraku;
use lib $?FILE.IO.parent.Str;
use Rules;
use Solver;
use Tally;

stylesheet q:to/CSS/;
    :root { --ink: #1d1d1b; --muted: #77736b; --rule: #e4e0d8; --paper: #fbfaf7; --card: #fff;
            --line: #cfc9bd; --thick: #57534b; --given: #1d1d1b; --mine: #1f5f8b;
            --peer: #f1eee6; --same: #e2ecf4; --clash: #c2573a; --clash-bg: #f8e3dc;
            --hint-bg: #e3f1e0; --sel: #fff6c9; --btn: #fff; --btn-hover: #f1eee8 }
    @media (prefers-color-scheme: dark) {
        :root { --ink: #e8e6e1; --muted: #9c978d; --rule: #34332f; --paper: #161614; --card: #1f1f1c;
                --line: #45433e; --thick: #9c978d; --given: #f2f0eb; --mine: #7fb6dc;
                --peer: #262622; --same: #1d2a34; --clash: #e98a6c; --clash-bg: #3a221b;
                --hint-bg: #1f3320; --sel: #3a3519; --btn: #24241f; --btn-hover: #2e2e28 }
    }
    * { box-sizing: border-box }
    body { font: 15px/1.5 system-ui, sans-serif; margin: 0; background: var(--paper); color: var(--ink) }
    main { max-width: 46rem; margin: 0 auto; padding: 1.2rem 1rem 3rem }
    nav.demos { display: flex; justify-content: space-between; font-size: .85rem; margin-bottom: 1.6rem }
    nav.demos a { color: var(--muted); text-decoration: none }
    nav.demos a:hover { color: var(--ink) }
    h1 { font-size: 1.5rem; margin: 0 0 .2rem }
    .sub { color: var(--muted); margin: 0 0 1.2rem }
    .levels { display: flex; gap: .4rem; margin-bottom: 1rem }
    button { font: inherit; padding: .4rem .9rem; border: 1px solid var(--line); border-radius: .4rem;
             background: var(--btn); color: var(--ink); cursor: pointer }
    button:hover { background: var(--btn-hover) }
    button.on { border-color: var(--ink); font-weight: 600 }
    button:disabled { opacity: .5; cursor: default }
    .play { display: grid; grid-template-columns: minmax(0, 27rem) 1fr; gap: 1.6rem; align-items: start }
    .grid { display: grid; grid-template-columns: repeat(9, 1fr); border: 2px solid var(--thick);
            background: var(--card); width: 100%; max-width: 27rem; aspect-ratio: 1 }
    .grid input { width: 100%; height: 100%; min-width: 0; border: 0; border-right: 1px solid var(--line);
                  border-bottom: 1px solid var(--line); text-align: center; padding: 0;
                  font: 500 clamp(1rem, 4.6vw, 1.55rem) system-ui, sans-serif; color: var(--mine);
                  background: transparent; caret-color: transparent; outline: none; border-radius: 0 }
    .grid input.br { border-right: 2px solid var(--thick) }
    .grid input.bb { border-bottom: 2px solid var(--thick) }
    .grid input.given { color: var(--given); font-weight: 700 }
    .grid input.peer { background: var(--peer) }
    .grid input.same { background: var(--same) }
    .grid input.sel { background: var(--sel) }
    .grid input.hinted { background: var(--hint-bg) }
    .grid input.clash, .grid input.wrong { color: var(--clash); background: var(--clash-bg) }
    .bar { display: flex; justify-content: space-between; max-width: 27rem; margin: .5rem 0 0;
           font-size: .9rem; color: var(--muted); font-variant-numeric: tabular-nums }
    .side .actions { display: flex; flex-wrap: wrap; gap: .4rem; margin-bottom: .8rem }
    .msg { min-height: 3em; margin: 0 0 1rem }
    .msg.good { color: #3d8b40; font-weight: 600 }
    .side h2 { font-size: .95rem; margin: 1.2rem 0 .4rem }
    .side p { font-size: .88rem; color: var(--muted); margin: 0 0 .6rem }
    .split { border-collapse: collapse; width: 100%; font-size: .85rem; margin-top: .3rem }
    .split td { padding: .35rem .4rem .35rem 0; border-top: 1px solid var(--rule); vertical-align: top }
    .split td:first-child { white-space: nowrap; font-weight: 600; padding-right: .8rem }
    code { font: .85em ui-monospace, SFMono-Regular, Menlo, monospace; background: var(--peer);
           padding: .05rem .3rem; border-radius: .25rem }
    @media (max-width: 44rem) { .play { grid-template-columns: 1fr } }
    CSS

my %CLUES = easy => 40, medium => 32, hard => 24;

# ---------- the server ----------

#| A new puzzle. Its solution is not kept, and not sent: whenever it is needed
#| the server finds it again from the puzzle, in a few milliseconds.
sub new-puzzle(Str $level) is server {
    my $l = %CLUES{$level}:exists ?? $level !! 'easy';
    my $grid = make-puzzle(%CLUES{$l}, single => $l eq 'hard');
    %( :$grid, level => $l, clues => filled(parse-grid($grid)) );
}

sub where(Int $i --> Str) { "row {$i div 9 + 1}, column {$i % 9 + 1}" }

#| One step toward the answer, for the grid as it stands: a digit that is
#| wrong, or else one that can be placed, with the reason a person would give.
sub hint(Str $puzzle, Str $now) is server {
    my @cells = parse-grid($now);
    my ($n, $solution) = solve-grid(parse-grid($puzzle));
    return %( kind => 'none', text => 'This puzzle has no solution.' ) unless $n;
    my @sol = $solution.list;

    with (^81).first({ @cells[$_] && @cells[$_] != @sol[$_] }) -> $i {
        return %( kind => 'wrong', cell => $i,
                  text => "The {@cells[$i]} in {where($i)} is not right." );
    }
    my @empty = (^81).grep({ !@cells[$_] });
    return %( kind => 'done', text => 'Every cell is filled, and filled right.' ) unless @empty;

    my @cand = candidates(@cells);
    with @empty.first({ @cand[$_] == 1 }) -> $i {
        return %( kind => 'digit', cell => $i, digit => @sol[$i],
                  text => "Only {@sol[$i]} fits in {where($i)}: every other digit is already in its row, column or box." );
    }
    for units() -> ($name, @unit) {
        for 1..9 -> $d {
            next if @unit.first({ @cells[$_] == $d }).defined;
            my @spots = @unit.grep(-> $i { !@cells[$i] && @cand[$i].first($d).defined });
            next unless @spots == 1;
            my $i = @spots[0];
            return %( kind => 'digit', cell => $i, digit => $d,
                      text => "$d can go nowhere else in this $name, so it goes in {where($i)}." );
        }
    }
    my $i = @empty.min({ +@cand[$_] });
    %( kind => 'digit', cell => $i, digit => @sol[$i],
       text => "{@sol[$i]} goes in {where($i)}. Nothing simpler was left, so this one is from the answer." );
}

#| The rows, columns and boxes, each as a name and its nine cells.
sub units() {
    |(^9).map(-> $r { ('row',    (^9).map({ $r * 9 + $_ }).List) }),
    |(^9).map(-> $c { ('column', (^9).map({ $_ * 9 + $c }).List) }),
    |(^9).map(-> $b { ('box',    (^9).map({ ($b div 3 * 3 + $_ div 3) * 9 + $b % 3 * 3 + $_ % 3 }).List) })
}

#| Which of the digits typed so far are wrong. The right ones are not named.
sub check(Str $puzzle, Str $now) is server {
    my @cells = parse-grid($now);
    my ($n, $solution) = solve-grid(parse-grid($puzzle));
    my @sol = $solution.list;
    %( wrong => (^81).grep({ @cells[$_] && @sol && @cells[$_] != @sol[$_] }).Array );
}

#| A puzzle was solved: count it, and say how it compares.
sub solved(Str $level, Int $seconds) is server { tally-solve($level, $seconds) }

# ---------- the page ----------

sub clock(Int $s --> Str) { sprintf('%d:%02d', $s div 60, $s % 60) }

#| The classes that never change for a cell: its place in the boxes, and
#| whether it is a given.
sub fixed-class(Int $i, Bool $given --> Str) {
    my @c;
    @c.push: 'given' if $given;
    @c.push: 'br' if $i % 9 == 2 || $i % 9 == 5;
    @c.push: 'bb' if $i div 9 == 2 || $i div 9 == 5;
    @c.join(' ')
}

page '/', :title('Sudoku · Webraku'), {
    my %p = new-puzzle('easy');
    my $puzzle = %p<grid>;
    my $level  = %p<level>;
    my @givens = parse-grid($puzzle);
    my @cells  = @givens.Array;
    my $seconds = 0;
    my $done    = False;
    my $sel     = -1;          # the focused cell
    my %wrong;                 # cells the server said are wrong, until changed
    my %hinted;                # cells a hint filled
    my $busy    = False;

    my (@in, %lvl, $grid, $count, $clock, $msg, $hint-b, $check-b, $clear-b);

    main {
        nav :class<demos>, {
            a '← Webraku demos', :href('/');
            a 'source', :href('https://github.com/ash/webraku/tree/main/examples/sudoku');
        }
        h1 'Sudoku';
        p 'The rules run in your browser; the answer stays on the server.', :class<sub>;

        div :class<levels>, {
            for <easy medium hard> -> $l {
                %lvl{$l} = button $l.tc, :class($l eq $level ?? 'on' !! '');
            }
        }
        div :class<play>, {
            div {
                $grid = div :class<grid>, {
                    for ^81 -> $i {
                        @in[$i] = input :type<text>, :inputmode<numeric>, :autocomplete<off>,
                            :data-i(~$i), :value(@givens[$i] ?? ~@givens[$i] !! ''),
                            :readonly(?@givens[$i]), :class(fixed-class($i, ?@givens[$i])),
                            :aria-label(where($i));
                    }
                }
                div :class<bar>, {
                    $count = span "{filled(@cells)} of 81 · {%p<clues>} given";
                    $clock = span clock(0);
                }
            }
            div :class<side>, {
                div :class<actions>, {
                    $hint-b  = button 'Hint';
                    $check-b = button 'Check';
                    $clear-b = button 'Clear mine';
                }
                $msg = p 'Click a cell and type a digit. A digit that repeats in its row, column or box turns red.',
                         :class<msg>;

                h2 'Where each part runs';
                table :class<split>, {
                    tr { td 'browser'; td raw('<code>clashes</code> and <code>peers</code> from Rules.rakumod, on every keystroke; the clock; the highlighting; noticing that a full grid with no clashes is solved') }
                    tr { td 'server';  td raw('<code>make-puzzle</code> and <code>solve-grid</code> from Solver.rakumod, behind <code>new-puzzle</code>, <code>hint</code> and <code>check</code>; the count of puzzles solved') }
                }
                p raw('One file, <code>sudoku.raku</code>, is both. The four subs marked <code>is server</code> keep their bodies on the server, and the browser calls them over HTTP. Solver.rakumod is not in the browser&rsquo;s script at all, so neither is any way to the solution.');
            }
        }
    }

    #| Write the state into the cells' classes and the counters.
    sub paint() {
        my %bad = clashes(@cells).map({ $_ => True });
        my %peer = $sel >= 0 ?? peers($sel).map({ $_ => True }) !! ();
        my $digit = $sel >= 0 ?? @cells[$sel] !! 0;
        for ^81 -> $i {
            my @c = fixed-class($i, ?@givens[$i]).words;
            @c.push: 'sel'    if $i == $sel;
            @c.push: 'peer'   if %peer{$i} && $i != $sel;
            @c.push: 'same'   if $digit && @cells[$i] == $digit && $i != $sel;
            @c.push: 'hinted' if %hinted{$i};
            @c.push: 'clash'  if %bad{$i};
            @c.push: 'wrong'  if %wrong{$i};
            @in[$i].set('class', @c.join(' '));
        }
        $count.text = "{filled(@cells)} of 81 · {@givens.grep(* != 0).elems} given";
    }

    #| Put a digit (0 for none) in a cell, in the model and in the page.
    sub put(Int $i, Int $d) {
        @cells[$i] = $d;
        @in[$i].set('value', $d ?? ~$d !! '');
        %wrong{$i}:delete;
        %hinted{$i}:delete;
    }

    sub finished() {
        return unless filled(@cells) == 81 && !clashes(@cells);
        $done = True;
        $msg.set('class', 'msg good');
        $msg.text = "Solved, in {clock($seconds)}. The browser knew without asking: a full grid with no clashes is the only solution there is.";
        my %t = solved($level, $seconds);
        $msg.text = $msg.text ~ " %t<text>";
    }

    sub start-puzzle(Str $l) {
        return if $busy;
        $busy = True;
        $msg.set('class', 'msg');
        $msg.text = 'Asking the server for a new puzzle…';
        my %n = new-puzzle($l);
        $busy = False;
        $puzzle = %n<grid>;
        $level = %n<level>;
        @givens = parse-grid($puzzle);
        @cells = @givens.Array;
        %wrong = ();
        %hinted = ();
        $sel = -1;
        $seconds = 0;
        $done = False;
        for ^81 -> $i {
            @in[$i].set('value', @givens[$i] ?? ~@givens[$i] !! '');
            @in[$i].set('readonly', ?@givens[$i]);
        }
        %lvl{$_}.set('class', $_ eq $level ?? 'on' !! '') for %lvl.keys;
        $clock.text = clock(0);
        $msg.text = "A new {$level} puzzle, with {%n<clues>} digits given. Made on the server just now, with exactly one solution.";
        paint();
    }

    react {
        whenever $grid.on('input') -> $ev {
            my $node = $ev<target>;
            my $i = $node.getAttribute('data-i').Str.Int;
            unless @givens[$i] || $done {
                # Whatever was typed, keep only the last digit 1–9. The DOM is
                # written directly too, since what was typed may not be what
                # stays, and the element already thinks it holds that.
                my $d = $node<value>.Str.comb.grep({ $_ ge '1' && $_ le '9' }).tail // '';
                $node<value> = $d;
                put($i, $d ?? $d.Int !! 0);
                paint();
                finished();
            }
        }
        whenever $grid.on('focusin') -> $ev {
            $sel = $ev<target>.getAttribute('data-i').Str.Int;
            paint();
        }
        whenever $grid.on('keydown') -> $ev {
            my $k = $ev<key>.Str;
            my %step = ArrowLeft => -1, ArrowRight => 1, ArrowUp => -9, ArrowDown => 9;
            if %step{$k}:exists && $sel >= 0 {
                my $j = $sel + %step{$k};
                if 0 <= $j < 81 {
                    $ev.preventDefault;
                    @in[$j].node.focus;
                }
            }
        }
        whenever every(1) {
            unless $done {
                $seconds++;
                $clock.text = clock($seconds);
            }
        }
        whenever %lvl<easy>.clicks   { start-puzzle('easy') }
        whenever %lvl<medium>.clicks { start-puzzle('medium') }
        whenever %lvl<hard>.clicks   { start-puzzle('hard') }
        whenever $hint-b.clicks {
            unless $busy || $done {
                $busy = True;
                $msg.set('class', 'msg');
                my %h = hint($puzzle, grid-string(@cells));
                $busy = False;
                if %h<kind> eq 'digit' {
                    put(%h<cell>, %h<digit>);
                    %hinted{%h<cell>} = True;
                }
                elsif %h<kind> eq 'wrong' {
                    %wrong{%h<cell>} = True;
                }
                $msg.text = %h<text>;
                paint();
                finished();
            }
        }
        whenever $check-b.clicks {
            unless $busy || $done {
                $busy = True;
                $msg.set('class', 'msg');
                my %c = check($puzzle, grid-string(@cells));
                $busy = False;
                %wrong = %c<wrong>.map({ $_ => True });
                my $mine = (^81).grep({ @cells[$_] && !@givens[$_] }).elems;
                my $bad = %c<wrong>.elems;
                $msg.text = !$mine ?? 'Nothing of yours to check yet.'
                         !! $bad    ?? "$bad of your $mine digit{$mine == 1 ?? '' !! 's'} {$bad == 1 ?? 'is' !! 'are'} wrong, marked in red. The server did not say what goes there."
                         !!            "All $mine of your digits are right so far.";
                paint();
            }
        }
        whenever $clear-b.clicks {
            unless $done {
                put($_, 0) for (^81).grep({ !@givens[$_] });
                $msg.set('class', 'msg');
                $msg.text = 'Back to the givens.';
                paint();
            }
        }
    }
}

serve;
