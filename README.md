# nix-bundle-lgx

A [Nix bundler](https://nixos.org/manual/nix/stable/command-ref/new-cli/nix3-bundle.html) that packages a derivation's `lib/` output into a single-variant `.lgx` file.

## Bundlers

### `#default` (dev)

Wraps the derivation's `lib/` directory directly into an `.lgx` package with a **dev variant** (`-dev` suffix). Dynamic libraries are **not** relocated — they continue to resolve dependencies from `/nix/store` at runtime. Suitable for environments where the Nix store is available.

```bash
nix bundle --bundler github:logos-co/nix-bundle-lgx .#lib
```

### `#portable`

First passes the derivation through [`nix-bundle-dir#qtPlugin`](https://github.com/logos-co/nix-bundle-dir), which copies all non-system/non-Qt transitive dependencies alongside the library and rewrites their rpaths to use `@loader_path` (macOS) or `$ORIGIN` (Linux). The resulting self-contained directory is then wrapped into an `.lgx` package with the **portable variant** (no suffix).

```bash
nix bundle --bundler github:logos-co/nix-bundle-lgx#portable .#lib
```

### `#dual`

Produces a **dual-variant** `.lgx` package containing both the portable variant and the dev variant. The portable variant is created via `nix-bundle-dir` (self-contained), while the dev variant uses the raw derivation output (resolves from `/nix/store`). Useful for distributing a single package that works in both dev and portable environments.

```bash
nix bundle --bundler github:logos-co/nix-bundle-lgx#dual .#lib
```

## Variant Names

Each bundler mode produces variants with specific naming:

| Nix system        | Dev variant (`#default`) | Portable variant (`#portable`) |
|-------------------|--------------------------|-------------------------------|
| `aarch64-darwin`  | `darwin-arm64-dev`       | `darwin-arm64`                |
| `x86_64-darwin`   | `darwin-amd64-dev`       | `darwin-amd64`                |
| `aarch64-linux`   | `linux-arm64-dev`        | `linux-arm64`                 |
| `x86_64-linux`    | `linux-amd64-dev`        | `linux-amd64`                 |

The `#dual` bundler includes both the portable and dev variant names in a single `.lgx` file.

## Output

All bundlers produce a single `.lgx` file placed in `$out/`. When invoked via `nix bundle -o result`, the result symlink points to that directory.

## Metadata

The bundler reads `metadata.json` from the derivation's **source tree** (`drv.src`) at Nix eval time — not from the build output. If `metadata.json` is found, the fields `name`, `version`, `description`, `author`, `type`, `category`, `dependencies`, and `view` are patched into the `.lgx` manifest automatically. If not found, the bundler falls back to an empty `{}`.

`metadata.json` is not required in the derivation output (`$out/`) for `core` or `ui` modules.

For `type == "ui_qml"`:
- `view` is required and points to the QML entry file bundled inside each variant
- `main` is optional and, when present, is treated as the backend plugin base name
- QML-only packages are emitted without synthesizing `main = view`

## Expected derivation layout

The bundler expects the input derivation to expose a `lib/` subdirectory containing the shared library (`.dylib` on macOS, `.so` on Linux). This matches the `#lib` output convention used by Logos modules.

```
$out/
  lib/
    libfoo.dylib   # or libfoo.so
  metadata.json    # optional
```

## Mobile variants: `lib.<system>.mobileCatalog`

A bundler cannot publish a phone. `nix bundle` hands the bundler a derivation
and nothing else, so there is no way to say *which* of `aarch64-ios`,
`aarch64-ios-simulator` or `aarch64-android` a cross-built artifact is for —
and `pkgs.stdenv.hostPlatform` under an iOS cross set answers "darwin", which
is the desktop variant name and the wrong one.

So mobile publishing is a **library**: the caller names the target, because the
caller is the only thing that knows which output it just built. Everything in
it runs on the builder over bytes that are already cross-compiled.

```nix
let
  publish = nix-bundle-lgx.lib.${buildSystem}.mkMobileCatalog {
    # Optional. Pass your own lgx when your closure already ships one: a
    # package written by one lgx and admitted by another is two
    # implementations agreeing by luck.
    inherit lgx;
  };

  payload = publish.mkVariantPayload {
    drv = myModule.packages.aarch64-ios-simulator.bare;   # or .mobile.<sys>.bare
    stem = "my_module_bare";
    target = "ios-sim-arm64";
  };

  pkg = publish.mkPackage {
    name = "my_module";
    version = "1.0.0";
    type = "core";
    dependencies = [ ];
    variants.ios-sim-arm64 = payload;
    signingKey = { name = "release"; jwk = /keys/release.jwk; };
  };

  catalog = publish.mkCatalog {
    release = "2026.1";
    signers = [ "did:jwk:..." ];          # the ONLY DIDs a member may carry
    packages = [ { spec = …; drv = pkg; } ];
  };

  # The artifact a consumer FETCHES: the same index with every member's
  # sha256 and Merkle root filled in.
  release = publish.mkRelease {
    inherit catalog;
    baseUrl = "https://github.com/org/repo/releases/download/2026.1";
  };
in release
```

| Function | Takes | Produces |
|---|---|---|
| `mkVariantPayload` | a `logos-module-builder` mobile artifact, a `stem`, a `target` | `{ main; payload; }` — the image restaged in the layout the target's loader wants |
| `mkPackage` | name/version/type/dependencies/`variants`/`signingKey` | `$out/<name>.lgx`, signed and `lgx verify`-clean |
| `mkCatalog` | `release`, `signers`, the packages | `{ index; root; }` — `index` is a **Nix value**, `root` a directory with `packages/` and `index.json` |
| `mkRelease` | a catalog, an optional `baseUrl` | `$out/index.json` + `packages/`, every entry carrying `sha256` and `rootHash` |

### Variant names and payload layout

| Nix pseudo-system | LGX variant | Payload layout | Embedded in the app under |
|---|---|---|---|
| `aarch64-ios` | `ios-arm64` | `Frameworks/<stem>.framework/<stem>` | `Frameworks/` |
| `aarch64-ios-simulator` | `ios-sim-arm64` | `Frameworks/<stem>.framework/<stem>` | `Frameworks/` |
| `aarch64-android` | `android-arm64` | `lib/lib<stem>.so` | `lib/` |

`variantForSystem`, `systemForVariant` and `embedDirFor` are exposed so a
consumer resolves the same mapping rather than restating it. The payload is
laid out for the **app**, not for the package, so assembling a set out of the
extracted variants is a copy and never a second re-layout that could disagree
with the manifest's `main`.

### Why `mkRelease` is separate

`mkCatalog`'s index is a Nix value on purpose: names, versions, dependencies
and which variants exist are all known at eval, so a consumer can refuse
"module X ships no `ios-sim-arm64`" *before* a cross toolchain runs. What is
**not** knowable at eval is a Merkle root or a sha256 — those exist only once
the archive does. `mkRelease` computes them in a derivation and writes them
into an `index.json` that a consumer reads as **data it fetched**, not as a
derivation it built. That file is what turns "trust this path" into a
fixed-output fetch that cannot resolve to different bytes.
