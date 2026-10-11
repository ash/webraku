# Analysis — the server half of the wavelet example.
#
# Everything numerical lives here, and none of it reaches the browser: the page
# calls it from inside an `is server` sub, so the bundler drops the call along
# with the body, and `use Math::Wavelet` is never seen by the transpiler. What
# the browser receives is the answer — SVG path data and a few numbers, already
# formatted — which is all it needs to redraw.
unit module Analysis;

use Math::Wavelet;

constant N       = 512;    # samples in every signal
constant MAXROWS = 6;      # detail levels the page has room for
constant W       = 1000;   # the plots' viewBox width
constant H       = 260;    # …and the main plot's height
constant RH      = 64;     # …and each coefficient row's

# ---------- the test signals ----------
#
# Donoho and Johnstone's four, from "Ideal spatial adaptation by wavelet
# shrinkage" (1994): the standard set for showing what wavelet denoising does
# with jumps, spikes, a kink and a frequency that changes. Each is scaled to
# unit standard deviation, so the noise slider reads as noise-to-signal.

my @BLOCK-T = .10, .13, .15, .23, .25, .40, .44, .65, .76, .78, .81;
my @BLOCK-H = 4, -5, 3, -4, 5, -4.2, 2.1, 4.3, -3.1, 2.1, -4.2;
my @BUMP-H  = 4, 5, 3, 4, 5, 4.2, 2.1, 4.3, 3.1, 5.1, 4.2;
my @BUMP-W  = .005, .005, .006, .01, .01, .03, .01, .01, .005, .008, .005;

sub raw-signal(Str $name, Num() $t --> Num) {
    return ([+] (^@BLOCK-T).map({ $t >= @BLOCK-T[$_] ?? @BLOCK-H[$_] !! 0 })).Num
        if $name eq 'blocks';
    return ([+] (^@BLOCK-T).map({ @BUMP-H[$_] / (1 + abs(($t - @BLOCK-T[$_]) / @BUMP-W[$_])) ** 4 })).Num
        if $name eq 'bumps';
    return (4 * sin(4 * π * $t) - sign($t - .3) - sign(.72 - $t)).Num
        if $name eq 'heavisine';
    (sqrt($t * (1 - $t)) * sin(2 * π * 1.05 / ($t + .05))).Num;     # doppler
}

# The server answers each request on its own thread, and Raku++ runs them in
# parallel, so the two caches below are filled under a lock.
my $CACHE = Lock.new;

my %SIGNALS;
sub clean-signal(Str $name --> List) is export {
    $CACHE.protect({ %SIGNALS{$name} //= make-signal($name) }).list
}
sub make-signal(Str $name --> List) {
    my @x = (^N).map({ raw-signal($name, ($_ + .5) / N) });
    my $mean = @x.sum / N;
    my $sd = sqrt(@x.map({ ($_ - $mean)² }).sum / N);
    @x.map({ ($_ - $mean) / $sd }).List;
}

# ---------- noise ----------
#
# Its own generator rather than `rand`, so the same seed gives the same noise on
# every engine and every request: dragging a slider then changes only what the
# slider controls. A 32-bit xorshift, and Box–Muller for the normal deviates.

sub gaussian-noise(Int $seed --> List) is export {
    my $s = ($seed * 2654435761 + 12345) % 4294967296 || 1;
    my &next = {
        $s +^= ($s +< 13) % 4294967296;
        $s +^= $s +> 17;
        $s +^= ($s +< 5) % 4294967296;
        ($s + .5) / 4294967296;
    };
    my @g;
    while @g < N {
        my ($u, $v) = next(), next();
        my $r = sqrt(-2 * log($u));
        @g.push: $r * cos(2 * π * $v), $r * sin(2 * π * $v);
    }
    @g.head(N).List;
}

# ---------- drawing ----------

sub f(Real $x --> Str) { ($x * 10).round.Int / 10 ~ '' }

#| A polyline through `@y`, across the full width, with `$lo`..`$hi` mapped
#| onto `$h`..0.
sub line-path(@y, Real $lo, Real $hi, Int $h --> Str) {
    my $span = ($hi - $lo) || 1;
    my $dx = W / (@y - 1 || 1);
    (^@y).map(-> $i {
        ($i ?? 'L' !! 'M') ~ f($i * $dx) ~ ' ' ~ f($h - ($h - 8) * (@y[$i] - $lo) / $span - 4)
    }).join;
}

#| One stem per coefficient, from the row's centre line. Two paths: the
#| coefficients that survive the threshold, and the ones it set to zero.
sub stem-paths(@c, @kept, Real $scale --> List) {
    my $mid = RH / 2;
    my $dx = W / @c;
    my ($on, $off) = '', '';
    for ^@c -> $i {
        my $x = f(($i + .5) * $dx);
        my $y = f($mid - ($mid - 3) * @c[$i] / $scale);
        my $seg = "M$x {f($mid)}V$y";
        if @kept[$i] != 0 { $on ~= $seg } else { $off ~= $seg }
    }
    ($on, $off);
}

sub rms(@a, @b --> Num) { sqrt((^@a).map({ (@a[$_] - @b[$_])² }).sum / @a).Num }

sub fmt(Real $x, Int $places = 3 --> Str) { sprintf("%.{$places}f", $x) }

# ---------- the wavelet's own shape ----------
#
# The cascade algorithm: a single 1 among zero coefficients, at a coarse level,
# reconstructed. A 1 in the deepest detail band draws ψ, the wavelet; a 1 in the
# approximation draws φ, its scaling function.

my %SHAPES;
sub shapes(Str $name --> Hash) {
    $CACHE.protect: { %SHAPES{$name} //= make-shapes($name) }
}
sub make-shapes(Str $name --> Hash) {
    my %out;
    for 0, 1 -> $band {
        my @c = wavedec([0e0 xx 1024], $name, :level(5), :mode<periodization>);
        @c[$band][16] = 1e0;
        my @y = waverec(@c, $name, :mode<periodization>);
        # Only the support is interesting; trim the zeros around it.
        my @nz = (^@y).grep({ abs(@y[$_]) > 1e-6 });
        my ($a, $b) = (@nz.min - 4) max 0, (@nz.max + 4) min @y.end;
        my @s = @y[$a .. $b];
        my $m = @s».abs.max || 1;
        %out{$band ?? 'psi' !! 'phi'} = line-path(@s, -$m * 1.1, $m * 1.1, 120);
    }
    %out;
}

# ---------- the whole analysis ----------

#| Everything the page draws, for one setting of the controls.
sub analyse(Str $signal, Real $noise, Int $seed, Str $wavelet, Int $want-level,
            Real $mult, Str $mode --> Hash) is export {
    my $w      = wavelet($wavelet);
    my @clean  = clean-signal($signal);
    my @g      = gaussian-noise($seed);
    my @noisy  = (^N).map({ @clean[$_] + $noise * @g[$_] });

    my $deepest   = dwt-max-level(N, $w);
    my $max-level = $deepest min MAXROWS;
    my $level     = ($want-level max 1) min $max-level;

    my @c = wavedec(@noisy, $w, :$level);
    # σ from the finest details, the threshold VisuShrink's, scaled by the slider.
    my $sigma = noise-sigma(@c[*-1]);
    my $universal = $sigma * sqrt(2 * log(N));
    my $thr = $universal * $mult;

    my @t = @c[0], |@c[1..*].map({ threshold($_, $thr, :$mode).Array });
    my @den = waverec(@t, $w).head(N);

    my ($lo, $hi) = (|@noisy, |@clean).min, (|@noisy, |@clean).max;
    my $pad = ($hi - $lo) * .04;
    ($lo, $hi) = $lo - $pad, $hi + $pad;

    # The detail rows, finest last in wavedec's order; the page shows them
    # coarsest first, the way a scalogram is read top to bottom.
    my $kept-all = 0;
    my $total-all = 0;
    my @rows;
    for 1 .. $level -> $k {
        my @d = @c[$k].list;
        my @dt = @t[$k].list;
        my $scale = (@d».abs.max max $thr) * 1.05 || 1;
        my ($on, $off) = stem-paths(@d, @dt, $scale);
        my $kept = @dt.grep(* != 0).elems;
        $kept-all += $kept;
        $total-all += @d.elems;
        my $ty = RH / 2 - (RH / 2 - 3) * $thr / $scale;
        @rows.push: %(
            label => "cD{$level - $k + 1}",
            on    => $on,
            off   => $off,
            band  => "M0 {f($ty)}H{W}M0 {f(RH - $ty)}H{W}",
            info  => "$kept / {@d.elems} kept",
            show  => True,
        );
    }
    @rows.push(%( label => '', on => '', off => '', band => '', info => '', show => False ))
        while @rows < MAXROWS;

    my @a = @c[0].list;
    my ($alo, $ahi) = @a.min, @a.max;
    my %shape = shapes($w.name);

    %(
        clean    => line-path(@clean, $lo, $hi, H),
        noisy    => line-path(@noisy, $lo, $hi, H),
        denoised => line-path(@den,   $lo, $hi, H),
        approx   => line-path(@a, $alo, $ahi, RH),
        approx-label => "cA$level",
        approx-info  => "{@a.elems}, never thresholded",
        rows     => @rows,
        psi      => %shape<psi>,
        phi      => %shape<phi>,
        level    => $level,
        level-note => $level < $want-level
            ?? "$level: the deepest $wavelet allows for {N} samples"
            !! "the deepest $wavelet allows for {N} samples: $deepest",
        family   => $w.family ~ ', ' ~ $w.dec-len ~ ' taps'
                    ~ ($w.vanishing-moments-psi ?? ', ' ~ $w.vanishing-moments-psi ~ ' vanishing moments' !! ''),
        sigma    => fmt($sigma),
        thr      => fmt($thr),
        universal => fmt($universal),
        kept     => "$kept-all of $total-all",
        kept-pct => fmt(100 * $kept-all / ($total-all || 1), 1) ~ '%',
        err-noisy => fmt(rms(@noisy, @clean)),
        err-den   => fmt(rms(@den, @clean)),
        gain      => $noise > 0
            ?? fmt(20 * log10(rms(@noisy, @clean) / (rms(@den, @clean) || 1e-9)), 1) ~ ' dB'
            !! '—',
    );
}

# ---------- the continuous transform ----------
#
# The scalogram is |W(scale, t)| for the signal on the page, drawn as a small
# bitmap: one row per scale, the highest frequency at the top, and a column
# per pair of samples. A bitmap rather than SVG, because it is 36 × 256 cells:
# as rectangles that is ten thousand elements per redraw, as a BMP it is 27 KB.
#
# The rows are spaced by FREQUENCY, from the Nyquist limit down to a period of
# 80 samples, and each wavelet's scales are found from its centre frequency.
# A fixed range of scales would mean a different band for every wavelet.

constant CWT-ROWS = 36;
constant CWT-COLS = 256;
constant F-HIGH   = 0.5e0;
constant F-LOW    = 1e0 / 80;
my @CWT-FREQ = (^CWT-ROWS).map({ F-HIGH * (F-LOW / F-HIGH) ** ($_ / (CWT-ROWS - 1)) });

#| A colour from 0 (dark) to 1 (bright), along viridis' five anchors.
my @VIRIDIS = (68, 1, 84), (59, 82, 139), (33, 145, 140), (94, 201, 98), (253, 231, 37);
sub viridis(Real $v --> List) {
    my $x = ($v max 0) min 1;
    my $i = ($x * 4).floor min 3;
    my $f = $x * 4 - $i;
    (^3).map({ (@VIRIDIS[$i][$_] * (1 - $f) + @VIRIDIS[$i + 1][$_] * $f).round }).List
}

#| A 24-bit BMP, top row first, as a list of byte values.
sub bmp(@rows --> List) {
    my $h = +@rows;
    my $w = +@rows[0];
    my $stride = ($w * 3 + 3) div 4 * 4;
    my $size = 54 + $stride * $h;
    my @b;
    sub le(Int $v, Int $n) { @b.append: (^$n).map({ ($v +> (8 * $_)) +& 255 }) }
    @b.append: 66, 77;                 # 'BM'
    le($size, 4); le(0, 4); le(54, 4);
    le(40, 4); le($w, 4); le(2 ** 32 - $h, 4);   # a negative height: top-down
    le(1, 2); le(24, 2); le(0, 4); le($stride * $h, 4);
    le(2835, 4); le(2835, 4); le(0, 4); le(0, 4);
    for @rows -> @row {
        for @row -> ($r, $g, $bl) { @b.append: $bl, $g, $r }
        @b.append: 0 xx ($stride - $w * 3);
    }
    @b.List
}

my @B64 = |('A'..'Z'), |('a'..'z'), |('0'..'9'), '+', '/';
sub base64(@bytes --> Str) {
    my @out;
    for @bytes.rotor(3, :partial) -> @t {
        my $n = (@t[0] +< 16) + ((@t[1] // 0) +< 8) + (@t[2] // 0);
        my @c = (18, 12, 6, 0).map({ @B64[($n +> $_) +& 63] });
        @c[3] = '=' if @t < 3;
        @c[2] = '=' if @t < 2;
        @out.push: @c.join;
    }
    @out.join
}

#| The scalogram of the clean or the noisy signal under one continuous
#| wavelet, with ψ drawn beside it and the frequencies its scales stand for.
sub scalogram(Str $signal, Real $noise, Int $seed, Str $wavelet, Str $which --> Hash) is export {
    my @clean = clean-signal($signal);
    my @x = $which eq 'clean'
        ?? @clean
        !! do { my @g = gaussian-noise($seed); (^N).map({ @clean[$_] + $noise * @g[$_] }) };
    my $w = wavelet($wavelet);
    my $cf = central-frequency($w, :precision(10));
    my @scales = @CWT-FREQ.map({ $cf / $_ });
    my ($coef, $freq) = cwt(@x, @scales, $w, :method<fft>);

    # |W|, averaged over each pair of samples, and scaled to the largest.
    my $per = N div CWT-COLS;
    my @mag = $coef.map(-> @row {
        (^CWT-COLS).map(-> $c { (^$per).map({ @row[$c * $per + $_].abs }).sum / $per }).List
    });
    my $top = @mag.map(*.max).max || 1;
    my @pixels = @mag.map(-> @row { @row.map({ viridis(($_ / $top) ** .8) }).List });

    my ($psi, $grid) = $w.wavefun(:level(9));
    my @re = $psi.map({ $_ ~~ Complex ?? .re !! $_ });
    my @im = $w.complex-cwt ?? $psi.map(*.im) !! ();
    my $m = (|@re».abs, |@im».abs).max * 1.1 || 1;

    %(
        image   => 'data:image/bmp;base64,' ~ base64(bmp(@pixels)),
        psi-re  => line-path(@re, -$m, $m, 120),
        psi-im  => @im ?? line-path(@im, -$m, $m, 120) !! '',
        top     => "top row: a period of {fmt(1 / $freq[0], 0)} samples, scale {fmt(@scales[0], 2)}",
        bottom  => "bottom row: {fmt(1 / $freq[*-1], 0)} samples, scale {fmt(@scales[*-1], 1)}",
        about   => $w.family
                   ~ ($w.complex-cwt ?? ' — complex, so |W| is the envelope'
                                     !! ' — real, so |W| ripples with the phase')
                   ~ "; centre frequency {fmt($cf, 4)}",
        support => "ψ on [{$w.lower-bound.Int}, {$w.upper-bound.Int}]"
                   ~ ($w.complex-cwt ?? '; solid is its real part, dashed its imaginary part' !! ''),
    );
}
