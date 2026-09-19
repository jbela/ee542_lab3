#!/bin/bash

set -u

# ============================================================
# EE 542 Lab 3 - Automated SCP TCP Performance Test
# ============================================================

# -------------------------
# USER CONFIGURATION
# -------------------------

SERVER_IP="<SERVER_LAB_IP>" #CHANGE ME!
SERVER_USER="ubuntu"

VYOS_IP="<VYOS_MANAGEMENT_IP>"  #CHANGE ME!
VYOS_USER="vyos"

SSH_KEY="$HOME/.ssh/ee542_lab" #CHANGE ME!

# VyOS interfaces carrying the client/server lab traffic.
# CHANGE THESE to your actual VyOS interfaces.
VYOS_IF1="eth0"
VYOS_IF2="eth1"

TEST_FILE="$HOME/data.bin"
REMOTE_FILE="$HOME/data.bin"

RESULT_DIR="$HOME/ee452/scp-matrix-results"

# Maximum time allowed for one SCP transfer.
MAX_TIME=180

# Number of times to repeat each configuration.
RUNS=3

# RTT values required by the experiment.
RTTS=(0 80 200)

# Bidirectional loss values.
LOSSES=(0 5 10 15 20)

# TBF settings.
RATE="100mbit"
BURST="901555"
LATENCY="1ms"


# ============================================================
# SETUP
# ============================================================

mkdir -p "$RESULT_DIR"

CSV="$RESULT_DIR/results.csv"

echo "kernel,rtt_ms,loss_pct,run,status,seconds,bytes_received,mbps" \
    > "$CSV"

KERNEL=$(uname -r)

echo
echo "============================================================"
echo "TCP experiment"
echo "============================================================"
echo "Kernel:      $KERNEL"
echo "Server:      $SERVER_IP"
echo "Max time:    ${MAX_TIME}s"
echo "Runs/config: $RUNS"
echo "Results:     $CSV"
echo "============================================================"
echo


# ============================================================
# VERIFY TEST FILE
# ============================================================

if [ ! -f "$TEST_FILE" ]; then
    echo "Creating 1 GiB test file..."
    fallocate -l 1G "$TEST_FILE"
fi

FILE_SIZE=$(stat -c%s "$TEST_FILE")

echo "Test file size: $FILE_SIZE bytes"


# ============================================================
# FUNCTION: CONFIGURE VYOS
#
# RTT is split evenly:
#
#     requested RTT = 200 ms
#     IF1 delay      = 100 ms
#     IF2 delay      = 100 ms
#
# ============================================================

configure_network()
{
    RTT=$1
    LOSS=$2

    ONE_WAY=$((RTT / 2))

    echo
    echo "Configuring network:"
    echo "  RTT:       ${RTT} ms"
    echo "  one-way:   ${ONE_WAY} ms/interface"
    echo "  loss:      ${LOSS}% each direction"
    echo

    ssh -i "$SSH_KEY" \
        "$VYOS_USER@$VYOS_IP" \
        "
        sudo tc qdisc del dev $VYOS_IF1 root 2>/dev/null || true
        sudo tc qdisc del dev $VYOS_IF2 root 2>/dev/null || true

        sudo tc qdisc add dev $VYOS_IF1 root handle 1: \
            tbf rate $RATE latency $LATENCY burst $BURST

        sudo tc qdisc add dev $VYOS_IF2 root handle 1: \
            tbf rate $RATE latency $LATENCY burst $BURST

        sudo tc qdisc add dev $VYOS_IF1 parent 1:1 handle 10: \
            netem delay ${ONE_WAY}ms loss ${LOSS}%

        sudo tc qdisc add dev $VYOS_IF2 parent 1:1 handle 10: \
            netem delay ${ONE_WAY}ms loss ${LOSS}%
        "

    if [ $? -ne 0 ]; then
        echo "ERROR: Failed to configure VyOS."
        exit 1
    fi

    # Give qdisc configuration a moment to settle.
    sleep 2
}


# ============================================================
# FUNCTION: RUN ONE SCP TEST
# ============================================================

run_test()
{
    RTT=$1
    LOSS=$2
    RUN=$3

    echo
    echo "------------------------------------------------------------"
    echo "RTT=${RTT}ms LOSS=${LOSS}% RUN=${RUN}"
    echo "------------------------------------------------------------"

    # Remove previous destination file.
    ssh -i "$SSH_KEY" \
        "$SERVER_USER@$SERVER_IP" \
        "rm -f '$REMOTE_FILE'"

    # Nanosecond-resolution start time.
    START=$(date +%s.%N)

    # Give SCP at most MAX_TIME seconds.
    timeout \
        --signal=TERM \
        --kill-after=5s \
        "${MAX_TIME}s" \
        scp \
        -q \
        -i "$SSH_KEY" \
        -o Compression=no \
        -o BatchMode=yes \
        -o ConnectTimeout=15 \
        "$TEST_FILE" \
        "$SERVER_USER@$SERVER_IP:$REMOTE_FILE"

    SCP_STATUS=$?

    END=$(date +%s.%N)

    ELAPSED=$(awk \
        -v start="$START" \
        -v end="$END" \
        'BEGIN { printf "%.6f", end - start }')

    # Ask receiver how many bytes actually arrived.
    BYTES=$(ssh -i "$SSH_KEY" \
        "$SERVER_USER@$SERVER_IP" \
        "stat -c%s '$REMOTE_FILE' 2>/dev/null || echo 0")

    # Safety check.
    if ! [[ "$BYTES" =~ ^[0-9]+$ ]]; then
        BYTES=0
    fi

    # Determine result type.
    if [ "$SCP_STATUS" -eq 0 ]; then
        STATUS="complete"

    elif [ "$SCP_STATUS" -eq 124 ]; then
        STATUS="timeout"

    else
        STATUS="error-$SCP_STATUS"
    fi

    # Calculate Mbps using the ACTUAL bytes received.
    MBPS=$(awk \
        -v bytes="$BYTES" \
        -v seconds="$ELAPSED" \
        'BEGIN {
            if (seconds > 0)
                printf "%.3f", (bytes * 8) / (seconds * 1000000);
            else
                printf "0.000";
        }')

    echo
    echo "Status:         $STATUS"
    echo "Elapsed:        $ELAPSED sec"
    echo "Bytes received: $BYTES"
    echo "Throughput:     $MBPS Mbps"

    echo \
"$KERNEL,$RTT,$LOSS,$RUN,$STATUS,$ELAPSED,$BYTES,$MBPS" \
        >> "$CSV"

    # Remove partial/completed destination before next run.
    ssh -i "$SSH_KEY" \
        "$SERVER_USER@$SERVER_IP" \
        "rm -f '$REMOTE_FILE'"

    # Small cooldown between runs.
    sleep 3
}


# ============================================================
# MAIN TEST MATRIX
# ============================================================

for RTT in "${RTTS[@]}"
do
    for LOSS in "${LOSSES[@]}"
    do
        configure_network "$RTT" "$LOSS"

        for RUN in $(seq 1 "$RUNS")
        do
            run_test "$RTT" "$LOSS" "$RUN"
        done
    done
done


# ============================================================
# FINISHED
# ============================================================

echo
echo "============================================================"
echo "TEST MATRIX COMPLETE"
echo "============================================================"
echo "Results:"
echo "$CSV"
echo