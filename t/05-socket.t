#!/usr/bin/env rakupp
# The bytes on the wire: a request read from a real socket, whose head ends in
# CRLF CRLF and whose body is binary and arrives in more than one packet.
# "\r\n" is one character in a Raku string, so a server that finds the end of
# the head in decoded text and cuts the bytes at that position cuts in the
# wrong place; this is the test that would have caught it.
use lib $?FILE.IO.parent.parent.add('lib').Str;
use Webraku;

my $n = 0;
my $bad = 0;
sub is-it($got, $want, Str $desc) {
    $n++;
    if $got eq $want { say "ok $n - $desc" }
    else { $bad++; say "not ok $n - $desc"; say "#      got: $got"; say "# expected: $want" }
}

route '/echo', :methods<POST>, {
    my $req = request();
    response("len={$req.raw.bytes} sum={[+] $req.raw.list} form={$req.form<a> // ''}", type => 'text/plain');
};

my $port = 18000 + $*PID % 1000;
my $listener = IO::Socket::INET.new(:localhost<127.0.0.1>, :localport($port), :listen);

sub ask(Blob $request --> Str) {
    my $client = start {
        my $c = IO::Socket::INET.new(:host<127.0.0.1>, :$port);
        # The head and the body in separate writes, as a slow client sends them.
        my $cut = 40;
        $c.write: $request.subbuf(0, $cut);
        sleep .05;
        $c.write: $request.subbuf($cut);
        my $answer = Buf.new;
        while my $chunk = $c.recv(:bin) { last unless $chunk.bytes; $answer.append: $chunk }
        $c.close;
        $answer.decode('utf8-c8');
    };
    serve-one($listener.accept, :!log);
    await $client;
}

{
    my $body = 'a=hello';
    my $req = "POST /echo HTTP/1.1\r\nHost: x\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: {$body.chars}\r\n\r\n$body";
    my $answer = ask($req.encode('utf8'));
    is-it $answer.lines[0], 'HTTP/1.1 200 OK', 'a form posted over a socket is answered';
    is-it $answer.split("\r\n\r\n", 2)[1], "len=7 sum={[+] $body.encode.list} form=hello", 'and its body is exactly the bytes sent';
}
{
    my $bin = Blob.new(0, 13, 10, 13, 10, 255, 128, 10, 13, 0);
    my $req = "POST /echo HTTP/1.1\r\nHost: x\r\nContent-Type: application/octet-stream\r\nContent-Length: {$bin.bytes}\r\n\r\n".encode('utf8') ~ $bin;
    my $answer = ask($req);
    is-it $answer.split("\r\n\r\n", 2)[1], "len=10 sum={[+] $bin.list} form=", 'a binary body with CR LF inside it arrives whole';
}
$listener.close;

say "1..$n";
say $bad ?? "# $bad of $n checks FAILED" !! "# all $n checks passed";
exit $bad ?? 1 !! 0;
