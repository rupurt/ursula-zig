{ ursula }:

# Both binaries come from the same workspace. Reuse the release, toolchain,
# vendored dependencies, and protoc patch so their pins cannot drift apart.
ursula.overrideAttrs (old: {
  pname = "ursulactl";
  cargoBuildFlags = [ "--package" "ursula-ctl" "--bin" "ursulactl" ];
  installCheckPhase = ''
    runHook preInstallCheck
    $out/bin/ursulactl --help > /dev/null
    runHook postInstallCheck
  '';

  meta = old.meta // {
    description = "Operational CLI for Ursula clusters";
    mainProgram = "ursulactl";
  };
})
