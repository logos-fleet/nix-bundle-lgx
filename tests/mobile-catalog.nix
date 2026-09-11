# The mobile publisher, over FIXTURE artifacts.
#
# What is under test is publishing: restage a cross-built module image as an
# LGX variant payload, sign it, index it, pin it. None of those steps can tell
# a real iOS framework binary from a text file -- they move bytes and hash
# them -- so the fixtures are text files in the LAYOUT logos-module-builder
# produces, and this runs anywhere in seconds.
#
# What a real cross-compiled module adds is the layout itself, and that is
# asserted here too: the payload has to come out as Frameworks/<stem>.framework
# on iOS and lib/lib<stem>.so on Android, because those are the only places the
# respective platform loader will look inside an app image.
{ pkgs, lgx, mobileCatalog, testKey }:

let
  inherit (pkgs) lib;

  signingKey = { inherit (testKey) name jwk; };

  # A logos-module-builder `bare`/`view` output, as this repo receives it:
  # an embedded framework under Library/Frameworks/ for iOS, a shared object
  # under lib/ for Android.
  iosArtifact = stem: pkgs.runCommand "${stem}-ios-artifact" { } ''
    mkdir -p $out/Library/Frameworks/${stem}.framework
    printf 'fixture image for %s\n' ${stem} > $out/Library/Frameworks/${stem}.framework/${stem}
    printf '<plist><dict><key>CFBundleExecutable</key><string>%s</string></dict></plist>\n' \
      ${stem} > $out/Library/Frameworks/${stem}.framework/Info.plist
  '';

  androidArtifact = stem: pkgs.runCommand "${stem}-android-artifact" { } ''
    mkdir -p $out/lib
    printf 'fixture image for %s\n' ${stem} > $out/lib/lib${stem}.so
  '';

  # The LGX icon contract (manifest 0.4.0+) makes a 256x256 PNG mandatory for a
  # ui_qml package and `lgx sign` enforces it, so a test that publishes a view
  # module needs artwork. Generated rather than committed: a binary blob in a
  # test directory is a thing nobody can diff.
  icon = pkgs.runCommand "fixture-icon.png" { nativeBuildInputs = [ pkgs.python3 ]; } ''
    python3 - "$out" <<'PY'
    import struct, sys, zlib

    W = H = 256
    raw = b"".join(b"\x00" + bytes([40, 40, 48]) * W for _ in range(H))

    def chunk(tag, data):
        body = tag + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body))

    png = (b"\x89PNG\r\n\x1a\n"
           + chunk(b"IHDR", struct.pack(">IIBBBBB", W, H, 8, 2, 0, 0, 0))
           + chunk(b"IDAT", zlib.compress(raw, 9))
           + chunk(b"IEND", b""))
    open(sys.argv[1], "wb").write(png)
    PY
  '';

  qmlEntry = pkgs.writeText "Main.qml" ''
    import QtQuick
    Item { }
  '';

  barePayload = mobileCatalog.mkVariantPayload {
    drv = iosArtifact "fixture_core_bare";
    stem = "fixture_core_bare";
    target = "ios-sim-arm64";
  };

  androidPayload = mobileCatalog.mkVariantPayload {
    drv = androidArtifact "fixture_core_bare";
    stem = "fixture_core_bare";
    target = "android-arm64";
  };

  viewPayload = mobileCatalog.mkVariantPayload {
    drv = iosArtifact "fixture_ui_view";
    stem = "fixture_ui_view";
    target = "ios-sim-arm64";
    extraFiles."qml/Main.qml" = qmlEntry;
  };

  specs = {
    fixture_core = {
      name = "fixture_core";
      version = "1.2.3";
      type = "core";
      category = "testing";
      description = "A core module published for two mobile targets";
      dependencies = [ ];
      variants = {
        ios-sim-arm64 = barePayload;
        android-arm64 = androidPayload;
      };
      inherit signingKey;
    };
    fixture_ui = {
      name = "fixture_ui";
      version = "0.9.0";
      type = "ui_qml";
      category = "misc";
      description = "A view module that depends on the core one";
      view = "qml/Main.qml";
      inherit icon;
      dependencies = [ "fixture_core" ];
      variants.ios-sim-arm64 = viewPayload;
      inherit signingKey;
    };
  };

  drvs = lib.mapAttrs (_: mobileCatalog.mkPackage) specs;

  catalog = mobileCatalog.mkCatalog {
    release = "fixture";
    signers = [ testKey.did ];
    packages = lib.mapAttrsToList (n: spec: { inherit spec; drv = drvs.${n}; }) specs;
  };

  release = mobileCatalog.mkRelease {
    inherit catalog;
    baseUrl = "https://example.invalid/releases/download/fixture";
  };

  # ── eval-time assertions ───────────────────────────────────────────────────
  # The payload layout is decided at eval -- `main` is what the catalog index
  # publishes and what a Bundled set looks for after extraction -- so a wrong
  # one has to be caught here, not by a missing file three derivations later.
  wantMain = {
    "ios-sim-arm64 bare" = { got = barePayload.main; want = "Frameworks/fixture_core_bare.framework/fixture_core_bare"; };
    "ios-sim-arm64 view" = { got = viewPayload.main; want = "Frameworks/fixture_ui_view.framework/fixture_ui_view"; };
    "android-arm64 bare" = { got = androidPayload.main; want = "lib/libfixture_core_bare.so"; };
  };

  mainOk = lib.all (what:
    let e = wantMain.${what}; in
    if e.got == e.want then true
    else throw "FAIL: ${what} payload main is '${e.got}', expected '${e.want}'")
    (lib.attrNames wantMain);

  # Spelled out rather than re-derived: an expectation computed the same way
  # the implementation computes it agrees with any implementation, including a
  # broken one.
  wantEmbedDir = {
    ios-arm64 = "Frameworks";
    ios-sim-arm64 = "Frameworks";
    android-arm64 = "lib";
  };

  embedDirOk = lib.all (t:
    let want = wantEmbedDir.${t};
        got = mobileCatalog.embedDirFor t; in
    if got == want then true
    else throw "FAIL: embedDirFor ${t} is '${got}', expected '${want}'")
    (lib.attrNames wantEmbedDir);

  variantMapOk =
    let want = { aarch64-ios = "ios-arm64"; aarch64-ios-simulator = "ios-sim-arm64"; aarch64-android = "android-arm64"; };
    in if mobileCatalog.variantForSystem == want then true
       else throw "FAIL: variantForSystem is ${builtins.toJSON mobileCatalog.variantForSystem}";

  evalFails = what: expr:
    let attempt = builtins.tryEval (builtins.deepSeq expr "forced"); in
    if attempt.success then throw "FAIL: ${what} must not evaluate" else true;

  # A ui_qml package whose view or icon is missing is refused by `lgx sign`,
  # deep inside a build. Refusing it at eval is the difference between a
  # message naming the package and a signer error naming a temp directory.
  viewlessRefused = evalFails "a ui_qml package with no `view`"
    (mobileCatalog.mkPackage (builtins.removeAttrs specs.fixture_ui [ "view" ]));

  iconlessRefused = evalFails "a ui_qml package with no `icon`"
    (mobileCatalog.mkPackage (builtins.removeAttrs specs.fixture_ui [ "icon" ]));

  variantlessRefused = evalFails "a package with no variants at all"
    (mobileCatalog.mkPackage (specs.fixture_core // { variants = { }; }));

in
assert mainOk;
assert embedDirOk;
assert variantMapOk;
assert viewlessRefused;
assert iconlessRefused;
assert variantlessRefused;
pkgs.runCommand "mobile-catalog-tests"
  {
    nativeBuildInputs = [ lgx pkgs.python3 ];
    catalogRoot = "${catalog.root}";
    releaseRoot = "${release}";
    signer = testKey.did;
    barePayloadDir = "${barePayload.payload}";
    androidPayloadDir = "${androidPayload.payload}";
    viewPayloadDir = "${viewPayload.payload}";
  } ''
  set -euo pipefail
  fail() { echo "FAIL: $*" >&2; exit 1; }

  # ── the payload is the target's layout, and nothing else ─────────────────
  test -f "$barePayloadDir/Frameworks/fixture_core_bare.framework/fixture_core_bare" \
    || fail "the iOS payload has no framework binary"
  test -f "$barePayloadDir/Frameworks/fixture_core_bare.framework/Info.plist" \
    || fail "the iOS payload dropped the framework's Info.plist"
  test ! -d "$barePayloadDir/Library" \
    || fail "the iOS payload still carries the builder's Library/ prefix"
  test -f "$androidPayloadDir/lib/libfixture_core_bare.so" \
    || fail "the Android payload has no shared object"
  test -f "$viewPayloadDir/qml/Main.qml" \
    || fail "extraFiles did not reach the view payload"

  # ── each package verifies, and says what it was published as ─────────────
  for p in fixture_core fixture_ui; do
    lgx verify "$catalogRoot/packages/$p.lgx" || fail "$p does not verify"
  done

  lgx manifest "$catalogRoot/packages/fixture_core.lgx" --json > core.json
  lgx manifest "$catalogRoot/packages/fixture_ui.lgx" --json > ui.json
  lgx signature "$catalogRoot/packages/fixture_core.lgx" > core.sig

  python3 - <<'PY'
  import json, os

  core = json.load(open("core.json"))
  ui = json.load(open("ui.json"))
  sig = json.load(open("core.sig"))

  assert core["name"] == "fixture_core" and core["version"] == "1.2.3", core
  assert core.get("type", "core") == "core", core
  assert sorted(core["main"]) == ["android-arm64", "ios-sim-arm64"], core["main"]
  assert core["main"]["ios-sim-arm64"] == \
      "Frameworks/fixture_core_bare.framework/fixture_core_bare", core["main"]
  assert core["main"]["android-arm64"] == "lib/libfixture_core_bare.so", core["main"]
  assert sig["did"] == os.environ["signer"], sig
  assert len(core["hashes"]["root"]) == 64, core["hashes"]

  assert ui["type"] == "ui_qml", ui
  assert ui["view"] == "qml/Main.qml", ui
  deps = [d if isinstance(d, str) else d["name"] for d in ui.get("dependencies", [])]
  assert deps == ["fixture_core"], deps
  print("published: fixture_core %s, fixture_ui %s" % (core["version"], ui["version"]))
  PY

  # ── extraction gives back exactly the payload ────────────────────────────
  # This is the round trip a Bundled-set build makes: what went in as a variant
  # comes out laid out for the loader, with no package structure around it.
  lgx extract "$catalogRoot/packages/fixture_core.lgx" -v ios-sim-arm64 -o extracted
  test -f extracted/ios-sim-arm64/Frameworks/fixture_core_bare.framework/fixture_core_bare \
    || fail "the extracted ios-sim-arm64 variant is not laid out for the loader"
  lgx extract "$catalogRoot/packages/fixture_core.lgx" -v android-arm64 -o extracted-android
  test -f extracted-android/android-arm64/lib/libfixture_core_bare.so \
    || fail "the extracted android-arm64 variant is not laid out for the loader"

  # ── the catalog index ────────────────────────────────────────────────────
  python3 - <<'PY'
  import json, os

  root = os.environ["catalogRoot"]
  index = json.load(open(os.path.join(root, "index.json")))
  assert index["catalogVersion"] == "1", index
  assert index["signers"] == [os.environ["signer"]], index
  by = {p["name"]: p for p in index["packages"]}
  assert sorted(by) == ["fixture_core", "fixture_ui"], sorted(by)
  assert sorted(by["fixture_core"]["variants"]) == ["android-arm64", "ios-sim-arm64"]
  assert by["fixture_ui"]["variants"]["ios-sim-arm64"]["view"] == "qml/Main.qml"
  assert by["fixture_ui"]["dependencies"] == ["fixture_core"]
  for p in index["packages"]:
      assert os.path.exists(os.path.join(root, p["file"])), p
      # An unpublished catalog pins nothing: the bytes are wherever `file`
      # says, and a consumer trusts the path.
      assert "sha256" not in p and "rootHash" not in p, p
  print("catalog index: %s" % ", ".join(sorted(by)))
  PY

  # ── the release index pins the bytes ─────────────────────────────────────
  # The numbers here are the whole reason mkRelease exists: a consumer that
  # fetches rather than reads a directory has nothing else to check against.
  python3 - <<'PY'
  import base64, hashlib, json, os, subprocess

  root = os.environ["releaseRoot"]
  index = json.load(open(os.path.join(root, "index.json")))
  assert index["pinned"] is True, index
  for p in index["packages"]:
      path = os.path.join(root, p["file"])
      data = open(path, "rb").read()
      want = "sha256-" + base64.b64encode(hashlib.sha256(data).digest()).decode()
      assert p["sha256"] == want, (p["name"], p["sha256"], want)
      manifest = json.loads(subprocess.check_output(["lgx", "manifest", path, "--json"]))
      assert p["rootHash"] == manifest["hashes"]["root"], (p["name"], p["rootHash"])
      assert p["url"] == \
          "https://example.invalid/releases/download/fixture/" + p["name"] + ".lgx", p
      # The release carries the SAME resolution data as the catalog it came
      # from -- a pin is an addition, not a re-derivation.
      assert p["variants"], p
  print("release: %d package(s) pinned by sha256 and Merkle root" % len(index["packages"]))
  PY

  mkdir -p $out
  cp "$releaseRoot/index.json" $out/release-index.json
  echo "PASS"
''
