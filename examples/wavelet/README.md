# Wavelet shrinkage

A page for playing with the discrete wavelet transform. A test signal is buried
in noise, decomposed with
[Math::Wavelet](https://github.com/ash/raku-modules/tree/main/Math-Wavelet),
its detail coefficients thresholded, and reconstructed. Every control is a
slider or a menu, and moving one redraws the page.

```
rakupp install Math::Wavelet
webraku run examples/wavelet/wavelet.raku --port=8795
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
  RMS error against the clean signal before and after.

## How it is split

| file | runs on |
|---|---|
| `wavelet.raku` | both. The server runs it to render the page; `webraku build` turns it into the browser's script |
| `Analysis.rakumod` | the server only. It holds the signals, the noise, the transform calls and the SVG path data |

`transform` is `is server`, so its body stays on the server. The browser's
copy posts the seven control values to `/_rpc/transform` and gets back SVG
path data and numbers that are already formatted: about 30 KB, in 60 ms
for db4 on the machine this was written on. The first time a wavelet is
asked for, its ψ and φ are computed as well, which for dmey takes 0.6 s.
After that they are cached.

`use Analysis` stays out of the browser bundle because the module lives beside
the application. The transpiler cannot load a user module, so the bundler
leaves out a `use` of one found in the application's directory. Math::Wavelet
reaches the server through `Analysis`, so all 106 filter banks stay there too.

The first render needs no request. The server's call to `transform` is in
the page's replay log, so the page arrives already drawn, and it shows a
complete picture with JavaScript switched off.

A slider sends an input event for every step it is dragged through, and the
answers can come back out of order. Each request takes a number, and an
answer that is not for the latest request is dropped.
