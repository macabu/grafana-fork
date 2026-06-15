{
  description = ''
    The open and composable observability and data visualization platform.
    Visualize metrics, logs, and traces from multiple sources like Prometheus, Loki, Elasticsearch, InfluxDB, Postgres and many more.
  '';

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
    }:
    let
      # System-independent: version resolution and build target lists.
      packageJson = builtins.fromJSON (builtins.readFile ./package.json);
      buildId =
        if builtins.pathExists ./build-id then
          nixpkgs.lib.removeSuffix "\n" (builtins.readFile ./build-id)
        else
          null;
      grafanaVersion =
        if buildId != null then
          builtins.replaceStrings [ "pre" ] [ buildId ] packageJson.version
        else
          packageJson.version;
      buildNumber = if buildId != null then buildId else "local";

      targets = [
        {
          goos = "linux";
          goarch = "amd64";
        }
        {
          goos = "linux";
          goarch = "arm64";
        }
        {
          goos = "linux";
          goarch = "arm";
          goarm = "6";
        }
        {
          goos = "linux";
          goarch = "arm";
          goarm = "7";
        }
        {
          goos = "linux";
          goarch = "s390x";
        }
        {
          goos = "linux";
          goarch = "riscv64";
        }
        {
          goos = "windows";
          goarch = "amd64";
        }
        {
          goos = "windows";
          goarch = "arm64";
        }
        {
          goos = "darwin";
          goarch = "amd64";
        }
        {
          goos = "darwin";
          goarch = "arm64";
        }
      ];

      debTargets = builtins.filter (t: t.goos == "linux") targets;
      rpmTargets = builtins.filter (t: t.goos == "linux") targets;

      mkTargetName =
        prefix:
        {
          goos,
          goarch,
          goarm ? null,
          ...
        }:
        "${prefix}-${goos}-${goarch}${nixpkgs.lib.optionalString (goarm != null) "v${goarm}"}";

      # Artifact filename arch label: arm variants use "arm-6"/"arm-7"
      # (matches scripts/build-{deb,rpm}.sh ARCH_LABEL).
      mkArchLabel =
        {
          goarch,
          goarm ? null,
          ...
        }:
        "${goarch}${nixpkgs.lib.optionalString (goarm != null) "-${goarm}"}";

      backendTargetName = mkTargetName "backend";
      pkgtreeTargetName = mkTargetName "pkgtree";
      targzTargetName = mkTargetName "targz";
      debTargetName = mkTargetName "deb";
      rpmTargetName = mkTargetName "rpm";

      # Docker images: linux only, and only arches we have a cross userland for
      # (amd64, arm64, s390x, armv7 — matches the publish matrices). arm v6 and
      # riscv64 are excluded.
      dockerTargets = builtins.filter (
        t: t.goos == "linux" && t.goarch != "riscv64" && !(t.goarch == "arm" && (t.goarm or "") == "6")
      ) targets;
      dockerVariants = [
        "alpine"
        "alpine-slim"
        "ubuntu"
        "ubuntu-slim"
        "distroless"
        "distroless-slim"
      ];
    in
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        # While nixpkgs does not yet have 1.26.4 on unstable.
        go_1_26_4 = pkgs.go_1_26.overrideAttrs (old: rec {
          version = "1.26.4";
          src = pkgs.fetchurl {
            url = "https://dl.google.com/go/go${version}.src.tar.gz";
            hash = "sha256-T2aKMvv8ETLmqIH7lowvHa2mMUkqM5IRc1+7JVpCYC0=";
          };
        });

        # Main function to build the backend.
        mkBackend =
          {
            goos,
            goarch,
            goarm ? null,
            ...
          }:
          pkgs.buildGo126Module.override
            {
              go =
                # Temporarily while nixpkgs does not have this version upstream.
                go_1_26_4

                # buildGoModule cross-compiles via `inherit (go) GOOS GOARCH`, so
                # we merge the target values onto the base go package to override
                # them. (GOARM is not inherited from `go`; it is set via env below.)
                // {
                  GOOS = goos;
                  GOARCH = goarch;
                };
            }
            {
              pname = "grafana";
              version = grafanaVersion;
              src = ./.;
              proxyVendor = true;
              vendorHash = "sha256-SQvx/Muu+SDOTeXoDwwRXa2LYY06uVIugF4yKdU1928=";
              subPackages = [ "./pkg/cmd/grafana" ];

              doCheck = false;

              env.CGO_ENABLED = "0";
              # buildGoModule inherits only GOOS/GOARCH from `go`, so GOARM must
              # be passed through the build env to take effect for arm targets.
              env.GOARM = if goarm != null then goarm else "";

              dontStrip = true;
              ldflags = [
                "-s"
                "-w"
                "-X main.version=${grafanaVersion}"
                "-X main.commit=${self.rev or "unknown"}"
                "-X main.buildBranch=main"
                "-X main.buildstamp=0"
              ];

              # Replicates how we've been organizing the output folder for the backend build.
              postInstall =
                let
                  ext = pkgs.lib.optionalString (goos == "windows") ".exe";
                in
                ''
                  mkdir -p $out/bin/${goos}/${goarch}
                  if [ -f $out/bin/${goos}_${goarch}/grafana${ext} ]; then
                    mv $out/bin/${goos}_${goarch}/grafana${ext} $out/bin/${goos}/${goarch}/grafana${ext}
                  else
                    mv $out/bin/grafana${ext} $out/bin/${goos}/${goarch}/grafana${ext}
                  fi
                '';
            };

        # Frontend assets.
        mkFrontend = pkgs.stdenv.mkDerivation (finalAttrs: {
          name = "grafana-frontend";
          # Scope the source to what the frontend build needs. Excluding the Go
          # backend and the flake files keeps this derivation (and the shared
          # offlineCache) stable when only backend/flake code changes, so editing
          # them no longer forces a full frontend rebuild.
          src = pkgs.lib.fileset.toSource {
            root = ./.;
            fileset = pkgs.lib.fileset.difference ./. (
              pkgs.lib.fileset.unions [
                ./.github
                ./apps
                ./pkg
                ./flake.nix
                ./flake.lock
                ./missing-hashes.json
              ]
            );
          };
          nativeBuildInputs = [
            pkgs.nodejs_24
            pkgs.faketty
            pkgs.yarn-berry_4
            pkgs.yarn-berry_4.yarnBerryConfigHook
          ];
          # nix run nixpkgs#yarn-berry_4.yarn-berry-fetcher -- missing-hashes yarn.lock > missing-hashes.json
          missingHashes = ./missing-hashes.json;
          offlineCache = pkgs.yarn-berry_4.fetchYarnBerryDeps {
            inherit (finalAttrs) src missingHashes;
            hash = "sha256-qhDG/lkP1uyxvcSucYbNPKG4gM4wxtjJbMUyWP30H2k=";
          };
          YARN_ENABLE_SCRIPTS = "0";

          # The Nix sandbox strips the environment, so nx never sees CI=true and starts its background daemon.
          # Disabling the daemon keeps the build self-contained.
          NX_DAEMON = "false";

          # Default V8 heap (~2GB) is too small for the webpack production build,
          # which gets OOM-killed. Raise it; keep below the runner's RAM.
          NODE_OPTIONS = "--max-old-space-size=8192";

          # Frontend output is static assets, skip the pointless strip pass.
          dontStrip = true;

          # Need "faketty" otherwise build panics: https://github.com/nrwl/nx/issues/22445
          buildPhase = ''
            faketty yarn build
          '';

          installPhase = ''
            cp -r public $out
          '';
        });

        # Builds the package tree used by tar, deb and rpm.
        mkPkgTree =
          {
            goos,
            goarch,
            goarm ? null,
            ...
          }:
          let
            backend = mkBackend { inherit goos goarch goarm; };
          in
          pkgs.stdenv.mkDerivation {
            name = "grafana-${grafanaVersion}-pkg-tree-${goos}-${mkArchLabel { inherit goarch goarm; }}";
            nativeBuildInputs = [ go_1_26_4 ];
            dontUnpack = true;
            buildPhase = ''
              mkdir -p $out/{bin,tools,docs,packaging,data/plugins-bundled,plugins-bundled}

              echo "${grafanaVersion}" > $out/VERSION

              cp ${./LICENSE}               $out/LICENSE
              cp ${./NOTICE.md}             $out/NOTICE.md
              cp ${./README.md}             $out/README.md
              cp ${./Dockerfile}            $out/Dockerfile
              cp -r ${./conf}               $out/conf
              cp -r ${./docs/sources}       $out/docs/sources
              cp -r ${./packaging/deb}      $out/packaging/deb
              cp -r ${./packaging/rpm}      $out/packaging/rpm
              cp -r ${./packaging/docker}   $out/packaging/docker
              cp -r ${./packaging/wrappers} $out/packaging/wrappers
              cp $(${go_1_26_4}/bin/go env GOROOT)/lib/time/zoneinfo.zip $out/tools/
              cp ${backend}/bin/${goos}/${goarch}/grafana* $out/bin/
              cp -r ${mkFrontend} $out/public
            '';
            installPhase = "true";
          };

        # Final tar artifact.
        mkTargz =
          {
            goos,
            goarch,
            goarm ? null,
            ...
          }:
          let
            tree = mkPkgTree { inherit goos goarch goarm; };
            archLabel = mkArchLabel { inherit goarch goarm; };
            filename = "grafana_${grafanaVersion}_${buildNumber}_${goos}_${archLabel}.tar.gz";
            root = "grafana-${grafanaVersion}";
          in
          pkgs.stdenv.mkDerivation {
            name = filename;
            nativeBuildInputs = [ pkgs.gnutar ];
            dontUnpack = true;
            buildPhase = ''
              cp -r ${tree} ${root}
              tar -czf ${filename} ${root}
            '';
            installPhase = ''
              mkdir -p $out
              cp ${filename} $out/${filename}
            '';
          };

        # .deb package assembly.
        mkDeb =
          {
            goos,
            goarch,
            goarm ? null,
            ...
          }:
          let
            tree = mkPkgTree { inherit goos goarch goarm; };
            archLabel = mkArchLabel { inherit goarch goarm; };
            debPkgName = if goarm == "6" then "grafana-rpi" else "grafana";
            # Strip v prefix, replace +security- with - (matches build-deb.sh debVersion logic).
            debVersion = builtins.replaceStrings [ "+security-" ] [ "-" ] (
              nixpkgs.lib.removePrefix "v" grafanaVersion
            );
            pkgArch = if goarch == "arm" then "armhf" else goarch;
            filename = "${debPkgName}_${grafanaVersion}_${buildNumber}_${goos}_${archLabel}.deb";
          in
          pkgs.stdenv.mkDerivation {
            name = filename;
            nativeBuildInputs = [ pkgs.fpm ];
            dontUnpack = true;
            buildPhase = ''
              mkdir -p pkg/usr/sbin
              mkdir -p pkg/usr/share/grafana
              mkdir -p pkg/etc/default pkg/etc/grafana pkg/etc/init.d
              mkdir -p pkg/usr/lib/systemd/system

              cp -r ${tree} pkg/usr/share/grafana
              chmod -R u+w pkg/usr/share/grafana

              cp ${tree}/packaging/wrappers/grafana        pkg/usr/sbin/grafana
              cp ${tree}/packaging/wrappers/grafana-server pkg/usr/sbin/grafana-server
              cp ${tree}/packaging/wrappers/grafana-cli    pkg/usr/sbin/grafana-cli
              chmod 0755 pkg/usr/sbin/grafana pkg/usr/sbin/grafana-server pkg/usr/sbin/grafana-cli

              cp ${tree}/packaging/deb/default/grafana-server         pkg/etc/default/grafana-server
              cp ${tree}/packaging/deb/init.d/grafana-server          pkg/etc/init.d/grafana-server
              cp ${tree}/packaging/deb/systemd/grafana-server.service pkg/usr/lib/systemd/system/grafana-server.service
              chmod 0755 pkg/etc/init.d/grafana-server
              chmod 0644 pkg/etc/default/grafana-server

              fpm \
                --input-type=dir \
                --chdir=pkg \
                --output-type=deb \
                --vendor="Grafana Labs" \
                --url=https://grafana.com \
                --maintainer=contact@grafana.com \
                --version="${debVersion}" \
                --package="${filename}" \
                --config-files=/etc/default/grafana-server \
                --config-files=/etc/init.d/grafana-server \
                --config-files=/usr/lib/systemd/system/grafana-server.service \
                --after-install="${tree}/packaging/deb/control/postinst" \
                --before-remove="${tree}/packaging/deb/control/prerm" \
                --depends=adduser \
                --architecture="${pkgArch}" \
                --description=Grafana \
                --license="AGPLv3" \
                --name="${debPkgName}" \
                --deb-no-default-config-files \
                --deb-compression xz \
                .
            '';
            installPhase = ''
              mkdir -p $out
              cp ${filename} $out/${filename}
            '';
          };

        # .rpm package assembly.
        mkRpm =
          {
            goos,
            goarch,
            goarm ? null,
            ...
          }:
          let
            tree = mkPkgTree { inherit goos goarch goarm; };
            archLabel = mkArchLabel { inherit goarch goarm; };
            # Strip v prefix, replace + with ^ (matches build-rpm.sh rpmVersion logic).
            rpmVersion = builtins.replaceStrings [ "+" ] [ "^" ] (nixpkgs.lib.removePrefix "v" grafanaVersion);
            pkgArch = if goarch == "arm" then "armhf" else goarch;
            filename = "grafana_${grafanaVersion}_${buildNumber}_${goos}_${archLabel}.rpm";
          in
          pkgs.stdenv.mkDerivation {
            name = filename;
            # fpm shells out to `rpmbuild` (from pkgs.rpm) to assemble the .rpm.
            nativeBuildInputs = [
              pkgs.fpm
              pkgs.rpm
            ];
            dontUnpack = true;
            buildPhase = ''
              mkdir -p pkg/usr/sbin
              mkdir -p pkg/usr/share/grafana
              mkdir -p pkg/etc/sysconfig pkg/etc/grafana
              mkdir -p pkg/usr/lib/systemd/system

              cp -r ${tree} pkg/usr/share/grafana
              chmod -R u+w pkg/usr/share/grafana

              cp ${tree}/packaging/wrappers/grafana        pkg/usr/sbin/grafana
              cp ${tree}/packaging/wrappers/grafana-server pkg/usr/sbin/grafana-server
              cp ${tree}/packaging/wrappers/grafana-cli    pkg/usr/sbin/grafana-cli
              chmod 0755 pkg/usr/sbin/grafana pkg/usr/sbin/grafana-server pkg/usr/sbin/grafana-cli

              cp ${tree}/packaging/rpm/sysconfig/grafana-server       pkg/etc/sysconfig/grafana-server
              cp ${tree}/packaging/rpm/systemd/grafana-server.service pkg/usr/lib/systemd/system/grafana-server.service
              chmod 0644 pkg/etc/sysconfig/grafana-server

              fpm \
                --input-type=dir \
                --chdir=pkg \
                --output-type=rpm \
                --vendor="Grafana Labs" \
                --url=https://grafana.com \
                --maintainer=contact@grafana.com \
                --version="${rpmVersion}" \
                --package="${filename}" \
                --config-files=/etc/sysconfig/grafana-server \
                --config-files=/usr/lib/systemd/system/grafana-server.service \
                --after-install="${tree}/packaging/rpm/control/postinst" \
                --depends=/sbin/service \
                --architecture="${pkgArch}" \
                --description=Grafana \
                --license="AGPLv3" \
                --name="grafana" \
                --rpm-posttrans="${tree}/packaging/rpm/control/posttrans" \
                --rpm-digest=sha256 \
                --rpm-compression xzmt \
                --rpm-user root \
                --rpm-group root \
                .
            '';
            installPhase = ''
              mkdir -p $out
              cp ${filename} $out/${filename}
            '';
          };

        # Container rootfs. Deliberately NOT mkPkgTree: that lays out the tarball
        # (flat bin/, tools/, docs/, packaging/, VERSION); a container needs the
        # /usr/share/grafana + /etc/grafana + /var layout the Dockerfile builds.
        mkImageRoot =
          {
            goos,
            goarch,
            goarm ? null,
            slim ? false,
            ...
          }:
          let
            backend = mkBackend { inherit goos goarch goarm; };
          in
          pkgs.stdenv.mkDerivation {
            name = "grafana-image-root-${goos}-${
              mkArchLabel { inherit goarch goarm; }
            }${pkgs.lib.optionalString slim "-slim"}";
            dontUnpack = true;
            installPhase = ''
              runHook preInstall

              mkdir -p $out/usr/share/grafana/{bin,public,conf,.aws,data/plugins-bundled}
              cp ${backend}/bin/${goos}/${goarch}/grafana $out/usr/share/grafana/bin/grafana
              cp -r ${mkFrontend}/. $out/usr/share/grafana/public/
              cp -r ${./conf}/. $out/usr/share/grafana/conf/
              echo "${grafanaVersion}" > $out/.grafana-version

              # conf/provisioning has no notifiers dir, so create all six explicitly.
              mkdir -p $out/etc/grafana/provisioning/{datasources,dashboards,notifiers,plugins,access-control,alerting}
              cp $out/usr/share/grafana/conf/sample.ini $out/etc/grafana/grafana.ini
              cp $out/usr/share/grafana/conf/ldap.toml $out/etc/grafana/ldap.toml

              mkdir -p $out/var/lib/grafana/plugins $out/var/log/grafana

              # slim would skip copying bundled plugins; the flake bundles none
              # today, so slim and full are identical for now.

              runHook postInstall
            '';
          };

        # OCI architecture string (Go GOARCH naming; dockerTools has no `variant`,
        # so armv7 is just "arm").
        dockerArch = { goarch, ... }: goarch;

        # The shell variants (alpine/ubuntu) need bash+coreutils for run.sh; those
        # are arch-specific, so cross-compile them for non-amd64 targets. The
        # static grafana binary itself comes from mkBackend, never rebuilt here.
        crossPkgs =
          {
            goarch,
            goarm ? null,
            ...
          }:
          if goarch == "amd64" then
            pkgs
          else if goarch == "arm64" then
            pkgs.pkgsCross.aarch64-multiplatform
          else if goarch == "s390x" then
            pkgs.pkgsCross.s390x
          else if goarch == "arm" && goarm == "7" then
            pkgs.pkgsCross.armv7l-hf-multiplatform
          else
            throw "no docker userland mapping for goarch=${goarch}";

        # A single Docker image variant for one target.
        mkDockerImage =
          {
            variant,
            goos ? "linux",
            goarch,
            goarm ? null,
            ...
          }:
          let
            lib = pkgs.lib;
            slim = lib.hasSuffix "-slim" variant;
            base = lib.removeSuffix "-slim" variant;
            isShell = base == "alpine" || base == "ubuntu";
            imageRoot = mkImageRoot {
              inherit
                goos
                goarch
                goarm
                slim
                ;
            };
            cross = crossPkgs { inherit goarch goarm; };

            # Non-root user without runAsRoot/KVM: ship /etc/passwd + /etc/group.
            passwd = pkgs.writeTextDir "etc/passwd" ''
              root:x:0:0:root:/root:/sbin/nologin
              nobody:x:65534:65534:nobody:/nonexistent:/sbin/nologin
              grafana:x:472:0::/usr/share/grafana:/bin/bash
            '';
            group = pkgs.writeTextDir "etc/group" ''
              root:x:0:
              nobody:x:65534:
            '';

            # Only these dirs must be writable by the grafana user at runtime.
            writableDirs = lib.concatStringsSep " " [
              "var/lib/grafana"
              "var/lib/grafana/plugins"
              "var/log/grafana"
              "etc/grafana/provisioning"
              "usr/share/grafana/.aws"
              "usr/share/grafana/data/plugins-bundled"
            ];

            shellPath = lib.concatStringsSep ":" [
              "/usr/share/grafana/bin"
              "${cross.coreutils}/bin"
              "${cross.gnugrep}/bin"
              "${cross.gnused}/bin"
              "${cross.bashInteractive}/bin"
            ];

            envCommon = [
              "GF_PATHS_CONFIG=/etc/grafana/grafana.ini"
              "GF_PATHS_DATA=/var/lib/grafana"
              "GF_PATHS_HOME=/usr/share/grafana"
              "GF_PATHS_LOGS=/var/log/grafana"
              "GF_PATHS_PLUGINS=/var/lib/grafana/plugins"
              "GF_PATHS_PROVISIONING=/etc/grafana/provisioning"
              "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
            ];
          in
          pkgs.dockerTools.buildLayeredImage {
            name = "grafana";
            tag = builtins.replaceStrings [ "+" ] [ "_" ] grafanaVersion;
            architecture = dockerArch { inherit goarch; };
            fromImage = null;
            # imageRoot is NOT in `contents`: contents are symlinked in via lndir,
            # and Grafana's core-plugin finder resolves symlinks and rejects any
            # public/app/plugins file whose real path escapes the plugins dir
            # (it would point at /nix/store/...-grafana-image-root/...). The
            # Dockerfile uses a real COPY, so we mirror that by copying imageRoot
            # into the layer as real files in extraCommands below.
            contents = [
              passwd
              group
              pkgs.cacert
              pkgs.tzdata
            ]
            ++ lib.optionals isShell [
              cross.bashInteractive
              cross.coreutils
              cross.gnugrep
              cross.gnused
            ];
            # Runs as the build user (no fakeroot). cp -r preserves modes, so the
            # grafana binary keeps its exec bit and assets stay real files.
            extraCommands = ''
              cp -r ${imageRoot}/. ./
              chmod -R 0777 ${writableDirs}
              # dockerTools ships no /tmp; Grafana's plugin installer writes its
              # download there. Real distro bases provide it (1777); recreate it.
              mkdir -p tmp
              chmod 1777 tmp
            ''
            + lib.optionalString isShell ''
              # bashInteractive is in `contents`, so /bin/bash (and /bin/sh)
              # already exist via lndir; run.sh's #!/bin/bash shebang resolves
              # to it. Just drop the entrypoint script at the image root.
              cp ${./packaging/docker/run.sh} run.sh
              chmod 0755 run.sh
            '';
            # chown is only honoured under fakeroot (tar --numeric-owner records it).
            fakeRootCommands = ''
              chown -R 472:0 ${writableDirs}
            '';
            enableFakechroot = false;
            config = {
              User = "472";
              WorkingDir = "/usr/share/grafana";
              ExposedPorts = {
                "3000/tcp" = { };
              };
              Labels = {
                maintainer = "Grafana Labs <hello@grafana.com>";
                "org.opencontainers.image.source" = "https://github.com/grafana/grafana";
              };
              Env = envCommon ++ [
                "PATH=${if isShell then shellPath else "/usr/share/grafana/bin"}"
              ];
            }
            // (
              if isShell then
                { Entrypoint = [ "/run.sh" ]; }
              else
                {
                  Entrypoint = [
                    "/usr/share/grafana/bin/grafana"
                    "server"
                    "--homepath=/usr/share/grafana"
                    "--config=/etc/grafana/grafana.ini"
                    "--packaging=docker"
                  ];
                  Cmd = [ "cfg:default.log.mode=console" ];
                }
            );
          };

        # Renames the buildLayeredImage output to the publish-pipeline filename.
        mkDockerArtifact =
          {
            variant,
            goos ? "linux",
            goarch,
            goarm ? null,
            ...
          }:
          let
            image = mkDockerImage {
              inherit
                variant
                goos
                goarch
                goarm
                ;
            };
            archLabel = mkArchLabel { inherit goarch goarm; };
            # alpine full has no flavor token; everything else carries one.
            suffix =
              if variant == "alpine" then
                ""
              else if variant == "alpine-slim" then
                "-slim"
              else
                ".${variant}";
            filename = "grafana_${grafanaVersion}_${buildNumber}_${goos}_${archLabel}${suffix}.docker.tar.gz";
          in
          pkgs.stdenv.mkDerivation {
            name = filename;
            dontUnpack = true;
            installPhase = ''
              mkdir -p $out
              cp ${image} $out/${filename}
            '';
          };
      in
      {
        packages =
          builtins.listToAttrs (
            map (t: {
              name = backendTargetName t;
              value = mkBackend t;
            }) targets
          )
          // {
            frontend = mkFrontend;
          }
          // builtins.listToAttrs (
            map (t: {
              name = pkgtreeTargetName t;
              value = mkPkgTree t;
            }) targets
          )
          // builtins.listToAttrs (
            map (t: {
              name = targzTargetName t;
              value = mkTargz t;
            }) targets
          )
          // builtins.listToAttrs (
            map (t: {
              name = debTargetName t;
              value = mkDeb t;
            }) debTargets
          )
          // builtins.listToAttrs (
            map (t: {
              name = rpmTargetName t;
              value = mkRpm t;
            }) rpmTargets
          )
          // builtins.listToAttrs (
            pkgs.lib.concatMap (
              variant:
              map (t: {
                name = mkTargetName "docker-${variant}" t;
                value = mkDockerArtifact (t // { inherit variant; });
              }) dockerTargets
            ) dockerVariants
          );
      }
    );
}
