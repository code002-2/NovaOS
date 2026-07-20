# ---
# Module: Xiaomi Sheng Fingerprint (FPC1553)
# Description: Prebuilt QTEE runtime + udev rules + systemd services
# Scope: System
# ---

{ config, lib, pkgs, ... }:

let
  cfg = config.hardware.xiaomi-sheng.fingerprint;
  fpSrc = pkgs.shengFingerprint;
  pkg = pkgs.stdenvNoCC.mkDerivation {
    pname = "xiaomi-sheng-fingerprint";
    version = "0.1.3";
    src = fpSrc;
    dontBuild = true;
    dontFixup = true;
    dontStrip = true;
    installPhase = ''
      runHook preInstall
      install -Dm0755 prebuilt/aarch64/qteesupplicant $out/libexec/qteesupplicant
      install -Dm0755 prebuilt/aarch64/sfs_config $out/libexec/fpc-sfs-config
      for lib in prebuilt/aarch64/qtee-listeners/*.so.1.0.0; do
        name=$(basename "$lib")
        short=''${name%.0.0}
        install -Dm0644 "$lib" $out/lib/qtee-listeners/$name
        ln -s $name $out/lib/qtee-listeners/$short
      done
      runHook postInstall
    '';
  };
in
{
  options.hardware.xiaomi-sheng.fingerprint = {
    enable = lib.mkEnableOption "Xiaomi Sheng fingerprint (FPC1553) support";
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ pkg ];

    services.udev.packages = [
      (pkgs.writeTextFile {
        name = "sheng-fingerprint-udev";
        destination = "/etc/udev/rules.d/99-qcomtee-fpc.rules";
        text = ''
          SUBSYSTEM=="tee", KERNEL=="tee[0-9]*", MODE="0600", OWNER="root", GROUP="root", TAG+="systemd", ENV{SYSTEMD_WANTS}+="qteesupplicant.service"
        '';
      })
    ];

    systemd.services.qteesupplicant = {
      description = "Qualcomm TEE listener services";
      after = [ "sfsconfig.service" ];
      requires = [ "sfsconfig.service" ];
      bindsTo = [ "dev-tee0.device" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "exec";
        ExecStart = "${pkg}/libexec/qteesupplicant";
        Environment = "LD_LIBRARY_PATH=${pkg}/lib/qtee-listeners";
        Restart = "always";
        AmbientCapabilities = "CAP_SYS_RAWIO";
        CapabilityBoundingSet = "CAP_SYS_RAWIO";
        ProtectSystem = "full";
        ProtectHome = false;
        PrivateTmp = false;
        NoNewPrivileges = false;
        DeviceAllow = [
          "/dev/tee0 rw"
          "/dev/bsg/0:0:0:49476 rw"
          "/dev/bsg/ufs-bsg0 rw"
        ];
      };
    };

    systemd.services.sfsconfig = {
      description = "QTEE secure-file-system configuration";
      before = [ "qteesupplicant.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${pkg}/libexec/fpc-sfs-config";
      };
    };
  };
}
