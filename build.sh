#!/bin/bash

set -ex

ROOT_DIR="$(pwd)"
git config --global user.email "133272416+bimuafaq@users.noreply.github.com"
git config --global user.name "bimuafaq"
git config --global --add safe.directory "*"

VANADIUM_TAG=$(git ls-remote --tags --sort="v:refname" https://github.com/GrapheneOS/Vanadium.git | tail -n1 | sed 's/.*\///; s/\^{}//')
CHROMIUM_VERSION=$(echo "$VANADIUM_TAG" | cut -d'.' -f1-4)

[ ! -d "src" ] && fetch --nohooks --no-history android

cd src
bun_dir="out/Default"
./build/install-build-deps.sh --android --no-prompt &> /dev/null
git fetch --depth=1 origin "refs/tags/$CHROMIUM_VERSION:refs/tags/$CHROMIUM_VERSION"
git checkout "$CHROMIUM_VERSION"

[ -d "$ROOT_DIR/Vanadium_repo" ] && rm -rf "$ROOT_DIR/Vanadium_repo"
git clone -q --depth=1 https://github.com/GrapheneOS/Vanadium.git -b "$VANADIUM_TAG" "$ROOT_DIR/Vanadium_repo"
git am --whitespace=nowarn --keep-non-patch "$ROOT_DIR/Vanadium_repo/patches/"*.patch
gclient sync -D --no-history --jobs 8

cat << EOF > "$ROOT_DIR/siso-credential-helper.sh"
#!/bin/bash
cat << JSON
{
  "headers": { "x-buildbuddy-api-key": ["$BUILDBUDDY_API_KEY"] },
  "expires": "$(date --date='now +6 hours' -Iseconds)"
}
JSON
EOF
chmod +x "$ROOT_DIR/siso-credential-helper.sh"
export SISO_CREDENTIAL_HELPER="$ROOT_DIR/siso-credential-helper.sh"

rm -rf "$bun_dir"
mkdir -p "$bun_dir"
cp "$ROOT_DIR/Vanadium_repo/args.gn" "$bun_dir/args.gn"

CERT_DIGEST="c6adb8b83c6d4c17d292afde56fd488a51d316ff8f2c11c5410223bff8a7dbb3"
[ -f "$ROOT_DIR/rom/script/rov.keystore" ] && CERT_DIGEST=$(keytool -export-cert -alias rov -keystore "$ROOT_DIR/rom/script/rov.keystore" -storepass rovars | sha256sum | cut -d' ' -f1)

sed -i "s/trichrome_certdigest = .*/trichrome_certdigest = \"$CERT_DIGEST\"/" "$bun_dir/args.gn"
sed -i "s/config_apk_certdigest = .*/config_apk_certdigest = \"$CERT_DIGEST\"/" "$bun_dir/args.gn"

cat <<EOF >> "$bun_dir/args.gn"
use_remoteexec = true
blink_symbol_level = 0
v8_symbol_level = 0
EOF

gn gen "$bun_dir"

mkdir -p out/x "$bun_dir/x"

for i in {1..10}; do
  if siso ninja -C "$bun_dir" -reapi_address=nano.buildbuddy.io:443 -reapi_instance=default chrome_public_apk; then
    break
  else
    if [ $i -eq 10 ]; then
      exit 1
    fi
    timeout 3m bash "$bun_dir/siso_failed_commands.sh" || true
  fi
done

mkdir -p ~/.config
[ -f "$ROOT_DIR/rom/config.zip" ] && unzip -q "$ROOT_DIR/rom/config.zip" -d ~/.config

cd "$bun_dir/apks"
APKSIGNER=$(find ../../../third_party/android_sdk/public/build-tools -name apksigner -type f | head -n 1)
ARCHIVE_CONTENT="*.apk"
if [ -f "$ROOT_DIR/rom/script/rov.keystore" ]; then
    for apk in ChromePublic.apk; do
        [ -f "$apk" ] && "$APKSIGNER" sign --ks "$ROOT_DIR/rom/script/rov.keystore" --ks-pass pass:rovars --ks-key-alias rov --in "$apk" --out "Signed-$apk"
    done
    ARCHIVE_CONTENT="Signed-*.apk"
fi

ARCHIVE_FILE="Vanadium-${VANADIUM_TAG}-arm64-$(date +%Y%m%d).tar.gz"
tar -czf "$ROOT_DIR/$ARCHIVE_FILE" $ARCHIVE_CONTENT

cd "$ROOT_DIR"
if command -v telegram-upload &> /dev/null && [ -n "$TG_CHAT_ID" ]; then
    export PARALLEL_UPLOAD_BLOCKS=2
    timeout 15m telegram-upload "$ARCHIVE_FILE" --to "$TG_CHAT_ID"
fi