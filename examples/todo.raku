#!/usr/bin/env rakupp
# Over-the-network — the browser calls the server, and the server keeps the data.
#
#     rakuweb run examples/todo.raku --port=8794
#
# The list lives in a file on the server. `add-item`, `toggle-item` and
# `remove-item` are marked `is server`: their bodies exist only on the server,
# and in the browser each one is a call to `/_rpc/<name>` with the arguments as
# JSON. Nothing in this file writes a fetch, a route, a handler or a JSON
# payload — the trait is the whole of it.
#
# The first render is different, and deliberately so: `items()` is called by the
# server while it renders, the call and its answer are written into the page,
# and the browser replays that log. So the list is in the HTML, it is there with
# JavaScript switched off, and the browser does not ask for it again. Every
# LATER call — after a click — goes over the network, which the request log in
# the terminal shows.
use Rakuweb;

my $STORE = %*ENV<RAKUWEB_TODO_FILE> // $*TMPDIR.add('rakuweb-todo.txt').Str;

stylesheet q:to/CSS/;
    body { font: 16px/1.6 system-ui, sans-serif; margin: 0; background: #fbfaf7; color: #1d1d1b }
    main { max-width: 34rem; margin: 3rem auto; padding: 0 1.5rem }
    h1 { font-size: 1.5rem; margin: 0 0 .3rem }
    .sub { color: #777; margin: 0 0 1.6rem }
    .row { display: flex; gap: .5rem; margin-bottom: 1.2rem }
    input[type=text] { flex: 1; font: inherit; padding: .5rem .7rem; border: 1px solid #cfc9bd;
                       border-radius: .4rem; background: #fff }
    button { font: inherit; padding: .5rem 1rem; border: 1px solid #cfc9bd; border-radius: .4rem;
             background: #fff; cursor: pointer }
    button:hover { background: #f1eee8 }
    ul { list-style: none; padding: 0; margin: 0 }
    li { display: flex; align-items: center; gap: .6rem; padding: .5rem 0; border-bottom: 1px solid #eae6de }
    li .t { flex: 1 }
    li.done .t { text-decoration: line-through; color: #9a958c }
    li button { padding: .15rem .5rem; font-size: .85rem }
    .count { color: #777; font-size: .9rem; margin-top: 1.2rem }
    .empty { color: #9a958c; padding: 1rem 0 }
    CSS

# ---------- the server's data ----------
#
# A file, because the point is that it is on the server and not in the page.
# One line per item: `0|text` or `1|text`.

sub read-store() {
    return [] unless $STORE.IO.e;
    $STORE.IO.lines.grep(*.chars).map(-> $l {
        my ($done, $text) = $l.split('|', 2);
        %( done => $done eq '1', text => ($text // '') );
    }).Array;
}
sub write-store(@items) {
    $STORE.IO.spurt: @items.map({ (.<done> ?? '1' !! '0') ~ '|' ~ .<text> }).join("\n");
}

#| Every item. Called by the server while rendering, and by the browser after
#| any change — the first goes into the replay log, the rest over the network.
sub items() is server { read-store() }

#| Add one. Answers the whole list, so the browser needs one call and not two.
sub add-item(Str $text) is server {
    my @items = read-store();
    my $t = $text.trim;
    @items.push: %( done => False, text => $t ) if $t;
    write-store(@items);
    @items;
}

#| Flip item `$i`.
sub toggle-item(Int $i) is server {
    my @items = read-store();
    @items[$i]<done> = !@items[$i]<done> if 0 <= $i < @items;
    write-store(@items);
    @items;
}

#| Drop item `$i`.
sub remove-item(Int $i) is server {
    my @items = read-store();
    @items.splice($i, 1) if 0 <= $i < @items;
    write-store(@items);
    @items;
}

sub clear-done() is server {
    my @items = read-store().grep({ !.<done> }).Array;
    write-store(@items);
    @items;
}

# ---------- the page ----------

page '/', :title('Todo'), {
    my @items = items();

    main {
        h1 'Todo';
        p 'the list is on the server; every change is one call', :class<sub>;

        my ($field, $add);
        div :class<row>, {
            $field = input :type<text>, :name<what>, :placeholder('what needs doing?'),
                           :autocomplete<off>, :value('');
            $add   = button 'Add';
        }
        my $list  = ul { };
        my $count = p '', :class<count>;
        my $clear = button 'Clear finished';
        # `$clear` sits after the count, which is where the page wants it.

        # Draw the list from `@items`. The same sub runs on the server (where it
        # builds HTML) and in the browser (where it builds DOM nodes and, after
        # the first time, replaces the ones that are there).
        sub draw() {
            my $n-left = @items.grep({ !.<done> }).elems;
            $count.text = @items
                ?? "{@items.elems} item{@items.elems == 1 ?? '' !! 's'}, $n-left left"
                !! '';
            render-list $list, {
                if !@items {
                    li 'nothing yet', :class<empty>;
                }
                else {
                    for @items.kv -> $i, %it {
                        li class => (%it<done> ?? 'done' !! ''), {
                            my $tick = button %it<done> ?? '✓' !! '○';
                            span %it<text>, :class<t>;
                            my $del = button '×';
                            # A handler per row, attached as the row is made.
                            # `whenever` needs an enclosing `react`, and there
                            # is none here — a row is built long after the page
                            # body ran — so the Supply is tapped directly. On
                            # the server it is an empty finished Supply and the
                            # tap costs nothing.
                            $tick.clicks.tap: { @items = toggle-item($i); draw() }
                            $del.clicks.tap:  { @items = remove-item($i); draw() }
                        }
                    }
                }
            }
        }
        draw();

        react {
            whenever $add.clicks {
                my $text = $field.attr('value') // '';
                if $text.trim {
                    @items = add-item($text);
                    $field.set('value', '');
                    draw();
                }
            }
            whenever $field.inputs -> $ev {
                # The DOM is the truth for what is typed; keep the element's own
                # idea of its value in step, so the handler above can read it.
                $field.set('value', $ev<target><value>.Str);
            }
            whenever $field.keyups -> $ev {
                next unless $ev<key>.Str eq 'Enter';
                my $text = $field.attr('value') // '';
                if $text.trim {
                    @items = add-item($text);
                    $field.set('value', '');
                    draw();
                }
            }
            whenever $clear.clicks { @items = clear-done(); draw() }
        }
    }
}

serve;
