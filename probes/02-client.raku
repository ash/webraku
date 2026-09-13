# probe 3b: same as p3, but `react` sits in the mainline, after the build, and
# attributes are explicit named parameters (no *%slurpy). marker: P3B-DOM
use JS;
my $doc = JS.document;
class El {
    has Str $.tag;
    has Str $.text is rw = '';
    has Str $.applied is rw = '';
    has $.node is rw;
    has Supplier $.tap = Supplier.new;
    method clicks { $!tap.Supply }
}
my @STACK;
my @LIVE;
sub el(Str $tag, Str $text, Str $id) {
    my $e = El.new(:$tag, :$text, applied => $text);
    $e.node = $doc.createElement($tag);
    $e.node<textContent> = $text;
    $e.node.setAttribute('id', $id) if $id;
    (@STACK ?? @STACK[*-1].node !! $doc.body).appendChild($e.node);
    @LIVE.push: $e;
    $e;
}
sub div(&body, Str :$id = '') { my $e = el('div', '', $id); @STACK.push($e); body(); @STACK.pop; $e }
sub span(Str $t, Str :$id = '') { el('span', $t, $id) }
sub button(Str $t, Str :$id = '') {
    my $e = el('button', $t, $id);
    $e.node.addEventListener('click', -> $ev { $e.tap.emit(True) });
    $e;
}
sub reconcile() { for @LIVE -> $e { if $e.text ne $e.applied { $e.node<textContent> = $e.text; $e.applied = $e.text } } }

my $n = 0;
my ($l, $b);
div :id<app>, {
    $l = span 'clicked 0 times', :id<count>;
    $b = button 'Click me', :id<btn>;
}
react {
    whenever $b.clicks { $l.text = "clicked {++$n} times"; reconcile() }
    whenever Promise.in(0.01) {
        $b.node.dispatchEvent(JS.Event.new('click'));
        $b.node.dispatchEvent(JS.Event.new('click'));
        say "after clicks: ", $doc.getElementById('count')<textContent>;
        done;
    }
}
say "P3B-DOM ", $doc.body<innerHTML>;
