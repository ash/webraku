# probe 1: a nested tag-builder DSL rendering to an HTML string, no framework.
# marker: P1-BUILDERS
class Node {
    has Str $.tag;
    has %.attrs;
    has @.kids;          # Node or Str
    method html(--> Str) {
        my $a = %!attrs.sort.map({ " {.key}=\"{esc(.value)}\"" }).join;
        my $inner = @!kids.map({ $_ ~~ Node ?? .html !! esc($_) }).join;
        "<$!tag$a>" ~ $inner ~ "</$!tag>";
    }
}
sub esc(Str $s) { $s.trans(['&', '<', '>', '"'] => ['&amp;', '&lt;', '&gt;', '&quot;']) }
my @STACK;
sub tag(Str $tag, *@kids, *%attrs) {
    my $n = Node.new(:$tag, :%attrs);
    for @kids -> $k {
        if $k ~~ Callable { @STACK.push($n); $k(); @STACK.pop }
        else { $n.kids.push($k) }
    }
    @STACK[*-1].kids.push($n) if @STACK;
    $n;
}
sub div(|c)  { tag('div', |c) }
sub p(|c)    { tag('p', |c) }
sub ul(|c)   { tag('ul', |c) }
sub li(|c)   { tag('li', |c) }
sub h1(|c)   { tag('h1', |c) }
sub button(|c) { tag('button', |c) }

my @items = <apple banana "cherry & co">;
my $n = 3;
my $page = div :class<app>, {
    h1 "P1-BUILDERS: {@items.elems} items";
    p "count is $n", :id<count>;
    ul { for @items -> $it { li $it } }
    button 'Add', :id<add>;
};
say $page.html;
