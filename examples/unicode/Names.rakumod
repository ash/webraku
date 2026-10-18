# Names — the server's half of the Unicode explorer: every named character,
# and what Unicode says about each one.
#
# The index is built once, when the server starts, from `uniname` over the
# whole code space: 172,808 names and 4.6 MB of text. That is the reason this
# half is on the server. Only `is server` subs call it, so the bundler leaves
# it out of the browser's script, and the browser asks for what it shows.
unit module Names;

# Names that are a prefix and a number, made by rule rather than chosen:
# 110,000 of them. They are left out of the word search — a search for "CJK"
# would be nothing else — and found instead by pasting the character or by
# its code.
my @GENERATED = 'CJK UNIFIED IDEOGRAPH-', 'CJK COMPATIBILITY IDEOGRAPH-', 'TANGUT IDEOGRAPH-',
                'TANGUT COMPONENT-', 'KHITAN SMALL SCRIPT CHARACTER-', 'NUSHU CHARACTER-',
                'EGYPTIAN HIEROGLYPH-', 'HANGUL SYLLABLE ';

my @CP;           # the searchable code points, in order
my @NAME;         # …and their names
my $ALL = 0;      # every named code point, generated names included

for 0 .. 0x10FFFF -> $cp {
    next if 0xD800 <= $cp <= 0xF8FF;     # surrogates and the private use area
    last if $cp >= 0xF0000;              # the private use planes
    my $n = uniname($cp);
    next if !$n || $n.starts-with('<');
    $ALL++;
    next if @GENERATED.first({ $n.starts-with($_) }).defined;
    @CP.push: $cp;
    @NAME.push: $n;
}

sub index-size(--> Hash) is export { %( all => $ALL, searchable => +@NAME ) }

#| What the page shows before anything is typed: the Unicode that is Raku
#| syntax, and the butterfly.
my @START = 0x00AB, 0x00BB, 0x2260, 0x2264, 0x2265, 0x2208, 0x2209, 0x220B, 0x2286, 0x2282,
            0x222A, 0x2229, 0x2216, 0x2296, 0x2205, 0x2218, 0x00D7, 0x00F7, 0x2212, 0x2026,
            0x221E, 0x03C0, 0x03C4, 0x1D452, 0x2070, 0x00B9, 0x00B2, 0x00B3, 0x207F, 0x00BD,
            0x2192, 0x269B, 0x300C, 0x300D, 0x2018, 0x2019, 0x201C, 0x201D, 0x2261, 0x2245,
            0x2A75, 0x221A, 0x00AC, 0x2227, 0x2228, 0x22BB, 0x1F98B;

sub name-of(Int $cp --> Str) { uniname($cp) // '' }
sub gc-of(Int $cp --> Str)   { uniprop($cp, 'General_Category') // 'Cn' }

sub hit(Int $cp --> Array) { [$cp, name-of($cp), gc-of($cp)] }

sub valid(Int $cp --> Bool) { 0 <= $cp <= 0x10FFFF && !(0xD800 <= $cp <= 0xDFFF) }

#| Search: a code (U+1F98B, 0x1F98B, \x[1F98B]), characters pasted in, or
#| words that must all be in the name. Answers the first `$limit` hits, the
#| best first, and how many there were.
sub search-names(Str $query, Int $limit = 72 --> Hash) is export {
    my $q = $query.trim.substr(0, 200);
    return %( total => +@START, hits => @START.map(&hit).Array,
              note => 'the Unicode that is Raku syntax' ) unless $q;

    if $q ~~ / ^ [ 'U+' | 'u+' | '0x' | '0X' | '\\x[' ] (<xdigit> ** 1..6) ']'? $ / {
        my $cp = (~$0).parse-base(16);
        return %( total => 1, hits => [hit($cp),], note => '' ) if valid($cp);
    }

    # anything that is not a letter, digit or space of ASCII: characters to
    # look up, not words
    if $q.ords.first({ $_ > 0x7E || ($_ < 0x30 && $_ != 0x20) }).defined {
        my @cps = $q.ords.unique.head($limit);
        return %( total => +@cps, hits => @cps.map(&hit).Array, note => 'the characters you typed' );
    }

    my @w = $q.uc.words;
    my @hits;
    for ^@NAME -> $i {
        my $n = @NAME[$i];
        next unless $n.contains(@w[0]);
        next if @w > 1 && @w[1..*].first({ !$n.contains($_) }).defined;
        @hits.push: $i;
    }
    # The name itself first, then names where each word is a whole word,
    # then the shorter names.
    my $exact = @w.join(' ');
    my @ranked = @hits.map(-> $i {
        my $n = @NAME[$i];
        my $whole = @w.grep({ " $n ".contains(" $_ ") }).elems;
        ($n eq $exact ?? 0 !! 1, @w - $whole, $n.chars, $i)
    }).sort.head($limit).map(*[3]);
    %( total => +@hits,
       hits  => @ranked.map({ [@CP[$_], @NAME[$_], gc-of(@CP[$_])] }).Array,
       note  => '' );
}

my %GC = Lu => 'letter, uppercase', Ll => 'letter, lowercase', Lt => 'letter, titlecase',
         Lm => 'letter, modifier', Lo => 'letter, other', Mn => 'mark, nonspacing',
         Mc => 'mark, spacing combining', Me => 'mark, enclosing', Nd => 'number, decimal digit',
         Nl => 'number, letter', No => 'number, other', Pc => 'punctuation, connector',
         Pd => 'punctuation, dash', Ps => 'punctuation, open', Pe => 'punctuation, close',
         Pi => 'punctuation, initial quote', Pf => 'punctuation, final quote',
         Po => 'punctuation, other', Sm => 'symbol, math', Sc => 'symbol, currency',
         Sk => 'symbol, modifier', So => 'symbol, other', Zs => 'separator, space',
         Zl => 'separator, line', Zp => 'separator, paragraph', Cc => 'control', Cf => 'format',
         Cs => 'surrogate', Co => 'private use', Cn => 'unassigned';

#| Code points as text: `SS  U+0053 U+0053`, or '' when the mapping changes
#| nothing.
sub mapping(@cps, Int $cp --> Str) {
    return '' if @cps == 1 && @cps[0] == $cp;
    @cps.map(*.chr).join ~ '  ' ~ @cps.map({ 'U+' ~ .fmt('%04X') }).join(' ')
}

#| Everything Unicode's tables say about one code point that the page shows.
sub describe-cp(Int $c --> Hash) is export {
    my $cp = valid($c) ?? $c !! 0x1F98B;
    my $ch = $cp.chr;
    my $gc = gc-of($cp);
    my $num = uniprop($cp, 'Numeric_Value');
    %( cp      => $cp,
       name    => name-of($cp),
       gc      => $gc,
       gc-name => %GC{$gc} // $gc,
       block   => uniprop($cp, 'Block') // '',
       script  => uniprop($cp, 'Script') // '',
       age     => ~(uniprop($cp, 'Age') // ''),
       bidi    => uniprop($cp, 'Bidi_Class') // '',
       width   => uniprop($cp, 'East_Asian_Width') // '',
       numeric => $num ~~ Real && $num == $num ?? ~$num !! '',
       upper   => mapping($ch.uc.ords, $cp),
       lower   => mapping($ch.lc.ords, $cp),
       title   => mapping($ch.tc.ords, $cp),
       nfd     => mapping($ch.NFD.list, $cp) );
}

#| Names and categories for the code points of a string, at most 256.
sub names-of(@cps --> Array) is export {
    @cps.head(256).map({ [name-of(+$_), gc-of(+$_)] }).Array
}
