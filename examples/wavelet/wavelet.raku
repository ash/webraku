#!/usr/bin/env rakupp
# Wavelet shrinkage — Math::Wavelet on the server, sliders in the browser.
#
#     rakupp install Math::Wavelet
#     webraku run examples/wavelet/wavelet.raku --port=8795
#
# A test signal is buried in noise, taken apart with a discrete wavelet
# transform, its detail coefficients thresholded, and put back together. Every
# control is a slider or a menu, and moving one redraws the page.
#
# The split between the halves is the one primes.raku makes, at a larger size:
#
#   `transform` is `is server`. Its body stays on the server, and so does
#   `Analysis`, the module beside this file that it calls — and through that
#   Math::Wavelet and all 106 of its filter banks. The bundler leaves out a
#   `use` of a module that lives beside the application, since the browser
#   could not load one anyway. The browser's `transform` is a stub that posts
#   the seven control values and gets back SVG path data and a handful of
#   numbers, already formatted.
#
#   The first render costs no request: the server's call is in the replay log,
#   so the page arrives drawn, and works as a static picture with JavaScript
#   switched off. Each later move of a control is one POST to /_rpc/transform.
use Webraku;
use lib $?FILE.IO.parent.Str;
use Analysis;

constant ROWS = 6;   # detail levels the page has room for; Analysis agrees

stylesheet q:to/CSS/;
    :root { --ink: #1d1d1b; --muted: #77736b; --rule: #e4e0d8; --paper: #fbfaf7;
            --clean: #9a958c; --noisy: #c9c3b8; --den: #1f5f8b; --kept: #1f5f8b;
            --gone: #d9d4ca; --band: #c2573a; }
    * { box-sizing: border-box }
    body { font: 15px/1.5 system-ui, sans-serif; margin: 0; background: var(--paper); color: var(--ink) }
    main { max-width: 72rem; margin: 2.5rem auto; padding: 0 1.25rem }
    h1 { font-size: 1.5rem; margin: 0 0 .2rem }
    .sub { color: var(--muted); margin: 0 0 1.8rem; max-width: 46rem }
    .layout { display: grid; grid-template-columns: 17rem 1fr; gap: 2rem; align-items: start }
    aside { position: sticky; top: 1rem }
    .ctl { margin: 0 0 1.1rem }
    .ctl label { display: flex; justify-content: space-between; font-size: .85rem; color: var(--muted); margin-bottom: .25rem }
    .ctl label b { color: var(--ink); font-weight: 600; font-variant-numeric: tabular-nums }
    .ctl .note { font-size: .78rem; color: var(--muted); margin-top: .2rem }
    input[type=range] { width: 100%; accent-color: var(--den) }
    select, button { font: inherit; width: 100%; padding: .35rem .5rem; border: 1px solid #cfc9bd;
                     border-radius: .35rem; background: #fff; color: var(--ink) }
    button { cursor: pointer; margin-top: .4rem }
    button:hover { background: #f1eee8 }
    table.facts { border-collapse: collapse; width: 100%; margin: 1.4rem 0 0; font-size: .88rem }
    table.facts td { padding: .25rem 0; border-bottom: 1px solid var(--rule) }
    table.facts td.v { text-align: right; font-weight: 600; font-variant-numeric: tabular-nums }
    table.facts tr.big td.v { color: var(--den) }
    .plot { background: #fff; border: 1px solid var(--rule); border-radius: .4rem; padding: .4rem }
    .plot svg { display: block; width: 100%; height: 260px }
    svg path { fill: none; vector-effect: non-scaling-stroke; stroke-linejoin: round }
    path.clean { stroke: var(--clean); stroke-width: 1.2; stroke-dasharray: 4 3 }
    path.noisy { stroke: var(--noisy); stroke-width: 1 }
    path.den   { stroke: var(--den); stroke-width: 1.8 }
    path.on    { stroke: var(--kept); stroke-width: 1.3 }
    path.off   { stroke: var(--gone); stroke-width: 1 }
    path.band  { stroke: var(--band); stroke-width: 1; stroke-dasharray: 3 3; opacity: .8 }
    path.appr  { stroke: var(--ink); stroke-width: 1.3 }
    .legend { display: flex; flex-wrap: wrap; gap: .3rem 1.2rem; font-size: .8rem; color: var(--muted); margin: .5rem 0 1.6rem }
    .legend span::before { content: ''; display: inline-block; width: 1.4rem; height: 0; margin-right: .4rem;
                           vertical-align: middle; border-top: 2px solid }
    .legend .l-clean::before { border-top: 2px dashed var(--clean) }
    .legend .l-noisy::before { border-color: var(--noisy) }
    .legend .l-den::before   { border-color: var(--den) }
    h2 { font-size: 1rem; margin: 0 0 .5rem }
    .row { display: grid; grid-template-columns: 3rem 1fr 8rem; align-items: center; gap: .6rem;
           border-bottom: 1px solid var(--rule) }
    .row.off { display: none }
    .row svg { display: block; width: 100%; height: 64px }
    .row .lab { font: 600 .85rem ui-monospace, monospace }
    .row .info { font-size: .78rem; color: var(--muted); text-align: right; font-variant-numeric: tabular-nums }
    .shapes { display: grid; grid-template-columns: 1fr 1fr; gap: 1rem; margin-top: 1.6rem }
    .shapes svg { display: block; width: 100%; height: 120px; background: #fff;
                  border: 1px solid var(--rule); border-radius: .4rem }
    .shapes path { stroke: var(--den); stroke-width: 1.6 }
    .shapes .cap { font-size: .8rem; color: var(--muted); margin-top: .25rem }
    .foot { color: var(--muted); font-size: .85rem; margin-top: 2rem; max-width: 46rem }
    code { background: #eceae4; padding: .05rem .3rem; border-radius: .25rem; font-size: .9em }
    @media (max-width: 52rem) {
        .layout { grid-template-columns: 1fr }
        aside { position: static }
        .row { grid-template-columns: 2.6rem 1fr 5.5rem }
    }
    CSS

#| The whole analysis, for one setting of the controls. The body runs on the
#| server only; the browser posts the seven values and draws what comes back.
sub transform(Str $signal, Real $noise, Int $seed, Str $wavelet, Int $level,
              Real $mult, Str $mode) is server {
    analyse($signal, $noise, $seed, $wavelet, $level, $mult, $mode);
}

#| A labelled slider. Answers the input and the `<b>` that shows its value.
sub slider(Str $title, $value, $min, $max, $step) {
    my ($in, $out);
    div :class<ctl>, {
        label { text $title; $out = b ~$value };
        $in = input :type<range>, :min(~$min), :max(~$max), :step(~$step), :value(~$value);
    }
    ($in, $out);
}

#| A labelled menu, with `$value` selected.
sub choice(Str $title, @choices, Str $value) {
    my $sel;
    div :class<ctl>, {
        label { text $title };
        $sel = select {
            for @choices -> ($v, $t) {
                option $t, :value($v), :selected($v eq $value);
            }
        }
    }
    $sel;
}

sub two(Real $x --> Str) { (($x * 100).round / 100).Str }

page '/', :title('Wavelet shrinkage'), {
    # The controls' state. The page starts here, and every handler below
    # changes one of these and asks the server again.
    my $signal  = 'doppler';
    my $noise   = 0.2;
    my $seed    = 1;
    my $wname   = 'db4';
    my $level   = 5;
    my $mult    = 1.0;
    my $mode    = 'hard';

    my %r = transform($signal, $noise, $seed, $wname, $level, $mult, $mode);

    my ($s-signal, $s-wavelet, $s-mode, $reseed, $seed-note);
    my ($s-noise, $o-noise, $s-level, $o-level, $s-mult, $o-mult);
    my ($level-note, $thr-note, $family);
    my ($p-clean, $p-noisy, $p-den, $p-appr, $appr-lab, $appr-info, $psi, $phi);
    my (@row, @lab, @on, @off, @band, @info);
    my %fact;

    main {
        h1 'Wavelet shrinkage';
        p raw('A signal in noise, taken apart by a discrete wavelet transform, its small '
              ~ 'detail coefficients thresholded away, and put back together. The transform is '
              ~ '<code>Math::Wavelet</code>, on the server; the page around it is Raku as well, '
              ~ 'and runs in the browser.'), :class<sub>;

        div :class<layout>, {
            aside {
                $s-signal = choice 'signal',
                    (<doppler Doppler>, <blocks Blocks>, <bumps Bumps>, <heavisine HeaviSine>), $signal;
                ($s-noise, $o-noise) = slider 'noise σ', $noise, 0, 0.6, 0.01;
                div :class<ctl>, {
                    $reseed = button 'new noise';
                    $seed-note = div "seed $seed", :class<note>;
                }
                $s-wavelet = choice 'wavelet',
                    (<haar haar>, <db2 db2>, <db4 db4>, <db8 db8>, <db16 db16>,
                     <sym4 sym4>, <sym8 sym8>, <coif2 coif2>, <coif5 coif5>,
                     <bior2.2 bior2.2>, <bior4.4 bior4.4>, <rbio3.1 rbio3.1>, <dmey dmey>), $wname;
                div :class<ctl>, {
                    ($s-level, $o-level) = slider 'levels', $level, 1, ROWS, 1;
                    $level-note = div %r<level-note>, :class<note>;
                }
                div :class<ctl>, {
                    ($s-mult, $o-mult) = slider 'threshold × universal', $mult, 0, 3, 0.05;
                    $thr-note = div "σ√(2 ln n) = %r<universal>", :class<note>;
                }
                $s-mode = choice 'threshold mode',
                    (<hard hard>, <soft soft>, <garrote garrote>), $mode;

                table :class<facts>, {
                    for (<sigma>,     'σ, estimated from cD1'),
                        (<thr>,       'threshold'),
                        (<kept>,      'details kept'),
                        (<kept-pct>,  'of all details'),
                        (<err-noisy>, 'RMS error, noisy'),
                        (<err-den>,   'RMS error, denoised'),
                        (<gain>,      'improvement') -> ($k, $t)
                    {
                        tr :class($k eq 'err-den' || $k eq 'gain' ?? 'big' !! ''), {
                            td $t;
                            %fact{$k} = td %r{$k}, :class<v>;
                        }
                    }
                }
            }

            section {
                div :class<plot>, {
                    tag 'svg', :viewBox('0 0 1000 260'), :preserveAspectRatio<none>, {
                        $p-noisy = tag 'path', :class<noisy>, :d(%r<noisy>);
                        $p-clean = tag 'path', :class<clean>, :d(%r<clean>);
                        $p-den   = tag 'path', :class<den>,   :d(%r<denoised>);
                    }
                }
                div :class<legend>, {
                    span 'signal', :class<l-clean>;
                    span 'signal + noise', :class<l-noisy>;
                    span 'reconstructed from the kept coefficients', :class<l-den>;
                }

                h2 'Coefficients, coarse to fine';
                div :class<row>, {
                    $appr-lab = span %r<approx-label>, :class<lab>;
                    tag 'svg', :viewBox('0 0 1000 64'), :preserveAspectRatio<none>, {
                        $p-appr = tag 'path', :class<appr>, :d(%r<approx>);
                    }
                    $appr-info = span %r<approx-info>, :class<info>;
                }
                for ^ROWS -> $k {
                    my %row = %r<rows>[$k];
                    @row[$k] = div :class(%row<show> ?? 'row' !! 'row off'), {
                        @lab[$k] = span %row<label>, :class<lab>;
                        tag 'svg', :viewBox('0 0 1000 64'), :preserveAspectRatio<none>, {
                            @off[$k]  = tag 'path', :class<off>,  :d(%row<off>);
                            @on[$k]   = tag 'path', :class<on>,   :d(%row<on>);
                            @band[$k] = tag 'path', :class<band>, :d(%row<band>);
                        }
                        @info[$k] = span %row<info>, :class<info>;
                    }
                }

                div :class<shapes>, {
                    div {
                        tag 'svg', :viewBox('0 0 1000 120'), :preserveAspectRatio<none>, {
                            $psi = tag 'path', :d(%r<psi>);
                        }
                        div 'ψ, the wavelet', :class<cap>;
                    }
                    div {
                        tag 'svg', :viewBox('0 0 1000 120'), :preserveAspectRatio<none>, {
                            $phi = tag 'path', :d(%r<phi>);
                        }
                        div 'φ, its scaling function', :class<cap>;
                    }
                }
                $family = p %r<family>, :class<foot>;
            }
        }

        p raw('Blue stems are the coefficients that survive the threshold, grey ones are set '
              ~ 'to zero, and the dashed lines are ± the threshold. The coarse approximation '
              ~ '<code>cA</code> is never thresholded. Hard thresholding keeps a survivor as it '
              ~ 'is, soft shrinks it toward zero by the threshold, and garrote does something in '
              ~ 'between.'), :class<foot>;
    }

    #| Write one answer into the page.
    sub show(%n) {
        $p-clean.set('d', %n<clean>);
        $p-noisy.set('d', %n<noisy>);
        $p-den.set('d', %n<denoised>);
        $p-appr.set('d', %n<approx>);
        $appr-lab.text = %n<approx-label>;
        $appr-info.text = %n<approx-info>;
        $psi.set('d', %n<psi>);
        $phi.set('d', %n<phi>);
        $level-note.text = %n<level-note>;
        $thr-note.text = "σ√(2 ln n) = %n<universal>";
        $family.text = %n<family>;
        for ^ROWS -> $k {
            my %row = %n<rows>[$k];
            @row[$k].set('class', %row<show> ?? 'row' !! 'row off');
            @lab[$k].text = %row<label>;
            @on[$k].set('d', %row<on>);
            @off[$k].set('d', %row<off>);
            @band[$k].set('d', %row<band>);
            @info[$k].text = %row<info>;
        }
        %fact{$_}.text = %n{$_} for %fact.keys;
    }

    # A slider fires many inputs while it is dragged, and their answers can come
    # back out of order. Each request takes a number, and an answer that is not
    # the latest one is dropped rather than drawn over a newer one.
    my $asked = 0;
    sub redraw() {
        my $mine = ++$asked;
        my %n = transform($signal, $noise, $seed, $wname, $level, $mult, $mode);
        show(%n) if $mine == $asked;
    }

    react {
        whenever $s-signal.changes  -> $ev { $signal = $ev<target><value>.Str; redraw() }
        whenever $s-wavelet.changes -> $ev { $wname  = $ev<target><value>.Str; redraw() }
        whenever $s-mode.changes    -> $ev { $mode   = $ev<target><value>.Str; redraw() }
        whenever $s-noise.inputs -> $ev {
            $noise = $ev<target><value>.Str.Num;
            $o-noise.text = two($noise);
            redraw();
        }
        whenever $s-level.inputs -> $ev {
            $level = $ev<target><value>.Str.Int;
            $o-level.text = ~$level;
            redraw();
        }
        whenever $s-mult.inputs -> $ev {
            $mult = $ev<target><value>.Str.Num;
            $o-mult.text = two($mult);
            redraw();
        }
        whenever $reseed.clicks {
            $seed++;
            $seed-note.text = "seed $seed";
            redraw();
        }
    }
}

serve;
