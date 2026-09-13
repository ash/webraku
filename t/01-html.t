#!/usr/bin/env rakupp
# Monarch::HTML — the builders and the element model. Pure Raku, so this runs
# identically under Raku++ and Rakudo; `./test.sh` runs it under both.
use lib $?FILE.IO.parent.parent.add('lib').Str;
use Monarch::HTML;

my $n = 0;
my $bad = 0;
sub is-it($got, $want, Str $desc) {
    $n++;
    if $got eq $want { say "ok $n - $desc" }
    else { $bad++; say "not ok $n - $desc"; say "#      got: $got"; say "# expected: $want" }
}

# ---------- escaping ----------
is-it escape-html('a & b'),        'a &amp; b',            'an ampersand is escaped';
is-it escape-html('<i>'),          '&lt;i&gt;',            'angle brackets are escaped';
is-it escape-html(Q{"x" and 'y'}), '&quot;x&quot; and &#39;y&#39;', 'both quote characters are escaped';
is-it escape-html('plain'),        'plain',                'text with nothing to escape is unchanged';
is-it escape-attr('a & "b" <c>'),  'a &amp; &quot;b&quot; <c>', 'an attribute keeps angle brackets';

# ---------- one element ----------
is-it (p 'hi').html,                    '<p>hi</p>',                    'an element with text';
is-it (p '<i>').html,                   '<p>&lt;i&gt;</p>',             'text is escaped, not markup';
is-it (p raw('<i>x</i>')).html,         '<p><i>x</i></p>',              'raw crosses unescaped';
is-it (p 'x', :id<a>, :class<b>).html,  '<p class="b" id="a">x</p>',    'attributes, sorted by name';
is-it (p 'x', :title('a & "b"')).html,  '<p title="a &amp; &quot;b&quot;">x</p>', 'an attribute value is escaped';
is-it (br).html,                        '<br>',                         'a void element has no closing tag';
is-it (img :src</a.png>, :alt<a>).html, '<img alt="a" src="/a.png">',   'a void element with attributes';

# ---------- boolean attributes ----------
is-it (button 'Go', :disabled).html,         '<button disabled>Go</button>', 'a true boolean attribute is bare';
is-it (button 'Go', :disabled(False)).html,  '<button>Go</button>',          'a false boolean attribute is left out';
is-it (button 'Go', :title(Str)).html,       '<button>Go</button>',          'an undefined attribute is left out';

# ---------- nesting ----------
is-it (div { p 'a'; p 'b' }).html, '<div><p>a</p><p>b</p></div>', 'a block nests its children in order';
is-it (ul { li $_ for <a b> }).html, '<ul><li>a</li><li>b</li></ul>', 'a loop inside a block';
is-it (table { tr { td '1'; td '2' } }).html, '<table><tr><td>1</td><td>2</td></tr></table>',
      '`tr` and `td` are ordinary builders';

# mixed content: `text` puts a bare string between elements
is-it (p { text 'Hello '; b 'world'; text '!' }).html, '<p>Hello <b>world</b>!</p>',
      'text nodes and elements interleave in order';

# ---------- the renamed three ----------
is-it (italic 'x').html,    '<i>x</i>',     'italic builds <i>';
is-it (subscript '2').html, '<sub>2</sub>', 'subscript builds <sub>';
is-it (image-map { }).html, '<map></map>',  'image-map builds <map>';
is-it (tag 'my-widget', 'x').html, '<my-widget>x</my-widget>', 'tag builds anything';

# ---------- the element is retained and writable ----------
{
    my $el = p 'before';
    $el.text = 'after';
    is-it $el.html, '<p>after</p>', 'text is writable after the element is built';
    $el.set('id', 'x');
    is-it $el.html, '<p id="x">after</p>', 'an attribute can be set afterwards';
    $el.set('id', Nil);
    is-it $el.html, '<p>after</p>', 'setting an attribute to Nil removes it';
}

# ---------- a builder returns its element, and places it ----------
{
    my $inner;
    my $outer = div { $inner = span 'x' };
    is-it $outer.html, '<div><span>x</span></div>', 'the child is placed in the parent';
    is-it $inner.tag, 'span', 'and the builder returns it';
    $inner.text = 'y';
    is-it $outer.html, '<div><span>y</span></div>', 'changing the child shows in the parent';
}

# ---------- composition by ordinary subs ----------
{
    sub card(Str $title, &body) { div :class<card>, { h2 $title; body() } }
    is-it card('T', { p 'body' }).html, '<div class="card"><h2>T</h2><p>body</p></div>',
          'a component is a sub taking a block';
}

# ---------- events are Supplies, and are inert on the server ----------
{
    my $b = button 'Go';
    is-it ($b.clicks ~~ Supply).Str, 'True', 'clicks answers a Supply';
    my $fired = 0;
    react { whenever $b.clicks { $fired++ } }
    is-it $fired.Str, '0', 'on the server the react block runs, and nothing fires';
}

# ---------- a void element refuses content ----------
{
    my $died = False;
    try { br 'nope'; CATCH { default { $died = True } } }
    is-it $died.Str, 'True', 'a void element refuses content rather than dropping it';
}

say "1..$n";
say $bad ?? "# $bad of $n checks FAILED" !! "# all $n checks passed";
exit $bad ?? 1 !! 0;
