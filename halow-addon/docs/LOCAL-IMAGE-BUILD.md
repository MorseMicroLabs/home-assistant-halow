# Local image build and publication procedure

Operator procedure for building and publishing the app image for one release. The image is
built on a maintainer's machine, not in GitHub Actions: it needs the artifact bundle
(`halow-addon/artifacts/`), which is git-ignored and not in Git, so a clean checkout cannot
build it. This procedure never contains a credential; you supply one interactively and it is
never written to a file, a script, an environment file or the repository.

Target: `ghcr.io/morsemicrolabs/home-assistant-halow:<version>`, linux/arm64 (aarch64).
`<version>` is the `version` in `halow-addon/config.yaml`. The Supervisor pulls the image
named by `image:` with the tag equal to `version`, so the tag must equal it exactly.

## 0. Prerequisites

- A Linux or WSL2 shell with `bash`, `sha256sum`, `awk`, `file`, `readelf` (binutils), `python3` (with PyYAML), Docker with
  BuildKit and linux/arm64 emulation (QEMU/binfmt) or an arm64 host.
- The verified artifact bundle directory: it holds `output/` and its own `MANIFEST.sha256`,
  produced by its own build script. Obtain it through the controlled channel, not from this repository.
- A GitHub account with write access to the `MorseMicroLabs` organization's packages, and the
  ability to create a token (below) at push time.

## 1. Check the source tree

```bash
cd halow-addon
grep -E '^(version|image):' config.yaml
grep -E 'io.hass.version|org.opencontainers.image.version' Dockerfile
```

`version` must equal both Dockerfile version labels (`build.sh` refuses to build otherwise)
and `image:` must be `ghcr.io/morsemicrolabs/home-assistant-halow`, with no tag, no digest and
no `{arch}` (the repository's release gate checks this). The `FROM` line must be pinned by digest.

```bash
bash tests/run_tests.sh                 # static suites; image-dependent suites skip until step 3
tools/final_release_gate.sh --assets /path/to/source-assets --private-preparation
tools/final_release_gate.sh --assets /path/to/source-assets      # all fourteen gates
```

`--private-preparation` evaluates gates 1 to 13 (everything that can be done before publication,
including the verification of the local source assets in step 4a) and reports gate 14 as pending.
The full run also evaluates gate 14, which stays BLOCKED until the source assets are recorded as
published (step 8). Do not make the repository or the package public while any of gates 1 to 13
BLOCKs.

## 2. Stage and verify the artifacts, build the image

```bash
export ARTIFACT_BUNDLE_DIR=/path/to/verified-artifact-bundle   # the directory with output/ and MANIFEST.sha256
BUILD_IMAGE=1 ./build.sh
```

`build.sh` verifies the bundle against its own manifest, copies the seven files the app needs
into `artifacts/`, compares the result with the tracked `MANIFEST.sha256` (it fails on any
difference; accept a change only after review, with `UPDATE_EXPECTED_MANIFEST=1`), checks the
Dockerfile pins, and runs `docker build --platform linux/arm64`. It tags
`morse-micro-halow-ap:local` and `morse-micro-halow-ap:<version>` and prints the image id.
Record the image id.

## 3. Verify the image (off-device)

```bash
bash tests/verify_image.sh morse-micro-halow-ap:<version>     # runs the in-image checks with --network none
HALOW_REQUIRE_REAL=1 bash tests/run_tests.sh                  # the real-container suites must now run, not skip
```

`verify_image.sh` checks architecture, the `io.hass.*` labels, the OCI source label, the build-input
labels, the stop budgets, packages, the status service and firmware handling. With
`HALOW_REQUIRE_REAL=1` a skipped suite fails the run.

Optional, slow (builds twice, no cache; needs network for the base image and the Alpine repository):

```bash
tools/check_reproducible_build.sh        # exit 0 identical, 1 differ, 2 could not run
```

## 4. Software bill of materials

```bash
SBOM_OUT="$(mktemp -d)"                  # keep it outside the tracked tree
tools/generate_sbom.sh morse-micro-halow-ap:<version> "$SBOM_OUT"
HALOW_SBOM_DIR="$SBOM_OUT" bash tests/test_sbom_completeness.sh
```

Review the outputs (`sbom.cdx.json`, `provenance-coverage.txt`, `licences-summary.txt`,
`unowned-files.txt`). Do not commit them unless reviewed.

## 4a. Corresponding-source assets

The corresponding source (the driver, kernel, Buildroot, hostap, libnl, glibc and Alpine sources,
the kernel build material and the hostapd relink material) is not in Git. It is provided as
release assets of `v<version>` (`SOURCE-OFFER.md`, `source-assets/SOURCE-INDEX.md`). The assets
are built once, kept outside the repository, and described by the committed manifest
`source-assets/ASSETS.psv` (name, size, SHA-256, archive member). Before the image is pushed,
check the complete local set against the manifest:

```bash
tools/verify_source_assets.sh /path/to/source-assets
```

It checks size, SHA-256 and archive contents of every asset, that the directory holds exactly the
manifest assets plus `SHA256SUMS`, that `SHA256SUMS` equals the manifest checksum list, and that
`SOURCE-INDEX.md` and `kernel-prep.sh` are byte-identical to the repository copies. The set can be
rebuilt only from the recipes recorded in the asset READMEs; do not change an asset without
updating the manifest, `corresponding_source.psv` and `SOURCE-OFFER.md` together. Any file copied
into the image (`SOURCE-OFFER.md`, the manifest, the index, the scripts) changes the image, so
rebuild and reverify the image after changing one. Keep the image at 8 layers or fewer:
`build.sh` gathers the license material into one directory so that it arrives in one `COPY`,
because every layer lengthens the root overlay line of the container's mount table, which the
BusyBox mount the app uses reads with a bounded buffer (`verify_image.sh` checks the count).

## 5. Tag and push

Create a token in the GitHub web interface with only the `write:packages` scope (a classic
personal access token, as GitHub documents for the container registry), with the shortest
expiry that works. Do not put it in a file or in shell history. Log in by reading it from the
prompt:

```bash
docker login ghcr.io -u <your-github-username> --password-stdin   # paste the token, then press Ctrl-D (Ctrl-Z on Windows)
docker tag morse-micro-halow-ap:<version> ghcr.io/morsemicrolabs/home-assistant-halow:<version>
docker push ghcr.io/morsemicrolabs/home-assistant-halow:<version>
docker logout ghcr.io
```

Registry names must be lower case. Never push a different image under an existing version tag.
Revoke the token when finished.

## 6. Publish together: repository, release assets and package

The source must be available when the binary is distributed, so the three things below are done as
one release step, only when the release is approved for publication, in this order:

1. Push the final commit of the repository (it carries `image:`, `version` and a
   `PUBLICATION-STATUS` that still says `status: prepared`). The release tag `v<version>` will point
   at this commit.
2. Make the repository public and create the release `v<version>` at that commit with **every file
   of the verified asset directory attached, including `SHA256SUMS`** (step 4a). Do not make the
   package public before the assets are attached.
3. Make the package public: in the organization's Packages tab open the package, Package settings,
   Change visibility, Public. A first-published package is private and the Supervisor pulls
   anonymously, so customers cannot install until this is done. A public package cannot be made
   private again (per GitHub's documentation), so do this deliberately, only after the logged-in
   digest check in step 7 passed. The image's `org.opencontainers.image.source` label (already set
   in the Dockerfile) links the package to the repository on first push; confirm the link on the
   package page, or connect it in Package settings.

Then do the anonymous checks of steps 7 and 8.

## 7. Verify the pushed image from the registry

First, while still logged in and before any visibility change, compare the registry's digest with
what you pushed. `docker image inspect` on the local image prints an id that, with the containerd
image store, is the digest of the image index (BuildKit adds an attestation manifest, so the index
also lists a second entry); `docker push` prints the same digest. Record the index digest, the
linux/arm64 manifest digest and the image config digest:

```bash
docker buildx imagetools inspect ghcr.io/morsemicrolabs/home-assistant-halow:<version>
```

The top-level digest must equal the one the local image and `docker push` reported, and the
linux/arm64 entry must equal the local platform manifest digest. The Supervisor pulls the arm64
manifest through the index.

After step 6 (the package is public), repeat the check from a context that is not logged in, which
is what a customer's Supervisor sees:

```bash
docker logout ghcr.io
docker buildx imagetools inspect ghcr.io/morsemicrolabs/home-assistant-halow:<version>
docker pull --platform linux/arm64 ghcr.io/morsemicrolabs/home-assistant-halow:<version>
```

Record the version, the image id from step 2, the registry digest and the date in the release record.

## 8. Check and record the publication of the source assets

From a context without credentials, once the release is public:

```bash
tools/final_publication_check.sh
```

By default it downloads every asset (several hundred MB) and compares its SHA-256, and it checks that
`SHA256SUMS` is present with the content generated from the manifest. `--size-only` is a quick
check that never authorizes the next step. When the full check passes it prints two lines. Record
exactly those lines in `source-assets/PUBLICATION-STATUS` (replacing `status: prepared`):

```
status: published
manifest-sha256: <the SHA-256 of source-assets/ASSETS.psv that was checked>
```

Commit that change after the release (it is a later commit than the one the release tag points at; the
status file is not part of the image), then run the full gate
(`tools/final_release_gate.sh --assets /path/to/source-assets`): all fourteen gates must pass. Gate 14 also
checks that the recorded checksum is that of the current manifest, so a manifest changed after the
check blocks again. Until the check has passed, the status stays `prepared` and gate 14 BLOCKs, which is
the correct state before publication.

## 9. Only then

Push the Git change that carries `image:` and the final `version` (the tag must exist
and be pullable before that version is released), and keep the artifact bundle and SBOM
outputs with the release record.
