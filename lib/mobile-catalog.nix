# Publishing MOBILE `.lgx` variants, and the catalog that indexes them.
#
# The rest of this repo is a nix BUNDLER: `drv -> .lgx`, one variant, named
# after the platform the derivation was built for. That shape cannot publish a
# phone. A bundler takes no arguments, so it cannot be told which of three
# cross targets a derivation is for; and `pkgs.stdenv.hostPlatform` under an
# iOS cross set answers "darwin", which is the desktop variant name and the
# wrong one.
#
# So mobile publishing is a LIBRARY, not a bundler: the caller names the
# target, because the caller is the only thing that knows which of
# `packages.aarch64-ios{,-simulator}` / `mobile.aarch64-android` it just built.
# Everything here RUNS ON THE BUILDER over an artifact that is already
# cross-compiled -- `pkgs` is a build-platform package set, never a cross one.
#
#     mkVariantPayload   a logos-module-builder mobile artifact, restaged in
#                        the layout the TARGET's loader wants
#     mkPackage          one signed .lgx, one or more variants
#     mkCatalog          the index a Bundled-set build resolves against
#     mkRelease          that index with each member's sha256 and Merkle root
#                        pinned -- the artifact a consumer FETCHES
#
# WHY THE INDEX IS A NIX VALUE AND NOT A FILE THE CONSUMER READS BACK.
# Everything a dependency closure and a variant check need -- names, versions,
# dependencies, which variants exist -- is known here, at eval, from the spec.
# Writing it out and reading it back would turn every Bundled-set build into an
# import-from-derivation, i.e. would cross-compile three modules before nix
# could tell you that you misspelled one of them. `mkRelease` is the one place
# that writes a file, because the numbers IT adds (a Merkle root, a sha256)
# exist only once the archive does -- and a consumer of a release reads that
# file as data it FETCHED, not as a derivation it built.
{ pkgs, lgx }:

let
  inherit (pkgs) lib;

  # The nix pseudo-systems logos-nix keys its mobile package sets by, mapped to
  # the variant vocabulary logos-package owns (docs/spec.md, "Platform Variant
  # Vocabulary"). Two namespaces, one target -- and they are spelled
  # differently, so the mapping is written down once here rather than guessed
  # at each call site.
  variantForSystem = {
    aarch64-ios-simulator = "ios-sim-arm64";
    aarch64-ios           = "ios-arm64";
    aarch64-android       = "android-arm64";
  };

  systemForVariant =
    lib.listToAttrs (lib.mapAttrsToList (s: v: { name = v; value = s; }) variantForSystem);

  # An iOS module is an embedded framework and an Android one a shared object,
  # and each platform's loader will look in exactly one place inside the app.
  # A variant's payload is laid out for that place, so the layout follows from
  # the target alone -- on both sides, because the consumer copies the payload
  # into the app verbatim rather than re-deriving where each file goes.
  embedDirFor = target:
    if lib.hasPrefix "ios" target then "Frameworks" else "lib";

  # `lgx create` writes a skeleton manifest and there is no `lgx manifest set`,
  # so the fields a catalog needs are patched in the way bundle.sh patches
  # them: rewrite manifest.json inside the archive before the variants go in.
  # After `lgx add` the hashes are recomputed and `lgx sign` covers the result,
  # so nothing here outlives the signature.
  patchManifest = pkgs.writeText "lgx-patch-manifest.py" ''
    import io, json, sys, tarfile

    lgx_path, fields_path = sys.argv[1], sys.argv[2]
    fields = json.load(open(fields_path))

    with tarfile.open(lgx_path, "r:gz") as tar:
        members = [(m, tar.extractfile(m).read() if m.isfile() else None)
                   for m in tar.getmembers()]

    patched = []
    for member, data in members:
        if member.name == "manifest.json":
            manifest = json.loads(data)
            manifest.update(fields)
            data = json.dumps(manifest, indent=2).encode()
            member.size = len(data)
        patched.append((member, data))

    with tarfile.open(lgx_path, "w:gz", format=tarfile.GNU_FORMAT) as tar:
        for member, data in patched:
            if data is None:
                tar.addfile(member)
            else:
                tar.addfile(member, io.BytesIO(data))
  '';

  # Restage a logos-module-builder mobile artifact as an LGX variant payload.
  #
  # `bare` and `view` publish an iOS framework under Library/Frameworks/ and an
  # Android shared object under lib/. A variant payload is the same image in
  # the layout the APP carries it in -- Frameworks/ on iOS, lib/ on Android --
  # so that assembling a Bundled set is a copy and not a second re-layout that
  # could disagree with the manifest's `main`.
  #
  # `extraFiles` is how a `ui_qml` package satisfies the format's `view`
  # contract: `lgx sign` refuses a ui_qml package whose declared view is not a
  # file inside the variant. On iOS the QML the host renders comes out of the
  # framework's own qrc (one image, nothing to install), so the copy in the
  # variant is what a reader of the PACKAGE sees. Name the same source file the
  # qrc is built from and the two cannot drift.
  mkVariantPayload =
    { drv
    , stem
    , target
    , extraFiles ? { }
    }:
    let
      ios = lib.hasPrefix "ios" target;
      embedDir = embedDirFor target;
      main = if ios then "Frameworks/${stem}.framework/${stem}" else "lib/lib${stem}.so";
      copyExtra = rel: file: ''
        mkdir -p "$out/$(dirname ${lib.escapeShellArg rel})"
        cp ${file} "$out/${rel}"
      '';
    in
    {
      inherit main;
      payload = pkgs.runCommand "${stem}-${target}-payload" { } (''
        set -euo pipefail
        mkdir -p $out/${embedDir}
        ${if ios
          then ''cp -R ${drv}/Library/Frameworks/${stem}.framework $out/Frameworks/''
          else ''cp ${drv}/lib/lib${stem}.so $out/lib/''}
        chmod -R u+w $out
        test -e $out/${main} || {
          echo "error: ${stem} produced no ${main}; the artifact is not shaped like a ${target} variant" >&2
          exit 1
        }
      '' + lib.concatStrings (lib.mapAttrsToList copyExtra extraFiles));
    };

  # One package, one derivation: $out/<name>.lgx, signed.
  #
  #   variants."<lgx variant>" = { payload = <dir>; main = "<relpath in payload>"; }
  #
  # `payload` is laid out the way the target's loader wants it -- which is what
  # mkVariantPayload produces, and what a consumer copies into the app image.
  mkPackage =
    { name
    , version
    , type ? "core"
    , description ? name
    , author ? "Logos"
    , category ? "misc"
    , dependencies ? [ ]
    , # ADR 0009: this module owns access a webview cannot give it -- a socket, a
      # keystore, a radio -- so it has no `web` variant and a Downloaded module
      # reaches what it owns by CALLING it. Read off the module's own
      # metadata.json (`"platform": true`) by the caller, never decided here.
      #
      # It travels in the catalog INDEX rather than in the signed manifest,
      # because the consumer of the fact is a BUILD: nix/platform-floor.nix in
      # logos-basecamp derives a shell's floor from the index and its own
      # Bundled closure, at eval, before any cross toolchain runs. A manifest
      # field would have to be unpacked from an archive to be read, which is the
      # import-from-derivation this whole library is shaped to avoid.
      platform ? false
    , view ? null
    , icon ? null
    , variants
    , signingKey        # { jwk = <file>; name = "<key name>"; }
    }:
    assert lib.assertMsg (variants != { })
      "nix-bundle-lgx: catalog package '${name}' declares no variants";
    assert lib.assertMsg (type != "ui_qml" || view != null)
      "nix-bundle-lgx: catalog package '${name}' is ui_qml and must declare a `view`";
    assert lib.assertMsg (type != "ui_qml" || icon != null)
      "nix-bundle-lgx: catalog package '${name}' is ui_qml, and the icon contract (manifest 0.4.0+) makes a 256x256 PNG mandatory for it";
    let
      fields = pkgs.writeText "${name}-manifest-fields.json" (builtins.toJSON ({
        inherit name version type description author category dependencies;
      } // lib.optionalAttrs (view != null) { inherit view; }));

      addOne = variant: v: ''
        lgx add "$pkg" \
          -v ${lib.escapeShellArg variant} \
          -f ${v.payload} \
          -m ${lib.escapeShellArg v.main} \
          ${lib.optionalString (view != null) "--view ${lib.escapeShellArg view}"} \
          ${lib.optionalString (icon != null) "--icon ${icon}"} \
          -y
      '';
    in
    pkgs.runCommand "${name}-${version}-lgx"
      {
        nativeBuildInputs = [ lgx pkgs.python3 ];
        passthru.variants = lib.attrNames variants;
      } ''
      set -euo pipefail
      lgx create ${lib.escapeShellArg name}
      pkg="${name}.lgx"
      python3 ${patchManifest} "$pkg" ${fields}
      ${lib.concatStringsSep "\n" (lib.mapAttrsToList addOne variants)}

      # The key is copied out of the store because `lgx sign` reads
      # <keys-dir>/<name>.jwk and the store is read-only 0444 -- and because a
      # signing key in a keys-dir the builder owns is the shape a real signer
      # has, so this step is not special-cased.
      mkdir -p keys
      cp ${signingKey.jwk} "keys/${signingKey.name}.jwk"
      chmod 600 "keys/${signingKey.name}.jwk"
      lgx sign "$pkg" -k ${lib.escapeShellArg signingKey.name} -d keys \
        --name ${lib.escapeShellArg "Logos catalog (${signingKey.name})"}

      lgx verify "$pkg"
      mkdir -p $out
      cp "$pkg" $out/
    '';

  # A catalog: the .lgx files under packages/, an index.json beside them for
  # anything that reads the directory, and the same index as a Nix value for a
  # Bundled-set build, which must not have to build the catalog to evaluate
  # against it.
  mkCatalog =
    { release
    , signers
    , packages         # [ { spec = <mkPackage args>; drv = <mkPackage result>; } ]
    }:
    let
      entry = { spec, ... }: {
        inherit (spec) name version;
        type = spec.type or "core";
        # ADR 0009's Platform flag, verbatim. A consumer's floor is derived from
        # this and from its own Bundled closure, so an index that dropped it
        # would silently make every Platform module look like an ordinary one.
        platform = spec.platform or false;
        dependencies = spec.dependencies or [ ];
        variants = lib.mapAttrs (_: v: { inherit (v) main; } //
          lib.optionalAttrs (spec ? view && spec.view != null) { inherit (spec) view; })
          spec.variants;
        file = "packages/${spec.name}.lgx";
      };

      index = {
        catalogVersion = "1";
        inherit release signers;
        packages = map entry packages;
      };

      root = pkgs.runCommand "catalog-${release}" { } ''
        set -euo pipefail
        mkdir -p $out/packages
        ${lib.concatMapStringsSep "\n" ({ spec, drv }:
          ''cp ${drv}/${spec.name}.lgx $out/packages/'') packages}
        cp ${pkgs.writeText "index.json" (builtins.toJSON index)} $out/index.json
      '';
    in
    { inherit index root; };

  # A RELEASE: the catalog with every member's bytes pinned.
  #
  # mkCatalog's index says which packages exist and what they depend on. It
  # cannot say what they HASH TO -- a Merkle root and a sha256 exist only once
  # the archive does, which is after eval. So the numbers are computed here, in
  # a derivation, and written into an index.json that a consumer reads as
  # DATA: a checked-in pin, or a file fetched beside the packages.
  #
  # That is the whole difference between a catalog a build produced and a
  # release a build CONSUMES. With `file` entries a Bundled set trusts whatever
  # is at that path; with `url` + `sha256` + `rootHash` the fetch is a
  # fixed-output derivation that cannot resolve to different bytes, and the
  # admission path re-checks the Merkle root against the pin before anything is
  # unpacked. A mirror, a re-upload or a substituter cannot change what ships.
  #
  # `baseUrl` is where the packages will be reachable from -- a GitHub release
  # asset prefix, say. It is optional because the pins are useful on their own:
  # an index with `file` + `rootHash` still gets the root check, it just has no
  # fetch to make.
  mkRelease =
    { catalog
    , baseUrl ? null
    }:
    pkgs.runCommand "release-${catalog.index.release}"
      {
        nativeBuildInputs = [ lgx pkgs.python3 ];
        catalogRoot = "${catalog.root}";
        baseUrl = if baseUrl == null then "" else baseUrl;
      } ''
      set -euo pipefail
      mkdir -p $out/packages
      cp "$catalogRoot"/packages/*.lgx $out/packages/
      chmod -R u+w $out/packages

      # `lgx manifest --json` is the package's own answer for its Merkle root,
      # so the pin is read out of the archive rather than recomputed here by a
      # second implementation that could disagree with the one doing the
      # checking.
      for pkg in $out/packages/*.lgx; do
        lgx manifest "$pkg" --json > "$pkg.manifest.json"
      done

      python3 - <<'PY'
      import base64, hashlib, json, os

      out = os.environ["out"]
      base = os.environ["baseUrl"].rstrip("/")
      index = json.load(open(os.path.join(os.environ["catalogRoot"], "index.json")))

      for entry in index["packages"]:
          rel = entry["file"]
          path = os.path.join(out, rel)
          data = open(path, "rb").read()
          entry["sha256"] = "sha256-" + base64.b64encode(hashlib.sha256(data).digest()).decode()
          entry["rootHash"] = json.load(open(path + ".manifest.json"))["hashes"]["root"]
          if base:
              entry["url"] = base + "/" + os.path.basename(rel)
          print("pinned %s %s  root %s" % (entry["name"], entry["version"], entry["rootHash"][:16]))

      index["pinned"] = True
      json.dump(index, open(os.path.join(out, "index.json"), "w"), indent=2, sort_keys=True)
      PY

      rm -f $out/packages/*.manifest.json
    '';

in
{
  inherit variantForSystem systemForVariant embedDirFor
          mkVariantPayload mkPackage mkCatalog mkRelease;
}
