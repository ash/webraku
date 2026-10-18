#!/usr/bin/env rakupp
# Pixels — one picture for everyone who has the page open.
#
#     webraku run examples/pixels/pixels.raku --port=8803
#
# The picture lives on the server, in Board.rakumod, and is shared by every
# visitor. Painting happens in the browser: a cell changes colour the moment
# it is touched, with no request. Every quarter of a second, if anything was
# painted, and every second regardless, the browser calls `sync` with the
# version of the picture it has and the strokes it made since. One round
# trip carries both ways: the server applies the strokes and answers every
# change made since that version, by anyone.
#
# The server limits how fast each address may paint — 60 pixels at once, 8 a
# second after that — so the board stays a board.
use Webraku;
use lib $?FILE.IO.parent.Str;
use Board;

constant W = 48;     # Board agrees
constant H = 32;

# PICO-8's sixteen colours.
my @PALETTE =
    ('#000000', 'black'), ('#1d2b53', 'dark blue'), ('#7e2553', 'plum'), ('#008751', 'dark green'),
    ('#ab5236', 'brown'), ('#5f574f', 'dark grey'), ('#c2c3c7', 'light grey'), ('#fff1e8', 'white'),
    ('#ff004d', 'red'), ('#ffa300', 'orange'), ('#ffec27', 'yellow'), ('#00e436', 'green'),
    ('#29adff', 'blue'), ('#83769c', 'lavender'), ('#ff77a8', 'pink'), ('#ffccaa', 'peach');

my $SWATCHES = @PALETTE.kv.map(-> $i, ($hex, $) { ".c$i \{ background: $hex }" }).join("\n");

stylesheet q:to/CSS/ ~ $SWATCHES;
    :root { --ink: #1d1d1b; --muted: #77736b; --rule: #e4e0d8; --paper: #fbfaf7; --card: #fff;
            --line: #cfc9bd; --soft: #f1eee6 }
    @media (prefers-color-scheme: dark) {
        :root { --ink: #e8e6e1; --muted: #9c978d; --rule: #34332f; --paper: #161614; --card: #1f1f1c;
                --line: #45433e; --soft: #262622 }
    }
    * { box-sizing: border-box }
    body { font: 15px/1.5 system-ui, sans-serif; margin: 0; background: var(--paper); color: var(--ink) }
    main { max-width: 60rem; margin: 0 auto; padding: 1.2rem 1rem 3rem }
    nav.demos { display: flex; justify-content: space-between; font-size: .85rem; margin-bottom: 1.6rem }
    nav.demos a { color: var(--muted); text-decoration: none }
    nav.demos a:hover { color: var(--ink) }
    h1 { font-size: 1.5rem; margin: 0 0 .2rem }
    .sub { color: var(--muted); margin: 0 0 1rem; max-width: 44rem }
    .tools { display: flex; flex-wrap: wrap; align-items: center; gap: .8rem 1.4rem; margin-bottom: .8rem }
    .swatches { display: grid; grid-template-columns: repeat(16, 1.7rem); gap: .25rem }
    .swatches button { width: 1.7rem; height: 1.7rem; border: 1px solid rgba(0,0,0,.25); border-radius: .3rem;
                       padding: 0; cursor: pointer }
    .swatches button.on { outline: 2px solid var(--ink); outline-offset: 2px }
    .status { font-size: .85rem; color: var(--muted); font-variant-numeric: tabular-nums }
    .status b { color: var(--ink) }
    .board { display: grid; grid-template-columns: repeat(48, 1fr); aspect-ratio: 48 / 32; width: 100%;
             border: 1px solid var(--line); border-radius: .3rem; overflow: hidden; touch-action: none;
             cursor: crosshair; user-select: none; -webkit-user-select: none }
    .board div { min-width: 0; min-height: 0 }
    .note { font-size: .85rem; color: #c2573a; min-height: 1.3em; margin: .4rem 0 0 }
    .split { font-size: .85rem; color: var(--muted); margin-top: 1.6rem; max-width: 46rem }
    code { font: .85em ui-monospace, SFMono-Regular, Menlo, monospace; background: var(--soft);
           padding: .05rem .3rem; border-radius: .25rem }
    @media (max-width: 40rem) { .swatches { grid-template-columns: repeat(8, 1.7rem) } }
    CSS

# ---------- the server ----------

#| The picture, for the first render.
sub snapshot() is server { board-now() }

#| Strokes in, changes out. `$since` is the version the browser has; `@strokes`
#| are `[cell, colour]` pairs; `$who` tells one visitor from another, for the
#| count of who is here.
sub sync(Int $since, @strokes, Str $who) is server {
    my $addr = (request().header('x-forwarded-for') // 'direct').split(',')[0].trim;
    board-sync($since, @strokes, $who, $addr);
}

# ---------- the page ----------

page '/', :title('Pixels · Webraku'), {
    my %b = snapshot();
    my $version = %b<version>;
    my @cells = %b<cells>.comb.map(*.parse-base(16));
    my $colour = 8;
    my @pending;                 # strokes painted here and not yet sent
    my $who = (rand * 2**40).Int.base(36);
    my $down = False;
    my $asking = False;
    my $mine = 0;
    my $tick = 0;

    my ($tools, @sw, $board, @px, $here, $count, $you, $note);

    main {
        nav :class<demos>, {
            a '← Webraku demos', :href('/');
            a 'source', :href('https://github.com/ash/webraku/tree/main/examples/pixels');
        }
        h1 'Pixels';
        p 'One picture for everyone who has this page open. Pick a colour and paint; '
          ~ 'the others see it within a second.', :class<sub>;

        div :class<tools>, {
            $tools = div :class<swatches>, {
                for @PALETTE.kv -> $i, ($hex, $name) {
                    @sw[$i] = button :class("c$i" ~ ($i == $colour ?? ' on' !! '')),
                                     :data-c(~$i), :title($name), :aria-label($name);
                }
            }
            div :class<status>, {
                $here = b ~%b<online>;
                text ' here · ';
                $count = b ~$version;
                text ' painted since the server started · you: ';
                $you = b '0';
            }
        }
        $board = div :class<board>, {
            for ^(W * H) -> $i {
                @px[$i] = div :class("c{@cells[$i]}"), :data-i(~$i);
            }
        }
        $note = p '', :class<note>;

        p raw('<code>snapshot</code> and <code>sync</code> are <code>is server</code>, and Board.rakumod '
            ~ 'behind them holds the picture, the record of changes and the limit on how fast each '
            ~ 'address may paint. Everything else — the palette, painting, sending strokes in batches, '
            ~ 'merging what comes back — is this page, running in your browser.'), :class<split>;
    }

    sub put(Int $i, Int $c) {
        @cells[$i] = $c;
        @px[$i].set('class', "c$c");
    }

    #| Paint the cell under the pointer, if it is one and not that colour yet.
    sub paint-at($ev) {
        my $el = window().document.elementFromPoint($ev<clientX>, $ev<clientY>);
        return unless $el;
        my $d = $el.getAttribute('data-i');
        return unless $d;
        my $i = $d.Str.Int;
        return if @cells[$i] == $colour;
        put($i, $colour);
        @pending.push: [$i, $colour];
        $you.text = ~++$mine;
    }

    #| One round trip: our strokes out, everyone's changes back. Changes to
    #| a cell painted here since the question went out are skipped: that
    #| stroke is still to be sent, and is newer.
    sub sync-now() {
        return if $asking;
        $asking = True;
        my @send = @pending;
        @pending = ();
        my %r = sync($version, @send, $who);
        $asking = False;
        my %waiting = @pending.map({ .[0] => True });
        if %r<cells> {
            my @all = %r<cells>.comb.map(*.parse-base(16));
            for ^(W * H) -> $i { put($i, @all[$i]) unless %waiting{$i} || @cells[$i] == @all[$i] }
        }
        else {
            for %r<changes>.list -> @c { put(@c[0], @c[1]) unless %waiting{@c[0]} }
        }
        $version = %r<version>;
        $here.text = ~%r<online>;
        $count.text = ~$version;
        if %r<refused> {
            # Some strokes were not taken. Ask for the whole picture next time,
            # which puts those cells back as everyone else sees them.
            $version = -1;
            $note.text = 'Slow down a little: the board takes 60 pixels at once from each of you, and 8 a second after that.';
        }
        else {
            $note.text = '';
        }
    }

    react {
        whenever $tools.on('click') -> $ev {
            my $b = $ev<target>.closest('button');
            if $b {
                $colour = $b.getAttribute('data-c').Str.Int;
                @sw[$_].set('class', "c$_" ~ ($_ == $colour ?? ' on' !! '')) for ^@sw;
            }
        }
        whenever $board.on('pointerdown') -> $ev {
            $down = True;
            $ev.preventDefault;
            paint-at($ev);
        }
        whenever $board.on('pointermove') -> $ev { paint-at($ev) if $down }
        whenever $board.on('pointerup')     { $down = False }
        whenever $board.on('pointercancel') { $down = False }
        whenever $board.on('pointerleave')  { $down = False }
        # A quarter-second clock: strokes go out within a quarter of a second,
        # and when there are none the board still asks once a second.
        whenever every(0.25) {
            $tick++;
            sync-now() if @pending || $tick %% 4;
        }
    }
}

serve;
