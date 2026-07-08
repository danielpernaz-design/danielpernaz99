#!/bin/bash
#
# Celestica Nebula JBOF ESM firmware downgrade/upgrade cycle test.
#
# Each cycle: downgrade both ESMs to 3.2.0.18 (3002), validate, then
# upgrade both ESMs to 5.2.2.18 (0522), validate. A cycle only proceeds
# to the next step if ESM count, ESM firmware revision, ESM relative-ID
# mapping, and NVMe drive count all match expectations. Any mismatch
# stops the test immediately with diagnostic output.

set -uo pipefail

DOWNGRADE_FW_DEFAULT="se4200_3.0.2.18__ses_osa.fw"
UPGRADE_FW_DEFAULT="se4200_ses_5.2.2.18-cls.fw"
DOWNGRADE_REV="3002"
UPGRADE_REV="0522"
RESET_DIAG_BYTES="10,00,00,09,00,01,72,65,73,65,74,20,31"
POST_RESET_SLEEP=40
MICROCODE_BPW=3072

DOWNGRADE_FW="$DOWNGRADE_FW_DEFAULT"
UPGRADE_FW="$UPGRADE_FW_DEFAULT"
ITERATIONS=""

usage() {
    echo "Usage: $0 [-n ITERATIONS] [-d DOWNGRADE_FW_FILE] [-u UPGRADE_FW_FILE]"
    echo ""
    echo "  -n ITERATIONS         Number of downgrade->upgrade cycles to run."
    echo "                        If omitted, you will be prompted."
    echo "  -d DOWNGRADE_FW_FILE  Path to the $DOWNGRADE_REV firmware file"
    echo "                        (default: $DOWNGRADE_FW_DEFAULT)"
    echo "  -u UPGRADE_FW_FILE    Path to the $UPGRADE_REV firmware file"
    echo "                        (default: $UPGRADE_FW_DEFAULT)"
    exit 1
}

while getopts "n:d:u:h" opt; do
    case "$opt" in
        n) ITERATIONS="$OPTARG" ;;
        d) DOWNGRADE_FW="$OPTARG" ;;
        u) UPGRADE_FW="$OPTARG" ;;
        h|*) usage ;;
    esac
done

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

fail() {
    echo "FAIL: $*"
}

for tool in lsscsi sg_ses sg_ses_microcode sg_senddiag; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "Error: required tool '$tool' not found in PATH."
        exit 1
    fi
done

if [[ -z "$ITERATIONS" ]]; then
    read -rp "Enter number of downgrade->upgrade cycles to run: " ITERATIONS
fi

if ! [[ "$ITERATIONS" =~ ^[0-9]+$ ]] || [[ "$ITERATIONS" -lt 1 ]]; then
    echo "Error: iterations must be a positive integer (got '$ITERATIONS')."
    exit 1
fi

for f in "$DOWNGRADE_FW" "$UPGRADE_FW"; do
    if [[ ! -f "$f" ]]; then
        echo "Error: firmware file not found: $f"
        exit 1
    fi
done

# Populates ESM_DEVICES / ESM_REVS / ESM_COUNT from `lsscsi -g`.
refresh_esm_list() {
    ESM_DEVICES=()
    ESM_REVS=()
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        ESM_DEVICES+=("$(awk '{print $NF}' <<<"$line")")
        ESM_REVS+=("$(awk '{print $(NF-2)}' <<<"$line")")
    done < <(lsscsi -g 2>/dev/null | egrep 'R3023|SE4200')
    ESM_COUNT=${#ESM_DEVICES[@]}
}

# Populates ESM_IDS / ESM_NPROC (parallel to ESM_DEVICES) via sg_ses.
refresh_esm_ids() {
    ESM_IDS=()
    ESM_NPROC=()
    local i dev out
    for i in "${!ESM_DEVICES[@]}"; do
        dev="${ESM_DEVICES[$i]}"
        out=$(sg_ses -p 1 "$dev" 2>/dev/null | grep -i 'relative ES process id')
        ESM_IDS+=("$(grep -oP 'relative ES process id:\s*\K[0-9]+' <<<"$out")")
        ESM_NPROC+=("$(grep -oP 'number of ES processes:\s*\K[0-9]+' <<<"$out")")
    done
}

get_nvme_count() {
    lsscsi -g 2>/dev/null | grep -ic nvme
}

# Refreshes state and checks it against expectations. Prints a full
# snapshot plus any FAIL lines. Returns 1 on any mismatch.
# Args: expected_count expected_rev(optional, empty = skip) expected_nvme phase_label
validate_snapshot() {
    local expected_count="$1" expected_rev="$2" expected_nvme="$3" phase="$4"
    local ok=1
    local i

    refresh_esm_list
    refresh_esm_ids
    local nvme_count
    nvme_count=$(get_nvme_count)

    echo ""
    echo "---- Validation: $phase ----"
    echo "ESM devices found: $ESM_COUNT (expected: $expected_count)"
    for i in "${!ESM_DEVICES[@]}"; do
        echo "  ${ESM_DEVICES[$i]}: fw_rev=${ESM_REVS[$i]:-?} relative_id=${ESM_IDS[$i]:-?}/${ESM_NPROC[$i]:-?}"
    done
    echo "NVMe drive count: $nvme_count (expected: $expected_nvme)"

    if [[ "$ESM_COUNT" -ne "$expected_count" ]]; then
        fail "ESM device count is $ESM_COUNT, expected $expected_count"
        ok=0
    fi

    for i in "${!ESM_DEVICES[@]}"; do
        if [[ -n "$expected_rev" && "${ESM_REVS[$i]:-}" != "$expected_rev" ]]; then
            fail "${ESM_DEVICES[$i]} firmware revision is ${ESM_REVS[$i]:-?}, expected $expected_rev"
            ok=0
        fi
        if [[ -z "${ESM_IDS[$i]:-}" || "${ESM_NPROC[$i]:-0}" -ne "$expected_count" ]]; then
            fail "${ESM_DEVICES[$i]} reports unexpected ES process info (id=${ESM_IDS[$i]:-?}, total=${ESM_NPROC[$i]:-?}, expected total=$expected_count)"
            ok=0
        fi
    done

    local sorted_ids expected_ids
    sorted_ids=$(printf '%s\n' "${ESM_IDS[@]:-}" | sort -n | tr '\n' ',')
    expected_ids=$(seq 1 "$expected_count" | tr '\n' ',')
    if [[ "$sorted_ids" != "$expected_ids" ]]; then
        fail "ESM relative IDs are not the expected unique set 1..$expected_count (got: ${ESM_IDS[*]:-none})"
        ok=0
    fi

    if [[ "$nvme_count" -ne "$expected_nvme" ]]; then
        fail "NVMe drive count is $nvme_count, expected $expected_nvme"
        ok=0
    fi

    [[ "$ok" -eq 1 ]]
}

# Args: fw_file label
perform_fw_update() {
    local fw_file="$1" label="$2" dev

    refresh_esm_list
    if [[ "$ESM_COUNT" -eq 0 ]]; then
        fail "no ESM devices found before applying firmware ($label)"
        return 1
    fi

    for dev in "${ESM_DEVICES[@]}"; do
        log "Applying firmware ($label) to $dev using $fw_file"
        if ! sg_ses_microcode -m 0xe -b "$MICROCODE_BPW" -I "$fw_file" "$dev"; then
            fail "sg_ses_microcode failed on $dev"
            return 1
        fi
    done

    for dev in "${ESM_DEVICES[@]}"; do
        log "Sending OEM chip reset to $dev"
        if ! sg_senddiag --pf -r "$RESET_DIAG_BYTES" "$dev" -vv; then
            fail "sg_senddiag reset failed on $dev"
            return 1
        fi
    done

    log "Sleeping ${POST_RESET_SLEEP}s for ESMs to come back online..."
    sleep "$POST_RESET_SLEEP"
    return 0
}

log "Capturing baseline state..."
refresh_esm_list
if [[ "$ESM_COUNT" -eq 0 ]]; then
    echo "Error: no ESM devices found (lsscsi -g | egrep 'R3023|SE4200' returned nothing)."
    exit 1
fi
BASELINE_COUNT="$ESM_COUNT"
BASELINE_NVME="$(get_nvme_count)"

if ! validate_snapshot "$BASELINE_COUNT" "" "$BASELINE_NVME" "baseline"; then
    echo "Stopping: baseline state is inconsistent (ESM IDs/count not sane). Fix before testing."
    exit 1
fi

log "Baseline: $BASELINE_COUNT ESM device(s), $BASELINE_NVME NVMe drive(s)."
log "Starting $ITERATIONS downgrade->upgrade cycle(s)."
log "Downgrade firmware: $DOWNGRADE_FW (-> $DOWNGRADE_REV)"
log "Upgrade firmware:   $UPGRADE_FW (-> $UPGRADE_REV)"

for ((cycle = 1; cycle <= ITERATIONS; cycle++)); do
    log "===== Cycle $cycle/$ITERATIONS: DOWNGRADE to $DOWNGRADE_REV ====="
    if ! perform_fw_update "$DOWNGRADE_FW" "downgrade to $DOWNGRADE_REV"; then
        echo "Stopping at cycle $cycle during downgrade firmware apply."
        exit 1
    fi
    if ! validate_snapshot "$BASELINE_COUNT" "$DOWNGRADE_REV" "$BASELINE_NVME" "cycle $cycle downgrade"; then
        echo "Stopping at cycle $cycle: post-downgrade validation failed."
        exit 1
    fi
    log "Cycle $cycle downgrade validated OK."

    log "===== Cycle $cycle/$ITERATIONS: UPGRADE to $UPGRADE_REV ====="
    if ! perform_fw_update "$UPGRADE_FW" "upgrade to $UPGRADE_REV"; then
        echo "Stopping at cycle $cycle during upgrade firmware apply."
        exit 1
    fi
    if ! validate_snapshot "$BASELINE_COUNT" "$UPGRADE_REV" "$BASELINE_NVME" "cycle $cycle upgrade"; then
        echo "Stopping at cycle $cycle: post-upgrade validation failed."
        exit 1
    fi
    log "Cycle $cycle upgrade validated OK."

    log "Cycle $cycle/$ITERATIONS completed successfully."
done

log "All $ITERATIONS cycle(s) completed successfully. ESM count, firmware revisions, relative IDs, and NVMe drive count remained consistent throughout."
