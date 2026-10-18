#!/usr/bin/env rakupp
# Unicode explorer — Unicode's tables on the server, the arithmetic in the browser.
#
#     webraku run examples/unicode/unicode.raku --port=8802
#
# Every named character can be searched for, picked and taken apart. The work
# is split by what each half has:
#
#   The server has Unicode's database: Raku++'s `uniname` and `uniprop`.
#   Names.rakumod builds an index of every name when the server starts — 4.6 MB
#   of text — and `find`, `about` and `name-codes` answer from it. Only those
#   `is server` subs use it, so it never reaches the browser.
#
#   The browser has the arithmetic. Codes.rakumod turns a code point into its
#   UTF-8 bytes and UTF-16 units and counts a string four ways, so a pick or a
#   keystroke shows those at once, with no request. The server uses the same
#   subs to render the first page.
#
# A typed search waits for a pause in the typing before it asks, and an answer
# that is not for the latest question is dropped.
use Webraku;
use lib $?FILE.IO.parent.Str;
use Codes;
use Names;

stylesheet q:to/CSS/;
    :root { --ink: #1d1d1b; --muted: #77736b; --rule: #e4e0d8; --paper: #fbfaf7; --card: #fff;
            --line: #cfc9bd; --accent: #1f5f8b; --soft: #f1eee6; --pick: #e2ecf4 }
    @media (prefers-color-scheme: dark) {
        :root { --ink: #e8e6e1; --muted: #9c978d; --rule: #34332f; --paper: #161614; --card: #1f1f1c;
                --line: #45433e; --accent: #7fb6dc; --soft: #262622; --pick: #1d2a34 }
    }
    * { box-sizing: border-box }
    body { font: 15px/1.5 system-ui, sans-serif; margin: 0; background: var(--paper); color: var(--ink) }
    main { max-width: 64rem; margin: 0 auto; padding: 1.2rem 1rem 3rem }
    nav.demos { display: flex; justify-content: space-between; font-size: .85rem; margin-bottom: 1.6rem }
    nav.demos a { color: var(--muted); text-decoration: none }
    nav.demos a:hover { color: var(--ink) }
    h1 { font-size: 1.5rem; margin: 0 0 .2rem }
    .sub { color: var(--muted); margin: 0 0 1.2rem; max-width: 44rem }
    input.q, textarea { font: inherit; width: 100%; padding: .55rem .75rem; border: 1px solid var(--line);
                        border-radius: .45rem; background: var(--card); color: var(--ink) }
    input.q { font-size: 1.05rem }
    .found { font-size: .85rem; color: var(--muted); margin: .35rem 0 .9rem; min-height: 1.3em }
    .layout { display: grid; grid-template-columns: 1fr 21rem; gap: 1.6rem; align-items: start }
    .layout > * { min-width: 0 }
    .hits { display: grid; grid-template-columns: repeat(auto-fill, minmax(3.2rem, 1fr)); gap: .3rem }
    .hits button { font: 1.5rem/1 system-ui, 'Apple Color Emoji', 'Segoe UI Emoji', 'Noto Sans Symbols 2', sans-serif;
                   aspect-ratio: 1; border: 1px solid var(--rule); border-radius: .4rem;
                   background: var(--card); color: var(--ink); cursor: pointer; padding: 0; overflow: hidden }
    .hits button:hover { border-color: var(--line); background: var(--soft) }
    .hits button.on { border-color: var(--accent); background: var(--pick) }
    .hits button.blank::after { content: 'space'; font-size: .55rem; color: var(--muted) }
    .detail { position: sticky; top: 1rem; background: var(--card); border: 1px solid var(--rule);
              border-radius: .6rem; padding: 1rem 1.1rem }
    .big { font: 4.4rem/1.2 system-ui, 'Apple Color Emoji', 'Segoe UI Emoji', sans-serif; text-align: center;
           min-height: 5.4rem }
    .detail h2 { font-size: .95rem; margin: .2rem 0 .1rem; text-align: center; word-break: break-word }
    .detail .code { text-align: center; color: var(--muted); font-size: .85rem; margin: 0 0 .7rem }
    .detail table { width: 100%; border-collapse: collapse; font-size: .82rem }
    .detail td { padding: .22rem 0; border-top: 1px solid var(--rule); vertical-align: top }
    .detail td:first-child { color: var(--muted); width: 6.5rem; padding-right: .5rem }
    .detail td.mono { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; word-break: break-all }
    .detail h3 { font-size: .78rem; text-transform: uppercase; letter-spacing: .04em; color: var(--muted);
                 margin: .9rem 0 .2rem }
    .detail .row { display: flex; gap: .4rem; margin-top: .7rem }
    button.small { font: inherit; font-size: .82rem; padding: .3rem .7rem; border: 1px solid var(--line);
                   border-radius: .4rem; background: var(--card); color: var(--ink); cursor: pointer }
    pre { margin: .3rem 0 0; padding: .6rem .7rem; background: var(--soft); border-radius: .4rem;
          font: .74rem/1.55 ui-monospace, SFMono-Regular, Menlo, monospace; overflow-x: auto; white-space: pre }
    .busy { opacity: .55 }
    section.inspect { margin-top: 2.4rem; border-top: 1px solid var(--rule); padding-top: 1.4rem }
    section.inspect h2 { font-size: 1.05rem; margin: 0 0 .3rem }
    section.inspect p { color: var(--muted); font-size: .88rem; margin: 0 0 .6rem; max-width: 44rem }
    .stats { display: flex; flex-wrap: wrap; gap: .4rem 1.4rem; margin: .7rem 0; font-variant-numeric: tabular-nums }
    .stats b { font-size: 1.15rem }
    table.cps { border-collapse: collapse; width: 100%; font-size: .85rem }
    table.cps td { padding: .25rem .6rem .25rem 0; border-top: 1px solid var(--rule) }
    table.cps td.g { font-size: 1.25rem; width: 2.5rem; text-align: center }
    table.cps td.mono { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; white-space: nowrap }
    .split { font-size: .85rem; color: var(--muted); margin-top: 2rem; max-width: 44rem }
    code { font: .85em ui-monospace, SFMono-Regular, Menlo, monospace; background: var(--soft);
           padding: .05rem .3rem; border-radius: .25rem }
    @media (max-width: 50rem) {
        .layout { grid-template-columns: 1fr }
        .detail { position: static }
        table.cps td.u8 { display: none }
    }
    CSS

# ---------- the server ----------

#| Search Unicode's names, or look up a code or a pasted character.
sub find(Str $query) is server { search-names($query) }

#| What Unicode's tables say about one character.
sub about(Int $cp) is server { describe-cp($cp) }

#| The names and categories of a string's code points.
sub name-codes(@cps) is server { names-of(@cps) }

#| The size of the index, for the page to say.
sub index-facts() is server { index-size() }

# ---------- the page ----------

#| The four counts of a string, as the page shows them.
sub count-line(Str $s --> List) {
    my %t = text-stats($s);
    (%t<chars>, %t<cps>, %t<utf8>, %t<utf16>)
}

sub explorer(Int $start) {
    my %found = find('');
    my %info  = about($start);
    my %size  = index-facts();
    my $cp    = %info<cp>;
    my $text  = "Camelia 🦋 says «hi» 🇺🇦 x²";
    my @names = name-codes($text.ords.Array).list;

    my ($q, $found-line, $hits, $big, $title, $code, %prop, %enc, $copy, $snippet);
    my ($area, @stat, $rows);

    main {
        nav :class<demos>, {
            a '← Webraku demos', :href('/');
            a 'source', :href('https://github.com/ash/webraku/tree/main/examples/unicode');
        }
        h1 'Unicode explorer';
        p "Every named character, searched on the server — {commas(%size<all>)} names in Raku++'s tables. "
          ~ 'The bytes and the counting are worked out in your browser.', :class<sub>;

        $q = input :class<q>, :type<search>, :autocomplete<off>, :spellcheck<false>, :value(''),
                   :placeholder('butterfly · arrow left · U+1F600 · or paste a character'),
                   :aria-label('search');
        $found-line = p "{%found<total>} characters: {%found<note>}", :class<found>;

        div :class<layout>, {
            $hits = div :class<hits>, {
                for %found<hits>.list -> @h {
                    my $g = glyph(@h[0], @h[2]);
                    button $g, :data-cp(~@h[0]), :data-gc(@h[2]), :title(@h[1]),
                           :class(($g ?? '' !! 'blank ') ~ (@h[0] == $cp ?? 'on' !! ''));
                }
            }
            aside :class<detail>, {
                $big   = div glyph($cp, %info<gc>), :class<big>;
                $title = h2 %info<name>;
                $code  = p "U+{hex4($cp)} · %info<gc-name>", :class<code>;
                table {
                    for <block Block>, <script Script>, <age Age>, <bidi Bidi>, <width Width>,
                        <numeric Numeric>, <upper Uppercase>, <lower Lowercase>, <title Titlecase>,
                        <nfd Decomposed> -> ($k, $label)
                    {
                        tr { td $label; %prop{$k} = td(%info{$k} || '—') }
                    }
                }
                h3 'Encoded';
                table {
                    tr { td 'UTF-8';  %enc<u8>  = td bytes-hex(utf8-bytes($cp)), :class<mono> }
                    tr { td 'UTF-16'; %enc<u16> = td units-hex(utf16-units($cp)), :class<mono> }
                    tr { td 'decimal'; %enc<dec> = td ~$cp, :class<mono> }
                    tr { td 'HTML';   %enc<html> = td "&#x{hex4($cp)};", :class<mono> }
                }
                div :class<row>, { $copy = button 'Copy the character', :class<small> }
                h3 'In Raku';
                $snippet = pre raku-snippet($cp, %info<name>, %info<block>);
            }
        }

        section :class<inspect>, {
            h2 "What's in a string";
            p 'Type or paste anything. The counts come from your browser as you type; '
              ~ 'the names come from the server once you pause.';
            $area = textarea $text, :rows(2), :spellcheck<false>, :aria-label('text to inspect');
            div :class<stats>, {
                my @c = count-line($text);
                my @what = 'characters', 'code points', 'bytes of UTF-8', 'UTF-16 units';
                for ^4 -> $k {
                    span { @stat[$k] = b ~@c[$k]; text " @what[$k]" }
                }
            }
            $rows = tag 'table', :class<cps>, {
                draw-codes($text.ords.Array, @names);
            }
        }

        p raw('<code>find</code>, <code>about</code>, <code>name-codes</code> and <code>index-facts</code> are '
            ~ 'marked <code>is server</code>: their bodies, and Names.rakumod behind them, run on the server only. '
            ~ 'Codes.rakumod is called by the page itself, so it runs in both places.'), :class<split>;
    }

    #| One table row per code point.
    sub draw-codes(@cps, @nm) {
        for @cps.head(256).kv -> $k, $c {
            my @n = (@nm[$k] // ['…', 'Cn']).list;
            tr {
                td glyph($c, @n[1]), :class<g>;
                td "U+{hex4($c)}", :class<mono>;
                td bytes-hex(utf8-bytes($c)), :class('mono u8');
                td @n[0];
            }
        }
    }

    #| Show one character in the panel: what arithmetic gives at once, then
    #| what the server knows.
    my $info-asked = 0;
    sub pick(Int $c, Str $name, Str $gc) {
        $cp = $c;
        for $hits.kids.grep(Element) -> $b {
            my $blank = !glyph($b.attr('data-cp').Int, $b.attr('data-gc'));
            $b.set('class', ($blank ?? 'blank ' !! '') ~ ($b.attr('data-cp') eq ~$c ?? 'on' !! ''));
        }
        $big.text = glyph($c, $gc);
        $title.text = $name;
        $code.text = "U+{hex4($c)}";
        %enc<u8>.text  = bytes-hex(utf8-bytes($c));
        %enc<u16>.text = units-hex(utf16-units($c));
        %enc<dec>.text = ~$c;
        %enc<html>.text = "&#x{hex4($c)};";
        $snippet.text = raku-snippet($c, $name, '');
        window().history.replaceState(Nil, '', url("/u/{hex4($c)}"));
        my $mine = ++$info-asked;
        %prop{$_}.set('class', 'busy') for %prop.keys;
        my %i = about($c);
        return unless $mine == $info-asked;
        $code.text = "U+{hex4($c)} · %i<gc-name>";
        for %prop.kv -> $k, $td { $td.text = %i{$k} || '—'; $td.set('class', '') }
        $snippet.text = raku-snippet($c, %i<name>, %i<block>);
    }

    my $search-asked = 0;
    sub run-search(Int $mine, Str $query) {
        $found-line.text = 'searching…';
        my %f = find($query);
        return unless $mine == $search-asked;
        $found-line.text = %f<total> == 0 ?? 'nothing by that name'
            !! "{commas(%f<total>)} character{%f<total> == 1 ?? '' !! 's'}"
               ~ (%f<note> ?? ": %f<note>" !! '')
               ~ (%f<total> > %f<hits>.elems ?? ", the first {%f<hits>.elems} shown" !! '');
        render-list $hits, {
            for %f<hits>.list -> @h {
                my $g = glyph(@h[0], @h[2]);
                button $g, :data-cp(~@h[0]), :data-gc(@h[2]), :title(@h[1]),
                       :class(($g ?? '' !! 'blank ') ~ (@h[0] == $cp ?? 'on' !! ''));
            }
        }
    }

    my $names-asked = 0;
    sub inspect(Str $s) {
        my @c = count-line($s);
        @stat[$_].text = ~@c[$_] for ^4;
        my @cps = $s.ords.Array;
        render-list $rows, { draw-codes(@cps, []) };
        my $mine = ++$names-asked;
        after(0.3).tap: {
            if $mine == $names-asked {
                my @nm = name-codes(@cps).list;
                render-list $rows, { draw-codes(@cps, @nm) } if $mine == $names-asked;
            }
        }
    }

    react {
        whenever $q.inputs -> $ev {
            my $query = $ev<target><value>.Str;
            $q.set('value', $query);
            my $mine = ++$search-asked;
            after(0.2).tap: { run-search($mine, $query) if $mine == $search-asked }
        }
        whenever $hits.on('click') -> $ev {
            my $b = $ev<target>.closest('button');
            if $b {
                pick($b.getAttribute('data-cp').Str.Int, $b.getAttribute('title').Str,
                     $b.getAttribute('data-gc').Str);
            }
        }
        whenever $copy.clicks {
            window().navigator.clipboard.writeText($cp.chr);
            $copy.text = 'Copied';
            after(1.2).tap: { $copy.text = 'Copy the character' };
        }
        whenever $area.inputs -> $ev {
            my $s = $ev<target><value>.Str;
            inspect($s);
        }
    }
}

page '/', :title('Unicode explorer · Webraku'), { explorer(0x1F98B) }

page '/u/:hex', :title('Unicode explorer · Webraku'), -> $hex {
    explorer((try $hex.parse-base(16)) // 0x1F98B)
}

serve;
