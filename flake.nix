{
  description = "Bundle Nix derivations into LGX packages (dev, portable, or dual-variant)";

  inputs = {
    logos-nix.url = "github:logos-co/logos-nix";
    nixpkgs.follows = "logos-nix/nixpkgs";
    logos-package.url = "github:logos-co/logos-package";
    nix-bundle-dir.url = "github:logos-co/nix-bundle-dir";
  };

  outputs = { self, nixpkgs, logos-nix, logos-package, nix-bundle-dir }:
    let
      # The BUILD platform for a given target. `lgx` and nix-bundle-dir are
      # tools that RUN during the build, so on a cross target they must come
      # from the build system -- taking them from `packages.x86_64-windows`
      # would hand the builder a PE it cannot execute. (Same host-tool /
      # target-artifact split as logos-cpp-sdk's generator.)
      buildSystemFor = target:
        if target == "x86_64-windows" then "x86_64-linux" else target;

      # `forAllTargets` (which adds the x86_64-windows pseudo-system) exists
      # only on logos-nix's cross-overlay branch. flake.nix declares the plain
      # `github:logos-co/logos-nix`, exactly like every other feat/windows-cross
      # repo -- the overlay is supplied by the WORKSPACE via follows, not pinned
      # here. So a bare `nix eval .#bundlers` on this branch resolved the
      # DEFAULT-branch logos-nix, which has no forAllTargets, and died with
      # "attribute 'forAllTargets' missing" before reaching anything real.
      #
      # That is not hypothetical: master's CI runs `tests/smoke.sh .` on a bare
      # checkout with no override, so the gate could never have gone green on
      # this branch. Degrade to forAllSystems instead of assuming the
      # capability -- same `f { system, pkgs }` contract, minus the Windows
      # target, which is the honest answer when the pinned logos-nix cannot
      # build it.
      forAllTargetsFn = logos-nix.lib.forAllTargets or logos-nix.lib.forAllSystems;
      forAllSystems = f: forAllTargetsFn ({ system, pkgs }:
        let buildSystem = buildSystemFor system; in f {
          inherit system pkgs;
          lgx = logos-package.packages.${buildSystem}.lgx;
          mkBundleDir = nix-bundle-dir.lib.${buildSystem}.mkBundle;
        });
    in
    {
      bundlers = forAllSystems ({ pkgs, lgx, mkBundleDir, ... }:
        let
          # Windows MUST be tested first. Under a mingw cross set `isDarwin` and
          # `isAarch64` are both false, so a Windows build used to fall through
          # the else-branch and label itself "linux-amd64" -- a Windows .lgx
          # claiming to be a Linux package. lgpm computes "windows-x86_64"
          # (package_manager_lib.cpp currentPlatformVariant) and has no alias
          # fallback for it, so that exact spelling is the contract.
          variantName =
            if pkgs.stdenv.hostPlatform.isWindows then
              (if pkgs.stdenv.hostPlatform.isAarch64 then "windows-arm64" else "windows-x86_64")
            else if pkgs.stdenv.isDarwin then
              (if pkgs.stdenv.isAarch64 then "darwin-arm64" else "darwin-amd64")
            else
              (if pkgs.stdenv.isAarch64 then "linux-arm64" else "linux-amd64");

          devVariantName = variantName + "-dev";

          # nix-bundle-dir's `guiApp` is deliberately not plumbed through.
          # It decides one thing only: whether bin/ entries are replaced by a
          # launcher that exports XKB_CONFIG_ROOT / QT_QPA_PLATFORMTHEME. An
          # .lgx payload is $SRC_DRV/lib plus extraDirs, so bin/ never enters
          # the package and the flag has no observable effect on our output.
          # It would be a knob callers could set and never see. Revisit only if
          # a consumer starts putting "bin" in extraDirs, in which case the
          # default (true) is already the safe direction.
          # On Windows the raw Nix output is ALREADY relocatable, so there is
          # nothing for nix-bundle-dir to do. A PE has no rpath and no
          # interpreter -- imports carry DLL base names only and Windows
          # searches the importing module's directory (given logos-module's
          # LOAD_WITH_ALTERED_SEARCH_PATH pre-load) -- so the path rewriting
          # that nix-bundle-dir exists for (patchelf --set-rpath,
          # install_name_tool) has no Windows analogue. logos-plugin-qt already
          # stages the plugin's transitive DLL closure into $out/lib via
          # linkDLLsInfolder, which is the whole job.
          #
          # Do NOT re-derive this bypass from bundle.sh's format dispatch. That
          # dispatch was once the reason and is no longer: nix-bundle-dir now
          # carries a full PE path (import-table sweep to a fixpoint, Qt
          # plugin/QML staging, qt.conf, machine checks), merged and pinned
          # below. So a reader who checks the dispatch WILL find a PE branch
          # there and conclude the bypass has expired. It has not.
          #
          # The reason that outlives that merge: the Windows payload is produced
          # by linkDLLsInfolder "$out/lib" in logos-plugin-qt and has never been
          # round-tripped through the directory bundler. Turning the bypass off
          # is a deliberate change needing its own end-to-end verification --
          # not a comment edit, and not a pin bump.
          #
          # When someone does try it, test THIS shape first: a Logos module
          # output is lib/<name>_plugin.dll and nothing else -- no bin/. The PE
          # path's Phase 2b Qt detection was blind to exactly that shape until
          # nix-bundle-dir 8bf12dd, because it globbed $out/bin/Qt6*.dll, which
          # cannot match when Qt is staged beside the importer in lib/. A Qt
          # module bundle exited 0 with the entire Windows Qt contract
          # unevaluated. The failure mode to expect here is a silent green, not
          # an error.
          # DLLs the Logos host already ships in its own bin/. Windows binds an import to a module
          # already loaded under that base name BEFORE searching any directory,
          # so a duplicate here would be inert rather than dangerous -- but
          # linkDLLsInfolder stages the FULL closure, and for capability_module
          # that is every one of these, ~36 MB (Qt6Core alone is 15 MB) of
          # host-provided runtime inside each module package. Dropping them is
          # the Windows spelling of the hostLibs list below, which exists for
          # exactly this reason. Note the Unix globs do NOT transfer: "libz*"
          # never matches "zlib1.dll".
          #
          # EVERY ENTRY HERE IS A PROMISE ABOUT ANOTHER REPO'S OUTPUT, and a
          # broken promise is silent: the module simply fails to load with
          # ERROR_MOD_NOT_FOUND (126) and Qt reports only "The specified module
          # could not be found", naming the PLUGIN rather than the missing
          # dependency. Four entries were wrong and one of them shipped:
          #
          #   libiconv-2.dll   libcharset-1.dll   libintl-8.dll   icui18n76.dll
          #
          # none of which the host bin/ contains -- checked against a real
          # portable Basecamp Windows bundle, and against logos_host_qt.exe's
          # own staged set, which the comment above once claimed as its
          # authority. libiconv-2.dll is reached as
          # package_downloader_plugin -> libpackage_downloader_lib -> libcurl-4
          # -> libidn2-0 -> libiconv-2, so it was staged correctly by
          # linkDLLsInfolder and then DELETED here.
          #
          # So: only strip something that is both LARGE and CERTAIN. When in
          # doubt, ship the duplicate -- Windows binds an import to a module
          # already loaded under that base name before searching any directory,
          # which makes a redundant copy inert, while a missing one is fatal and
          # silent. That asymmetry is the whole design rule for this list.
          windowsHostLibs = [
            # Certain: LogosBasecamp.exe / logos_host.exe import these directly,
            # so the host cannot start without them.
            "Qt*.dll"
            "libcrypto-*.dll" "libssl-*.dll"
            "libstdc++-*.dll" "libgcc_s_*.dll" "libmcfgthread-*.dll"
            "libpcre2-*.dll" "libb2-*.dll" "libdouble-conversion.dll"
            "libzstd.dll" "zlib1.dll"
            "libfmt.dll" "libspdlog.dll"
            "liblogos_core*.dll" "liblogos_sdk*.dll" "liblgx*.dll"
            # NOT stripped, deliberately:
            #   libiconv / libcharset / libintl -- absent from the host bin/.
            #   ICU -- the previous globs (libicuuc*, libicui18n*, libicudata*)
            #     never matched the real filenames (icuuc76.dll, icui18n76.dll,
            #     icudt76.dll: no `lib` prefix, and `icudt` not `icudata`), so
            #     ICU has always shipped in payloads. Do not "fix" those globs
            #     without splitting them: icuuc/icudt reach the host bin/ only
            #     as a transitive copy out of liblogos' lib/, and icui18n never
            #     does -- so a naive repair reintroduces exactly this bug.
            #     Costs ~30 MB per package; that is the price of certainty.
          ];

          # DLLs Windows itself provides. Matched case-insensitively with the
          # extension stripped, because import tables mix spellings freely
          # ("KERNEL32.dll" and "IPHLPAPI.DLL" both occur in this tree).
          # `api-ms-win-*` / `ext-ms-*` are matched by prefix in the shell.
          windowsSystemDlls = [
            "kernel32" "kernelbase" "ntdll" "user32" "gdi32" "gdiplus" "advapi32"
            "shell32" "shcore" "shlwapi" "ole32" "oleaut32" "oleacc" "comdlg32"
            "comctl32" "ws2_32" "wsock32" "mswsock" "crypt32" "bcrypt" "ncrypt"
            "secur32" "iphlpapi" "dbghelp" "version" "winmm" "imm32" "netapi32"
            "userenv" "dwmapi" "uxtheme" "d2d1" "d3d9" "d3d11" "d3d12" "dxgi"
            "dwrite" "opengl32" "glu32" "setupapi" "wtsapi32" "mpr" "rpcrt4"
            "msvcrt" "normaliz" "winspool" "odbc32" "authz" "dnsapi" "wldap32"
            "winhttp" "wininet" "psapi" "cfgmgr32" "uiautomationcore"
            "windowscodecs" "avicap32" "msimg32" "powrprof" "propsys" "usp10"
            "wintrust" "avrt"
            # Ships with Windows 8+ and is where ProcessPrng lives, which Rust's
            # `std` has used for its RNG since 1.78 -- so EVERY Rust module's
            # plugin imports it. Absent from this list it looked like a payload
            # that forgot a dependency, and blocked packaging chat_module.
            "bcryptprimitives"
          ];

          # A PE-capable objdump. NOT `pkgs.pkgsBuildBuild.binutils`: plain
          # nixpkgs binutils is built without the PE targets and prints NOTHING
          # for a valid mingw DLL, which is indistinguishable from "no imports"
          # and turns this entire gate into a vacuous pass. Measured on
          # libpackage_downloader_lib.dll: the cross objdump reports 13 imports,
          # the native one reports 0.
          peObjdump = "${pkgs.stdenv.cc.bintools.bintools}/bin/${pkgs.stdenv.cc.targetPrefix}objdump";

          # Windows payload: the raw output minus host-provided DLLs. Copies the
          # WHOLE tree, not just lib/, because bundle.sh reads extraDirs out of
          # SRC_DRV too. Uses pkgsBuildBuild so this file-shuffling runs on the
          # builder rather than becoming a cross derivation.
          mkWindowsPayload = drv:
            pkgs.pkgsBuildBuild.runCommand "${drv.pname or drv.name or "bundle"}-win-payload" { } ''
              mkdir -p $out
              cp -rL ${drv}/. $out/ 2>/dev/null || true
              chmod -R u+w $out
              if [ -d "$out/lib" ]; then
                for pat in ${nixpkgs.lib.escapeShellArgs windowsHostLibs}; do
                  for f in $out/lib/$pat; do
                    [ -e "$f" ] || continue
                    echo "host-provided, dropping from payload: $(basename "$f")"
                    rm -f "$f"
                  done
                done
              fi

              # ---------------------------------------------------------------
              # Prove the payload is import-complete, to a FIXPOINT.
              #
              # Upstream staging is nixpkgs' win-dll-link.sh, whose worker
              # `linkDLLsInfolder` does iterate imports to a fixpoint -- but it
              # resolves each name against LINK_DLL_FOLDERS, which an env hook
              # fills from ONE level of buildInputs, and when a name is not on
              # that path it gives up without a word:
              #
              #     readarray -d "" pathsFound < <(find "''${searchPaths[@]}" ...)
              #     if [ ''${#pathsFound[@]} -eq 0 ]; then continue; fi
              #
              # So a payload can ship one level short and nothing says so. The
              # symptom appears much later and somewhere else: LoadLibrary fails
              # with ERROR_MOD_NOT_FOUND (126) naming the PLUGIN, never the DLL
              # that is absent, and Qt reports only "The specified module could
              # not be found".
              #
              # A name that is missing from the payload is only acceptable if it
              # is a Windows system DLL, or if windowsHostLibs above CLAIMS the
              # host ships it. That claim cannot be checked from here -- only an
              # assembled application tree has both halves -- so it is echoed at
              # the end to keep it visible rather than implicit.
              _objdump=${nixpkgs.lib.escapeShellArg peObjdump}
              if [ ! -x "$_objdump" ]; then
                echo "ERROR: no PE-capable objdump at $_objdump" >&2
                exit 1
              fi

              _sysdlls=${nixpkgs.lib.escapeShellArg (nixpkgs.lib.concatStringsSep " " windowsSystemDlls)}
              _is_system_dll() {
                local _b="''${1,,}" _s
                _b="''${_b%.dll}"; _b="''${_b%.drv}"; _b="''${_b%.exe}"
                case "$_b" in api-ms-win-*|ext-ms-*) return 0 ;; esac
                for _s in $_sysdlls; do [ "$_b" = "$_s" ] && return 0; done
                return 1
              }
              _is_host_claimed() {
                local _p
                shopt -s nocasematch
                for _p in ${nixpkgs.lib.escapeShellArgs windowsHostLibs}; do
                  if [[ "$1" == $_p ]]; then shopt -u nocasematch; return 0; fi
                done
                shopt -u nocasematch
                return 1
              }

              # Index what the payload actually contains. lgpm flattens the
              # payload into modules/<name>/, so every file in it ends up beside
              # the plugin: index by base name, ignoring directory.
              declare -A _have _seen _hostdeps _missing
              _roots=()
              while IFS= read -r _f; do
                _b="$(basename "$_f")"
                _have["''${_b,,}"]="$_f"
                case "''${_b,,}" in *.dll|*.exe) _roots+=("$_b") ;; esac
              done < <(find "$out" -type f 2>/dev/null)

              # An empty root set is NOT "nothing to verify" -- it is the loudest
              # possible symptom of the strip loop above having eaten the
              # payload, and reporting success on it reproduces exactly the class
              # of bug this whole block exists to catch. Demonstrated: adding an
              # over-broad "*.dll" to windowsHostLibs logged
              # `host-provided, dropping from payload: main_ui.dll`, left the
              # payload with no PE at all, printed this line, and the derivation
              # SUCCEEDED. Compare against the SOURCE: zero PEs in is a package
              # that legitimately ships none (a QML-only ui_qml module, which is
              # a real and supported shape); zero out after non-zero in is the
              # strip list being wrong.
              _src_pes=$(find -L ${drv} -type f \( -iname '*.dll' -o -iname '*.exe' \) 2>/dev/null | wc -l)
              if [ ''${#_roots[@]} -eq 0 ] && [ "$_src_pes" -gt 0 ]; then
                echo "ERROR: the source derivation has $_src_pes PE file(s) but the payload has none." >&2
                echo "The windowsHostLibs strip loop removed every binary in this package." >&2
                echo "Contents of the payload:" >&2
                find "$out" -type f >&2 || true
                exit 1
              fi

              if [ ''${#_roots[@]} -eq 0 ]; then
                echo "payload contains no PE file (source ships none either); nothing to verify"
              else
                _queue=("''${_roots[@]}")
                declare -A _from
                for _r in "''${_roots[@]}"; do _from["''${_r,,}"]="(payload root)"; done
                _imports_read=0
                while [ ''${#_queue[@]} -gt 0 ]; do
                  _n="''${_queue[0]}"; _queue=("''${_queue[@]:1}")
                  _k="''${_n,,}"
                  [ -n "''${_seen[$_k]:-}" ] && continue
                  _seen[$_k]=1
                  _is_system_dll "$_n" && continue
                  _p="''${_have[$_k]:-}"
                  if [ -z "$_p" ]; then
                    if _is_host_claimed "$_n"; then
                      _hostdeps[$_n]=1
                    else
                      _missing[$_n]="''${_from[$_k]:-?}"
                    fi
                    continue
                  fi
                  while IFS= read -r _d; do
                    [ -n "$_d" ] || continue
                    _imports_read=$((_imports_read + 1))
                    [ -n "''${_from[''${_d,,}]:-}" ] || _from["''${_d,,}"]="$(basename "$_p")"
                    _queue+=("$_d")
                  done < <("$_objdump" -p "$_p" 2>/dev/null | sed -n 's/.*DLL Name: *//p' | tr -d '\r')
                done

                # Zero imports across a payload that HAS PE files means the
                # reader failed, not that the payload is dependency-free. That
                # is the one result that must never be read as a pass.
                if [ "$_imports_read" -eq 0 ]; then
                  echo "ERROR: read 0 imports from ''${#_roots[@]} PE file(s) --" >&2
                  echo "$_objdump has no PE target. This is a measurement failure." >&2
                  exit 1
                fi

                if [ -n "''${_missing[*]+x}" ]; then
                  echo "" >&2
                  echo "ERROR: the .lgx payload is missing ''${#_missing[@]} DLL(s) that it imports:" >&2
                  for _n in "''${!_missing[@]}"; do
                    echo "  $_n   (first reached from ''${_missing[$_n]})" >&2
                  done
                  echo "" >&2
                  echo "These are neither Windows system DLLs nor claimed by the" >&2
                  echo "windowsHostLibs list above, so nothing will provide them at" >&2
                  echo "runtime. The usual cause is that the producing derivation's" >&2
                  echo "linkDLLsInfolder call could not see the providing store path:" >&2
                  echo "extend LINK_DLL_FOLDERS with the external libraries' closure" >&2
                  echo "(see logos-plugin-qt lib/buildPlugin.nix) rather than relying" >&2
                  echo "on direct buildInputs." >&2
                  exit 1
                fi

                echo "payload import closure verified over ''${#_roots[@]} PE file(s)," \
                     "$_imports_read import entries, ''${#_seen[@]} distinct name(s)"
                if [ -n "''${_hostdeps[*]+x}" ]; then
                  echo "payload relies on the host for: ''${!_hostdeps[*]}"
                fi
              fi
            '';

          mkBundleDirForDrv =
            if pkgs.stdenv.hostPlatform.isWindows then mkWindowsPayload
            else drv: mkBundleDir {
            inherit drv;
            name = drv.pname or drv.name or "bundle";
            extraDirs = drv.extraDirs or [];
            hostLibs = (drv.hostLibs or []) ++ [
              "Qt*"
              "libQt*"
              "liblogos_core*"
              "liblogos_sdk*"
              "libcharset*"
              "libiconv*"
              "libintl*"
              "liblgx*"
              "libz*"
              "libicuuc*"
              "libicui18n*"
              "libicudata*"
            ];
            warnOnBinaryData = true;
          };

          # mode: "dev" (raw nix output, -dev variant), "portable" (bundle-dir, no suffix), "dual" (both)
          mkLgxBundle = { mode ? "dev" }: drv:
            let
              srcDrv =
                if mode == "dev"
                then drv
                else mkBundleDirForDrv drv;

              name = drv.pname or drv.name or "bundle";

              # Read metadata.json from the derivation's source at eval time.
              # drv.src is a store path for the module source (set via `src = ./.` in
              # the module flake), so metadata.json is reachable without a build step.
              metadataJson =
                let
                  result = builtins.tryEval (
                    if drv ? src && builtins.pathExists (drv.src + "/metadata.json")
                    then builtins.readFile (drv.src + "/metadata.json")
                    else "{}"
                  );
                in if result.success then result.value else "{}";

              metadataFile = pkgs.writeText "${name}-metadata.json" metadataJson;

              # Source directory of the module (for resolving icon paths etc.)
              moduleSrc =
                if drv ? src then "${drv.src}" else null;
            in
            pkgs.stdenv.mkDerivation ({
              pname = "${name}-lgx";
              version = drv.version or "0";

              src = null;
              dontUnpack = true;
              dontFixup = true;

              nativeBuildInputs = [ lgx pkgs.python3 ];

              SRC_DRV = "${srcDrv}";
              VARIANT = if mode == "dev" then devVariantName else variantName;
              PACKAGE_NAME = name;
              METADATA_FILE = "${metadataFile}";
              LIB_EXT =
                if pkgs.stdenv.hostPlatform.isWindows then ".dll"
                else if pkgs.stdenv.isDarwin then ".dylib"
                else ".so";
              MODULE_SRC = if moduleSrc != null then moduleSrc else "";
              EXTRA_DIRS = builtins.concatStringsSep "\n" (drv.extraDirs or []);

              buildPhase = ''
                bash ${./bundle.sh}
              '';

              installPhase = ''
                mkdir -p $out
                cp *.lgx $out/
              '';
            } // (if mode == "dual" then {
              # For dual mode, also pass the raw (dev) derivation so bundle.sh
              # can add it as a second variant.
              DEV_SRC_DRV = "${drv}";
              DEV_VARIANT = devVariantName;
              DUAL_VARIANT = "1";
            } else {}));
        in
        {
          # Bundle the lib output as-is with a -dev variant name.
          # Dynamic libraries resolve from /nix/store at runtime.
          default = mkLgxBundle { mode = "dev"; };

          # Apply nix-bundle-dir first to produce a self-contained directory,
          # then wrap it into an lgx package with the portable variant name.
          portable = mkLgxBundle { mode = "portable"; };

          # Produce a dual-variant package containing both portable and dev variants.
          dual = mkLgxBundle { mode = "dual"; };
        });

      # Publishing a MOBILE variant is a library call, not a bundler.
      #
      # A nix bundler is `drv -> drv` and takes no arguments, so it cannot be
      # told which of three cross targets a derivation was built for -- and
      # `pkgs.stdenv.hostPlatform` under an iOS cross set answers "darwin",
      # which is the desktop variant name and the wrong one. The caller is the
      # only thing that knows it just built
      # `packages.aarch64-ios-simulator.bare`, so the caller names the target.
      #
      # Keyed by the system the PUBLISHER runs on. Everything in here moves and
      # hashes bytes that are already cross-compiled; nothing in it is built
      # for the phone.
      lib = forAllSystems (args@{ pkgs, ... }:
        let
          repoLgx = args.lgx;
          # For a cross target (x86_64-windows) `pkgs` is the target set, and
          # the publisher's tools have to run on the builder either way.
          buildPkgs = pkgs.pkgsBuildBuild;
        in
        rec {
          # `lgx` is an argument because a consumer that also ships lgx in its
          # own closure must publish with THAT one: the manifest version and
          # the Merkle layout are the tool's, and a package written by one lgx
          # and admitted by another is two implementations agreeing by luck.
          mkMobileCatalog = { lgx ? repoLgx }:
            import ./lib/mobile-catalog.nix { pkgs = buildPkgs; inherit lgx; };

          mobileCatalog = mkMobileCatalog { };
        });

      # Not `forAllSystems`: that adds the x86_64-windows pseudo-system, whose
      # entry would be a build-platform derivation wearing a Windows key --
      # `nix flake check` would build the same thing twice and call one of them
      # a Windows check.
      checks = logos-nix.lib.forAllSystems ({ system, pkgs }: {
        mobile-catalog = import ./tests/mobile-catalog.nix {
          inherit pkgs;
          lgx = logos-package.packages.${system}.lgx;
          mobileCatalog = self.lib.${system}.mobileCatalog;
          testKey = {
            name = "nix-bundle-lgx-test";
            jwk = ./tests/keys/nix-bundle-lgx-test.jwk;
            did = nixpkgs.lib.fileContents ./tests/keys/nix-bundle-lgx-test.did;
          };
        };
      });
    };
}
