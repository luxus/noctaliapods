# NixOS module for MagicPods using hjem (github:feel-co/hjem) to place the
# plugin files declaratively, plus a systemd user service for the daemon.
#
# Usage (flake), assuming hjem's NixOS module is already imported:
#   imports = [ inputs.magicpods.nixosModules.magicpods-hjem ];
#   services.magicpods.enable = true;
#   services.magicpods.user   = "alice";
#
# hjem manages files under $HOME; this module writes the plugin to
# ~/.local/share/noctalia/plugins/magicpods for the given user. The daemon runs
# as a systemd user service and python3 is added system-wide for bridge.py.
self:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.magicpods;
  pluginSrc = self.outPath + "/magicpods";
  defaultPackage = self.packages.${pkgs.stdenv.hostPlatform.system}.magicpodscore or null;
in
{
  options.services.magicpods = {
    enable = lib.mkEnableOption "MagicPods (MagicPodsCore daemon + Noctalia plugin) via hjem";

    user = lib.mkOption {
      type = lib.types.str;
      description = "The hjem user to install the Noctalia plugin for.";
    };

    package = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      default = defaultPackage;
      defaultText = lib.literalExpression "magicpods.packages.\${system}.magicpodscore";
      description = "MagicPodsCore daemon package.";
    };

    python = lib.mkOption {
      type = lib.types.package;
      default = pkgs.python3;
      defaultText = lib.literalExpression "pkgs.python3";
      description = "Python 3 interpreter used by the plugin's WebSocket bridge.";
    };

    enableBluetooth = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable hardware.bluetooth (the daemon needs BlueZ).";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.package != null;
        message = "services.magicpods.package must be set (no daemon package for this system).";
      }
    ];

    # Place the plugin read-only via hjem.
    hjem.users.${cfg.user}.files.".local/share/noctalia/plugins/magicpods".source = pluginSrc;

    # python3 (for bridge.py) and the daemon binary available in the session.
    environment.systemPackages = [ cfg.python ] ++ lib.optional (cfg.package != null) cfg.package;

    hardware.bluetooth.enable = lib.mkIf cfg.enableBluetooth (lib.mkDefault true);

    systemd.user.services.magicpodscore = {
      description = "MagicPodsCore daemon (AirPods / Beats / Galaxy Buds)";
      documentation = [ "https://github.com/steam3d/MagicPodsCore" ];
      after = [ "bluetooth.target" ];
      wants = [ "bluetooth.target" ];
      wantedBy = [ "default.target" ];
      serviceConfig = {
        ExecStart = "${cfg.package}/bin/magicpodscore";
        Restart = "on-failure";
        RestartSec = 5;
      };
    };
  };
}
