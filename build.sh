#!/bin/bash

set -ex

ROOT_DIR="$(pwd)"
ROM_REPO_DIR="$ROOT_DIR/rom"

cat > "$ROOT_DIR/siso_helper.sh" << 'EOF'
#!/bin/bash
cat << HELPER
{
  "headers": {
    "x-buildbuddy-api-key": ["${RBE_API_KEY}"]
  },
  "token": "dummy"
}
HELPER
EOF
chmod +x "$ROOT_DIR/siso_helper.sh"

if [ -z "$RBE_API_KEY" ]; then
  echo "ERROR: RBE_API_KEY not set. Please export it in your environment."
  exit 1
fi

export SISO_PROFILER=1
export SISO_CREDENTIAL_HELPER="$ROOT_DIR/siso_helper.sh"
export SISO_FALLBACK=true
export SISO_ARGS="-reapi_keep_exec_stream -fs_min_flush_timeout 300s"

export DEPOT_TOOLS_UPDATE=1
export GCLIENT_SUPPRESS_GIT_VERSION_WARNING=1
export PATH="$ROOT_DIR/depot_tools:$PATH"

git clone -q --depth=1 https://chromium.googlesource.com/chromium/tools/depot_tools.git "$ROOT_DIR/depot_tools"

VANADIUM_TAG=$(git ls-remote --tags --sort="v:refname" https://github.com/GrapheneOS/Vanadium.git | tail -n1 | sed 's/.*\///; s/\^{}//')
git clone -q --depth=1 https://github.com/GrapheneOS/Vanadium.git -b "$VANADIUM_TAG" "$ROOT_DIR/Vanadium"
cd "$ROOT_DIR/Vanadium"

cat > .gclient << EOF
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

gclient sync --nohooks --no-history

cd src
CHROMIUM_VERSION=$(echo "$VANADIUM_TAG" | cut -d'.' -f1-4)
git fetch --depth=1 origin "refs/tags/$CHROMIUM_VERSION:refs/tags/$CHROMIUM_VERSION"
git checkout "$CHROMIUM_VERSION"

gclient sync -D --nohooks --no-history -j 8
git am --3way --whitespace=nowarn --keep-non-patch ../patches/*.patch
gclient runhooks

SCRIPT_DIR="$ROM_REPO_DIR/script/chromium"
if [ -f "$SCRIPT_DIR/rov.keystore" ]; then
    CERT_DIGEST=$(keytool -export-cert -alias rov -keystore "$SCRIPT_DIR/rov.keystore" -storepass rovars | sha256sum | cut -d' ' -f1)
else
    CERT_DIGEST="000000"
fi

BUILD_DIR="out/Default"
mkdir -p "$BUILD_DIR"

cp ../args.gn "$BUILD_DIR/args.gn"

sed -i "s/trichrome_certdigest = .*/trichrome_certdigest = \"$CERT_DIGEST\"/" "$BUILD_DIR/args.gn"
sed -i "s/config_apk_certdigest = .*/config_apk_certdigest = \"$CERT_DIGEST\"/" "$BUILD_DIR/args.gn"

echo "use_remoteexec=true" >> "$BUILD_DIR/args.gn"
echo "use_reclient=false" >> "$BUILD_DIR/args.gn"

echo 'symbol_level = 0' >> "$BUILD_DIR/args.gn"
echo 'blink_symbol_level = 0' >> "$BUILD_DIR/args.gn"
echo 'v8_symbol_level = 0' >> "$BUILD_DIR/args.gn"
echo 'optimize_for_size = true' >> "$BUILD_DIR/args.gn"
echo 'dcheck_always_on = false' >> "$BUILD_DIR/args.gn"
echo 'enable_iterator_debugging = false' >> "$BUILD_DIR/args.gn"
echo 'exclude_unwind_tables = true' >> "$BUILD_DIR/args.gn"
echo 'enable_gdbinit = false' >> "$BUILD_DIR/args.gn"

gn gen "$BUILD_DIR"

chrt -b 0 autoninja -C "$BUILD_DIR" chrome_public_apk

mkdir -p ~/.config
[ -f "$ROM_REPO_DIR/config.zip" ] && unzip -q "$ROM_REPO_DIR/config.zip" -d ~/.config

cd "$BUILD_DIR/apks"
APKSIGNER=$(find ../../../third_party/android_sdk/public/build-tools -name apksigner -type f | head -n 1)

if [ -f "$SCRIPT_DIR/rov.keystore" ]; then
    for apk in ChromePublic.apk; do
        if [ -f "$apk" ]; then
            "$APKSIGNER" sign --ks "$SCRIPT_DIR/rov.keystore" --ks-pass pass:rovars --ks-key-alias rov --in "$apk" --out "Signed-$apk"
        fi
    done
    ARCHIVE_CONTENT="Signed-*.apk"
else
    ARCHIVE_CONTENT="*.apk"
fi

ARCHIVE_FILE="Vanadium-${VANADIUM_TAG}-arm64-$(date +%Y%m%d).tar.gz"
tar -czf "$ROOT_DIR/$ARCHIVE_FILE" $ARCHIVE_CONTENT

cd "$ROOT_DIR"
timeout 15m telegram-upload "$ARCHIVE_FILE" --to "$TG_CHAT_ID"
