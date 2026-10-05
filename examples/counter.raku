#!/usr/bin/env rakupp
# The counter — the same nine lines as the GUI::Wings example, in a browser.
#
#     webraku run examples/counter.raku
#
# Everything here happens in the browser. There is no server computation and no
# network traffic after the page loads: the server renders the HTML once, the
# browser adopts it, and from then on the clicks are handled by the `react`
# block below — which is the same block, from the same file.
use Webraku;

stylesheet q:to/CSS/;
    body { font: 16px/1.5 system-ui, sans-serif; margin: 0; background: #faf8f5; color: #222 }
    main { max-width: 34rem; margin: 4rem auto; padding: 0 1.5rem }
    h1 { font-size: 1.4rem; margin: 0 0 1.5rem }
    #count { font-size: 3rem; font-weight: 600; margin: 0 0 1.5rem; font-variant-numeric: tabular-nums }
    button { font: inherit; padding: .5rem 1.1rem; margin-right: .5rem; border: 1px solid #c9c2b6;
             border-radius: .4rem; background: #fff; cursor: pointer }
    button:hover { background: #f2efe9 }
    .clock { color: #776; font-size: .9rem }
    CSS

page '/', :title('Counter'), {
    my $n = 0;

    main {
        h1 'Camelia counts';
        my $out   = p 'clicked 0 times', :id<count>;
        my $up    = button 'Click me';
        my $reset = button 'Reset';
        my $clock = p '', :class<clock>;

        # Identical in shape to the Wings counter: a Supply per control, a
        # `whenever` per behaviour. On the server none of these ever emit, so
        # the block runs, registers nothing and returns — which is how the same
        # code can be both the page and the program.
        react {
            whenever $up.clicks    { $out.text = "clicked {++$n} times" }
            whenever $reset.clicks { $n = 0; $out.text = 'clicked 0 times' }
            whenever every(1)      { $clock.text = DateTime.now.hh-mm-ss }
        }
    }
}

serve;
