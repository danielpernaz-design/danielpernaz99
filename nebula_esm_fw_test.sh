#!/bin/bash
#
# Celestica Nebula JBOF ESM firmware downgrade/upgrade cycle test.
#
# Each cycle: downgrade to 3.2.0.18 (3002), then upgrade to 5.2.2.18
# (0522). Within each phase, ESMs are processed one at a time in
# relative-ES-process-ID order (id 1 = ESM-A first, then id 2 = ESM-B,
# etc.) — an ESM is fully flashed, reset, and re-validated before the
# next one is touched. A cycle only proceeds if ESM count, each ESM's
# firmware revision, the ESM relative-ID mapping, and NVMe drive count
# all match expectations at every step. Any mismatch stops the test
# immediately with diagnostic output.

set -uo pipefail

DOWNGRADE_FW_DEFAULT="se4200_3.0.2.18__ses_osa.fw"
UPGRADE_FW_DEFAULT="se4200_ses_5.2.2.18-cls.fw"
DOWNGRADE_REV="3002"
UPGRADE_REV="0522"
RESET_DIAG_BYTES="10,00,00,09,00,01,72,65,73,65,74,20,31"
POST_RESET_SLEEP=60
MICROCODE_BPW=3072

DOWNGRADE_FW="$DOWNGRADE_FW_DEFAULT"
UPGRADE_FW="$UPGRADE_FW_DEFAULT"
ITERATIONS=""

declare -A REV_BY_ID

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

esm_label() {
    case "$1" in
        1) echo "ESM-A" ;;
        2) echo "ESM-B" ;;
        *) echo "ESM-$1" ;;
    esac
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

# Prints indices into ESM_DEVICES/ESM_IDS, one per line, sorted by
# ascending relative ES process ID (missing/unparsed ids sort last).
order_by_relative_id() {
    local i
    for i in "${!ESM_DEVICES[@]}"; do
        printf '%s %s\n' "${ESM_IDS[$i]:-999}" "$i"
    done | sort -n -k1,1 | awk '{print $2}'
}

# Refreshes state and checks each ESM's firmware revision against
# REV_BY_ID[relative_id], plus overall ESM count / ID-set sanity / NVMe
# count. Prints a full snapshot plus any FAIL lines. Returns 1 on any
# mismatch. Args: expected_count expected_nvme phase_label
validate_snapshot() {
    local expected_count="$1" expected_nvme="$2" phase="$3"
    local ok=1
    local i id expected_rev

    refresh_esm_list
    refresh_esm_ids
    local nvme_count
    nvme_count=$(get_nvme_count)

    echo ""
    echo "---- Validation: $phase ----"
    echo "ESM devices found: $ESM_COUNT (expected: $expected_count)"
    for i in "${!ESM_DEVICES[@]}"; do
        id="${ESM_IDS[$i]:-}"
        echo "  ${ESM_DEVICES[$i]} ($(esm_label "${id:-?}")): fw_rev=${ESM_REVS[$i]:-?} relative_id=${id:-?}/${ESM_NPROC[$i]:-?}"
    done
    echo "NVMe drive count: $nvme_count (expected: $expected_nvme)"

    if [[ "$ESM_COUNT" -ne "$expected_count" ]]; then
        fail "ESM device count is $ESM_COUNT, expected $expected_count"
        ok=0
    fi

    for i in "${!ESM_DEVICES[@]}"; do
        id="${ESM_IDS[$i]:-}"
        expected_rev="${REV_BY_ID[$id]:-}"
        if [[ -n "$expected_rev" && "${ESM_REVS[$i]:-}" != "$expected_rev" ]]; then
            fail "${ESM_DEVICES[$i]} ($(esm_label "${id:-?}")) firmware revision is ${ESM_REVS[$i]:-?}, expected $expected_rev"
            ok=0
        fi
        if [[ -z "$id" || "${ESM_NPROC[$i]:-0}" -ne "$expected_count" ]]; then
            fail "${ESM_DEVICES[$i]} reports unexpected ES process info (id=${id:-?}, total=${ESM_NPROC[$i]:-?}, expected total=$expected_count)"
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

# Flashes + resets a single ESM device. Args: dev fw_file label
perform_fw_update_one() {
    local dev="$1" fw_file="$2" label="$3"

    log "Applying firmware to $label ($dev) using $fw_file"
    if ! sg_ses_microcode -m 0xe -b "$MICROCODE_BPW" -I "$fw_file" "$dev"; then
        fail "sg_ses_microcode failed on $label ($dev)"
        return 1
    fi

    log "Sending OEM chip reset to $label ($dev)"
    if ! sg_senddiag --pf -r "$RESET_DIAG_BYTES" "$dev" -vv; then
        fail "sg_senddiag reset failed on $label ($dev)"
        return 1
    fi

    log "Sleeping ${POST_RESET_SLEEP}s for $label to come back online..."
    sleep "$POST_RESET_SLEEP"
    return 0
}

# Processes every ESM sequentially (ESM-A, then ESM-B, ...), validating
# after each one before moving to the next.
# Args: fw_file target_rev expected_count expected_nvme phase_name
run_phase() {
    local fw_file="$1" target_rev="$2" expected_count="$3" expected_nvme="$4" phase_name="$5"
    local idx id dev label

    refresh_esm_list
    refresh_esm_ids

    for idx in $(order_by_relative_id); do
        dev="${ESM_DEVICES[$idx]}"
        id="${ESM_IDS[$idx]:-}"
        label="$(esm_label "${id:-?}")"

        echo ""
        log "----- $phase_name: $label (relative id ${id:-?}, $dev) -----"
        if ! perform_fw_update_one "$dev" "$fw_file" "$label"; then
            return 1
        fi

        if [[ -n "$id" ]]; then
            REV_BY_ID[$id]="$target_rev"
        fi

        if ! validate_snapshot "$expected_count" "$expected_nvme" "$phase_name - after $label"; then
            return 1
        fi
        log "$phase_name: $label validated OK."
    done

    return 0
}

log "Capturing baseline state..."
refresh_esm_list
if [[ "$ESM_COUNT" -eq 0 ]]; then
    echo "Error: no ESM devices found (lsscsi -g | egrep 'R3023|SE4200' returned nothing)."
    exit 1
fi
refresh_esm_ids
BASELINE_COUNT="$ESM_COUNT"
BASELINE_NVME="$(get_nvme_count)"

for i in "${!ESM_IDS[@]}"; do
    id="${ESM_IDS[$i]:-}"
    [[ -n "$id" ]] && REV_BY_ID[$id]="${ESM_REVS[$i]:-}"
done

if ! validate_snapshot "$BASELINE_COUNT" "$BASELINE_NVME" "baseline"; then
    echo "Stopping: baseline state is inconsistent (ESM IDs/count not sane). Fix before testing."
    exit 1
fi

log "Baseline: $BASELINE_COUNT ESM device(s), $BASELINE_NVME NVMe drive(s)."
log "Starting $ITERATIONS downgrade->upgrade cycle(s)."
log "Downgrade firmware: $DOWNGRADE_FW (-> $DOWNGRADE_REV)"
log "Upgrade firmware:   $UPGRADE_FW (-> $UPGRADE_REV)"

for ((cycle = 1; cycle <= ITERATIONS; cycle++)); do
    log "===== Cycle $cycle/$ITERATIONS: DOWNGRADE to $DOWNGRADE_REV ====="
    if ! run_phase "$DOWNGRADE_FW" "$DOWNGRADE_REV" "$BASELINE_COUNT" "$BASELINE_NVME" "cycle $cycle downgrade"; then
        echo "Stopping at cycle $cycle during downgrade."
        exit 1
    fi
    log "Cycle $cycle downgrade complete: all ESMs at $DOWNGRADE_REV."

    log "===== Cycle $cycle/$ITERATIONS: UPGRADE to $UPGRADE_REV ====="
    if ! run_phase "$UPGRADE_FW" "$UPGRADE_REV" "$BASELINE_COUNT" "$BASELINE_NVME" "cycle $cycle upgrade"; then
        echo "Stopping at cycle $cycle during upgrade."
        exit 1
    fi
    log "Cycle $cycle upgrade complete: all ESMs at $UPGRADE_REV."

    log "Cycle $cycle/$ITERATIONS completed successfully."
done

log "All $ITERATIONS cycle(s) completed successfully. ESM count, firmware revisions, relative IDs, and NVMe drive count remained consistent throughout."
