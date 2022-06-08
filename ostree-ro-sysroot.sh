#!/bin/bash

# Update an existing system to use a read only sysroot
# See https://fedoraproject.org/wiki/Changes/Silverblue_Kinoite_readonly_sysroot
# and https://bugzilla.redhat.com/show_bug.cgi?id=2060976

set -euo pipefail
# TODO: Remove me once ready
set -x

# $ sudo rpm-ostree kargs --append-if-missing=rw
# $ sudo ostree config --repo=/sysroot/ostree/repo set "sysroot.readonly" "true"
# $ sudo systemctl reboot

main() {
    # Used to condfition execution of this unit at the systemd level
    local -r stamp_file="/var/lib/.ostree_sysroot_readonly"

    if [[ -f "${stamp_file}" ]]; then
        exit 0
    fi

    local -r ostree_sysroot_readonly="$(ostree config --repo=/sysroot/ostree/repo get "sysroot.readonly" &> /dev/null || echo "false")"
    if [[ "${ostree_sysroot_readonly}" == "true" ]]; then
        # Nothing to do
        touch "${stamp_file}"
        exit 0
    fi

    local -r boot_entries="$(ls -A /boot/loader/entries/ | wc -l)"

    # Ensure that we can read BLS entries to avoid touching systems where /boot
    # is not mounted
    if [[ "${boot_entries}" -eq 0 ]]; then
        echo "No BLS entry found: Maybe /boot is not mounted?" 1>&2
        echo "This is unexpected thus no migration wil be performed" 1>&2
        touch "${stamp_file}"
        exit 0
    fi

    # Check if any existing deployment is still missing the rw karg
    local rw_kargs_found=0
    local count=0
    for f in "/boot/loader/entries/"*; do
        count="$(grep -c "^options .* rw" "${f}" || true)"
        if [[ "${count}" -ge 1 ]]; then
            rw_kargs_found=$((rw_kargs_found + 1))
        fi
    done

    # Some deployments are still missing the rw karg. Let's try to update them
    if [[ "${boot_entries}" -ne "${rw_kargs_found}" ]]; then
        # TODO: Use https://github.com/ostreedev/ostree/issues/2617 instead to
        # better handle errors and corner cases
        for f in "/boot/loader/entries/"*; do
            count="$(grep -c "^options .* rw" "${f}" || true)"
            if [[ "${count}" -eq 0 ]]; then
                echo "Appending 'rw' karg to boot entry: '${f}'"
                # Skip this entry if anything fails here
                cp "${f}" "${f}.tmp" || continue
                sed -i '/^options/ s/$/ rw/' "${f}.tmp" || continue
                mv "${f}.tmp" "${f}" || continue
            fi
        done
    fi

    # Re-check if any existing deployment is still missing the rw karg
    rw_kargs_found=0
    count=0
    for f in "/boot/loader/entries/"*; do
        count="$(grep -c "^options .* rw" "${f}" || true)"
        if [[ "${count}" -ge 1 ]]; then
            rw_kargs_found=$((rw_kargs_found + 1))
        fi
    done
    unset count

    # If all deployments are good, then we can set the sysroot.readonly option
    # in the ostree repo config
    if [[ "${boot_entries}" -eq "${rw_kargs_found}" ]]; then
        echo "Setting up the sysroot.readonly option in the ostree repo config"
        ostree config --repo=/sysroot/ostree/repo set "sysroot.readonly" "true"
        touch "${stamp_file}"
        exit 0
    fi

    # If anything else before failed, we will retry on next boot
    exit 0
}

main "${@}"
