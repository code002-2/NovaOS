# ---
# Module: Xiaomi Pen Status
# Description: Pen Status tray utility for Xiaomi Pad 6S Pro 12.4
# Scope: System
# ---

{ config, lib, pkgs, ... }:

let
  cfg = config.hardware.xiaomi-sheng.pen-status;
  pkg = pkgs.libsForQt5.callPackage
    ({ stdenv, lib, mkDerivation, qmake, qtbase, qtsvg, qtwebsockets, qtx11extras }:
      mkDerivation {
        pname = "xiaomi-pen-status";
        version = "0.1.0";
        src = pkgs.shengPenStatus;
        nativeBuildInputs = [ qmake ];
        buildInputs = [ qtbase qtsvg qtwebsockets qtx11extras ];
        installPhase = ''
          runHook preInstall
          install -Dm755 xiaomi-pen-status $out/bin/xiaomi-pen-status
          install -Dm644 xiaomi-pen-status.desktop $out/share/applications/xiaomi-pen-status.desktop
          install -Dm644 xiaomi-pen-status.svg $out/share/icons/hicolor/scalable/apps/xiaomi-pen-status.svg
          runHook postInstall
        '';
        meta = with lib; {
          description = "Pen Status tray utility for Xiaomi Pad 6S Pro 12.4";
          license = licenses.mit;
          platforms = platforms.aarch64;
        };
      }) { };
in
{
  options.hardware.xiaomi-sheng.pen-status = {
    enable = lib.mkEnableOption "Xiaomi Pen Status tray utility";
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ pkg ];
  };
}
