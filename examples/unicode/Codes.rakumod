# Codes — what can be worked out about a character from its number alone,
# for both halves.
#
# The bytes of UTF-8 and the units of UTF-16 are arithmetic on the code
# point, so the browser does them itself, the moment a character is picked or
# a string is typed. What needs Unicode's own tables — names, categories,
# scripts, case mappings — is in Names.rakumod, on the server.
unit module Codes;

#| A code point as Unicode writes it, without the `U+`: 0041, 1F98B.
sub hex4(Int $cp --> Str) is export { $cp.fmt('%04X') }

#| A count with thousands separated: 172,808.
sub commas(Int $n --> Str) is export { $n.Str.flip.comb(3).join(',').flip }

#| The bytes UTF-8 spends on one code point.
sub utf8-bytes(Int $cp --> List) is export {
    $cp < 0x80    ?? ($cp,)
 !! $cp < 0x800   ?? (0xC0 +| ($cp +> 6), 0x80 +| ($cp +& 0x3F))
 !! $cp < 0x10000 ?? (0xE0 +| ($cp +> 12), 0x80 +| (($cp +> 6) +& 0x3F), 0x80 +| ($cp +& 0x3F))
 !!                  (0xF0 +| ($cp +> 18), 0x80 +| (($cp +> 12) +& 0x3F),
                      0x80 +| (($cp +> 6) +& 0x3F), 0x80 +| ($cp +& 0x3F))
}

#| The 16-bit units UTF-16 spends on it: one, or a surrogate pair.
sub utf16-units(Int $cp --> List) is export {
    return ($cp,) if $cp < 0x10000;
    my $v = $cp - 0x10000;
    (0xD800 +| ($v +> 10), 0xDC00 +| ($v +& 0x3FF))
}

sub bytes-hex(@b --> Str) is export { @b.map(*.fmt('%02X')).join(' ') }
sub units-hex(@u --> Str) is export { @u.map(*.fmt('%04X')).join(' ') }

#| How to show a character on its own. A combining mark sits on a dotted
#| circle, a control character is shown by its picture, and a space or an
#| invisible format character by nothing at all (the page labels it).
sub glyph(Int $cp, Str $gc --> Str) is export {
    return "\x[25CC]" ~ $cp.chr if $gc eq 'Mn' || $gc eq 'Me' || $gc eq 'Mc';
    return (0x2400 + $cp).chr   if $cp < 0x20;
    return "\x[2421]"           if $cp == 0x7F;
    return ''                   if $gc eq 'Zs' || $gc eq 'Zl' || $gc eq 'Zp' || $gc eq 'Cf' || $gc eq 'Cc';
    $cp.chr
}

#| Characters, code points, bytes and units of a string. Raku's `.chars`
#| counts what a reader sees as one character — a flag made of two code
#| points is one — which is not what any of the other three count.
sub text-stats(Str $s --> Hash) is export {
    my @o = $s.ords;
    %( chars => $s.chars,
       cps   => +@o,
       utf8  => @o.map({ utf8-bytes($_).elems }).sum,
       utf16 => @o.map({ utf16-units($_).elems }).sum )
}

#| Raku that makes and inspects the character, for the panel beside it.
sub raku-snippet(Int $cp, Str $name, Str $block --> Str) is export {
    my $lit = $name && !$name.starts-with('<') ?? "\\c[$name]" !! "\\x[{hex4($cp)}]";
    my @lines = "my \$c = \"$lit\";";
    @lines.push: "say \$c.uniname;               # $name" if $name;
    @lines.push: "say \$c.ord.fmt('U+%04X');     # U+{hex4($cp)}";
    @lines.push: "say \$c.uniprop('Block');      # $block" if $block;
    @lines.push: "say \$c.encode('utf8');        # utf8:0x<{bytes-hex(utf8-bytes($cp))}>";
    @lines.join("\n")
}
