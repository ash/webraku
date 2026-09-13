# Does a declared `sub tr` win over the tr/// quote when followed by a block?
# Rakudo: yes. Raku++ parses `tr { 1 }` as the quote construct, so only the
# parenthesised call reaches the sub. Marker for the listop form: tr(&1).
sub tr(&b) { "tr(&" ~ b() ~ ")" }
say tr { 1 };
say tr({ 2 });
