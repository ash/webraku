# Plan: one Raku program for the server and the browser

**Status: BUILT 2026-09-13.** P0 through P4 landed in one sitting: the engine
fixes, `Webraku::HTML`, `Webraku::Client`, `Webraku::Server`, the bundler with
hydration and RPC, and three examples driven end to end in a real browser. What
was left out is in *What this plan does not do* at the end, unchanged. The name is
Webraku (it was Rakuweb until 2026-10-05; see [Name](#name)). See
[README.md](README.md) for the user's side and *Where it stands* below for what
each phase actually cost.

The probes in `probes/` ran on Raku++ 3.28.0-22-g3a8f214 (`build-arm64`),
Rakudo v2026.08, Node v24.20.0 and Bun 1.4.0 on the benchmark machine (Darwin
24.6, arm64), 2026-09-13. `rakupp probes/run.raku` reruns them.

## TL;DR

- **The idea.** A web application is one Raku program. Its HTML is nested
  builder calls, the way GUI::Wings builds a window; its behaviour is
  `react`/`whenever` over the elements' event Supplies; its data is ordinary
  subs. Raku++ runs that program on the server to answer a request with
  finished HTML, and `rakupp --target=js` turns the *same file* into the
  script that runs in the browser, where the same builder calls adopt the
  HTML already on the page and the `react` block comes alive. Subs marked
  server-only stay on the server; the browser calls them over HTTP without
  the author writing a request. No JavaScript is written, no JSX, no npm, no
  bundler other than rakupp. That is the whole of what Next.js on Bun does
  for a React application, with Raku in every seat.
- **Raku++ only, on purpose.** `--target=js` exists in no other Raku, so the
  framework cannot be engine-neutral and should not pretend to be. It is free
  to lean on whatever the engine offers — the transpiler, `--exe` for a single
  deployable binary, and slangs if a markup layer is ever wanted. The server
  half is ordinary Raku and runs under Rakudo as a cross-check on the pure
  parts, which is a test oracle rather than a supported configuration.
- **Dependencies: none.** Not Cro, not Air, not Humming-Bird, nothing from
  npm. The HTTP server is the framework's own, over `IO::Socket::INET`, the
  sockets `rakus` already serves with on both engines. The browser side is
  `use JS` and the transpiler's `react`/`supply` runtime, both in Raku++
  today.
- **Measured before planning.** A builder DSL renders the same HTML byte for
  byte on Rakudo, Raku++ and transpiled under Node (`probes/01`). The client
  half — builders making DOM nodes, a click becoming a Supply emit, a
  `whenever` updating an element, the change reaching the page — runs
  transpiled today (`probes/02`), in a 382 KB standalone script, 104 KB
  gzipped, of which the runtime is 376 KB / 102 KB. Of the 113 HTML tag
  names, 3 cannot be bare Raku subs on either engine (`i`, `map`, `sub`) and
  4 fail on Raku++ only (`div`, `q`, `tr`, `sub`) — the `div` one is a parser
  bug that must go first.
- **Three engine items came out of the probes before any code was written**,
  two of them blocking. Building the rest found six more: **nine Raku++ bugs
  in all**, every one fixed, listed in [Where it stands](#where-it-stands).
  The worst was silent — every closure made in a `for` loop saw the loop
  variable's last value, so each row of a list called the last row's handler.
- **Five phases, each gated, all landed.** Engine fixes → HTML builders → the
  browser side → the server → the bundler with hydration and RPC, then three
  examples. What is deliberately left out is listed at the end.
- **Name: Webraku** — Raku, the web variety: the last word names what it
  is. It sits beside `rakupp`, `rakus` and `rakugrid`. The rounds of
  candidates are kept in [Name](#name).

## What it replaces, piece by piece

| Next.js on Bun | here |
|---|---|
| JSX | tag builders: `div :class<card>, { h2 $title; p $text }` |
| React state, hooks, re-render | plain Raku variables; `react { whenever $b.clicks { $n.text = … } }`; changed element properties are reconciled into the page after each event |
| server components, SSR | the page function run by Raku++ per request, rendered to a string |
| client components, hydration | the same file under `--target=js`; the builders adopt the existing nodes in build order |
| server actions, API routes | `sub load-items() is server { … }` becomes an HTTP call from the browser; `api '/items' -> { … }` for JSON endpoints |
| `getServerSideProps` | the results of `is server` calls made while rendering are embedded in the page and replayed on hydration, so the first client render needs no network |
| file-based routing | `page '/' -> { … }`, `page '/post/:id' -> ($id) { … }` in the program; files later, if wanted |
| Bun: runtime, bundler, server | Raku++ (the interpreter, or `--exe` for one deployable binary), `--target=js`, and the framework's server |
| npm packages | `use JS` reaches any browser API; nothing else is needed for the framework itself |
| fast refresh | the dev server watches the program's mtime, rebuilds, and the page reloads |

## The HTML question: builders, decided

Three ways were considered.

1. **Builders** — `div :id<app>, { h1 'Hello'; ul { for @items { li $_ } } }`.
   Escaping by construction (a `Str` argument is text, `raw` is the one door
   for trusted markup); composition by ordinary subs
   (`sub card($title, &body) { div :class<card>, { h2 $title; body() } }`);
   loops and conditionals are Raku's own; attributes are named arguments,
   hyphenated ones included (`:data-id($id)`, `:aria-label('…')`); and one
   implementation renders to a string on the server or to DOM nodes in the
   browser. This is what GUI::Wings does with `window`/`label`/`button`, and
   it is the shape the user singled out.
2. **String templates** — heredocs with interpolation. No structure,
   escaping by discipline. Rejected.
3. **A markup slang** — `<div class="x">{ $expr }</div>` inside Raku, the
   way JSX sits inside JavaScript. Raku++ has the machinery now (eight
   slangs run their own tokens, per the slang plan in the rakupp
   repository), so this is possible as a *layer over the builders* later.
   Not in this plan.

**Builders it is.** The cost is tag names that are Raku words, and it was
measured (`probes/tags.raku`, 113 tags, three call shapes each):

| engine | tags that cannot be a bare builder | why |
|---|---|---|
| Rakudo | `i`, `map`, `sub` | `i` is the imaginary-unit term; `map` insists on its comma after a block; `sub` is a keyword |
| Raku++ | `div`, `q`, `tr`, `sub` | `div` parses as the infix at term position; `q` and `tr` as quote constructs — Rakudo lets a declared sub win in all three cases; `sub` as on Rakudo |

Rules that follow:

- Every tag is a builder except the three Raku reserves on both engines,
  which get descriptive names: `italic` for `<i>`, `image-map` for `<map>`,
  `subscript` for `<sub>`. `tag 'x', …` makes any element, unusual or
  custom.
- `div`, `tr` and `q` stay bare — they are the framework's most-used tags —
  and the Raku++ parser is fixed to Rakudo's behaviour (P0 below). Until it
  is, `div` is unusable on Raku++, which is why P0 is first.
- Event handlers are not attributes. An element is returned as an object,
  and its events are Supplies: `$b.clicks`, `$in.inputs`, `$f.submits`,
  `$e.on('keydown')`. That is the Wings design (`whenever $b.clicks`), and
  it is the reason the same code is a program on the server (no events
  ever fire; the tree is rendered once) and an application in the browser.

The counter, as it would read:

```raku
use Webraku;

page '/', {
    my $n = 0;
    my $l = p 'clicked 0 times', :id<count>;
    my $b = button 'Click me';

    react {
        whenever $b.clicks { $l.text = "clicked {++$n} times" }
    }
}

serve;
```

On the server `page` renders the two elements and the `react` block is not
entered (there are no sources). In the browser the same file, transpiled,
adopts the `<p>` and the `<button>` and the `react` block runs. The Wings
counter is nine lines; this is nine lines.

## The model

**Element.** A retained object: `tag`, `attrs`, `kids`, and read-write
properties the program may change later — `.text`, `.set(attr, value)`,
`.class`, `.value` for inputs, `.hidden`, `.kids` for replacing children.
On the server it renders once. In the browser it holds its DOM node, and
after every event turn a reconcile pass writes the properties that changed
(Wings' `applied` vs `text`), so the program never touches the DOM. There
is no virtual DOM and no diff of whole trees: the only diff is over a
node's children when `.kids` is reassigned, keyed by `:key` when given and
by position otherwise.

**Events.** A builder that makes an interactive element attaches one
listener per event kind on demand — the first `$b.clicks` adds the
`click` listener — and the listener emits on a Supplier. `whenever` bodies
run synchronously on emit (the runtime's rule), then reconcile runs. Timer
and interval sources the framework hands out schedule a reconcile too;
`refresh` does it by hand for anything else.

**Where `react` sits.** Measured in `probes/02` and its predecessor: a
`react` inside a block passed to a builder becomes an `async` function, the
builder cannot know to await it, and the program moves on — under Node the
mainline finished and the process exited before the first event. So the
rule is that `react` and every `await` live at the top level of a `page`
body, after the tree is built; builder blocks only build. The transpiler's
own guide states the same limit for blocks handed to `.map`. It is a rule
the bundler can check, and one the emitter could remove (P0, optional).

**Server functions.** `sub load-items() is server { … }`. On the server it
is the sub, and `serve` registers it at `/_rpc/load-items` taking JSON
arguments and answering JSON. In the client bundle its body is replaced by
a stub that posts the arguments and awaits the answer; arguments and
results must be plain data (the `use JS` marshalling table: numbers,
strings, booleans, arrays, hashes). During server rendering, every `is
server` call a page makes is logged (name, arguments, result) and the log
is embedded in the page; on hydration the stub answers from the log first,
so the first client render matches the server's without a request, and
only later calls go over the network. That is `getServerSideProps` without
a second function.

**Pages, routes, requests.** `page $path, &body` registers a page; `$path`
may carry `:name` segments, bound to the block's parameters. `api $path,
&body` registers a JSON endpoint. Inside either, `$*REQUEST` carries
method, path, params, query, headers, cookies; the block's return value is
the response body for `api`, and for `page` the framework wraps the built
tree in a document shell with the CSS and script tags. `static $dir` serves
files. `serve :port` starts the server; under `--exe` the client bundle is
embedded in the binary, so the deployment is one file.

**The bundler.** `--target=js` took one file and refused `use` of a user
module when this was written (it compiles `use`d modules since 2026-10-11, and
the bundler now keeps an application's own `use`s), so the client bundle is
assembled by the framework, as the three
`--target=js` showcases in the rakupp repository do by hand: the client
half of the framework, then the application with its `use` line stripped
and each `is server` body replaced by the stub (line ranges from
`rakupp --ast`), then `--standalone`. One bundle per application; on load
it matches `location.pathname` against the pages and hydrates the one that
answers. When the emitter learns to resolve `use` (an item on the
transpile plan's list), the concatenation step goes away and nothing else
changes.

**Hydration.** In hydrate mode a builder does not create a node: it takes
the next child of the current parent and adopts it if the tag matches, and
replaces it if not — the escape hatch for a tree the server did not
produce. Text arguments adopt text nodes. Because the same code built the
server's HTML from the same replayed data, the walk lines up; when it does
not, the mismatch is reported to the console with the element path and the
page still works, with a repaint instead of an adoption.

## Engine items the probes found

These three were known before any framework code existed — the probes in
`probes/` are what found them. Six more came out of the building, and all nine
are in [Where it stands](#where-it-stands).

| # | what | where | probe | blocks |
|---|---|---|---|---|
| 1 | `sub f(*%a)` under `--target=js` binds the *positionals* into `%a` — `f(:id<c>)` dies with "Odd number of elements found where hash initializer expected", and so does `f()`. The emitted function has `const [_pos, _named] = R.splitArgs(_args)` and then `R.newHash(R.mkList(_pos.slice(0)))` | `src/codegen/Js.cpp`, parameter binding | `03-slurpy-named.raku` | every Wings-style builder takes `*%opts`; P1 |
| 2 | a declared sub named `div` is parsed as the infix at term position (`say div "txt"` becomes `say() div "txt"`); a declared `tr` or `q` followed by `{` is parsed as the quote construct. Rakudo calls the sub in all three cases; `div("txt")` with parentheses works on both | `src/Parser.cpp`, term position | `04-div-term.raku`, `05-tr-term.raku` | `<div>`; P1 |
| 3 | a block containing `react`/`await`, passed to a user sub that calls it through a `&param`, becomes `async` at the call site while the sub is not coloured, so the block's promise is dropped. A fixpoint over (sub invokes a `&`-parameter) × (some call site passes an async block) would colour the sub and await the invocation | `src/codegen/Js.cpp`, the colouring prepass | the first version of `02-client.raku` | nothing — designed around; would lift the "react at top level" rule |

Items 1 and 2 were P0 and are fixed. Item 3 is not: the framework designs
around it, by requiring `react` at the top of a page body rather than inside a
builder block, and the emitter fix stays on the transpile plan's list.

## Where it stands

All five phases landed on 2026-09-13. What each produced, and what it cost:

**P0 — the engine.** Nine bugs in Raku++, listed below. The gates after them:
`t/run.raku` 891 of 891, and the `--target=js` corpus gate's *disagreeing set*
unchanged against a clean build of `HEAD` in a separate worktree (161 agreeing
/ 336 refused / 73 disagreeing, same files). The gate is not green and never
was — its own header says so — which is why the set, and not the exit code, is
the measure.

**P1 — `Webraku::HTML`.** The `Element` class and a builder per tag, in pure
Raku. A page of every construct — nesting, loops, boolean attributes, void
elements, `raw`, the three renamed tags, a custom tag — renders byte for byte
identically under Rakudo and Raku++.

**P2 — `Webraku::Client`.** DOM nodes, hydration by adoption, events as
Supplies, the per-turn reconcile, `render-list`. Checked in a real browser and
not only under a stub, which is where the two hydration bugs surfaced that a
stub could not have shown: the implicit `<tbody>` a parser inserts, and
`.children` being an HTMLCollection in a browser but a copied Array from
anything array-like.

**P3 — `Webraku::Server`.** HTTP/1.1 over `IO::Socket::INET`, one thread per
connection; `page`, `api`, `static`, `serve`, `$*REQUEST`, the document shell,
the replay log, the dev reload. `handle` is a pure function of the request and
the route table, so what the server answers is testable with no port.

**P4 — the bundler, hydration, RPC.** `webraku build` assembles, stubs every
`is server` body, and transpiles. Verified end to end in a browser: the todo
list adds, toggles, removes and clears, each one exactly one `POST /_rpc/…`,
the server's file holding the result, and a reload serving it back and adopting
it without rebuilding the tree.

**P5 — the examples.** Three, one per half of the idea, listed in the README.

### The nine engine bugs this found

All in the rakupp repository, all fixed there, each with a probe that fails
without the fix. Six were in the `--target=js` backend and three in the parser
and lexer.

| # | what was wrong | where |
|---|---|---|
| 1 | `sub f(*%a)` bound the POSITIONAL arguments into `%a`, so `f(:id<c>)` — and even `f()` — died with "Odd number of elements found where hash initializer expected". Every builder takes `*%attrs`. | `codegen/Js.cpp`, `bindParams` |
| 2 | A declared sub named `div` lost to the infix at term position, and `tr`/`q` to the quote constructs. Rakudo lets the declared routine win; an adverb (`s:g///`, `q:to//`) is where it draws the line, and so does this now. | `Parser.cpp`, `Lexer.cpp` |
| 3 | `.trans(['&','<'] => ['&amp;','&lt;'])` mapped the CONCATENATED strings character by character, so `"` became the `p` of `&quot;`. HTML escaping is the framework's most important function, and this produced text that looked escaped and was not. | `js-rt/20-str.js` |
| 4 | A file-scope `constant` was invisible inside a class method, because classes are hoisted to the front of their statement list and the declaration had not been walked yet. | `codegen/Js.cpp`, `emitStmts` |
| 5 | A `&`-sigil parameter lost to a global sub of the same name: `sub page($p, &body)` stored the `body` TAG BUILDER in the route, and every page built one empty `<body>`. | `codegen/Js.cpp`, name resolution |
| 6 | Two anonymous parameters in one signature — `-> $, Str $ { … }`, ordinary Raku — emitted `(_anon, _anon)`, a JavaScript syntax error that took the whole program with it. | `codegen/Js.cpp`, parameter lists |
| 7 | A type smiley was dropped in a smartmatch: `$x ~~ Element:D` was true for the type object, so a guard meant to catch "no parent" let it through. | `codegen/Js.cpp`, `js-rt/30-list.js` |
| 8 | **Every closure made in a `for` loop captured the same loop variable**, and saw its last value: three rows of a list all called the handler of the third. The variable was declared outside the loop so a `LAST` phaser could read it; now the head declares it per iteration and the phaser reads a copy. | `codegen/Js.cpp`, `forStmt` |
| 9 | `@a.map(* => True)` passed a literal Whatever-keyed Pair instead of currying, so `map` was handed a Pair where it wanted a callable. | `codegen/Js.cpp`, `hasWhatever` |

Two more divergences were found and left alone, recorded rather than fixed:
`tr:c///` (the complement adverb) is not implemented in Raku++, and `react`
over a live Supplier that never emits returns at once under Raku++ where
Rakudo blocks. The framework does not lean on either — the second is the reason
an element's events are an already-finished Supply on the server rather than a
live one.

### Three things the design had to learn

- **A page body that calls an `is server` sub is async**, so the builder stack
  must stay open across an `await`. `with-parent` awaits the body; the guard is
  the engine and not the value, because a JavaScript Promise crossing back into
  Raku arrives as `Any`.
- **`react` in a browser never returns.** Nothing may be written after the page
  body, so anything that has to happen "once the tree is built" has no moment
  to run in. Hydration is therefore decided per element — adopt when there is a
  node at this position, create when there is not — which is self-correcting
  where a queued timer was a race that built the whole page a second time.
- **A DOM listener attaches when the Supply is first asked for**, which is when
  `whenever $b.clicks` evaluates it, before the enclosing `react` starts
  waiting. A pass scheduled afterwards never runs.

## Name

**Decided: Webraku** (2026-10-05). In an English compound the last word names
the thing, so Webraku reads as a kind of Raku — Raku for the web, a dialect
for this one area — where Rakuweb read as a kind of web. That is what the
framework is: one Raku program on both sides, with `is server` marking where a
part runs. It needs no explaining and stays in the family the rest of this
work uses — `rakupp` the engine, `rakus` the static server, `rakugrid`,
`rakumap`, `rakujs`.

The program writes `use Webraku;` — one name only. A lowercase `use webraku;`
was considered, since a dialect is close to a pragma, and left out so that
there is a single spelling.

Before 2026-10-05 the name was Rakuweb and the directory was called `rakuact`
("React, in Raku"). Five rounds of candidates came before Webraku, and the
reasoning is kept because it is what arrived here. The first four rounds were
checked free in the ecosystem index (2026-09-06 copy, checked 2026-09-13).

**Round one, a name of its own.** Monarch — the butterfly that migrates between
two homes, in Camelia's family like Wings. Rejected: it is an ordinary English
word whose dominant meaning is a ruler, so the butterfly reading needs a
footnote every time, and it is used by unrelated products elsewhere.

**Round two, wider.** Amphi (the Greek "both sides"), Duplex (both directions at
once), Isomer, Tandem, Duet; Eclosion and Instar and Pinion from the butterfly's
own vocabulary; Heddle and Skein and Weft from weaving, which is where the word
"web" comes from; Tsunagi and Mado from Japanese. Loom, Quill, Shuttle, Twain,
Ditto and Hashi were ruled out on collisions outside Raku.

**Round three, built on `raku` itself, leaning Japanese.** 楽 is "ease", so
Rakuraku (楽々, "effortlessly"), Rakuen (楽園, "paradise" — but one letter from
Rakuten), Rakusho, Rakuyaki.

**Round four, built on `raku` without the Japanese.** Rakuweb, Rakuapp, Rakuone,
Rakuduo, Rakutwin, Rakubridge, Rakulink, Rakuflux, Rakuforge, Rakuwright. One
practical filter thinned this list: `rakupp` and `rakus` already exist as
commands, so anything beginning `rakup-` or `rakus-` makes tab-completion
ambiguous, which ruled out Rakusite, Rakustack, Rakuserve, Rakuspan and
Rakupage. Rakuweb was chosen from this round and used until 2026-10-05.

**Round five (2026-10-05).** Emit, after the keyword that drives every update —
but emit-rs, a Rust diagnostics framework, already brands itself as plain
`emit`; variants Emitto (Latin, "I send out"), Emitsu, Emittance, Reemit.
Blends where Raku takes over the start of a word: Rakunect (connect) was the
working name for a while, then Rakuncord, Rakuntinuum, Rakunverge, Rakumbine;
anything containing "kuni" was ruled out. Raku, web and framework squeezed
together: Fraku, Webku, Wraku, Rakuwerk. Translations of 楽 into European
languages (Gemak, Leggiero, Eukolia) lost the link to Raku. Then an internet
word in front of `raku`: Webraku, Netraku, Interaku, Hyperaku. Names built on
Japanese words were dropped as a rule: a name should not carry meanings its
author cannot check.

Distribution `Webraku`; modules `Webraku::HTML`, `Webraku::Route`,
`Webraku::JSON`, `Webraku::Server`, `Webraku::Client`, `Webraku::Rpc`,
`Webraku::Bundle`; the command is `webraku`.

## What this plan does not do

Kept out on purpose, each a later plan if wanted:

- a markup slang over the builders (the JSX look);
- a virtual DOM and whole-tree diffing — the retained-element model covers
  the applications this is for, and lists are the one diff;
- streaming server rendering, partial hydration, islands;
- WebSocket-backed Supplies (`whenever $server.events`) — the natural next
  step once P4 stands, and the one where `react` earns its keep;
- file-based routing, nested layouts, middleware chains;
- sessions, authentication, forms validation, CSS helpers;
- HTTP/2, TLS termination (put it behind nginx, as raku.online is);
- anything from npm, or a Node-side host: the server is Raku++, full stop.

## Reproducing the numbers

```
rakupp probes/run.raku      # the five probes on Rakudo, Raku++ and Node
rakupp probes/tags.raku     # the 113-tag table on both engines
```

After the P0 fixes the tag table reads: Rakudo fails on `i`, `map` and `sub`;
Raku++ on `sub` alone.

`probes/02-client.raku` needs a JavaScript host — `bun` by default, `node` with
`RAKUPP_JS=node` — and preloads `probes/dom-stub.js`;
the standalone size quoted above is the `-o` output of that file. Rakudo
is read from `$RAKUDO`, default `/opt/homebrew/bin/raku`; the Raku++ is
the one running the script.
