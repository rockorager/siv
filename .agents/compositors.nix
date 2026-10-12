# Compositors for `zig build test-compositor` (src/platform/compositors.zig),
# from a pinned nixpkgs so that every orb runs the same releases. Only cached
# derivations are used (no overrides), so setup downloads instead of builds.
#
# To update: pick a nixos-unstable commit, then
#   nix-prefetch-url --unpack https://github.com/NixOS/nixpkgs/archive/<rev>.tar.gz
let
  rev = "6510408d147d8c5e6d76043e899e9251756f6a75"; # nixos-unstable, 2026-10-10
  pkgs = import (fetchTarball {
    url = "https://github.com/NixOS/nixpkgs/archive/${rev}.tar.gz";
    sha256 = "012w2z2w4k0c3kg9hcy9cpd7qgxgrpxvf0735vy014r7x9qhmbjw";
  }) { config = { }; overlays = [ ]; };
in
pkgs.buildEnv {
  name = "siv-test-compositors";
  paths = [
    pkgs.sway-unwrapped # sway 1.12, wlroots 0.20
    pkgs.wtype # virtual keyboard input for sway
  ];
}
