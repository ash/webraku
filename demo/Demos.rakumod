# Demos — the list in demos.txt, for the hub and for run.raku.
unit module Demos;

#| The demos, in order: name, port, mount and program, each a hash.
sub read-demos(IO::Path $file --> List) is export {
    $file.lines.map(*.trim).grep({ $_ && !.starts-with('#') }).map(-> $l {
        my ($name, $port, $mount, $app) = $l.words;
        %( :$name, port => $port.Int, mount => ($mount eq '/' ?? '' !! $mount), :$app );
    }).List
}
