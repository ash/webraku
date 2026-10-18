# Unicode explorer

Unicode's tables on the server, the arithmetic in the browser.

```
webraku run examples/unicode/unicode.raku --port=8802
```

Search every named character by words in its name, by its code (`U+1F600`,
`0x1F600`, `\x[1F600]`), or by pasting it. Pick one to see what Unicode says
about it, its encodings, and the Raku that makes it. Below, a box takes any
string and lists its code points.

## How it is split

| file | runs on |
|---|---|
| `unicode.raku` | both. The server renders the page from it; `webraku build` turns it into the browser's script |
| `Codes.rakumod` | both. UTF-8 bytes, UTF-16 units, how to show a character on its own, a string counted four ways |
| `Names.rakumod` | the server only. The index of names, the search, the properties |

The server has Unicode's database: Raku++'s `uniname` and `uniprop`.
`Names.rakumod` runs `uniname` over the whole code space when the server
starts, in about two seconds, and keeps 46,710 names to search. Another
126,000 are a prefix and a number, such as `CJK UNIFIED IDEOGRAPH-4E00`; they
are left out of the word search and found by code or by pasting. All of that
is 4.6 MB of text, and none of it is in the browser's script, since only the
`is server` subs use `Names`.

The browser has the arithmetic. A code point's UTF-8 bytes and UTF-16 units
follow from its number, so `Codes.rakumod` is called by the page itself and
runs in both places. Picking a character shows its encodings at once, and the
properties arrive from the server a moment later. Typing in the string box
updates the four counts on every keystroke. Raku's `.chars` counts what a
reader sees as one character, so a flag made of two code points counts once.
The names come from the server once the typing pauses.

| `is server` sub | what it answers |
|---|---|
| `find($query)` | up to 72 characters, the best first, and how many matched |
| `about($cp)` | block, script, age, bidirectional class, East Asian width, numeric value, case mappings and canonical decomposition |
| `name-codes(@cps)` | the name and general category of each code point in a string |
| `index-facts()` | how many names there are |

A search waits until the typing has paused for 0.2 s before it asks, and
each question takes a number, so an answer that arrives after a newer
question was asked is dropped. The same goes for the properties, which can
be asked for faster than they come back.

`/u/1F98B` is the page with that character picked. The server renders it,
so the link works with JavaScript switched off, and picking a character
updates the address with `window().history.replaceState`.

## Measured

On Raku++, a word search over the 46,710 names takes 40–50 ms, and the
index takes 2.4 s to build when the server starts.
