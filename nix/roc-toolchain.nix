{ pkgs, upstream }:

# Use the pinned official Roc source with a narrow ELF constant-data fix.
# Remove the patch when the unchanged native platform fixture passes upstream.
# Zig 0.16's InternPool can overflow
# while interning Roc's embedded builtin arrays on many-core build hosts.
# A graph-level `zig build -j8` does not constrain the compiler's CPU count.
upstream.overrideAttrs (old: {
  patches = (old.patches or [ ]) ++ [ ./roc-elf-relro.patch ];
  nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ pkgs.util-linux pkgs.gawk ];
  preBuild = (old.preBuild or "") + ''
    roc_allowed_cpus="$(${pkgs.util-linux}/bin/taskset -pc "$$")"
    roc_allowed_cpus="''${roc_allowed_cpus##*: }"
    roc_build_cpus="$(${pkgs.gawk}/bin/awk -v allowed="$roc_allowed_cpus" '
      BEGIN {
        ranges = split(allowed, pieces, ","); count = 0; result = "";
        for (part = 1; part <= ranges && count < 32; part++) {
          endpoints = split(pieces[part], bound, "-");
          first = bound[1] + 0; last = endpoints == 1 ? first : bound[2] + 0;
          for (cpu = first; cpu <= last && count < 32; cpu++) {
            result = result (count ? "," : "") cpu; count++;
          }
        }
        if (!count) exit 1;
        print result;
      }
    ')"
    ${pkgs.util-linux}/bin/taskset -pc "$roc_build_cpus" "$$"
  '';
})
