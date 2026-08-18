# Home Manager module for MagicPods.
#
# Usage (flake):
#   imports = [ inputs.magicpods.homeManagerModules.default ];
#   services.magicpods.enable = true;
#
# It places the plugin into ~/.local/share/noctalia/plugins/magicpods, ensures
# python3 (needed by the plugin's WebSocket bridge) and the daemon are on PATH,
# and runs magicpodscore as a systemd user service.
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
    enable = lib.mkEnableOption "MagicPods (MagicPodsCore daemon + Noctalia plugin)";

    package = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      default = defaultPackage;
      defaultText = lib.literalExpression "magicpods.packages.\${system}.magicpodscore";
      description = "MagicPodsCore daemon package. Set to null to manage the daemon yourself.";
    };

    python = lib.mkOption {
      type = lib.types.package;
      default = pkgs.python3;
      defaultText = lib.literalExpression "pkgs.python3";
      description = "Python 3 interpreter used by the plugin's WebSocket bridge (bridge.py).";
    };

    installPlugin = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Link the plugin into ~/.local/share/noctalia/plugins/magicpods.";
    };

    startService = lib.mkOption {
      type = lib.types.bool;
      default = cfg.package != null;
      defaultText = lib.literalExpression "config.services.magicpods.package != null";
      description = "Run the MagicPodsCore daemon as a systemd user service.";
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      # python3 must be on the Noctalia session PATH so bridge.py runs; the
      # daemon is added too so `magicpodscore` is available for manual use.
      home.packages = [ cfg.python ] ++ lib.optional (cfg.package != null) cfg.package;
    }

    (lib.mkIf cfg.installPlugin {
      home.file.".local/share/noctalia/plugins/magicpods".source = pluginSrc;
    })

    (lib.mkIf cfg.startService {
      assertions = [
        {
          assertion = cfg.package != null;
          message = "services.magicpods.startService requires services.magicpods.package to be set.";
        }
      ];
      systemd.user.services.magicpodscore = {
        Unit = {
          Description = "MagicPodsCore daemon (AirPods / Beats / Galaxy Buds)";
          Documentation = "https://github.com/steam3d/MagicPodsCore";
          After = [ "bluetooth.target" ];
          Wants = [ "bluetooth.target" ];
        };
        Service = {
          ExecStart = "${cfg.package}/bin/magicpodscore";
          Restart = "on-failure";
          RestartSec = 5;
        };
        Install.WantedBy = [ "default.target" ];
      };
    })
  ]);
}
