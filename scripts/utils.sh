export KERNEL_VER="$(uname -r)"
export PACKAGE_DIR="$GOW_PLUGIN/packages"

function pkg_name() {
    local package_name=$1
    if [[ $package_name == kernel/* ]]; then
        # strip the namespace
        package_name=${package_name/kernel\//}
        # add the kernel version
        package_name="$package_name-$KERNEL_VER"
    else
        # remove namespace names for everything else. since bash regexes don't
        # support lookbehind, it's easiest to just list the (currently 2) known
        # namespaces.
        package_name=${package_name/common\//}
        package_name=${package_name/nvidia\//}
    fi

    echo "$package_name"
}

# TODO: need to get the version in here somewhere for non-kernel packages
function pkg_file() {
    local package_name=$(pkg_name "$1")

    echo "$PACKAGE_DIR/$package_name.txz"
}

function pkg_url() {
    local name=$1
    local package_name=$(pkg_name "$name")

    if [[ $name == kernel/* ]]; then
        echo "$GOW_GITMODRELEASEURL/$package_name.txz"
    else
        echo "$GOW_GITRELEASEURL/$package_name.txz"
    fi
}

function download_file() {
    local url=$1
    local file=$2
    local allow_no_hash=${3:-false}

    if wget -q -nc --show-progress --progress=bar:force:noscroll -O "$file" "$url"; then
        # try to get the sha256 sum
        local sha_sum=$(wget -qO- "$url.sha256" | cut -d ' ' -f1)
        if [ ! -z "$sha_sum" ]; then
            echo "INFO: using sha256 sum"
            if [ "$(sha256sum "$file" | cut -d ' ' -f1)" != "$sha_sum" ]; then
                echo "ERROR: Checksum (sha256) mismatch for $url"
                return 1
            fi
        else
            # try to get the md5 sum
            local md5_sum=$(wget -qO- "$url.md5" | cut -d ' ' -f1)
            if [ ! -z "$md5_sum" ]; then
                echo "INFO: using md5 sum"
                if [ "$(md5sum "$file" | cut -d ' ' -f1)" != "$md5_sum" ]; then
                    echo "ERROR: Checksum (md5) mismatch for $url"
                    return 1
                fi
            elif [[ "$allow_no_hash" = "false" ]]; then
                # couldn't verify the hash and we're not allowing install without a matching hash; fail the install
                echo "ERROR: unable to verify hash for $url"
                return 1
            fi
        fi
    else
        echo "ERROR: Unable to download $url ($?)"
        return 1
    fi
}

function download_pkg() {
    local package_file=$(pkg_file "$1")
    local package_url=$(pkg_url "$1")

    download_file "$package_url" "$package_file"
}
