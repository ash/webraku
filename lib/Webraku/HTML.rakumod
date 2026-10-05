# Webraku::HTML — the element tree, and a builder sub per HTML tag.
#
# One `Element` class serves both homes. On the server it renders to a string;
# in the browser Webraku::Client gives it a DOM node and writes the properties
# that changed. Neither is known here — this file is pure Raku and runs on any
# engine, and under `rakupp --target=js` as well.
#
# A builder call nests by handing the block a fresh parent:
#
#     div :class<card>, {
#         h2 'Title';
#         ul { li $_ for @items }
#     }
#
# The parent is a lexical stack in this module rather than a dynamic variable:
# a `$*VAR` lookup costs on every builder call, and the transpiler has no
# dynamic scope worth leaning on. A builder appends itself to the innermost
# open parent and returns the element, so `my $b = button 'Go'` both places it
# and names it — which is how a handler gets hold of it afterwards.
unit module Webraku::HTML;

# ---------- escaping ----------

#| Text into HTML. Everything a builder is handed as a Str goes through here;
#| `raw` is the one door that skips it.
sub escape-html(Str() $s --> Str) is export {
    $s.trans(['&', '<', '>', '"', "'"] => ['&amp;', '&lt;', '&gt;', '&quot;', '&#39;']);
}

#| An attribute value sits inside double quotes, so `<` and `>` may stay as they
#| are; `&` and `"` may not.
sub escape-attr(Str() $s --> Str) is export {
    $s.trans(['&', '"'] => ['&amp;', '&quot;']);
}

#| Markup that is already HTML and crosses into the tree unescaped. The name is
#| deliberately blunt: every injection this framework can suffer comes through
#| here, so it should be visible in a review.
class Raw is export {
    has Str $.html;
    method Str(--> Str) { $!html }
    method gist(--> Str) { $!html }
}
sub raw(Str() $html --> Raw) is export { Raw.new(:$html) }

# ---------- the element ----------

# The void elements: no children, no closing tag. The list is the HTML
# standard's, and a builder for one refuses content rather than dropping it.
my constant VOID = <area base br col embed hr img input link meta param source track wbr>;

# Which half is running. Webraku::Client sets it; on the server it stays False,
# and the event Supplies an Element hands out are empty and already finished.
my $IN-BROWSER = False;
sub webraku-in-browser(--> Bool) is export { $IN-BROWSER }
sub webraku-set-browser(Bool $b) is export { $IN-BROWSER = $b }

#| A node in the page.
#|
#| `text` is the element's text content and is writable — `$l.text = "…"` is the
#| whole of what a handler usually does. When it is defined it IS the content;
#| otherwise `kids` renders in order, which is how mixed content is written.
#| `attrs` is writable too, through `set`.
class Element is export {
    has Str $.tag;
    has Str $.text is rw;        # undefined = the content is @!kids
    has %.attrs is rw;
    has @.kids is rw;            # Element, Str or Raw, in order
    has $.node is rw;            # the DOM node in the browser; Nil on the server
    has Str $.applied-text is rw;      # what the DOM currently shows
    has %.applied-attrs is rw;         # …and for each attribute
    has %.taps;                        # event name => Supplier, made on first use
    has Bool $.listened is rw = False; # Webraku::Client: listeners attached?
    has Bool $.drawn is rw = False;    # `render-list` has rebuilt this one before

    method void(--> Bool) { $!tag (elem) VOID }

    #| Set an attribute. `Nil` or `False` removes it; `True` writes it bare.
    method set(Str $k, $v --> Element) { %!attrs{$k} = $v; self }
    method attr(Str $k) { %!attrs{$k} }

    #| Replace the children. Used for a list that changes: the browser side
    #| diffs the new list against the old one, keyed by `:key` where given.
    method set-kids(@new --> Element) { @!kids = @new; $!text = Str; self }

    #| The events. In the browser each name gets one Supplier, and
    #| Webraku::Client attaches the DOM listener the first time one is asked for
    #| — a page with no handlers registers none.
    #|
    #| On the SERVER the answer is an empty Supply that is already done, not a
    #| live one that never emits. That is the difference between a page that
    #| renders and a server that hangs: `react` waits for its sources to
    #| finish, so a live Supplier with no emitter blocks forever. (Rakudo blocks;
    #| Raku++ returns at once, which is a divergence and not something to lean
    #| on.) An already-finished source ends the react immediately on both.
    method on(Str $name --> Supply) {
        return Supply.from-list() unless webraku-in-browser();
        # The DOM listener is attached HERE, when the Supply is first asked for,
        # and not in a pass after the page body has run. `whenever $b.clicks`
        # evaluates this before the enclosing `react` starts waiting, and a
        # `react` in a browser never finishes — so a pass scheduled after the
        # body would never run, and no button would ever work.
        my $fresh = !(%!taps{$name}:exists);
        my $sup = self.supplier($name);
        LISTEN(self, $name) if $fresh;
        $sup.Supply;
    }
    method supplier(Str $name) { %!taps{$name} //= Supplier.new; %!taps{$name} }
    method tapped-events() { %!taps.keys }

    method clicks(--> Supply)  { self.on('click') }
    method inputs(--> Supply)  { self.on('input') }
    method changes(--> Supply) { self.on('change') }
    method submits(--> Supply) { self.on('submit') }
    method keyups(--> Supply)  { self.on('keyup') }

    # ----- rendering
    method attrs-html(--> Str) {
        %!attrs.keys.sort.map(-> $k {
            my $v = %!attrs{$k};
            # A boolean attribute is written bare when true and left out when
            # false or undefined, which is what the HTML standard says it means.
            $v ~~ Bool  ?? ($v ?? ' ' ~ $k !! '')
                        !! ($v.defined ?? ' ' ~ $k ~ '="' ~ escape-attr($v) ~ '"' !! '');
        }).join;
    }

    method content-html(--> Str) {
        return escape-html($!text) if $!text.defined;
        @!kids.map({
            $_ ~~ Element ?? .html !! $_ ~~ Raw ?? .html !! escape-html($_.Str)
        }).join;
    }

    method html(--> Str) {
        my $open = '<' ~ $!tag ~ self.attrs-html ~ '>';
        return $open if self.void;
        $open ~ self.content-html ~ '</' ~ $!tag ~ '>';
    }
    method gist(--> Str) { self.html }
    method Str(--> Str)  { self.html }
}

# ---------- the builder stack ----------

my @STACK;

#| Open `$el` as the parent for the duration of `&body`. Every framework entry
#| point that builds a subtree goes through here, so a body that dies cannot
#| leave the stack unbalanced.
sub with-parent(Element $el, &body) is export {
    @STACK.push: $el;
    SCOPE-IN($el);
    # In the browser a page that calls an `is server` sub is ASYNC: `body()`
    # hands back a Promise and the tree is built in a continuation. Returning
    # here would pop the stack before a single builder had run, and the first
    # one would then find no open parent — which showed up as a child pushed
    # into nothing. Awaiting keeps this frame open for as long as the body
    # takes. Under the interpreter a block returns its value and the `if` is
    # false, so nothing is awaited and nothing changes.
    my $r = body();
    # The guard is the ENGINE, not the value: a JavaScript Promise crossing back
    # into Raku arrives as `Any`, so `$r ~~ Promise` is false there and the test
    # would never fire. `await` on a plain value is fine under Raku++ and under
    # `--target=js`; Rakudo refuses it, which is why it sits behind a flag that
    # is only ever true in a browser. The line also has to be written HERE, not
    # called through a hook: the transpiler decides what is async by reading the
    # text, and a call through a `&` variable tells it nothing.
    $r = await $r if webraku-in-browser();
    SCOPE-OUT($el);
    @STACK.pop;
    $r;
}

# Webraku::Client follows this stack with a cursor of its own, so that a builder
# under hydration knows which existing child it should adopt. On the server both
# hooks are no-ops.
# Webraku::Client attaches a DOM listener the first time an element's event is
# asked for. On the server there is nothing to listen to.
my &LISTEN = -> $, Str $ { };
sub webraku-listen-hook(&hook) is export { &LISTEN = &hook }

my &SCOPE-IN  = -> Element $ { };
my &SCOPE-OUT = -> Element $ { };
sub webraku-scope-hook(&in, &out) is export { &SCOPE-IN = &in; &SCOPE-OUT = &out }

#| The element a builder would append to, or Nil at the top of a page.
sub current-parent() is export { @STACK ?? @STACK[*-1] !! Element }

# Webraku::Client replaces this so a builder also makes (or adopts) a DOM node.
# On the server it stays the identity.
my &MAKE = -> Element $el { $el };
sub webraku-element-hook(&hook) is export { &MAKE = &hook }

#| Build one element and place it in the open parent. `@inner` holds text, Raw
#| markup, child Elements and at most one block; `%attrs` are the attributes.
sub el(Str $tag, *@inner, *%attrs --> Element) is export {
    my @body    = @inner.grep(Callable);
    my @content = @inner.grep(* !~~ Callable);
    my $el = Element.new(:$tag, attrs => %attrs);
    die "<$tag> is a void element and takes no content"
        if $el.void && (@body || @content);
    # The common case by a wide margin is one Str and nothing else — `p 'hi'`,
    # `td $cell`, `button 'Go'` — and that is what makes `.text` writable later.
    if @content == 1 && @content[0] ~~ Str {
        $el.text = @content[0];
    }
    else {
        # `.Array` is not decoration: a Seq assigned to an `@` attribute stays a
        # Seq under `--target=js`, and the first `.kids.push` then dies with
        # "Cannot call push on a Seq". The interpreter reifies it.
        $el.kids = @content.map({ $_ ~~ Element|Raw ?? $_ !! .Str }).Array;
    }
    MAKE($el);
    my $parent = current-parent();
    $parent.kids.push: $el if $parent ~~ Element:D;
    with-parent($el, $_) for @body;
    $el;
}

#| Any tag at all, including one HTML has never heard of: `tag 'my-widget', …`.
sub tag(Str $name, |c --> Element) is export { el($name, |c) }

#| A text node with no element around it, for mixed content:
#|     p { text 'Hello '; b 'world'; text '!' }
sub text(Str() $s) is export {
    my $parent = current-parent();
    die 'text used outside an element' unless $parent ~~ Element:D;
    # The parent may have been given its content as `.text`; moving it into the
    # children keeps one ordered list rather than two places to look.
    if $parent.text.defined { $parent.kids.push: $parent.text; $parent.text = Str }
    $parent.kids.push: $s;
    $s;
}

# ---------- a builder per tag ----------
#
# Three tag names cannot be bare subs in Raku. `i` is the imaginary unit, `map`
# insists on a comma after a block, and `sub` is a keyword — all three on
# Rakudo; Raku++ takes `i` and `map` but not `sub`. They are `italic`,
# `image-map` and `subscript` here, and `tag 'i', …` always works. Every other
# tag, `div`, `tr` and `q` included, is spelled as itself.

sub a(|c)          is export { el('a', |c) }
sub abbr(|c)       is export { el('abbr', |c) }
sub address(|c)    is export { el('address', |c) }
sub area(|c)       is export { el('area', |c) }
sub article(|c)    is export { el('article', |c) }
sub aside(|c)      is export { el('aside', |c) }
sub audio(|c)      is export { el('audio', |c) }
sub b(|c)          is export { el('b', |c) }
sub base(|c)       is export { el('base', |c) }
sub bdi(|c)        is export { el('bdi', |c) }
sub bdo(|c)        is export { el('bdo', |c) }
sub blockquote(|c) is export { el('blockquote', |c) }
sub body(|c)       is export { el('body', |c) }
sub br(|c)         is export { el('br', |c) }
sub button(|c)     is export { el('button', |c) }
sub canvas(|c)     is export { el('canvas', |c) }
sub caption(|c)    is export { el('caption', |c) }
sub cite(|c)       is export { el('cite', |c) }
sub code(|c)       is export { el('code', |c) }
sub col(|c)        is export { el('col', |c) }
sub colgroup(|c)   is export { el('colgroup', |c) }
sub data(|c)       is export { el('data', |c) }
sub datalist(|c)   is export { el('datalist', |c) }
sub dd(|c)         is export { el('dd', |c) }
sub del(|c)        is export { el('del', |c) }
sub details(|c)    is export { el('details', |c) }
sub dfn(|c)        is export { el('dfn', |c) }
sub dialog(|c)     is export { el('dialog', |c) }
sub div(|c)        is export { el('div', |c) }
sub dl(|c)         is export { el('dl', |c) }
sub dt(|c)         is export { el('dt', |c) }
sub em(|c)         is export { el('em', |c) }
sub embed(|c)      is export { el('embed', |c) }
sub fieldset(|c)   is export { el('fieldset', |c) }
sub figcaption(|c) is export { el('figcaption', |c) }
sub figure(|c)     is export { el('figure', |c) }
sub footer(|c)     is export { el('footer', |c) }
sub form(|c)       is export { el('form', |c) }
sub h1(|c)         is export { el('h1', |c) }
sub h2(|c)         is export { el('h2', |c) }
sub h3(|c)         is export { el('h3', |c) }
sub h4(|c)         is export { el('h4', |c) }
sub h5(|c)         is export { el('h5', |c) }
sub h6(|c)         is export { el('h6', |c) }
sub head(|c)       is export { el('head', |c) }
sub header(|c)     is export { el('header', |c) }
sub hgroup(|c)     is export { el('hgroup', |c) }
sub hr(|c)         is export { el('hr', |c) }
sub html(|c)       is export { el('html', |c) }
sub iframe(|c)     is export { el('iframe', |c) }
sub img(|c)        is export { el('img', |c) }
sub input(|c)      is export { el('input', |c) }
sub ins(|c)        is export { el('ins', |c) }
sub italic(|c)     is export { el('i', |c) }          # `i` is the imaginary unit
sub image-map(|c)  is export { el('map', |c) }        # `map` wants a comma after a block
sub kbd(|c)        is export { el('kbd', |c) }
sub label(|c)      is export { el('label', |c) }
sub legend(|c)     is export { el('legend', |c) }
sub li(|c)         is export { el('li', |c) }
sub link(|c)       is export { el('link', |c) }
sub main(|c)       is export { el('main', |c) }
sub mark(|c)       is export { el('mark', |c) }
sub menu(|c)       is export { el('menu', |c) }
sub meta(|c)       is export { el('meta', |c) }
sub meter(|c)      is export { el('meter', |c) }
sub nav(|c)        is export { el('nav', |c) }
sub noscript(|c)   is export { el('noscript', |c) }
sub object(|c)     is export { el('object', |c) }
sub ol(|c)         is export { el('ol', |c) }
sub optgroup(|c)   is export { el('optgroup', |c) }
sub option(|c)     is export { el('option', |c) }
sub output(|c)     is export { el('output', |c) }
sub p(|c)          is export { el('p', |c) }
sub param(|c)      is export { el('param', |c) }
sub picture(|c)    is export { el('picture', |c) }
sub pre(|c)        is export { el('pre', |c) }
sub progress(|c)   is export { el('progress', |c) }
sub q(|c)          is export { el('q', |c) }
sub rp(|c)         is export { el('rp', |c) }
sub rt(|c)         is export { el('rt', |c) }
sub ruby(|c)       is export { el('ruby', |c) }
sub s(|c)          is export { el('s', |c) }
sub samp(|c)       is export { el('samp', |c) }
sub script(|c)     is export { el('script', |c) }
sub search(|c)     is export { el('search', |c) }
sub section(|c)    is export { el('section', |c) }
sub select(|c)     is export { el('select', |c) }
sub slot(|c)       is export { el('slot', |c) }
sub small(|c)      is export { el('small', |c) }
sub source(|c)     is export { el('source', |c) }
sub span(|c)       is export { el('span', |c) }
sub strong(|c)     is export { el('strong', |c) }
sub style(|c)      is export { el('style', |c) }
sub subscript(|c)  is export { el('sub', |c) }        # `sub` is a keyword
sub summary(|c)    is export { el('summary', |c) }
sub sup(|c)        is export { el('sup', |c) }
sub table(|c)      is export { el('table', |c) }
sub tbody(|c)      is export { el('tbody', |c) }
sub td(|c)         is export { el('td', |c) }
sub template(|c)   is export { el('template', |c) }
sub textarea(|c)   is export { el('textarea', |c) }
sub tfoot(|c)      is export { el('tfoot', |c) }
sub th(|c)         is export { el('th', |c) }
sub thead(|c)      is export { el('thead', |c) }
sub time(|c)       is export { el('time', |c) }
sub title(|c)      is export { el('title', |c) }
sub tr(|c)         is export { el('tr', |c) }
sub track(|c)      is export { el('track', |c) }
sub u(|c)          is export { el('u', |c) }
sub ul(|c)         is export { el('ul', |c) }
sub video(|c)      is export { el('video', |c) }
sub wbr(|c)        is export { el('wbr', |c) }
