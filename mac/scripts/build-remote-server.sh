#!/bin/zsh
set -euo pipefail

ROOT_DIR="${SRCROOT}/.."
WORK_DIR="${TARGET_TEMP_DIR}/remote-server"
BUILD_DIR="${WORK_DIR}/source"
# Archives install the app outside BUILT_PRODUCTS_DIR; declare the real destination.
OUTPUT_DIR="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"
OUTPUT="${OUTPUT_DIR}/zshell-server"
export CARGO_TARGET_DIR="${WORK_DIR}/target"

for candidate in "${HOME}/.cargo/bin" /opt/homebrew/bin /usr/local/bin; do
  [[ -x "${candidate}/cargo" ]] && export PATH="${candidate}:${PATH}"
done
if command -v rustup >/dev/null 2>&1; then
  rustup_cargo="$(rustup which cargo)"
  export PATH="$(dirname "${rustup_cargo}"):${PATH}"
fi
if ! command -v cargo >/dev/null 2>&1; then
  echo "error: cargo is required to bundle zshell-server." >&2
  exit 1
fi

mkdir -p "${BUILD_DIR}/remote" "${BUILD_DIR}/mac/Vendor/alacritty-bridge" "${BUILD_DIR}/mac/zshell/ThirdPartyNotices" "${OUTPUT_DIR}"
cp "${ROOT_DIR}/remote/Cargo.toml" "${ROOT_DIR}/remote/Cargo.lock" "${BUILD_DIR}/remote/"
cp "${ROOT_DIR}/remote/build.rs" "${BUILD_DIR}/remote/"
mkdir -p "${BUILD_DIR}/mac/zshell/ShellIntegration"
rm -rf "${BUILD_DIR}/mac/zshell/ShellIntegration/TerminalCompletions"
cp -R "${SRCROOT}/zshell/ShellIntegration/TerminalCompletions" "${BUILD_DIR}/mac/zshell/ShellIntegration/"
cp "${SRCROOT}/Vendor/alacritty-bridge/Cargo.toml" "${SRCROOT}/Vendor/alacritty-bridge/Cargo.lock" "${BUILD_DIR}/mac/Vendor/alacritty-bridge/"
cp "${SRCROOT}/zshell/ThirdPartyNotices/Kero.txt" "${BUILD_DIR}/mac/zshell/ThirdPartyNotices/"
mkdir -p "${BUILD_DIR}/mac/zshell/AgentIntegrations/opencode" "${BUILD_DIR}/mac/zshell/AgentIntegrations/pi"
cp "${SRCROOT}/zshell/AgentIntegrations/opencode/zshell-agent-state.js" "${SRCROOT}/zshell/AgentIntegrations/opencode/zshell-conversation-tui.js" "${BUILD_DIR}/mac/zshell/AgentIntegrations/opencode/"
cp "${SRCROOT}/zshell/AgentIntegrations/pi/zshell-agent-state.pi.txt" "${BUILD_DIR}/mac/zshell/AgentIntegrations/pi/"
rm -rf "${BUILD_DIR}/remote/src" "${BUILD_DIR}/mac/Vendor/alacritty-bridge/src"
cp -R "${ROOT_DIR}/remote/src" "${BUILD_DIR}/remote/src"
cp -R "${SRCROOT}/Vendor/alacritty-bridge/src" "${BUILD_DIR}/mac/Vendor/alacritty-bridge/src"

slices=()
for arch in ${=ARCHS}; do
  case "${arch}" in
    arm64) target="aarch64-apple-darwin" ;;
    x86_64) target="x86_64-apple-darwin" ;;
    *) echo "error: unsupported server architecture ${arch}" >&2; exit 1 ;;
  esac
  cargo build --release --locked --manifest-path "${BUILD_DIR}/remote/Cargo.toml" --target "${target}"
  slices+=("${CARGO_TARGET_DIR}/${target}/release/zshell-server")
done
if [[ ${#slices[@]} -eq 1 ]]; then cp "${slices[1]}" "${OUTPUT}"
else lipo -create "${slices[@]}" -output "${OUTPUT}"; fi
chmod 755 "${OUTPUT}"
if [[ "${CODE_SIGNING_ALLOWED:-NO}" = YES && -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]]; then
  /usr/bin/codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY}" --options runtime "${OUTPUT}"
fi
