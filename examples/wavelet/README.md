# Wavelet shrinkage

A page for playing with wavelet transforms. A test signal is buried
in noise, decomposed with
[Math::Wavelet](https://github.com/ash/raku-modules/tree/main/Math-Wavelet),
its detail coefficients thresholded, and reconstructed. Below that, the
continuous transform of the same signal is drawn as a scalogram. Every
control is a slider or a menu, and moving one redraws the page.

```
rakupp install Math::Wavelet
webraku run examples/wavelet/wavelet.raku --port=8795
```

The page needs a Raku++ whose `--target=js` compiles `use`d modules (built
after 2026-10-11), and Math::Wavelet 0.0.2, which adds the continuous
transform. To run against a checkout of the module instead of an installed
copy, point `RAKULIB` at it:

```
RAKULIB=../raku-modules/Math-Wavelet/lib webraku run examples/wavelet/wavelet.raku --port=8795
```

## What is on the page

| control | what it changes |
|---|---|
| signal | one of Donoho and Johnstone's four test signals: Doppler, Blocks, Bumps, HeaviSine, each scaled to unit standard deviation |
| noise σ | the standard deviation of the added Gaussian noise, 0 to 0.6 |
| new noise | the seed. The noise comes from its own generator, so the same seed gives the same noise on every request, and a slider changes only what it controls |
| wavelet | thirteen of the 106: Haar, Daubechies, Symlets, Coiflets, biorthogonal, reverse biorthogonal and discrete Meyer |
| levels | how many times the transform is applied, 1 to 6, limited by what the wavelet allows for 512 samples |
| threshold × universal | the threshold, as a multiple of VisuShrink's σ√(2 ln n), with σ estimated from the finest details |
| threshold mode | hard, soft or garrote |

What it draws:

- the signal, the noisy signal, and the reconstruction from the coefficients
  that survived;
- every detail level, coarsest first, with one stem per coefficient: blue
  where it survived the threshold, grey where it was set to zero, and the
  threshold itself as dashed lines;
- the approximation coefficients, which are never thresholded;
- ψ and φ, the wavelet and its scaling function, drawn by the cascade
  algorithm: a single 1 among zero coefficients, reconstructed;
- σ as estimated, the threshold, how many coefficients were kept, and the
  RMS error against the clean signal before and after;
- the scalogram, |W| of the continuous transform of the noisy or the clean
  signal, under one of twelve continuous wavelets. Its 36 rows run from a
  period of 2 samples at the top to 80 at the bottom. Each wavelet's scales
  are found from its centre frequency, so every wavelet covers the same
  band. Beside it is ψ, with the imaginary part dashed for a complex
  wavelet.

## How it is split

| file | runs on |
|---|---|
| `wavelet.raku` | both. The server runs it to render the page; `webraku build` turns it into the browser's script |
| `Analysis.rakumod` | both. It holds the signals, the noise, the transform calls, the SVG path data, and the scalogram's bitmap |

Both `transform` and `scales` are ordinary subs, so after the first render
the page is a program running in the browser. Nothing in it is `is server`.

`transform` is an ordinary sub. The server calls it to render the first
picture, and in the browser it runs on every move of a control with no request:
a median of 6 ms per step for db4 in the browser this was measured in, against
60 ms on the server plus the round trip when it was an `is server` call.

It can, because `rakupp --target=js` compiles `use`d modules into the program.
The browser's code calls `analyse`, which `Analysis` exports, so the bundler
keeps `use Analysis` and passes the application's directory to rakupp as `-I`.
`Analysis` uses Math::Wavelet, which comes too, all 106 filter tables of it.
The script is about 750,000 characters.

Getting Math::Wavelet through the transpiler took, besides module support
itself, twelve fixes in Raku++'s JavaScript backend. Among them are
hyphenated attributes (`@!dec-lo` read as empty), one-letter constants (`N`
and `H` were one variable), a sub declared in a class body, `Lock`, `.Map`,
`cis`, and `.max(:by)` on a Range. Each is checked in Raku++'s JS gate.

The scalogram, `scales`, runs in the browser too. It draws the image as a
`data:` URI: a 256 × 36 BMP of 27 KB, written byte by byte in
`Analysis.rakumod`, where as SVG it would be ten thousand rectangles. One
takes 0.4–0.7 s in the browser, against 1–2.7 s on the Raku++ server, so it
is redone only when the signal, the seed or the continuous wavelet changes,
and the noise slider redoes it only when let go. The DWT sliders never touch
it. Because the work blocks the page while it runs, it waits for
`after(0.02)`: the event turn ends, "computing…" is drawn, and the result is
drawn when the work is done.

Nothing is `is server` any more. Once the page and its script have loaded,
the browser asks the server for nothing. The server renders the first
picture, so the page arrives drawn and shows a complete picture with
JavaScript switched off. The browser then computes the same `transform` and
`scales` the server did, and adopts the nodes the server sent. The cost is
paid twice: the server renders in about 2.3 s, and hydrating the page
spends about half a second on the scalogram again.

If a second change arrives before the deferred scalogram starts, the first
one is moot. Each request takes a number, and one that is no longer the
latest is skipped.
