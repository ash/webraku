# Sudoku

The rules run in the browser; the answer stays on the server.

```
webraku run examples/sudoku/sudoku.raku --port=8801
```

## How it is split

| file | runs on |
|---|---|
| `sudoku.raku` | both. The server renders the page from it; `webraku build` turns it into the browser's script |
| `Rules.rakumod` | both. `clashes`, `peers`, `filled` and the grid's text form |
| `Solver.rakumod` | the server only. `solve-grid`, `make-puzzle`, `candidates` |
| `Tally.rakumod` | the server only. How many puzzles have been solved since it started |

The page calls `clashes` on every keystroke to mark a digit that repeats in
its row, column or box. The browser's code calls it, so the bundler keeps
`use Rules`, and the rule runs with no request. The server uses the same subs
while it renders and while it answers.

`Solver.rakumod` is used by the four `is server` subs and by nothing else, so
the bundler leaves it out of the browser's script. A visitor reading the
page's JavaScript finds the rules and no way to the answer. The solution of
the puzzle on the screen is never sent either. It is not stored anywhere: the
server finds it again from the puzzle whenever `hint` or `check` needs it,
which takes a few milliseconds for a puzzle with one solution.

| `is server` sub | what it answers |
|---|---|
| `new-puzzle($level)` | a fresh puzzle with exactly one solution: 40 digits for easy, 32 for medium, as few as it can manage for hard |
| `hint($puzzle, $now)` | a wrong digit if there is one; else a cell where only one digit fits, or a digit with one place left in its row, column or box, with the reason; else a digit from the answer |
| `check($puzzle, $now)` | which of the digits typed so far are wrong, without saying what goes there |
| `solved($level, $seconds)` | how many puzzles at that level have been solved since the server started, and how many of them faster |

One thing needs no question. A full grid with no clashes is a solution, and a
puzzle with one solution has no other, so the browser says "solved" by
itself.

## Making a puzzle

`make-puzzle` fills an empty grid with random digits by searching for a
solution with the digits tried in a random order, then takes digits away in
pairs that mirror through the centre, as long as the solution stays unique.
For a hard puzzle it then tries single cells, giving up the symmetry to go
further. The search always branches on the empty cell with the fewest
candidates, kept as bit masks per row, column and box.

On Raku++ a puzzle takes 0.05 s for easy, 0.1 s for medium and about
0.25 s for hard, which ends with 26 to 30 digits given.

## The page

The first render needs no request: the server's call to `new-puzzle` is in the
page's replay log, so the browser hydrates the same puzzle. Arrow keys move
between cells; the focused cell's row, column and box are shaded, and so is
every cell holding the same digit. The clock runs in the browser.
