# Does a declared `sub div` win at term position? Rakudo: yes. Raku++ parses
# `say div "txt"` as `say() div "txt"` (the infix), so only the parenthesised
# call reaches the sub. Marker for the listop form: div(txt).
sub div(Str $t) { "div($t)" }
say div "txt";
say div("paren");
