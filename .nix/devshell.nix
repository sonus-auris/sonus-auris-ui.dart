{ pkgs }:

pkgs.mkShell {
  packages = with pkgs; [
    flutter
    dart

    git
    just
  ];
}
