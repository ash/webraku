# Webraku::Client — the same builders, in a browser.
#
# This file only ever runs under `rakupp --target=js`. It installs a hook into
# Webraku::HTML so that building an element also makes (or adopts) a DOM node,
# and it provides the reconcile pass that writes changed properties back into
# the page after every event turn.
#
# Two modes:
#   create   — the element gets a fresh DOM node. Used for anything the page
#              did not already contain.
#   hydrate  — the element ADOPTS the next child of the open parent. Because the
#              server built its HTML from this same code and the same data, the
#              walk lines up; when a tag does not match, the node is replaced and
#              the mismatch is reported rather than hidden.
#
# There is no virtual DOM. An element is retained, its writable properties are
# compared with what the DOM currently shows, and only the differences are
# written. The one place a tree is diffed is `render-list`, where a list of
# children is replaced.
unit module Webraku::Client;

use js;
use Webraku::HTML;
use Webraku::Route;
use Webraku::Rpc;

my $DOC       = JS.document;
my @LIVE;                    # every element that may need reconciling
my $HYDRATING = False;
my @HCURSOR;                 # per open parent: the next existing child to adopt
my $PENDING   = False;       # a reconcile is already queued for this turn

#| Every element built so far, in build order. The bundle's hydration check
#| compares this against the server's HTML.
sub live-elements() is export { @LIVE }

# ---------- making and adopting nodes ----------

#| Where a child node actually belongs. For a <table> the browser keeps rows in
#| a <tbody> it inserted itself, so appending a <tr> to the table directly would
#| put it after that body rather than in it.
sub child-host($node, Str $childTag) {
    return $node unless $childTag eq 'tr';
    return $node unless $node<tagName>.Str.lc eq 'table';
    $node.querySelector('tbody') // $node;
}

sub apply-attrs(Element $el) {
    for $el.attrs.kv -> $k, $v {
        next if $v ~~ Bool && !$v;
        next unless $v.defined;
        $el.node.setAttribute($k, $v ~~ Bool ?? '' !! $v.Str);
        $el.applied-attrs{$k} = $v;
    }
}

sub apply-text(Element $el) {
    if $el.text.defined {
        $el.node<textContent> = $el.text;
        $el.applied-text = $el.text;
    }
}

# The hook Webraku::HTML calls for every element it builds.
sub make-node(Element $el) {
    my $parent = current-parent();
    if $HYDRATING && $parent ~~ Element:D && $parent.node {
        # The candidate is walked as a SIBLING CHAIN, not indexed out of
        # `.children`: that is an HTMLCollection in a browser but crosses to Raku
        # as a copied Array from anything array-like, and the two do not index
        # alike. `firstElementChild` and `nextElementSibling` are plain
        # properties answering one node, and behave the same everywhere.
        my $cand = @HCURSOR ?? @HCURSOR[*-1] !! Nil;
        # A browser's HTML parser inserts a <tbody> that the markup never wrote,
        # so a <tr> built as a direct child of a <table> meets that instead of
        # the row. Step into it — the rows are its children, and they are what
        # this code is building.
        if $cand && $el.tag eq 'tr' && $cand<tagName>.Str.lc eq 'tbody' {
            $cand = $cand<firstElementChild>;
        }
        @HCURSOR[*-1] = $cand ?? $cand<nextElementSibling> !! Nil if @HCURSOR;
        # No candidate at this position simply means the server did not send a
        # node here — anything built after the first render is in that case — so
        # it is created without comment. Only a candidate of the WRONG TAG is a
        # real mismatch, and that one is reported.
        if !$cand {
            $el.node = $DOC.createElement($el.tag);
            apply-attrs($el); apply-text($el);
            child-host($parent.node, $el.tag).appendChild($el.node);
            @LIVE.push: $el;
            return $el;
        }
        if $cand<tagName>.Str.lc eq $el.tag.lc {
            $el.node = $cand;
            # Adopted: the DOM already shows what the server rendered, so record
            # that as applied and write nothing. Writing it anyway would be
            # correct but would touch every node on load.
            $el.applied-text = $el.text if $el.text.defined;
            $el.applied-attrs{$_} = $el.attrs{$_} for $el.attrs.keys;
            @LIVE.push: $el;
            return $el;
        }
        # The page is not what this code would have built. Say so — a silent
        # repaint here is how a hydration bug stays hidden for months — and
        # carry on by building the node fresh.
        JS.console.warn("webraku: hydration mismatch — the page has <{$cand<tagName>.Str.lc}> where this code builds <{$el.tag}>; the node was replaced");
        $el.node = $DOC.createElement($el.tag);
        apply-attrs($el); apply-text($el);
        $parent.node.replaceChild($el.node, $cand);
        @LIVE.push: $el;
        return $el;
    }
    $el.node = $DOC.createElement($el.tag);
    apply-attrs($el);
    apply-text($el);
    child-host($parent.node, $el.tag).appendChild($el.node) if $parent ~~ Element:D && $parent.node;
    @LIVE.push: $el;
    $el;
}

# Webraku::HTML pushes an element onto its own stack for the duration of a
# builder block; the hydration cursor follows it, one entry per open parent, so
# that each level adopts its own children rather than the root's.
sub scope-in(Element $e)  { @HCURSOR.push: ($HYDRATING && $e.node) ?? $e.node<firstElementChild> !! Nil }
sub scope-out(Element $)  { @HCURSOR.pop }

# ---------- events ----------

#| Attach one DOM listener. Webraku::HTML calls this the first time an element's
#| event Supply is asked for — which is when `whenever $b.clicks` evaluates it,
#| before the enclosing `react` starts waiting and never returns.
sub listen(Element $el, Str $name) is export {
    return unless $el.node;
    my $sup = $el.supplier($name);
    $el.node.addEventListener($name, -> $ev {
        # A submit inside a form would navigate away; a page that handles the
        # event does not want that.
        $ev.preventDefault if $name eq 'submit';
        $sup.emit($ev);
        schedule-reconcile();
    });
    $el.listened = True;
}

# ---------- reconcile ----------

#| Write every changed property into the DOM. Cheap: one comparison per live
#| element, and a DOM write only where something actually differs.
sub reconcile() is export {
    for @LIVE -> $el {
        next unless $el.node;
        if $el.text.defined && (!$el.applied-text.defined || $el.text ne $el.applied-text) {
            $el.node<textContent> = $el.text;
            $el.applied-text = $el.text;
        }
        for $el.attrs.kv -> $k, $v {
            next if $el.applied-attrs{$k}:exists && $el.applied-attrs{$k} eqv $v;
            if ($v ~~ Bool && !$v) || !$v.defined {
                $el.node.removeAttribute($k);
            }
            else {
                $el.node.setAttribute($k, $v ~~ Bool ?? '' !! $v.Str);
                # `value` on an input is a PROPERTY: the attribute only sets the
                # default, so typing into the field then ignores it.
                $el.node<value> = $v.Str if $k eq 'value';
            }
            $el.applied-attrs{$k} = $v;
        }
    }
}

#| Queue one reconcile for the end of this event turn. Several handlers firing
#| for the same event then cost one pass, not one each.
sub schedule-reconcile() is export {
    return if $PENDING;
    $PENDING = True;
    JS.queueMicrotask(-> { $PENDING = False; reconcile() });
}

# ---------- lists ----------

#| Replace the children of `$parent` with what `&body` builds, and put the new
#| nodes in the page. This is the one place a tree is rebuilt rather than
#| patched: a list whose items come and go.
#|
#|     render-list $ul, { li .text, :key(.id) for @todos }
sub render-list(Element $parent, &body) is export {
    # Every element in the old subtree leaves the document, so it must leave
    # @LIVE too — otherwise reconcile keeps writing into detached nodes, and the
    # list grows without bound on a page that re-renders often.
    my @dead;
    sub collect(Element $e) { @dead.push: $e; collect($_) for $e.kids.grep(Element) }
    collect($_) for $parent.kids.grep(Element);
    my %dead = @dead.map({ $_.WHICH => True }).Hash;
    @LIVE = @LIVE.grep({ !%dead{$_.WHICH} }).Array;

    # The FIRST draw of a parent the server already filled adopts what is there;
    # clearing it would throw away exactly what hydration is for, and every child
    # would then report a mismatch against a parent that had just been emptied.
    # Every later draw clears and rebuilds — and so does a first draw into a
    # parent whose children this code already built some other way, with a
    # block: that one was hydrated when it was built, and this is a redraw.
    my $built = $parent.kids.elems || $parent.text.defined;
    $parent.node<innerHTML> = '' if $parent.drawn || !$HYDRATING || $built;
    $parent.drawn = True;
    $parent.kids = [];
    $parent.text = Str;
    $parent.applied-text = Str;
    with-parent($parent, &body);
    reconcile();
    $parent;
}

# ---------- the browser itself ----------

#| The browser's global object, for what the builders do not cover. The
#| server half answers a stand-in that does nothing.
sub window() is export { JS.globalThis }

# ---------- sources the framework hands out ----------

#| A Supply that emits every `$seconds`. `Supply.interval` works here too; this
#| one also schedules a reconcile, so a `whenever` body that changes an element
#| reaches the page without saying so.
sub every(Real $seconds --> Supply) is export {
    supply {
        whenever Supply.interval($seconds) -> $n { emit $n; schedule-reconcile() }
    }
}

#| A Supply that emits once, after `$seconds`.
sub after(Real $seconds --> Supply) is export {
    supply {
        whenever Promise.in($seconds) { emit True; schedule-reconcile(); done }
    }
}

# ---------- mounting ----------

#| Build the page under `$root` and bring it to life. `$hydrate` adopts the
#| nodes already there instead of creating new ones.
sub mount(&body, :$selector = 'body', Bool :$hydrate = False) is export {
    my $rootnode = $selector eq 'body' ?? $DOC<body> !! $DOC.querySelector($selector);
    die "webraku: no element matches '$selector'" unless $rootnode;
    my $root = Element.new(tag => $selector eq 'body' ?? 'body' !! 'div');
    $root.node = $rootnode;
    $HYDRATING = $hydrate;
    webraku-set-browser(True);
    webraku-element-hook(&make-node);
    webraku-scope-hook(&scope-in, &scope-out);
    webraku-listen-hook(&listen);
    # A handler that awaits a server call changes the page after its event turn
    # is over, so the reconcile that turn scheduled has already run. A microtask
    # queued when the answer arrives would run too early as well — before the
    # caller's own continuation — so this one is a task, which runs after every
    # continuation the answer releases.
    webraku-rpc-hook({ JS.setTimeout(-> { reconcile() }, 0) });
    # A page body ends in a `react`, and a `react` in a browser never returns —
    # it is the page, for as long as the page is open — and a body that calls an
    # `is server` sub suspends at its first `await`. So there is no moment "after
    # the build" to hook, and `$HYDRATING` is never turned off: whether a builder
    # adopts or creates is decided per element, by whether the walk still has a
    # node at that position. A node the server did not send has no candidate, and
    # is created. That is self-correcting, where a timer was a race — it fired at
    # the first await, and the whole page was built a second time beneath the
    # first.
    schedule-reconcile();
    with-parent($root, &body);
    $root;
}

# ---------- routes, in the browser ----------
#
# The application's `page` calls run here too — the bundle carries the whole
# program — so the browser ends up with the same table the server has, built by
# the same statements. `api` and `static` are the server's business and are
# accepted and ignored, so that a program need not know which half is reading it.

my @ROUTES;

sub page(Str $pattern, &body, Str :$title = 'Webraku') is export {
    @ROUTES.push: Route.new(kind => 'page', :$pattern, segments => split-path($pattern), :&body, :$title);
}
sub api(Str $pattern, &body) is export { }
sub static(Str $prefix, Str $dir) is export { }
sub stylesheet(Str $css) is export { }

#| The bundle's last statement. Find the page this URL names, replay the log the
#| server embedded, and hydrate the tree the server sent.
sub webraku-hydrate() is export {
    webraku-load-replay();
    my $path = JS.location<pathname>.Str || '/';
    my $base = webraku-page-base();
    $path = $path.substr($base.chars) || '/'
        if $base && ($path eq $base || $path.starts-with("$base/"));
    my ($route, %params) = match-route(@ROUTES, $path, kind => 'page');
    without $route {
        JS.console.warn("webraku: no page matches $path; nothing was hydrated");
        return;
    }
    my @args = $route.param-names.map({ %params{$_} });
    # `mount` does NOT return: a page body ends in a `react` that runs for as
    # long as the page is open. Everything that has to happen after the tree is
    # built and before the react starts waiting happens inside `mount`.
    mount({ $route.body.(|@args) }, selector => '#webraku-root', hydrate => True);
}
