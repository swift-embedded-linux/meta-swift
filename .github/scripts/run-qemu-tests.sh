#!/usr/bin/env bash
set -euo pipefail

if (( $# != 2 )); then
    echo "Usage: $0 {aarch64|x86_64} WORKDIR" >&2
    exit 2
fi

arch=$1
workdir=$2
sysroot=$workdir/recipe-sysroot
libs=$sysroot/usr/lib/swift/linux:$sysroot/usr/lib:$sysroot/lib

case $arch in
    aarch64)
        # Prefer the command used by the old workflow, if available.
        qemu=$(command -v qemu-arm64 || command -v qemu-aarch64)
        loader=$sysroot/lib/ld-linux-aarch64.so.1
        # On ARM hosts, the host loader can also load AArch64 libraries.
        # Give the Yocto library path to the guest only.
        guest_args=(-L "$sysroot" -E "LD_LIBRARY_PATH=$libs")
        baseline=(env -u LD_LIBRARY_PATH "$qemu")
        ;;
    x86_64)
        qemu=$(command -v qemu-x86_64)
        loader=$sysroot/lib/ld-linux-x86-64.so.2
        # Prefer the Yocto libs to the host's x86_64 libs; -L alone
        # doesn't isolate library lookup.
        guest_args=(-L "$sysroot" "$loader" --library-path "$libs")
        baseline=("$qemu")
        ;;
    *)
        echo "Unsupported target: $arch" >&2
        exit 2
        ;;
esac

echo "Host kernel and architecture: $(uname -sr -m)"
echo "Host page size: $(getconf PAGESIZE) bytes"
dpkg-query -W qemu-user 2>/dev/null || true
file -L "$qemu"
"$qemu" --version || true

# Keep retries bounded and report their status without replacing the original
# test result. The last lines of a guest trace usually contain the signal.
probe() {
    local status=0
    (
        ulimit -c 0
        timeout --kill-after=5s 30s "$@"
    ) 2>&1 | tail -n 120 || status=$?
    echo "Diagnostic exit status: $status"
}

host_backtrace() {
    if ! command -v gdb >/dev/null; then
        echo 'GDB is not installed; skipping the host backtrace.'
        return
    fi

    # Start GDB with host libraries and match the test's QEMU environment.
    local -a inferior_env=()
    if [[ $arch == x86_64 && -v LD_LIBRARY_PATH ]]; then
        inferior_env=(-ex "set environment LD_LIBRARY_PATH=$LD_LIBRARY_PATH")
    fi
    echo 'Host QEMU backtrace (first stop; QEMU may handle some signals itself):'
    probe env -u LD_LIBRARY_PATH DEBUGINFOD_URLS= gdb -nx -batch \
        -iex 'set auto-load off' \
        -ex 'set startup-with-shell off' -ex 'set disable-randomization off' \
        "${inferior_env[@]}" -ex run -ex 'p $_siginfo' -ex 'bt 20' \
        --args "$qemu" "${guest_args[@]}" "$@"
}

run_test() {
    local status=0
    echo "Running ${1##*/} under QEMU ($arch)"
    "${baseline[@]}" "${guest_args[@]}" "$@" || status=$?
    if (( status == 0 )); then
        return 0
    fi

    echo "::group::QEMU diagnostics for ${1##*/} (original exit status: $status)"
    file -L "$1" "$loader" || true
    readelf -lW -dW "$1" || true

    echo 'Guest syscall trace of the failing command:'
    probe "${baseline[@]}" -strace "${guest_args[@]}" "$@"

    echo 'Target loader smoke test (no Swift executable):'
    probe env -u LD_LIBRARY_PATH "$qemu" -L "$sysroot" "$loader" --version

    echo 'Target loader dependency list (without host LD_LIBRARY_PATH):'
    probe env -u LD_LIBRARY_PATH "$qemu" -L "$sysroot" \
        "$loader" --library-path "$libs" --list "$1"

    if [[ $arch == aarch64 && $(uname -m) == aarch64 ]]; then
        echo 'Native AArch64 comparison with the Yocto loader (no QEMU):'
        probe env -u LD_LIBRARY_PATH "$loader" --library-path "$libs" "$@"
    fi

    host_backtrace "$@"
    echo '::endgroup::'
    return "$status"
}

run_test "$workdir/build/release/hello-world"
run_test "$workdir/build/release/hello-worldPackageTests.xctest" --testing-library swift-testing
