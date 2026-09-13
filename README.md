# Rakuweb

One Raku program, on the server and in the browser.

A page is a Raku block. Its HTML is nested builder calls, its behaviour is
`react`/`whenever` over the elements' event Supplies, and its data comes from
ordinary subs. Raku++ runs that block on the server to answer a request with
finished HTML; `rakupp --target=js` turns the **same file** into the script the
browser runs, where the builders adopt the HTML already on the page and the
`react` block comes alive. A sub marked `is server` keeps its body on the
server, and the browser calls it over HTTP without the author writing a request.

No JavaScript is written. No JSX, no npm, no bundler other than rakupp. **No
dependencies at all** — the HTTP server is this framework's own, over
`IO::Socket::INET`, and the browser half is `use JS` and the transpiler's own
`react`/`supply` runtime.

**It requires Raku++, and that is the point rather than a limitation.**
`--target=js` exists in no other Raku, and this framework is that feature made
into something you can build with. Requiring the engine that has it is the same
kind of requirement as needing a browser to run JavaScript. The server half is
ordinary Raku and happens to run under Rakudo too, which the test suite uses as
a second opinion on the pure parts — but that is a cross-check, not a promise.

The distribution is `Rakuweb` and the command is `rakuweb`; the working
directory is still called `rakuact`.

```raku
use Rakuweb;

page '/', :title('Counter'), {
    my $n = 0;
    main {
        h1 'Camelia counts';
        my $out = p 'clicked 0 times', :id<count>;
        my $up  = button 'Click me';

        react {
            whenever $up.clicks { $out.text = "clicked {++$n} times" }
            whenever every(1)   { … }
        }
    }
}

serve;
```

```
rakuweb run examples/counter.raku
```

## What replaces what

| Next.js on Bun | here |
|---|---|
| JSX | tag builders: `div :class<card>, { h2 $title; p $text }` |
| React state, hooks, re-render | plain Raku variables; a changed element property is reconciled into the page after the event turn that changed it |
| server components, SSR | the `page` block, run by Raku++ per request |
| client components, hydration | the same block under `--target=js`; the builders adopt the nodes in build order |
| server actions, API routes | `sub load() is server { … }`; `api '/x', { … }` for JSON |
| `getServerSideProps` | every `is server` call made while rendering is logged into the page and replayed on hydration |
| file-based routing | `page '/post/:id', -> $id { … }` |
| Bun: runtime, bundler, server | Raku++, `--target=js`, and `Rakuweb::Server` |
| npm packages | `use JS` reaches any browser API; the framework needs nothing else |

## The three examples

Each is one file, and each shows one half of the idea.

| example | what it demonstrates | run it |
|---|---|---|
| [`counter.raku`](examples/counter.raku) | **client-side only.** After the page loads there is no network traffic at all: clicks and a one-second timer are handled by the `react` block in the browser. | `rakuweb run examples/counter.raku --port=8791` |
| [`primes.raku`](examples/primes.raku) | **server-side computation.** The sieve of Eratosthenes is `is server`, so its body is not in the browser bundle — only its answer, which the server wrote into the HTML. `/primes/500` is a route parameter. | `rakuweb run examples/primes.raku --port=8793` |
| [`todo.raku`](examples/todo.raku) | **over the network.** The list is a file on the server. Add, toggle, remove and clear are `is server`, so each one is a `POST /_rpc/<name>` the author never wrote. The first render comes from the replay log and costs no request. | `rakuweb run examples/todo.raku --port=8794` |

The primes example is the one to read first if the claim sounds too good:
search `primes.client.js` for the sieve's algorithm and it is not there, then
search the page source for the numbers and they are.

## Writing a page

**Builders.** Every HTML tag is a sub. A `Str` argument is text and is escaped;
named arguments are attributes; a block nests. Three tag names cannot be bare
Raku subs — `i` is the imaginary unit, `map` insists on a comma after a block,
and `sub` is a keyword — so they are `italic`, `image-map` and `subscript`.
`tag 'my-widget', …` builds anything else. `raw($html)` is the one door for
markup that must not be escaped, and `text 'x'` puts a bare text node between
elements.

```raku
div :class<card>, :data-id($id), {
    h2 $title;
    ul { li .<name> for @rows }
    button 'Delete', :disabled($locked);
}
```

**Elements are retained.** A builder returns its element, and the element's
`text` and attributes are writable. Changing one marks it; after every event
turn the changed properties are written into the DOM. There is no virtual DOM
and no tree diff. `render-list $ul, { … }` is the one place a subtree is
rebuilt, for a list whose items come and go.

**Events are Supplies**, not attributes: `$b.clicks`, `$in.inputs`,
`$f.submits`, `$e.on('keydown')`. That is what makes the same code a program on
the server — where those Supplies are empty and already finished, so the
`react` block runs and returns — and an application in the browser.

**`react` goes at the end of the page body**, after the tree is built. In the
browser it never returns: it is the page, for as long as the page is open. A
handler for an element built later (inside `render-list`) taps its Supply
directly instead: `$b.clicks.tap: { … }`.

**`is server`.** The body runs on the server; `serve` publishes it at
`/_rpc/<name>`; the browser's copy is a call that posts the arguments as JSON
and awaits the answer. Arguments and results must be plain data — numbers,
strings, booleans, arrays, hashes.

## Layout

```
lib/Rakuweb.rakumod          `use Rakuweb` — re-exports, and the `is server` trait
lib/Rakuweb/HTML.rakumod     the element tree and a builder per tag (pure Raku, runs on Rakudo too)
lib/Rakuweb/Route.rakumod    the route table, shared by both halves
lib/Rakuweb/JSON.rakumod     the JSON the framework needs, and no more
lib/Rakuweb/Server.rakumod   HTTP/1.1 over IO::Socket::INET; pages, api, static, RPC
lib/Rakuweb/Client.rakumod   the browser half: DOM nodes, hydration, reconcile
lib/Rakuweb/Rpc.rakumod      the browser end of `is server`
lib/Rakuweb/Bundle.rakumod   assembling the browser program
bin/rakuweb                  build / run / bundle
```

`rakuweb build` concatenates the framework's browser half with the application,
replaces every `is server` body with the RPC stub, and runs
`rakupp --target=js --standalone`. Concatenation is needed only because the
transpiler takes one file and refuses `use` of a user module; when it learns to
resolve `use`, that step goes away and nothing else changes.

## Status

Everything described above runs. What is not built: a markup slang over the
builders, streaming render, partial hydration, WebSocket-backed Supplies,
nested layouts, sessions, forms validation, HTTP/2 and TLS. The plan in
[PLAN.md](PLAN.md) lists them as later work and says why each was left out.

Verified in a real browser, not only under a stub: the counter counts clicks
and ticks a clock; the primes page hydrates one tree with no console output and
its four figures match the known values for π(200), the prime sum, the twin
pairs and the largest gap; the todo list survives a reload, adopts the server's
list without rebuilding it, and each change is exactly one request.

## Engine work this needed

Building it found and fixed nine bugs in Raku++, all in the repository beside
this one. Six were in the `--target=js` emitter and runtime, three in the
parser and lexer. They are listed with their probes in [PLAN.md](PLAN.md); the
two that cost the most to find were a closure made in a `for` loop capturing
the loop variable by reference, so every row of a list called the handler of the
last row, and a `&`-sigil parameter losing to a global sub of the same name, so
a route stored the `body` tag builder instead of the page it was given.

## Reproducing the probes

```
rakupp probes/run.raku      # the five probes, on Rakudo, Raku++ and Node
rakupp probes/tags.raku     # every HTML tag name as a bare builder, on both engines
```
