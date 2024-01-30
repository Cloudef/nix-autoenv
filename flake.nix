{
   description = "nix-autoenv";

   inputs = {
      nixpkgs.url = "github:nixos/nixpkgs";
      flake-utils.url = "github:numtide/flake-utils";
   };

   outputs = { self, nixpkgs, flake-utils }: let
      outputs = (flake-utils.lib.eachDefaultSystem (system: let
         pkgs = nixpkgs.outputs.legacyPackages.${system};
      in {
         packages.default = pkgs.callPackage ./default.nix {};
         devShells.default = pkgs.mkShell {
            nativeBuildInputs = with pkgs; [ pkg-config lolcat ];
            buildInputs = with pkgs; [ sqlite ];
            shellHook = ''
            echo "This a test for nix-autoenv"
            export HELLO_WORLD=someone-set-env-in-hook-test
            export BREAKING="new's"
            '';
         };
      }));
   in outputs;
}
