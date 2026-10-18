# Webraku::Rpc — the browser end of `is server`.
#
# A sub marked `is server` has no body in the browser bundle: the bundler
# replaced it with `await webraku-call('name', [args])`, which is this file.
#
# Two ways a call is answered:
#
#   the replay log — every `is server` call the SERVER made while rendering the
#   page is embedded in it, as JSON. The first client render replays that log,
#   so it produces exactly what the server produced, with no network at all.
#   This is what `getServerSideProps` buys, without a second function to write.
#
#   the network — anything the log does not answer is a POST to /_rpc/<name>
#   with the arguments as a JSON array, and the answer is the sub's return
#   value. The log is consumed by the first render, so every later call goes
#   to the network.
unit module Webraku::Rpc;

use js;
use Webraku::JSON;

my @REPLAY;
my %USED;
my $BASE = '';      # the path the application is mounted under; the page says which

#| A path inside this application, as the browser must ask for it. The server
#| half's `url`, with the base read from the page the server sent.
sub url(Str $path = '/' --> Str) is export {
    $BASE ~ ($path.starts-with('/') ?? $path !! "/$path");
}

#| The mount point, for the route match in Webraku::Client.
sub webraku-page-base(--> Str) is export { $BASE }

# Webraku::Client installs this, to reconcile after an answer arrives.
my &ANSWERED = -> { };
sub webraku-rpc-hook(&hook) is export { &ANSWERED = &hook }

#| Read the log the server embedded. Called once, before the first render.
sub webraku-load-replay() is export {
    my $meta = JS.document.querySelector('meta[name="webraku-base"]');
    $BASE = $meta.getAttribute('content').Str if $meta;
    my $tag = JS.document.getElementById('webraku-replay');
    return unless $tag;
    @REPLAY = from-json($tag<textContent> || '[]').list.Array;
}

#| Call a server sub. During hydration the answer comes from the log; after it,
#| over the network.
sub webraku-call(Str $name, @args) is export {
    # The log first, and each entry only once. The server made exactly the calls
    # the first client render makes, so the entries are consumed by it and every
    # later call finds nothing and goes to the network. There is no separate
    # "hydration is over" moment to key on: a page body that awaits has no such
    # moment, which an earlier version of this file learned the hard way.
    my $want = to-json(@args.Array);
    for ^@REPLAY -> $i {
        next if %USED{$i};
        my %e = @REPLAY[$i];
        next unless %e<name> eq $name;
        next unless to-json(%e<args>) eq $want;
        %USED{$i} = True;
        return %e<result>;
    }
    my $res = await JS.fetch($BASE ~ '/_rpc/' ~ $name, {
        method  => 'POST',
        headers => { 'content-type' => 'application/json' },
        body    => to-json(@args.Array),
    });
    my $text = await $res.text;
    my %answer = from-json($text);
    die "webraku: $name — %answer<error>" if %answer<error>:exists;
    # The event turn that made this call has long been reconciled, and what the
    # caller does with the answer happens after this returns. So a reconcile is
    # asked for now, to run after that.
    ANSWERED();
    %answer<result>;
}
