# Pixels

One picture, 48 × 32 cells in sixteen colours, shared by everyone who has the
page open.

```
webraku run examples/pixels/pixels.raku --port=8803
```

## How it is split

| file | runs on |
|---|---|
| `pixels.raku` | both. The server renders the page from it; `webraku build` turns it into the browser's script |
| `Board.rakumod` | the server only. The picture, the record of changes, who is here, and how fast each address may paint |

Painting is the browser's: a cell changes colour the moment the pointer
crosses it, with no request. The strokes wait in a list. A quarter-second
clock sends them if there are any, and asks anyway once a second, with one
call:

```raku
sub sync(Int $since, @strokes, Str $who) is server { … }
```

`$since` is the version of the picture the browser has. The server applies
the strokes and answers every change made since that version, by anyone, its
own included, so one round trip carries both ways. A visitor too far behind
for the record, which keeps the last 5,000 changes, gets the whole picture
instead, and so does one whose version is ahead of a server that has
restarted since.

A change that comes back for a cell painted here after the question went out
is skipped: that stroke is newer, and goes out next time.

The server takes 60 pixels at once from each address and 8 a second after
that, read from `X-Forwarded-For` when the server is behind a proxy. When
some strokes are refused, the browser asks for the whole picture on its next
call, which puts those cells back as everyone else sees them, and says why.
The address comes from `request()`, which an `is server` sub can call to see
the request it is answering.

`$who` is a random name the page makes when it loads, so the server can count
the visitors it has heard from in the last 15 seconds.

The picture is saved to a file after every change, `$TMPDIR/webraku-pixels.txt`
or `WEBRAKU_PIXELS_FILE`, and read back when the server starts. Deleting the
file starts the board again from the picture in `Board.rakumod`.

## The first render

The server's call to `snapshot` is in the page's replay log, so the browser
hydrates the picture the server drew without asking for it. With JavaScript
switched off, the page is the picture as it was when it was sent.
