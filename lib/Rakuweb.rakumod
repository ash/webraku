# Rakuweb — one Raku program, on the server and in the browser.
#
# `use Rakuweb;` is what an application writes, and it is the only line it needs.
# The shape of an application:
#
#     use Rakuweb;
#
#     sub todos() is server { 'todos.txt'.IO.lines }   # the server only
#
#     page '/', :title('Todo'), {
#         my $ul = ul { li $_ for todos() };
#         my $b  = button 'Add';
#         react {
#             whenever $b.clicks { ... }
#         }
#     }
#
#     serve :port(8080);
#
# The server runs the `page` block to render HTML. The browser runs the SAME
# block, transpiled: the builders adopt the nodes the server sent instead of
# making new ones, `todos()` answers from the log embedded in the page, and the
# `react` block comes alive.
#
# There is no `unit module` here, and the `EXPORT` sub is in the file's mainline
# rather than inside the module block: that is where Rakudo looks for it, and
# both engines then re-export the same names.

use Rakuweb::HTML;
use Rakuweb::JSON;
use Rakuweb::Server;

#| The trait itself. It has to be declared where a `sub … is server` in the
#| APPLICATION can see it, which is why it is exported rather than namespaced.
#|
#| Two things happen here. The routine is registered, so `serve` can publish it
#| at `/_rpc/<name>`; and it is WRAPPED, so that every call made while a page is
#| rendering records its arguments and its answer in that page's replay log. The
#| browser reads the log instead of asking again, which is why the first client
#| render costs no round trip. Wrapping is how the recording happens without the
#| application writing anything: `todos()` in a page body is an ordinary call.
multi sub trait_mod:<is>(Routine $r, :$server!) {
    rakuweb-register($r);
    my $name = $r.name;
    # `my \result` and not `my $result`: a Scalar ITEMIZES a returned list, so
    # `my @p = sieve(100)` came back with one element — the whole array — and
    # every count in the page was 1. A sigilless binding keeps it flat, on both
    # engines.
    $r.wrap(-> |args {
        my \result = callsame();
        record-call($name, args.list.Array, result);
        result;
    });
}

sub EXPORT(|) {
    Map.new(
        |Rakuweb::HTML::EXPORT::DEFAULT::.pairs,
        |Rakuweb::JSON::EXPORT::DEFAULT::.pairs,
        |Rakuweb::Server::EXPORT::DEFAULT::.pairs,
        '&trait_mod:<is>' => &trait_mod:<is>,
    );
}
