# Webraku

One Raku program, on the server and in the browser. A page is a Raku block:
Raku++ runs it on the server to answer a request with finished HTML, and
`rakupp --target=js` turns the same file into the script the browser runs,
where the page is hydrated and its `react` block comes alive. A sub marked
`is server` keeps its body on the server, and the browser calls it over HTTP
without the author writing a request.

> Version 0.0.1. **This is a work in progress**: everything below runs and is
> tested, but the interface is still moving and may change between versions
> without notice. What it leaves out is under Scope.

```raku
use Webraku;

sub rendered-at(--> Str) is server { DateTime.now.hh-mm-ss }

page '/', :title('Counter'), {
    my $n = 0;
    main {
        h1 'Camelia counts';
        my $out = p 'clicked 0 times';
        my $up  = button 'Click me';
        p "rendered on the server at {rendered-at()}";

        react {
            whenever $up.clicks { $out.text = "clicked {++$n} times" }
        }
    }
}

serve;
```

```bash
webraku run hello.raku --port=8080
```

The clicks are counted in the browser, with no request after the page loads.
`rendered-at` runs once, on the server. Its answer is written into the page,
so hydration does not call it again, and its body is not in the browser's
script.

## Install

```bash
rakupp install Webraku
```

`zef install Webraku` works too, into the same `~/.raku` store, but the
`webraku` command it installs still hands the work to `rakupp`, which has to
be on `PATH`.

## Raku++ is required

**`--target=js` exists in no other Raku, and Webraku is that feature made
into something to build with.** Requiring the engine that has it is the same
kind of requirement as needing a browser to run JavaScript.

The server half is ordinary Raku and runs under Rakudo too, which the test
suite uses as a second opinion on the pure parts. That is a cross-check, not a
promise. The browser half is built by `rakupp --target=js`.

There are no other dependencies: no JSX, no npm, no bundler but rakupp. The
HTTP server is Webraku's own, over `IO::Socket::INET`, and the browser half is
`use js` and the transpiler's own `react`/`supply` runtime.

## What replaces what

| Next.js on Bun | Webraku |
|---|---|
| JSX | tag builders: `div :class<card>, { h2 $title; p $text }` |
| React state, hooks, re-render | plain Raku variables; a changed element property is reconciled into the page after the event turn that changed it |
| server components, SSR | the `page` block, run by Raku++ per request |
| client components, hydration | the same block under `--target=js`; the builders adopt the nodes in build order |
| server actions, API routes | `sub load() is server { … }`; `api '/x', { … }` for JSON |
| `getServerSideProps` | every `is server` call made while rendering is logged into the page and replayed on hydration |
| file-based routing | `page '/post/:id', -> $id { … }` |
| Bun: runtime, bundler, server | Raku++, `--target=js`, and `Webraku::Server` |
| npm packages | `use js` reaches any browser API; the framework needs nothing else |

## Writing a page

**Builders.** Every HTML tag is a sub. A `Str` argument is text and is
escaped; named arguments are attributes; a block nests. Three tag names cannot
be bare Raku subs — `i` is the imaginary unit, `map` insists on a comma after
a block, and `sub` is a keyword — so they are `italic`, `image-map` and
`subscript`. `tag 'my-widget', …` builds anything else. `raw($html)` is the
one door for markup that must not be escaped, and `text 'x'` puts a bare text
node between elements.

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
`$f.submits`, `$e.on('keydown')`. That is what makes the same code a program
on the server, where those Supplies are empty and already finished, so the
`react` block runs and returns, and an application in the browser.

**`react` goes at the end of the page body**, after the tree is built. In the
browser it never returns: it is the page, for as long as the page is open. A
handler for an element built later (inside `render-list`) taps its Supply
directly instead: `$b.clicks.tap: { … }`.

**`is server`.** The body runs on the server; `serve` publishes it at
`/_rpc/<name>`; the browser's copy is a call that posts the arguments as JSON
and awaits the answer. Arguments and results must be plain data: numbers,
strings, booleans, arrays, hashes. An element changed after the answer
arrives is reconciled into the page, the same as one changed by a handler.

**Modules.** `rakupp --target=js` compiles a `use`d module into the browser's
script, and so does an installed one. A module that lives beside the
application, such as `use Analysis` for an `Analysis.rakumod` in the same
directory, gets one more rule. It goes into the browser's script only when the
browser's code calls something it exports, which is what remains once the
`is server` bodies are stubbed. A module that only `is server` code calls
stays on the server, along with everything it uses.

## The command

| | |
|---|---|
| `webraku run app.raku [--port=N] [--dev]` | build the browser half, then run the application, whose `serve` starts the server |
| `webraku build app.raku` | write `app.client.js` beside the application |
| `webraku bundle app.raku` | print the assembled Raku of the browser half, without transpiling |

`--dev` reloads the page when the program changes. `--keep-raku` keeps the
assembled `app.client.raku`, to read or to transpile by hand. `RAKUPP` names
the Raku++ binary when it is not the `rakupp` on `PATH`.

`webraku build` concatenates the framework's browser half with the
application, replaces every `is server` body with the RPC stub, and runs
`rakupp --target=js --standalone -I <the application's directory>`. The
application's own `use`s are compiled in by rakupp.

## The modules

| module | what it is |
|---|---|
| `Webraku` | the one `use` line, and the `is server` trait |
| `Webraku::HTML` | the element tree and a builder per tag; pure Raku |
| `Webraku::Route` | the route table, shared by both halves |
| `Webraku::JSON` | the JSON the framework needs, and no more |
| `Webraku::Server` | HTTP/1.1 over `IO::Socket::INET`: pages, `api`, `static`, RPC |
| `Webraku::Bundle` | assembling the browser program |

The browser-only half, `resources/client/Client.rakumod` (DOM nodes,
hydration, reconcile) and `resources/client/Rpc.rakumod` (the browser end of
`is server`), ships as resources rather than as modules. Both `use js`, which
only Raku++ can compile, and only `webraku build` ever reads them.

## Examples

Each of the first three is one file and shows one half of the idea. The
fourth puts them together in a page with a module of its own.

- `examples/counter.raku` — client-side only. After the page loads there is
  no network traffic at all: clicks and a one-second timer are handled by the
  `react` block in the browser.
- `examples/primes.raku` — server-side computation. The sieve of Eratosthenes
  is `is server`, so its body is not in the browser's script, only its answer,
  which the server wrote into the HTML. Search `primes.client.js` for the
  sieve and it is not there; search the page source for the numbers and they
  are. `/primes/500` is a route parameter.
- `examples/todo.raku` — over the network. The list is a file on the server.
  Add, toggle, remove and clear are `is server`, so each one is a
  `POST /_rpc/<name>` the author never wrote. The first render comes from the
  replay log and costs no request.
- `examples/wavelet/` — both halves, with a library.
  [Math::Wavelet](https://github.com/ash/raku-modules/tree/main/Math-Wavelet) and a module beside
  the page are compiled into the browser's script, so a slider redraws the
  plots with no request. The scalogram is an `is server` call that answers
  with an image. It has a README of its own.

```bash
webraku run examples/counter.raku --port=8791
```

## Scope

Left out of 0.0.1, each a later piece of work if wanted:

| | |
|---|---|
| a markup slang | the builders are the HTML; there is no JSX-like syntax over them |
| streaming render, partial hydration, islands | a page renders whole and hydrates whole |
| WebSocket-backed Supplies | the browser reaches the server only through `is server` calls |
| nested layouts, middleware | one `page` block per route |
| sessions, authentication, forms validation | |
| HTTP/2, TLS | put it behind a proxy that terminates TLS |

## Compatibility

| engine | version | 01-html | 02-server | 03-bundle |
|---|---|---:|---:|---:|
| Raku++ | 5.3.0-72, a development build | 33/33 | 36/36 | 7/7 |
| Rakudo | v2026.09 | 33/33 | 36/36 | 7/7 |

Rakudo runs the suite as a cross-check on the pure parts; it cannot run an
application.

Neither version is an established floor, as no older engine has been tried.
The wavelet example needs a Raku++ whose `--target=js` compiles `use`d
modules, which landed after 5.3.0, so until the next release that means a
build from source.

## Author

Andrew Shitov (`zef:ash`).

## Licence

Artistic-2.0.

---

Why Webraku is shaped this way, the engine bugs it found in Raku++, and the
probes that reproduce them are in
[PLAN.md](https://github.com/ash/webraku/blob/main/PLAN.md).
