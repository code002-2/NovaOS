{
  description = "Xiaomi Pad 6S Pro (Sheng) NixOS Flake - Rolling Release";

  inputs = {
    # ✨ 永远跟随主线的最新滚动版本
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    
    # ✨ 引入官方格式生成器插件 (完美解决打包问题)
    nixos-generators = {
      url = "github:nix-community/nixos-generators";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, nixos-generators, ... }: {
    # 1. 留存标准的系统配置 (未来你可以在平板上直接跑 nixos-rebuild 使用)
    nixosConfigurations.sheng = nixpkgs.lib.nixosSystem {
      system = "aarch64-linux";
      modules = [
        ./configuration.nix
        ./sheng-hardware.nix
      ];
    };

    # 2. ✨ 新增专门针对 GitHub Actions 的 Tarball 极速打包目标
    packages.aarch64-linux.sheng-tarball = nixos-generators.nixosGenerate {
      system = "aarch64-linux";
      format = "tarball";
      modules = [
        ./configuration.nix
        ./sheng-hardware.nix
      ];
    };
  };
}
