#!/usr/bin/env bash

setup_src() {
    repo init -u https://github.com/LineageOS/android.git -b lineage-18.1 --groups=all,-notdefault,-darwin,-mips --git-lfs --depth=1
    git clone -q https://github.com/rovars/rom "$PWD/rox"
    mkdir -p "$PWD/.repo/local_manifests/"
    cp -r "$PWD/rox/script/device.xml" "$PWD/.repo/local_manifests/"

    repo sync -j8 -c --no-clone-bundle --no-tags

    # patch -p1 < "$PWD/rox/script/sepolicy.patch"
    patch -p1 < "$PWD/rox/script/core.patch"
    source "$PWD/rox/script/constify.sh"

    git clone https://github.com/bimuafaq/android_vendor_extra vendor/extra

    #rm -rf kernel/realme/RMX2185
    #git clone https://github.com/rovars/kernel_realme_RMX2185 kernel/realme/RMX2185 --depth=5
    #cd kernel/realme/RMX2185
    #git reset --hard HEAD~3
    #cd -   
}

build_src() {
    source "$PWD/build/envsetup.sh"
    # source rovx --ccache

    export OWN_KEYS_DIR="$PWD/rox/keys"
    sudo ln -sf "$OWN_KEYS_DIR/releasekey.pk8" "$OWN_KEYS_DIR/testkey.pk8"
    sudo ln -sf "$OWN_KEYS_DIR/releasekey.x509.pem" "$OWN_KEYS_DIR/testkey.x509.pem"

    export KBUILD_BUILD_USER="nobody"
    export KBUILD_BUILD_HOST="android-build"
    export BUILD_USERNAME="nobody"
    export BUILD_HOSTNAME="android-build"

    lunch lineage_RMX2185-userdebug
    #source "$PWD/rox/script/mmm.sh" icons
    #chmod +x "$PWD/rox/script/fix.sh"
    #source "$PWD/rox/script/fix.sh" || exit 1
    mka bacon
    #mka selinux_policy
}

upload_build() {
    local release_file=$(find "$PWD/out/target/product/RMX2185" -maxdepth 1 -name "*-RMX*.zip" -print -quit)
    local release_name=$(basename "$release_file" .zip)
    local release_tag=$(date +%Y%m%d)
    local repo_releases="bimuafaq/releases"
    local UPLOAD_GH=false
    
    if [[ -n "$release_file" && -f "$release_file" ]]; then
        if [[ "${UPLOAD_GH}" == "true" && -n "$GITHUB_TOKEN" ]]; then
            echo "$GITHUB_TOKEN" > rox.txt
            gh auth login --with-token < rox.txt
            rovx --post "Uploading to GitHub Releases..."
            gh release create "$release_tag" -t "$release_name" -R "$repo_releases" -F "$PWD/rox/script/notes.txt" || true

            if gh release upload "$release_tag" "$release_file" -R "$repo_releases" --clobber; then
                rovx --post "GitHub Release upload successful: <a href='https://github.com/$repo_releases/releases/tag/$release_tag'>$release_name</a>"
            else
                rovx --post "GitHub Release upload failed"
            fi
        fi

        mkdir -p ~/.config
        unzip -q "$PWD/rox/config.zip" -d ~/.config
        rovx --post "Uploading build result to Telegram..."
        timeout 15m telegram-upload "$release_file" --to "$TG_CHAT_ID" --caption "$CIRRUS_COMMIT_MESSAGE"
    else
        rovx --post "Build file not found for upload"
        exit 0
    fi
}

case "$1" in
    --sync) setup_src ;;
    --build) build_src ;;
    --upload) upload_build ;;
    *) echo "Unknown: $1"; exit 1 ;;
esac