# The Webraku demos, as a site

Everything needed to serve the examples on one domain, such as
`webraku.raku.online`: a front page that is itself a Webraku program, a
launcher that runs each demo as its own process, a Caddyfile, and a systemd
unit.

| file | what it is |
|---|---|
| `demos.txt` | what runs where: a name, a port, a mount path and a program per line |
| `hub.raku` | the front page, at `/` |
| `run.raku` | builds every demo's browser half, runs each on its port, and starts again any that stops |
| `Caddyfile` | the proxy in front, made from `demos.txt` by `run.raku caddy` |
| `webraku-demos.service` | the systemd unit that keeps `run.raku` running |

| path | demo | why it is split the way it is |
|---|---|---|
| `/` | the front page | lists the demos, and reads each one's source on the server to show which subs and modules stay there |
| `/sudoku/` | Sudoku | the rules run in the browser on every keystroke; the solver and the solution stay on the server |
| `/unicode/` | Unicode explorer | 172,808 names and Unicode's properties are on the server; encodings and counting are worked out in the browser |
| `/pixels/` | Pixels | one picture shared by every visitor, kept on the server; painting is instant and local, synced every second |
| `/wavelet/` | Wavelet shrinkage | Math::Wavelet in both halves: the discrete transform in the browser, the continuous one on the server |
| `/sieve/` | Primes | a computation whose code never reaches the browser |
| `/counter/` | Counter | nothing from the server after the page loads |

## Trying it on one machine

```bash
rakupp demo/run.raku --proxy=8080
```

`--proxy` adds a small proxy of its own, so the whole site is at
`http://127.0.0.1:8080/` with no Caddy. It is for trying the site, not for
serving it. `--only=hub,sudoku` runs some of the demos; `--no-build` skips
building the browser halves when they are already built.

The wavelet demo needs Math::Wavelet 0.0.2 or later, either installed
(`rakupp install Math::Wavelet`) or a checkout named by `RAKULIB`.

## How the demos share a domain

Each demo is an ordinary Webraku program with its own routes written from
`/`. `run.raku` starts each one with `WEBRAKU_BASE` set to its mount, such as
`/sudoku`, and the program then answers under that path: a request for
`/sudoku/_rpc/hint` reaches its `hint`, its pages ask for their script at
`/sudoku/_webraku/client.js`, and `url('/u/41')` in a program mounted at
`/unicode` is `/unicode/u/41`, on the server and in the browser alike. The
proxy passes the path on unchanged. A program that is reached with the base
already taken off answers the same, so a proxy that strips it works too.

A demo that stops is started again after a second, and the wait doubles, up
to a minute, while it keeps stopping.

## Serving it

On a Linux server with Caddy installed, as root:

1. Point the domain's DNS at the server.

2. Make a user and install Raku++ for it, with the installer from raku.online.
   The browser halves are built with the same `rakupp` that runs the servers.
   The demos were built and tried with Raku++ 5.4.1-122, a development build
   made after v5.4.1; no release has been tried, so until the next one, a
   build from source is the safe choice.

   ```bash
   useradd --system --create-home --shell /usr/sbin/nologin webraku
   sudo -u webraku sh -c 'curl -fsSL https://raku.online/install.sh | sh'
   sudo -u webraku /home/webraku/.rakupp/bin/rakupp install Math::Wavelet
   ```

3. Put the repository in `/opt/webraku`, owned by that user.

   ```bash
   git clone https://github.com/ash/webraku /opt/webraku
   chown -R webraku:webraku /opt/webraku
   ```

4. Install the unit and start it. The first start builds seven browser
   halves, one after another, which takes a minute or two.

   ```bash
   cp /opt/webraku/demo/webraku-demos.service /etc/systemd/system/
   systemctl daemon-reload
   systemctl enable --now webraku-demos
   journalctl -u webraku-demos -f
   ```

5. Give Caddy the site. For a domain other than `webraku.raku.online`, make
   the Caddyfile for it first with
   `rakupp demo/run.raku caddy your.domain`.

   ```bash
   cp /opt/webraku/demo/Caddyfile /etc/caddy/Caddyfile
   systemctl reload caddy
   ```

   Caddy gets the certificate and compresses the answers. Each browser half
   is about half a megabyte, and about a quarter of that compressed (the
   wavelet demo's is 750 KB, 185 KB gzipped). Pages are
   sent with `Cache-Control: no-store`; a bundle's address carries its
   server's start time and may be cached for good.

To update, pull and restart: `run.raku` rebuilds every browser half when it
starts.

```bash
sudo -u webraku git -C /opt/webraku pull
systemctl restart webraku-demos
```

## What the public can do to it

The demos were written to be left open:

- No demo runs code it is sent. The Unicode search takes words, a code or
  characters, and matches them as text.
- The pixel board takes 60 pixels at once from each address and 8 a second
  after that, by `X-Forwarded-For`, which Caddy sets. Its state is one file,
  `/var/lib/webraku/pixels.txt`; deleting it and restarting starts the board
  again from the picture in `examples/pixels/Board.rakumod`.
- The Sudoku tally keeps at most 10,000 times per level, in memory.
- A request body over a megabyte is answered 413 without being read.
- The todo example writes whatever it is sent to a file, so it is not among
  the demos.
- Each demo listens on 127.0.0.1 only, so only the proxy reaches it.
