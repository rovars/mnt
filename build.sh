#!/bin/bash

set -ex

ROOT_DIR="$(pwd)"
BUILD_DIR="$ROOT_DIR/chromium"
bun_dir="out/Default"

export PATH="/opt/depot_tools:$PATH"
export DEPOT_TOOLS_UPDATE=1
export GCLIENT_SUPPRESS_GIT_VERSION_WARNING=1

if [ -z "$RBE_API_KEY" ]; then
    echo "ERROR: RBE_API_KEY not set."
    exit 1
fi

cat > "$ROOT_DIR/siso_helper.sh" << EOF
#!/bin/bash
echo '{"headers": {"x-buildbuddy-api-key": ["$RBE_API_KEY"]}, "token": "dummy"}'
EOF
chmod +x "$ROOT_DIR/siso_helper.sh"

export SISO_PROFILER=1
export SISO_CREDENTIAL_HELPER="$ROOT_DIR/siso_helper.sh"
export SISO_FALLBACK=true
export SISO_ARGS="-reapi_keep_exec_stream -fs_min_flush_timeout 300s"

VANADIUM_TAG=$(git ls-remote --tags --sort="v:refname" https://github.com/GrapheneOS/Vanadium.git | tail -n1 | sed 's/.*\///; s/\^{}//')
CHROMIUM_VERSION=$(echo "$VANADIUM_TAG" | cut -d'.' -f1-4)

mkdir -p "$BUILD_DIR" && cd "$BUILD_DIR"

if [ ! -d "src" ]; then
    fetch --nohooks --no-history android
fi

cd src
./build/install-build-deps.sh --android --no-prompt

git fetch --depth=1 origin "refs/tags/$CHROMIUM_VERSION:refs/tags/$CHROMIUM_VERSION"
git checkout "$CHROMIUM_VERSION"

cat > ../.gclient << EOF
solutions = [
  {
    "name": "src",
    "url": "https://chromium.googlesource.com/chromium/src.git",
    "managed": False,
    "custom_deps": {},
    "custom_vars": {
      "reapi_instance": "default",
      "reapi_address": "nano.buildbuddy.io:443",
      "reapi_backend_config_path": "google.star"
    },
  },
]
target_os = ["android"]
EOF

[ -d "$ROOT_DIR/Vanadium_repo" ] && rm -rf "$ROOT_DIR/Vanadium_repo"
git clone -q --depth=1 https://github.com/GrapheneOS/Vanadium.git -b "$VANADIUM_TAG" "$ROOT_DIR/Vanadium_repo"

git am --whitespace=nowarn --keep-non-patch "$ROOT_DIR/Vanadium_repo/patches/"*.patch

gclient sync -D --no-history --jobs 8

mkdir -p "$bun_dir"
cp "$ROOT_DIR/Vanadium_repo/args.gn" "$bun_dir/args.gn"

KEYSTORE="$ROOT_DIR/rom/script/rov.keystore"
if [ -f "$KEYSTORE" ]; then
    CERT_DIGEST=$(keytool -export-cert -alias rov -keystore "$KEYSTORE" -storepass rovars | sha256sum | cut -d' ' -f1)
else
    CERT_DIGEST="c6adb8b83c6d4c17d292afde56fd488a51d316ff8f2c11c5410223bff8a7dbb3"
fi

sed -i "s/trichrome_certdigest = .*/trichrome_certdigest = \"$CERT_DIGEST\"/" "$bun_dir/args.gn"
sed -i "s/config_apk_certdigest = .*/config_apk_certdigest = \"$CERT_DIGEST\"/" "$bun_dir/args.gn"

{
    echo "use_remoteexec = true"
    echo "symbol_level = 0"
    echo "blink_symbol_level = 0"
    echo "v8_symbol_level = 0"
} >> "$bun_dir/args.gn"

gn gen "$bun_dir"

chrt -b 0 autoninja -C "$bun_dir" chrome_public_apk

mkdir -p ~/.config
[ -d "$ROOT_DIR/rom" ] && [ -f "$ROOT_DIR/rom/config.zip" ] && unzip -q "$ROOT_DIR/rom/config.zip" -d ~/.config

cd "$bun_dir/apks"
APKSIGNER=$(find ../../../third_party/android_sdk/public/build-tools -name apksigner -type f | head -n 1)
if [ -f "$KEYSTORE" ]; then
    for apk in ChromePublic.apk; do
        [ -f "$apk" ] && "$APKSIGNER" sign --ks "$KEYSTORE" --ks-pass pass:rovars --ks-key-alias rov --in "$apk" --out "Signed-$apk"
    done
    ARCHIVE_CONTENT="Signed-*.apk"
else
    ARCHIVE_CONTENT="*.apk"
fi

ARCHIVE_FILE="Vanadium-${VANADIUM_TAG}-arm64-$(date +%Y%m%d).tar.gz"
tar -czf "$ROOT_DIR/$ARCHIVE_FILE" $ARCHIVE_CONTENT

cd "$ROOT_DIR"
if command -v telegram-upload &> /dev/null && [ -n "$TG_CHAT_ID" ]; then
    export PARALLEL_UPLOAD_BLOCKS=2
    timeout 15m telegram-upload "$ARCHIVE_FILE" --to "$TG_CHAT_ID"
fi
