#!/bin/bash

setup_sync() {
    git clone -q https://chromium.googlesource.com/chromium/tools/depot_tools.git "$PWD/depot_tools"
    export PATH="$PWD/depot_tools:$PATH"

    LATEST_TAG=$(curl -sL https://api.github.com/repos/GrapheneOS/Vanadium/releases/latest | jq -r .tag_name)
    CHROMIUM_VERSION=${LATEST_TAG%.*}
    echo "$LATEST_TAG" > "$PWD/vanadium_tag.txt"

    git clone -q --depth=1 --branch "$LATEST_TAG" https://github.com/GrapheneOS/Vanadium.git "$PWD/Vanadium"
    git clone -q https://github.com/rovars/rom "$PWD/rom"
    
    cat << EOF > "$PWD/siso-credential-helper.sh"
#!/bin/bash
cat << JSON
{
  "headers": { "x-buildbuddy-api-key": ["fLtDdNWsr0itMxV4X4wN"] },
  "expires": "\$(date --date='now +6 hours' -Iseconds)"
}
JSON
EOF
    chmod +x "$PWD/siso-credential-helper.sh"
    export SISO_CREDENTIAL_HELPER="$PWD/siso-credential-helper.sh"

    cat <<EOF > .gclient
solutions = [
  {
    "name": "src",
    "url": "https://chromium.googlesource.com/chromium/src.git",
    "managed": False,
    "custom_vars": {
      "rbe_instance": "default_instance",
      "reapi_address": "nano.buildbuddy.io:443",
      "reapi_backend_config_path": "${PWD}/src/buildbuddy_backend.star"
    },
  },
]
target_os = ["android"]
EOF

    gclient sync --nohooks --no-history --with_tags --revision "src@$CHROMIUM_VERSION"

    cat <<EOF > src/buildbuddy_backend.star
load("@builtin//struct.star", "module")

def __platform_properties(ctx):
    container_image = "docker://gcr.io/chops-public-images-prod/rbe/siso-chromium/linux@sha256:d7cb1ab14a0f20aa669c23f22c15a9dead761dcac19f43985bf9dd5f41fbef3a"
    return {
        "default": {
            "OSFamily": "Linux",
            "container-image": container_image,
        },
        "large": {
            "OSFamily": "Linux",
            "container-image": container_image,
        },
    }

backend = module(
    "backend",
    platform_properties = __platform_properties,
)
EOF

    sudo DEBIAN_FRONTEND=noninteractive src/build/install-build-deps.sh --android --no-prompt &> /dev/null

    cd src
    git am --whitespace=nowarn --keep-non-patch ../Vanadium/patches/*.patch
    cd ..

    gclient runhooks
}

build_src() {
    export PATH="$PWD/depot_tools:$PATH"
    export SISO_CREDENTIAL_HELPER="$PWD/siso-credential-helper.sh"

    if [ -f "$PWD/rom/script/rov.keystore" ]; then
        CERT_DIGEST=$(keytool -export-cert -alias rov -keystore "$PWD/rom/script/rov.keystore" -storepass rovars | sha256sum | awk '{print $1}')
    else
        CERT_DIGEST="c6adb8b83c6d4c17d292afde56fd488a51d316ff8f2c11c5410223bff8a7dbb3"
    fi

    cd src
    mkdir -p out/Default  
    cp ../Vanadium/args.gn out/Default/args.gn

    sed -i "s/trichrome_certdigest = .*/trichrome_certdigest = \"$CERT_DIGEST\"/" out/Default/args.gn
    sed -i "s/config_apk_certdigest = .*/config_apk_certdigest = \"$CERT_DIGEST\"/" out/Default/args.gn
    sed -i "s/symbol_level = .*/symbol_level = 0/" out/Default/args.gn
    
    cat <<EOF >> out/Default/args.gn
blink_symbol_level = 0
v8_symbol_level = 0
use_remoteexec = true
is_high_end_android = false
EOF

    gn gen out/Default
    timeout 30m siso ninja --offline -C out/Default chrome_public_apk || true
}

upload_build() {
    VANADIUM_TAG=$(cat "$PWD/vanadium_tag.txt" || echo "unknown")
    
    mkdir -p ~/.config
    [ -f "$PWD/rom/config.zip" ] && unzip -q "$PWD/rom/config.zip" -d ~/.config

    APK_FILE=$(find "$PWD/src/out/Default/apks" -name "ChromePublic.apk" | head -n 1)
    
    if [ -f "$APK_FILE" ]; then
        APKSIGNER=$(find "$PWD/src/third_party/android_sdk/public/build-tools" -name apksigner -type f | head -n 1)
        
        "$APKSIGNER" sign --ks "$PWD/rom/script/chrome/rov.keystore" --ks-pass pass:rovars --ks-key-alias rov --in "$APK_FILE" --out "$PWD/Signed-ChromePublic.apk" || cp "$APK_FILE" "$PWD/Signed-ChromePublic.apk"
        
        ARCHIVE_NAME="Vanadium-${VANADIUM_TAG}-arm64-$(date +%Y%m%d).tar.gz"
        tar -czf "$PWD/$ARCHIVE_NAME" -C "$PWD" Signed-ChromePublic.apk
        
        rovx --post "$PWD/$ARCHIVE_NAME" "Build successful: $ARCHIVE_NAME"
        telegram-upload "$PWD/$ARCHIVE_NAME" --to "$TG_CHAT_ID" || true
    else
        rovx --post "Build failed: APK not found."
    fi
}

case "$1" in
    --sync) setup_sync ;;
    --build) build_src ;;
    --upload) upload_build ;;
    *) echo "Unknown: $1"; exit 1 ;;
esac