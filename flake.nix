{
  description = "synth";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/ffb3c9b700e759be2ef13237c9d8f953b32a1e46";
    flake-utils.url = "github:numtide/flake-utils";

    zig = {
      url = "github:mitchellh/zig-overlay/6b5e8a65de00723fae1f3c6d6434469ac754715c";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    zls = {
      url = "github:zigtools/zls/0.16.0";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      flake-utils,
      nixpkgs,
      zig,
      zls,
      ...
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
      in
      {
        devShells.default = pkgs.mkShell {
          buildInputs = [
            zig.packages.${system}."0.16.0"
            zls.packages.${system}.zls
          ];
        };
      }
    );
}
