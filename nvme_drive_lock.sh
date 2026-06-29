#!/bin/bash

set -e

usage() {
    echo "Usage: $0 --encrypt /dev/sgX | --decrypt /dev/sgX | --msid /dev/sgX | --secure-erase /dev/sgX | --all /dev/sgX"
    echo ""
    echo "  --encrypt /dev/sgX      Lock the drive"
    echo "  --decrypt /dev/sgX      Unlock the drive"
    echo "  --msid /dev/sgX         Print the MSID (default password) of the drive"
    echo "  --secure-erase /dev/sgX          Securely erase the locking range (prompts for confirmation)"
    echo "  --secure-erase /dev/sgX --batch  Securely erase without confirmation prompt"
    echo "  --status /dev/sgX                Show lock status of the drive"
    echo "  --all /dev/sgX                   Print MSID, encrypt, then decrypt the drive"
    exit 1
}

get_msid() {
    local DEVICE="$1"
    sedutil-cli -n --printdefaultpassword "$DEVICE" 2>/dev/null | grep -oP "(?<=MSID: )\S+"
}

encrypt_drive() {
    local DEVICE="$1"
    local MSID
    MSID=$(get_msid "$DEVICE")

    if [[ -z "$MSID" ]]; then
        echo "Error: could not retrieve MSID for $DEVICE"
        exit 1
    fi

    echo "Using MSID: $MSID"

    CURRENT=$(sedutil-cli -n --query "$DEVICE" 2>/dev/null)
    LOCK_ENABLED=$(echo "$CURRENT" | grep -oP "(?<=LockingEnabled = )\w" || true)

    if [[ "$LOCK_ENABLED" != "Y" ]]; then
        echo ""
        echo "=== [ENCRYPT] Step 1: Initial setup on $DEVICE ==="
        sedutil-cli -n --initialsetup "test" "$DEVICE"
    else
        echo ""
        echo "=== [ENCRYPT] Step 1: Drive already initialized — skipping initial setup ==="
    fi

    echo ""
    echo "=== [ENCRYPT] Step 2: Enable locking range ==="
    sedutil-cli -n --enablelockingrange 0 "test" "$DEVICE"

    echo ""
    echo "=== [ENCRYPT] Step 3: Set locking range ==="
    sedutil-cli -n --setlockingrange 0 LK "test" "$DEVICE"

    echo ""
    echo "=== [ENCRYPT] Step 4: Verifying lock status ==="
    QUERY_OUTPUT=$(sedutil-cli -n --query "$DEVICE")
    echo "$QUERY_OUTPUT"

    LOCKED=$(echo "$QUERY_OUTPUT" | grep -oP "(?<=Locked = )\w" || true)
    LOCK_ENABLED=$(echo "$QUERY_OUTPUT" | grep -oP "(?<=LockingEnabled = )\w" || true)

    if [[ "$LOCKED" == "Y" && "$LOCK_ENABLED" == "Y" ]]; then
        echo "SUCCESS: Drive $DEVICE is locked (Locked = Y, LockingEnabled = Y)"
    else
        echo "WARNING: Lock verification failed (Locked = $LOCKED, LockingEnabled = $LOCK_ENABLED)."
        exit 1
    fi
}

decrypt_drive() {
    local DEVICE="$1"
    local MSID
    MSID=$(get_msid "$DEVICE")

    if [[ -z "$MSID" ]]; then
        echo "Error: could not retrieve MSID for $DEVICE"
        exit 1
    fi

    echo "Using MSID: $MSID"

    echo ""
    echo "=== [DECRYPT] Step 1: Set locking range to RW ==="
    sedutil-cli -n --setlockingrange 0 RW "test" "$DEVICE"

    echo ""
    echo "=== [DECRYPT] Step 2: Disable locking range ==="
    sedutil-cli -n --disablelockingrange 0 "test" "$DEVICE"
    sedutil-cli --revertnoerase test "$DEVICE"

    echo ""
    echo "=== [DECRYPT] Step 3: Verifying unlock status ==="
    QUERY_OUTPUT=$(sedutil-cli -n --query "$DEVICE")
    echo "$QUERY_OUTPUT"

    LOCKED=$(echo "$QUERY_OUTPUT" | grep -oP "(?<=Locked = )\w" || true)

    if [[ "$LOCKED" == "N" ]]; then
        echo "SUCCESS: Drive $DEVICE is unlocked (Locked = N)"
    else
        echo "WARNING: Unlock verification failed (Locked = $LOCKED)."
        exit 1
    fi
}

secure_erase_drive() {
    local DEVICE="$1"
    local BATCH="$2"
    local MSID
    MSID=$(get_msid "$DEVICE")

    if [[ -z "$MSID" ]]; then
        echo "Error: could not retrieve MSID for $DEVICE"
        exit 1
    fi

    echo "Using MSID: $MSID"

    if [[ "$BATCH" != "--batch" ]]; then
        echo ""
        echo "WARNING: This will permanently erase ALL data on $DEVICE!"
        read -rp "Are you sure you want to continue? [yes/N]: " CONFIRM
        if [[ "$CONFIRM" != "yes" ]]; then
            echo "Aborted."
            exit 0
        fi
    fi

    echo ""
    echo "=== [SECURE ERASE] Erasing locking range on $DEVICE ==="
    sedutil-cli --revertTPer test "$DEVICE"
    echo "SUCCESS: Locking range erased on $DEVICE"
}

show_status() {
    local DEVICE="$1"
    echo ""
    echo "=== [STATUS] Lock status for $DEVICE ==="
    QUERY_OUTPUT=$(sedutil-cli -n --query "$DEVICE" 2>/dev/null)

    LOCKED=$(echo "$QUERY_OUTPUT" | grep -oP "(?<=Locked = )\w" || true)
    LOCK_ENABLED=$(echo "$QUERY_OUTPUT" | grep -oP "(?<=LockingEnabled = )\w" || true)

    echo "Locked         = $LOCKED"
    echo "LockingEnabled = $LOCK_ENABLED"
}

print_msid() {
    local DEVICE="$1"
    echo ""
    echo "=== [MSID] Printing default password for $DEVICE ==="
    sedutil-cli -n --printdefaultpassword "$DEVICE"
}

[[ $# -lt 2 ]] && usage

FLAG="$1"
DEVICE="$2"

if [[ ! -e "$DEVICE" ]]; then
    echo "Error: device $DEVICE not found."
    exit 1
fi

case "$FLAG" in
    --encrypt)
        encrypt_drive "$DEVICE"
        ;;
    --decrypt)
        decrypt_drive "$DEVICE"
        ;;
    --msid)
        print_msid "$DEVICE"
        ;;
    --secure-erase)
        secure_erase_drive "$DEVICE" "$3"
        ;;
    --status)
        show_status "$DEVICE"
        ;;
    --all)
        print_msid "$DEVICE"
        encrypt_drive "$DEVICE"
        decrypt_drive "$DEVICE"
        ;;
    *)
        usage
        ;;
esac
