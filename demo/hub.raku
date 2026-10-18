#!/usr/bin/env rakupp
# The front page of the Webraku demos — itself a Webraku program.
#
#     webraku run demo/hub.raku --port=8800
#
# It lists the demos in demos.txt, and for each one shows how its work is
# split. That part is read, not written down: the server opens each demo's
# source and runs Webraku's own bundler over it, which is what decides what
# reaches the browser, so the page cannot disagree with the demos.
use Webraku;
use Webraku::Bundle;
use lib $?FILE.IO.parent.Str;
use Demos;

my $STARTED = now;

my %ABOUT =
    sudoku  => ('Sudoku', 'The rules in your browser, the answer on the server.',
                'A repeated digit turns red on the keystroke, because the rules are compiled into the page. '
                ~ 'The solver is not: hints and checks are questions the server answers, and the solution is never sent.'),
    unicode => ('Unicode explorer', "Unicode's tables on the server, the arithmetic in the browser.",
                'Search 172,808 character names held by the server; UTF-8 bytes, UTF-16 units and the counting '
                ~ 'of a string are worked out in your browser as you type.'),
    pixels  => ('Pixels', 'One picture for everyone who has the page open.',
                'Painting is instant and local; every second the browser sends its strokes and gets back '
                ~ "everyone else's in the same round trip. The server keeps the picture and the pace."),
    wavelet => ('Wavelet shrinkage', 'Math::Wavelet on both sides.',
                'A discrete transform redraws on every slider step in the browser, compiled from the module with the page; '
                ~ 'the continuous transform is computed on the server and sent as a picture.'),
    primes  => ('Primes', 'A computation the browser never sees.',
                'The sieve is a server sub. Its answer is written into the page; its code is not in the script.'),
    counter => ('Counter', 'The other extreme: nothing but the browser.',
                'After the page loads there is no network traffic at all.');

stylesheet q:to/CSS/;
    :root { --ink: #1d1d1b; --muted: #77736b; --rule: #e4e0d8; --paper: #fbfaf7; --card: #fff;
            --line: #cfc9bd; --accent: #1f5f8b; --soft: #f1eee6; --srv: #c2573a; --both: #3d8b40 }
    @media (prefers-color-scheme: dark) {
        :root { --ink: #e8e6e1; --muted: #9c978d; --rule: #34332f; --paper: #161614; --card: #1f1f1c;
                --line: #45433e; --accent: #7fb6dc; --soft: #262622; --srv: #e98a6c; --both: #7cc47f }
    }
    * { box-sizing: border-box }
    body { font: 16px/1.55 system-ui, sans-serif; margin: 0; background: var(--paper); color: var(--ink) }
    main { max-width: 62rem; margin: 0 auto; padding: 2.4rem 1rem 3rem }
    h1 { font-size: 1.9rem; margin: 0 0 .4rem; letter-spacing: -.01em }
    .lede { font-size: 1.05rem; max-width: 46rem; margin: 0 0 .6rem }
    .lede2 { color: var(--muted); max-width: 46rem; margin: 0 0 2rem; font-size: .95rem }
    .cards { display: grid; grid-template-columns: repeat(auto-fill, minmax(18.5rem, 1fr)); gap: 1rem }
    .card { background: var(--card); border: 1px solid var(--rule); border-radius: .7rem; padding: 1.1rem 1.2rem 1rem;
            display: flex; flex-direction: column }
    .card h2 { font-size: 1.12rem; margin: 0 0 .15rem }
    .card h2 a { color: var(--ink); text-decoration: none }
    .card h2 a:hover { color: var(--accent) }
    .card .pitch { font-weight: 600; font-size: .9rem; margin: 0 0 .5rem; color: var(--accent) }
    .card .why { font-size: .88rem; color: var(--muted); margin: 0 0 .8rem; flex: 1 }
    .card .go { display: flex; gap: .6rem; align-items: center; font-size: .85rem }
    .card .go a.open { background: var(--ink); color: var(--paper); text-decoration: none; padding: .35rem .9rem;
                       border-radius: .4rem; font-weight: 600 }
    .card button { font: inherit; font-size: .85rem; background: none; border: 0; color: var(--muted);
                   cursor: pointer; padding: .35rem 0; text-decoration: underline dotted }
    .split { display: none; margin-top: .8rem; font-size: .8rem; border-top: 1px solid var(--rule); padding-top: .6rem }
    .split.open { display: block }
    .split table { border-collapse: collapse; width: 100% }
    .split td { padding: .18rem .4rem .18rem 0; vertical-align: top }
    .split td.where { white-space: nowrap; font-weight: 600 }
    .split .srv { color: var(--srv) }
    .split .both { color: var(--both) }
    code { font: .85em ui-monospace, SFMono-Regular, Menlo, monospace; background: var(--soft);
           padding: .05rem .3rem; border-radius: .25rem }
    .foot { margin-top: 2.4rem; font-size: .85rem; color: var(--muted); max-width: 46rem }
    .foot a { color: var(--muted) }
    CSS

# ---------- the server ----------

#| Each demo, with what its source says about the split: the subs marked
#| `is server`, and the modules beside it, with whether the bundler sends
#| each one to the browser.
sub demos() is server {
    my $root = $?FILE.IO.parent.parent;
    read-demos($root.add('demo/demos.txt')).grep(*<name> ne 'hub').map(-> %d {
        my $file = $root.add(%d<app>);
        my $src = $file.slurp;
        my $stubbed = stub-server-subs($src);
        my @mods = $src.lines.map(-> $l {
            with local-module($l, $file.parent) -> $m {
                my $both = strip-uses($l, beside => $file.parent, client => $stubbed).trim.chars > 0;
                [$m.basename, $both ?? 'both' !! 'server', $m.lines.elems];
            }
        }).grep(*.defined).Array;
        my @about = |(%ABOUT{%d<name>} // (%d<name>, '', ''));
        %( name   => %d<name>,
           href   => %d<mount> ~ '/',
           title  => @about[0],
           pitch  => @about[1],
           why    => @about[2],
           file   => $file.basename,
           lines  => $src.lines.elems,
           server => server-subs($src).map(*<name>).Array,
           mods   => @mods );
    }).Array
}

#| What is serving this.
sub engine() is server {
    %( engine  => "{$*RAKU.compiler.name} {$*RAKU.compiler.version}",
       os      => $*KERNEL.name,
       started => $STARTED.Int );
}

# ---------- the page ----------

sub ago(Int $s --> Str) {
    $s < 60    ?? "{$s} s"
 !! $s < 3600  ?? "{$s div 60} min"
 !! $s < 86400 ?? "{$s div 3600} h {$s % 3600 div 60} min"
 !!               "{$s div 86400} d {$s % 86400 div 3600} h"
}

page '/', :title('Webraku demos'), {
    my @d = demos().list;
    my %e = engine();
    my $up = (now - %e<started>).Int;
    my (@toggle, @panel, $cards, $uptime);

    main {
        h1 'Webraku demos';
        p raw('Each page below is <strong>one Raku program</strong>. Raku++ runs it on this server to answer '
            ~ 'the request with finished HTML, and <code>rakupp --target=js</code> compiled the same file into '
            ~ 'the script your browser runs, which picks the page up where the server left it.'), :class<lede>;
        p raw('A sub marked <code>is server</code> keeps its body here, and the browser calls it over HTTP '
            ~ 'without anyone writing a request. Everything else runs in both places. Each demo puts the line '
            ~ 'somewhere else, for a different reason.'), :class<lede2>;

        $cards = div :class<cards>, {
            for @d.kv -> $k, %x {
                div :class<card>, {
                    h2 { a %x<title>, :href(%x<href>) }
                    p %x<pitch>, :class<pitch>;
                    p %x<why>, :class<why>;
                    div :class<go>, {
                        a 'Open', :href(%x<href>), :class<open>;
                        @toggle[$k] = button 'how it is split', :data-k(~$k);
                    }
                    @panel[$k] = div :class<split>, {
                        tag 'table', {
                            tr {
                                td %x<file>, :class('where both');
                                td "{%x<lines>} lines, both halves";
                            }
                            for %x<mods>.list -> @m {
                                tr {
                                    td @m[0], :class('where ' ~ @m[1]);
                                    td "{@m[2]} lines, " ~ (@m[1] eq 'both' ?? 'both halves' !! 'the server only');
                                }
                            }
                            tr {
                                td 'is server', :class('where srv');
                                td(%x<server> ?? %x<server>.join(', ') !! 'none: the page needs nothing from the server after it loads');
                            }
                        }
                    }
                }
            }
        }

        p :class<foot>, {
            text "This server is %e<engine> on %e<os>, up ";
            $uptime = span ago($up);
            text '. Each demo is its own process behind one proxy. The split above is read from each '
               ~ "demo's source by Webraku's bundler as this page renders. ";
            a 'Webraku on GitHub', :href('https://github.com/ash/webraku');
            text ' · ';
            a 'raku.online', :href('https://raku.online/');
        }
    }

    react {
        whenever every(1) { $uptime.text = ago(++$up) }
        whenever $cards.on('click') -> $ev {
            my $b = $ev<target>.closest('button');
            if $b {
                my $k = $b.getAttribute('data-k').Str.Int;
                my $open = @panel[$k].attr('class') eq 'split open';
                @panel[$k].set('class', $open ?? 'split' !! 'split open');
                @toggle[$k].text = $open ?? 'how it is split' !! 'hide';
            }
        }
    }
}

serve;
