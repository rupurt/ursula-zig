{ lib, fetchFromGitHub, makeRustPlatform, rust-bin, protobuf }:

let
  # Match rust-toolchain.toml in the release; Foyer uses nightly Rust features.
  rust = rust-bin.nightly."2026-06-01".minimal;
  rustPlatform = makeRustPlatform {
    cargo = rust;
    rustc = rust;
  };
in
rustPlatform.buildRustPackage rec {
  pname = "ursula";
  version = "0.5.1";

  src = fetchFromGitHub {
    owner = "tonbo-io";
    repo = "ursula";
    tag = "v${version}";
    hash = "sha256-QItqgN88xR+FIn+BAsdQ456fMZQ6fnp8IkhRkwhN78Q=";
  };
  cargoHash = "sha256-ReejZG6R7BUMVtPItXsEDYNXRNSFZq3TjP5qjEvU8l0=";

  nativeBuildInputs = [ protobuf ];
  # Use Nix's protoc, rather than the platform binaries bundled in a Cargo crate.
  postPatch = ''
    substituteInPlace crates/ursula-proto/build.rs crates/ursula-raft/build.rs \
      --replace-fail 'protoc_bin_vendored::protoc_bin_path()?' \
      '"${protobuf}/bin/protoc"'
  '';

  cargoBuildFlags = [ "--package" "ursula" "--bin" "ursula" ];
  # Upstream's cluster tests require networking. Our opt-in integration suite
  # validates the installed server through the Zig client outside the sandbox.
  doCheck = false;
  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    $out/bin/ursula --help > /dev/null
    runHook postInstallCheck
  '';

  meta = {
    description = "Durable Streams HTTP server";
    homepage = "https://github.com/tonbo-io/ursula";
    license = lib.licenses.asl20;
    mainProgram = "ursula";
    platforms = lib.platforms.unix;
  };
}
