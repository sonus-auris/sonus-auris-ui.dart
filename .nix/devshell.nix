{ pkgs, agentCheck }:
let
  linuxPackages = pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux (
    with pkgs;
    [
      clang
      cmake
      glib
      gtk3
      libGL
      libsecret
      ninja
      pkg-config
    ]
  );
  linuxLibraries = with pkgs; [
    glib
    gtk3
    libGL
    libsecret
  ];
  shellPackages =
    (with pkgs; [
      actionlint
      cacert
      flutter
      git
      jdk17
      jq
      just
      nixfmt-rfc-style
      shellcheck
      shfmt
    ])
    ++ linuxPackages
    ++ [ agentCheck ];
in
pkgs.mkShell {
  packages = shellPackages;

  JAVA_HOME = "${pkgs.jdk17.home}";
  LANG = if pkgs.stdenv.hostPlatform.isDarwin then "en_US.UTF-8" else "C.UTF-8";
  LC_ALL = if pkgs.stdenv.hostPlatform.isDarwin then "en_US.UTF-8" else "C.UTF-8";
  LD_LIBRARY_PATH = pkgs.lib.optionalString pkgs.stdenv.hostPlatform.isLinux (
    pkgs.lib.makeLibraryPath linuxLibraries
  );

  shellHook = ''
    export NIX_DEV_SHELL=sonus-auris-ui
    export NIX_AGENT_CACHE_ROOT="''${NIX_AGENT_CACHE_ROOT:-$PWD/.cache/nix-agent}"
    export PUB_CACHE="''${PUB_CACHE:-$NIX_AGENT_CACHE_ROOT/dart-pub}"
    export GRADLE_USER_HOME="''${GRADLE_USER_HOME:-$NIX_AGENT_CACHE_ROOT/gradle}"
    export XDG_CACHE_HOME="''${XDG_CACHE_HOME:-$NIX_AGENT_CACHE_ROOT/xdg-cache}"
    export XDG_CONFIG_HOME="''${XDG_CONFIG_HOME:-$NIX_AGENT_CACHE_ROOT/xdg-config}"
    export XDG_DATA_HOME="''${XDG_DATA_HOME:-$NIX_AGENT_CACHE_ROOT/xdg-data}"
    export FLUTTER_SUPPRESS_ANALYTICS="''${FLUTTER_SUPPRESS_ANALYTICS:-true}"
    export DART_SUPPRESS_ANALYTICS="''${DART_SUPPRESS_ANALYTICS:-true}"
    mkdir -p \
      "$PUB_CACHE" \
      "$GRADLE_USER_HOME" \
      "$XDG_CACHE_HOME" \
      "$XDG_CONFIG_HOME" \
      "$XDG_DATA_HOME"
  '';
}
