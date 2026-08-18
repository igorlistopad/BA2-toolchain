#!/usr/bin/env bash
set -Eeuo pipefail

# Build the BA2 cross compiler (binutils + GCC/newlib) from the source archives
# checked into this repository.  The older Build.sh script also builds GDB and
# JP3; this script intentionally keeps the reusable compiler build separate.

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

BINUTILS_VERSION=2.22
BINUTILS_NAME="binutils-${BINUTILS_VERSION}-ba-r33675"
GCC_VERSION=4.7.4
GCC_NAME="gcc-${GCC_VERSION}-ba-r36379"
NEWLIB_NAME="newlib-2.0.0-ba-r33675"
GMP_NAME="gmp-4.3.2"
MPFR_NAME="mpfr-2.4.2"
MPC_NAME="mpc-0.8.1"
TARGET=ba-elf
RELEASE=r36379

# Apple Clang treats several diagnostics used by the 2012-era configure tests
# as hard errors. Keep the host compiler path configurable, but require Clang
# so that the host build never falls back to an installed GCC.
HOST_CC=${CC:-clang}
HOST_CXX=${CXX:-clang++}
export CC="$HOST_CC"
export CXX="$HOST_CXX"
export CC_FOR_BUILD="${CC_FOR_BUILD:-$HOST_CC}"
export CXX_FOR_BUILD="${CXX_FOR_BUILD:-$HOST_CXX}"
# GCC 4.7's Texinfo sources are rejected by current makeinfo. The compiler
# package does not need GCC's manuals, so skip info generation by default.
MAKEINFO=${MAKEINFO:-true}
export MAKEINFO
# GMP 4.3.2 runs an obsolete flex probe even though release sources already
# contain the generated files. ':' skips that probe and is propagated by GCC's
# top-level configure to the nested configure-gmp invocation.
LEX=${LEX:-:}
export LEX
if "$HOST_CC" --version 2>/dev/null | grep -qi clang; then
    export CFLAGS="${CFLAGS:-} -Wno-error=implicit-function-declaration -Wno-error=deprecated-non-prototype -Wno-int-conversion -Wno-incompatible-pointer-types"
    export CXXFLAGS="${CXXFLAGS:-} -Wno-error=deprecated-non-prototype"
    export CFLAGS_FOR_BUILD="${CFLAGS_FOR_BUILD:-} -Wno-error=implicit-function-declaration -Wno-error=deprecated-non-prototype -Wno-int-conversion -Wno-incompatible-pointer-types"
fi

PREFIX=
WORK_DIR=
JOBS=
KEEP_WORK=false

usage() {
    cat <<EOF
Usage: $0 [options]

Build binutils and GCC/newlib for the ${TARGET} target.

Options:
  --prefix DIR       Installation directory (required)
  --work-dir DIR     Build directory (default: temporary directory)
  --jobs N           Number of parallel make jobs (default: host CPU count)
  --keep-work        Keep the temporary/build directory after completion
  -h, --help         Show this help
EOF
}

die() {
    echo "error: $*" >&2
    exit 1
}

for host_compiler in "$HOST_CC" "$HOST_CXX" "$CC_FOR_BUILD" "$CXX_FOR_BUILD"; do
    "$host_compiler" --version 2>/dev/null | grep -qi clang \
        || die "host compiler must be Clang: $host_compiler"
done

while (($#)); do
    case "$1" in
        --prefix)
            (($# >= 2)) || die "--prefix requires a directory"
            PREFIX=$2
            shift 2
            ;;
        --work-dir)
            (($# >= 2)) || die "--work-dir requires a directory"
            WORK_DIR=$2
            shift 2
            ;;
        --jobs)
            (($# >= 2)) || die "--jobs requires a number"
            JOBS=$2
            shift 2
            ;;
        --keep-work)
            KEEP_WORK=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "unknown option: $1"
            ;;
    esac
done

[[ -n "$PREFIX" ]] || { usage >&2; die "--prefix is required"; }

if [[ -z "$JOBS" ]]; then
    if command -v sysctl >/dev/null 2>&1; then
        JOBS=$(sysctl -n hw.ncpu)
    elif command -v getconf >/dev/null 2>&1; then
        JOBS=$(getconf _NPROCESSORS_ONLN)
    else
        JOBS=2
    fi
fi
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || die "--jobs must be a positive integer"

for command_name in awk make patch sed tar; do
    command -v "$command_name" >/dev/null 2>&1 || die "required command not found: $command_name"
done

archive() {
    local name=$1
    printf '%s/%s.tar.xz' "$SCRIPT_DIR" "$name"
}

patches() {
    local patch_dir=$1
    local source_dir=$2
    [[ -d "$SCRIPT_DIR/$patch_dir" ]] || return 0

    while IFS= read -r patch_file; do
        [[ "$(basename "$patch_file")" == 103-* ]] && continue
        apply_patch_file "$patch_file" "$source_dir"
    done < <(find "$SCRIPT_DIR/$patch_dir" -type f -name '*.patch' -print | sort)
}

apply_patch_file() {
    local patch_file=$1
    local source_dir=$2
    echo "Applying ${patch_file#$SCRIPT_DIR/}"
    (cd "$source_dir" && patch -p0 < "$patch_file")
}

CONFIG_GUESS=
CONFIG_SUB=
for config_dir in \
    /usr/share/misc \
    /usr/share/automake-* \
    /usr/local/share/automake-* \
    /opt/homebrew/share/automake-* \
    /usr/share/libtool/build-aux \
    /usr/share/gettext; do
    if [[ -f "$config_dir/config.guess" && -f "$config_dir/config.sub" ]]; then
        CONFIG_GUESS="$config_dir/config.guess"
        CONFIG_SUB="$config_dir/config.sub"
        break
    fi
done

refresh_config_scripts() {
    local source_dir=$1
    local config_script
    local destination_dir
    local temporary_sub

    [[ -n "$CONFIG_GUESS" ]] || return 0
    while IFS= read -r -d '' config_script; do
        destination_dir=${config_script%/*}
        case "${config_script##*/}" in
            config.guess) cp "$CONFIG_GUESS" "$destination_dir/config.guess" ;;
            config.sub)
                cp "$CONFIG_SUB" "$destination_dir/config.sub"
                if ! sh "$destination_dir/config.sub" "$TARGET" >/dev/null 2>&1; then
                    temporary_sub="$destination_dir/config.sub.ba2"
                    awk '
                        !inserted && /\| pdp10/ {
                            print "\t| ba \134"
                            inserted=1
                        }
                        { print }
                        END { exit !inserted }
                    ' "$destination_dir/config.sub" > "$temporary_sub" \
                        || die "cannot add ${TARGET} to $destination_dir/config.sub"
                    mv "$temporary_sub" "$destination_dir/config.sub"
                fi
                ;;
        esac
    done < <(find "$source_dir" -type f \( -name config.guess -o -name config.sub \) -print0)
}

extract() {
    local archive_file=$1
    local destination=$2
    echo "Extracting $(basename "$archive_file")"
    tar -xJf "$archive_file" -C "$destination"
}

if [[ -z "$WORK_DIR" ]]; then
    WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/ba2-toolchain.XXXXXX")
    TEMP_WORK=true
else
    mkdir -p "$WORK_DIR"
    TEMP_WORK=false
fi

cleanup() {
    if [[ "$TEMP_WORK" == true && "$KEEP_WORK" == false ]]; then
        rm -rf "$WORK_DIR"
    fi
}
trap cleanup EXIT

mkdir -p "$PREFIX"
mkdir -p "$WORK_DIR/sources" "$WORK_DIR/binutils-build" "$WORK_DIR/gcc-build"

extract "$(archive "$BINUTILS_NAME")" "$WORK_DIR/sources"
extract "$(archive "$GCC_NAME")" "$WORK_DIR/sources"
extract "$(archive "$NEWLIB_NAME")" "$WORK_DIR/sources"
extract "$(archive "$GMP_NAME")" "$WORK_DIR/sources"
extract "$(archive "$MPFR_NAME")" "$WORK_DIR/sources"
extract "$(archive "$MPC_NAME")" "$WORK_DIR/sources"

BINUTILS_SOURCE="$WORK_DIR/sources/$BINUTILS_NAME"
GCC_SOURCE="$WORK_DIR/sources/$GCC_NAME"

patches "${BINUTILS_NAME}-patches" "$BINUTILS_SOURCE"

# GCC's in-tree layout is the one used by the original Build.sh.
rm -rf "$GCC_SOURCE/newlib" "$GCC_SOURCE/libgloss" "$GCC_SOURCE/gmp" \
       "$GCC_SOURCE/mpfr" "$GCC_SOURCE/mpc"
mv "$WORK_DIR/sources/$NEWLIB_NAME/newlib" "$GCC_SOURCE/newlib"
mv "$WORK_DIR/sources/$NEWLIB_NAME/libgloss" "$GCC_SOURCE/libgloss"
mv "$WORK_DIR/sources/$GMP_NAME" "$GCC_SOURCE/gmp"
mv "$WORK_DIR/sources/$MPFR_NAME" "$GCC_SOURCE/mpfr"
mv "$WORK_DIR/sources/$MPC_NAME" "$GCC_SOURCE/mpc"

patches "${GCC_NAME}-patches" "$GCC_SOURCE"

# The bundled Autotools metadata predates Linux/aarch64. Refresh every copy
# before configure when a current pair is available from automake/libtool.
# Modern config.sub does not know the custom BA target, so restore its alias.
refresh_config_scripts "$BINUTILS_SOURCE"
refresh_config_scripts "$GCC_SOURCE"

if [[ -z "$CONFIG_GUESS" && "$(uname -m)" == "aarch64" ]]; then
    die "current config.guess/config.sub are required to build on aarch64"
fi

chmod +x "$BINUTILS_SOURCE/configure" "$GCC_SOURCE/configure"
export PATH="$PREFIX/bin:$PATH"

echo "Configuring binutils for ${TARGET}"
(
    cd "$WORK_DIR/binutils-build"
    "$BINUTILS_SOURCE/configure" \
        --target="$TARGET" \
        --prefix="$PREFIX" \
        --disable-werror \
        --disable-nls
)

echo "Building and installing binutils"
make -C "$WORK_DIR/binutils-build" -j"$JOBS"
# libiberty's legacy install rule probes the host compiler with
# -print-multi-os-directory, which Clang does not implement.
make -C "$WORK_DIR/binutils-build" install MULTIOSDIR=.

echo "Configuring GCC ${GCC_VERSION} for ${TARGET}"
GCC_CONFIGURE_ARG=
case "$(uname -s)" in
    MSYS*|MINGW*|CYGWIN*)
        # GCC 4.7 ICEs while generating libstdc++ PCHs under MSYS2.
        GCC_CONFIGURE_ARG=--disable-libstdcxx-pch
        ;;
esac
(
    cd "$WORK_DIR/gcc-build"
    "$GCC_SOURCE/configure" \
        --target="$TARGET" \
        --prefix="$PREFIX" \
        --enable-languages=c,c++,lto \
        --with-gnu-as \
        --with-gnu-ld \
        --with-newlib \
        --disable-nls \
        --enable-target-optspace \
        --disable-libssp \
        --disable-__cxa_atexit \
        --disable-werror \
        --with-gxx-include-dir="$PREFIX/$TARGET/include" \
        $GCC_CONFIGURE_ARG
)

# GCC's top-level configure can regenerate the bundled GMP configure script.
# Apply the generated-script fix after that step and immediately before make.
apply_patch_file "$SCRIPT_DIR/${GCC_NAME}-patches/103-gmp-darwin-clang-configure.patch" "$GCC_SOURCE"

echo "Building and installing GCC/newlib"
make -C "$WORK_DIR/gcc-build" -j"$JOBS" MAKEINFO="$MAKEINFO"
make -C "$WORK_DIR/gcc-build" install MAKEINFO="$MAKEINFO"

echo "Checking installed BA2 compiler"
for tool in "$TARGET-gcc" "$TARGET-as" "$TARGET-ld" "$TARGET-ar"; do
    [[ -x "$PREFIX/bin/$tool" ]] || die "missing installed tool: $PREFIX/bin/$tool"
done
"$PREFIX/bin/$TARGET-gcc" --version | sed -n '1p'

echo "BA2 toolchain ${RELEASE} installed in $PREFIX"
