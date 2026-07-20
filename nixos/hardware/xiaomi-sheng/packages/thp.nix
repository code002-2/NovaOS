# ---
# Module: Xiaomi Sheng Touch Host Processor
# Description: NT36532E userspace touch processor for multitouch + Focus Pen
# Scope: System
# ---

{ config, lib, pkgs, ... }:

let
  cfg = config.hardware.xiaomi-sheng.thp;
  pkg = pkgs.stdenv.mkDerivation {
    pname = "xiaomi-sheng-thp";
    version = "0.3.7";
    src = pkgs.shengThp;
    buildInputs = with pkgs; [ ];
    makeFlags = [ "PREFIX=${placeholder "out"}" ];
    installPhase = ''
      runHook preInstall
      install -Dm755 -s build/xiaomi-sheng-thp $out/libexec/xiaomi-sheng-thp/xiaomi-sheng-thp
      install -Dm644 systemd/xiaomi-sheng-thp.service $out/lib/systemd/system/xiaomi-sheng-thp.service
      runHook postInstall
    '';
  };
in
{
  options.hardware.xiaomi-sheng.thp = {
    enable = lib.mkEnableOption "Xiaomi Sheng touch host processor";
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ pkg ];

    systemd.services.xiaomi-sheng-thp = {
      description = "Xiaomi Sheng NT36532E userspace touch processor";
      after = [ "systemd-modules-load.service" "bluetooth.service" ];
      wants = [ "bluetooth.service" ];
      wantedBy = [ "multi-user.target" ];
      startLimitIntervalSec = 0;
      serviceConfig = {
        Type = "simple";
        ExecStartPre = [
          "${pkgs.coreutils}/bin/test -e /proc/nvt_thp_stream"
          "${pkgs.coreutils}/bin/test -e /proc/nvt_thp_stylus"
        ];
        ExecStart = "${pkg}/libexec/xiaomi-sheng-thp/xiaomi-sheng-thp";
        Restart = "on-failure";
        RestartSec = 1;
        KillSignal = "SIGINT";
        TimeoutStopSec = 10;
      };
    };
  };
}
