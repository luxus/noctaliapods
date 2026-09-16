{
  description = "MagicPodsCore daemon + MagicPods Noctalia v5 plugin";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      packages = forAllSystems (pkgs: rec {
        # The MagicPodsCore daemon.
        magicpodscore = pkgs.callPackage ./nix/package.nix { };

        # The Noctalia plugin as a plain file tree (drop it into a plugins dir or
        # point a local plugin source at its parent).
        magicpods-plugin = pkgs.runCommandLocal "magicpods-noctalia-plugin" { } ''
          mkdir -p "$out"
          cp -r ${./magicpods}/. "$out/"
        '';

        default = magicpodscore;
      });

      # Home Manager module: places the plugin, ensures python3 + the daemon are
      # available, and runs magicpodscore as a systemd user service.
      homeManagerModules.magicpods = import ./nix/hm-module.nix self;
      homeManagerModules.default = self.homeManagerModules.magicpods;

      # NixOS module for hjem users: places the plugin via hjem and runs the
      # daemon as a systemd user service.
      nixosModules.magicpods-hjem = import ./nix/hjem-module.nix self;

      formatter = forAllSystems (pkgs: pkgs.nixfmt-rfc-style);
    };
}
