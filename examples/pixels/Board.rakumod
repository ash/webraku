# Board — the server's half of the pixel board: one picture shared by every
# visitor, and the record of how it changed.
#
# Only `is server` subs use it, so the browser never has it. What the browser
# has is a copy of the picture and the version it is at; every second or so
# it sends the strokes it has made since it last asked, and gets back every
# change made since that version, its own included.
unit module Board;

constant W = 48;               # the page agrees
constant H = 32;
constant N = W * H;
constant LOG-MAX = 5000;       # changes kept for visitors who are behind
constant BURST = 60;           # pixels a visitor may paint at once…
constant RATE  = 8;            # …and per second after that

my $FILE = (%*ENV<WEBRAKU_PIXELS_FILE> // $*TMPDIR.add('webraku-pixels.txt').Str).IO;
my @CELLS;                     # a colour 0..15 per cell
my $VERSION = 0;               # how many changes since the server started
my @LOG;                       # [version, cell, colour], oldest first
my %SEEN;                      # visitor => when last heard from
my %BUCKET;                    # address => [pixels it may still paint, when that was]
my $LOCK = Lock.new;           # requests are answered on parallel threads

# ---------- the picture it starts from ----------

my %FONT =
    R => <11110 10001 10001 11110 10100 10010 10001>,
    A => <01110 10001 10001 11111 10001 10001 10001>,
    K => <10001 10010 10100 11000 10100 10010 10001>,
    U => <10001 10001 10001 10001 10001 10001 01110>;

# A butterfly: B blue, R red, Y yellow, G green, K black.
my @FLY = '...K...K...',
          '....K.K....',
          'BBB..K..BBB',
          'BBBB.K.BBBB',
          'BRRBBKBBRRB',
          'BRRRBKBRRRB',
          '.BBBBKBBBB.',
          '..YYBKBYY..',
          '.YGGYKYGGY.',
          '.YGGY.YGGY.',
          '..YY...YY..';
my %INK = B => 12, R => 8, Y => 10, G => 11, K => 0;

sub seed(--> List) {
    my @c = 7 xx N;
    for <R A K U>.kv -> $n, $letter {
        for %FONT{$letter}.kv -> $y, $row {
            for $row.comb.kv -> $x, $bit {
                @c[(10 + $y) * W + 5 + $n * 6 + $x] = 1 if $bit eq '1';
            }
        }
    }
    for @FLY.kv -> $y, $row {
        for $row.comb.kv -> $x, $ch {
            @c[(8 + $y) * W + 31 + $x] = %INK{$ch} if %INK{$ch}:exists;
        }
    }
    @c.List
}

{
    my $saved = $FILE.e ?? $FILE.slurp.trim !! '';
    @CELLS = $saved.chars == N && $saved ~~ /^ <xdigit>+ $/
        ?? $saved.comb.map(*.parse-base(16))
        !! seed();
}

sub cells-text(--> Str) { @CELLS.map(*.base(16)).join.lc }

# ---------- what the page asks ----------

#| The picture as it is, one hex digit per cell, and its version.
sub board-now(--> Hash) is export {
    $LOCK.protect: { %( version => $VERSION, cells => cells-text(), online => %SEEN.elems ) }
}

#| How many of `$want` pixels the address may paint now.
sub take(Str $addr, Int $want, Num $t --> Int) {
    my $b = %BUCKET{$addr} // [BURST.Num, $t];
    my $have = ($b[0] + ($t - $b[1]) * RATE) min BURST;
    my $got = $want min $have.floor;
    %BUCKET{$addr} = [$have - $got, $t];
    $got
}

#| Apply a visitor's strokes, as many as its address may paint, and answer
#| what changed since `$since`: the changes, or the whole picture when the
#| visitor is too far behind for the log (or ahead of a server that has
#| restarted since).
sub board-sync(Int $since, @strokes, Str $who, Str $addr --> Hash) is export {
    $LOCK.protect: {
        my $t = now.Num;
        %SEEN{$who.substr(0, 40)} = $t;
        my @s = @strokes.head(400);
        my $allowed = take($addr, +@s, $t);
        my $painted = 0;
        for @s.head($allowed) -> $stroke {
            my ($i, $c) = $stroke.list.map({ (try .Int) // -1 });
            next unless 0 <= $i < N && 0 <= $c < 16 && @CELLS[$i] != $c;
            @CELLS[$i] = $c;
            @LOG.push: [++$VERSION, $i, $c];
            $painted++;
        }
        @LOG.splice(0, @LOG - LOG-MAX) if @LOG > LOG-MAX;
        $FILE.spurt(cells-text()) if $painted;

        %SEEN{$_}:delete   for %SEEN.keys.grep({ $t - %SEEN{$_} > 15 });
        if %BUCKET > 1000 {
            %BUCKET{$_}:delete for %BUCKET.keys.grep({ $t - %BUCKET{$_}[1] > 60 });
        }

        my %out = version => $VERSION, online => %SEEN.elems, refused => @s - $allowed;
        my $oldest = @LOG ?? @LOG[0][0] !! $VERSION + 1;
        if $since > $VERSION || $since < $oldest - 1 {
            %out<cells> = cells-text();
        }
        else {
            %out<changes> = @LOG.grep(*[0] > $since).map({ [.[1], .[2]] }).Array;
        }
        %out
    }
}
