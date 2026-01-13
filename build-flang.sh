#!/bin/bash
#
# Build script for LLVM Flang compiler and runtime
# Based on: https://flang.llvm.org/docs/GettingStarted.html
#
# This script builds Flang in-tree with bootstrapped Flang-RT
# for the host target processor.
#

set -e

# Calculate default parallel jobs: min(max(nproc/4, 1), 64)
calc_default_jobs() {
    local cores=$(nproc)
    local quarter=$((cores / 4))
    [[ ${quarter} -lt 1 ]] && quarter=1
    [[ ${quarter} -gt 64 ]] && quarter=64
    echo ${quarter}
}

# Calculate default memory limit (half of available memory in MB)
calc_default_memory() {
    local total_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    local half_mb=$((total_kb / 2 / 1024))
    echo ${half_mb}
}

# Configuration
BUILD_TYPE="${BUILD_TYPE:-Release}"
DEFAULT_JOBS=$(calc_default_jobs)
PARALLEL_JOBS="${PARALLEL_JOBS:-${DEFAULT_JOBS}}"
ENABLE_ASSERTIONS="${ENABLE_ASSERTIONS:-ON}"
MEMORY_LIMIT_MB="${MEMORY_LIMIT_MB:-$(calc_default_memory)}"
ENABLE_WERROR="${ENABLE_WERROR:-ON}"
ENABLE_REAL16="${ENABLE_REAL16:-ON}"
LLVM_TARGETS=""
EXTRA_CMAKE_ARGS=()
PRINT_CMAKE_CMD=0

# Directory setup - use current working directory as root
ROOTDIR="${ROOTDIR:-$(pwd)}"
SRCDIR="${ROOTDIR}/llvm-project"
BUILDDIR="${ROOTDIR}/build"
INSTALLDIR="${INSTALLDIR:-${ROOTDIR}/install}"

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Build LLVM Flang compiler and runtime for the host target.

Options:
    -h, --help              Show this help message
    -j, --jobs NUM          Number of parallel build jobs (default: min(nproc/4, 64))
    -t, --type TYPE         Build type: Release, Debug, RelWithDebInfo (default: Release)
    -r, --root DIR          Root directory for build (default: current directory)
    -i, --install DIR       Installation directory (default: <root>/install)
    -m, --memory MB         Memory limit in MB (default: half of available RAM)
    -c, --clean             Clean build directories before building
    --clone                 Clone or update the llvm-project repository
    --no-assertions         Disable LLVM assertions
    --no-werror             Disable treating warnings as errors (default: enabled)
    --no-real16             Disable REAL(16) support (default: enabled)
    --targets TARGETS       Semicolon-separated list of LLVM targets to build
                            (default: X86;AArch64)
                            Example: --targets "X86;NVPTX"
    --cmake-args "ARGS"     Additional CMake arguments to pass (can override script defaults)
                            Example: --cmake-args "-DLLVM_ENABLE_LTO=ON -DCMAKE_VERBOSE_MAKEFILE=ON"
    --print-cmake-command   Print the complete CMake command that will be executed
    --test                  Run tests after build
    --install-only          Only run install step (assumes build is complete)
    -y, --yes               Assume yes to all confirmation prompts

Environment variables:
    BUILD_TYPE              Same as --type
    PARALLEL_JOBS           Same as --jobs
    ROOTDIR                 Same as --root
    INSTALLDIR              Same as --install
    MEMORY_LIMIT_MB         Same as --memory
    CC                      C compiler to use (overrides auto-detection)
    CXX                     C++ compiler to use (overrides auto-detection)

Example:
    $(basename "$0") --clone --jobs 8 --type Release --install /opt/flang
    $(basename "$0") --cmake-args "-DLLVM_ENABLE_LTO=Thin"

EOF
    exit 0
}

# Function to prompt for confirmation
confirm() {
    local prompt="$1"
    if [[ "${ASSUME_YES}" -eq 1 ]]; then
        return 0
    fi
    read -r -p "${prompt} [y/N] " response
    case "$response" in
        [yY][eE][sS]|[yY]) return 0 ;;
        *) return 1 ;;
    esac
}

# Function to detect and validate compilers
detect_compilers() {
    echo "Detecting compilers..."

    # Check for C compiler if not specified
    if [[ -z "${CC}" ]]; then
        if command -v clang &> /dev/null; then
            CC="clang"
            echo "  Found C compiler: clang"
        elif command -v gcc &> /dev/null; then
            echo "  Warning: clang not found, gcc detected."
            echo "  Note: Building compiler-rt requires clang. GCC may cause issues."
            if ! confirm "  Continue with gcc?"; then
                echo "Aborted by user."
                exit 1
            fi
            CC="gcc"
        else
            echo "Error: No C compiler found. Please install clang or gcc."
            exit 1
        fi
    else
        if ! command -v "${CC}" &> /dev/null; then
            echo "Error: Specified C compiler '${CC}' not found."
            exit 1
        fi
        echo "  Using specified C compiler: ${CC}"
    fi

    # Check for C++ compiler if not specified
    if [[ -z "${CXX}" ]]; then
        if command -v clang++ &> /dev/null; then
            CXX="clang++"
            echo "  Found C++ compiler: clang++"
        elif command -v g++ &> /dev/null; then
            echo "  Warning: clang++ not found, g++ detected."
            if [[ "${CC}" != "gcc" ]]; then
                echo "  Note: Mixing clang (C) with g++ (C++) is not recommended."
                if ! confirm "  Continue with g++?"; then
                    echo "Aborted by user."
                    exit 1
                fi
            fi
            CXX="g++"
        else
            echo "Error: No C++ compiler found. Please install clang++ or g++."
            exit 1
        fi
    else
        if ! command -v "${CXX}" &> /dev/null; then
            echo "Error: Specified C++ compiler '${CXX}' not found."
            exit 1
        fi
        echo "  Using specified C++ compiler: ${CXX}"
    fi

    export CC CXX
}

# Function to detect linker
detect_linker() {
    echo "Detecting linker..."

    if command -v ld.lld &> /dev/null; then
        USE_LLD=1
        echo "  Found linker: lld"
    elif command -v ld &> /dev/null; then
        echo "  Warning: lld not found, falling back to ld."
        echo "  Note: lld is faster and recommended for LLVM builds."
        if ! confirm "  Continue with ld?"; then
            echo "Aborted by user."
            exit 1
        fi
        USE_LLD=0
        echo "  Using linker: ld"
    else
        echo "Error: No linker found. Please install lld or ld."
        exit 1
    fi
}

# Function to detect ccache
detect_ccache() {
    echo "Detecting ccache..."

    if command -v ccache &> /dev/null; then
        USE_CCACHE=1
        echo "  Found ccache: enabled"
    else
        USE_CCACHE=0
        echo "  ccache not found: disabled"
    fi
}

# Function to check for libquadmath
check_libquadmath() {
    echo "Checking for libquadmath..."
    
    if [[ "${ENABLE_REAL16}" == "OFF" ]]; then
        echo "  REAL(16) support disabled"
        return 0
    fi
    
    # Find quadmath.h location
    QUADMATH_INCLUDE=""
    for dir in /usr/include /usr/local/include /usr/lib/gcc/*/*/include; do
        if [[ -f "${dir}/quadmath.h" ]]; then
            QUADMATH_INCLUDE="${dir}"
            break
        fi
    done
    
    # Try to compile a test program that uses libquadmath
    local test_flags="-lquadmath"
    if [[ "${CC}" == "clang" ]] && [[ -n "${QUADMATH_INCLUDE}" ]]; then
        test_flags="-I${QUADMATH_INCLUDE} -lquadmath"
    fi
    
    if echo "#include <quadmath.h>
int main() { __float128 x = 1.0Q; return 0; }" | \
        ${CC} -x c - ${test_flags} -o /dev/null 2>/dev/null; then
        echo "  libquadmath found"
        if [[ -n "${QUADMATH_INCLUDE}" ]]; then
            echo "  quadmath.h located at: ${QUADMATH_INCLUDE}"
        fi
        return 0
    else
        echo ""
        echo "  Warning: libquadmath not found"
        echo "  libquadmath is required for REAL(16) math APIs for intrinsics such as SIN, COS, etc."
        echo "  REAL(16) support will be limited without it."
        echo "  To disable REAL(16) in subsequent builds, use --no-real16 flag."
        echo ""
        if ! confirm "  Continue without full REAL(16) support?"; then
            echo "Aborted by user."
            exit 1
        fi
        return 1
    fi
}

# Parse command line arguments
CLEAN_BUILD=0
DO_CLONE=0
RUN_TESTS=0
INSTALL_ONLY=0
ASSUME_YES=0
NO_ARGS_PROVIDED=0

# Check if no arguments were provided
if [[ "$#" -eq 0 ]]; then
    NO_ARGS_PROVIDED=1
fi

while [[ "$#" -gt 0 ]]; do
    case $1 in
        -h|--help) usage ;;
        -j|--jobs) PARALLEL_JOBS="$2"; shift ;;
        -t|--type) BUILD_TYPE="$2"; shift ;;
        -r|--root) ROOTDIR="$2"; shift ;;
        -i|--install) INSTALLDIR="$2"; shift ;;
        -m|--memory) MEMORY_LIMIT_MB="$2"; shift ;;
        -c|--clean) CLEAN_BUILD=1 ;;
        --clone) DO_CLONE=1 ;;
        --no-assertions) ENABLE_ASSERTIONS="OFF" ;;
        --no-werror) ENABLE_WERROR="OFF" ;;
        --no-real16) ENABLE_REAL16="OFF" ;;
        --targets) LLVM_TARGETS="$2"; shift ;;
        --cmake-args) EXTRA_CMAKE_ARGS+=($2); shift ;;
        --print-cmake-command) PRINT_CMAKE_CMD=1 ;;
        --test) RUN_TESTS=1 ;;
        --install-only) INSTALL_ONLY=1 ;;
        -y|--yes) ASSUME_YES=1 ;;
        *) echo "Unknown parameter: $1"; exit 1 ;;
    esac
    shift
done

# Update paths if ROOTDIR was changed via command line
SRCDIR="${ROOTDIR}/llvm-project"
BUILDDIR="${ROOTDIR}/build"
INSTALLDIR="${INSTALLDIR:-${ROOTDIR}/install}"

# Build LLVM targets list
if [[ -z "${LLVM_TARGETS}" ]]; then
    # Default: X86 and AArch64
    LLVM_TARGETS="host;X86;AArch64"
fi

# Detect tools
detect_compilers
detect_linker
detect_ccache
check_libquadmath

echo ""
echo "=============================================="
echo "Flang Build Configuration"
echo "=============================================="
echo "Root directory:    ${ROOTDIR}"
echo "Source directory:  ${SRCDIR}"
echo "Build directory:   ${BUILDDIR}"
echo "Install directory: ${INSTALLDIR}"
echo "Build type:        ${BUILD_TYPE}"
echo "Parallel jobs:     ${PARALLEL_JOBS}"
echo "Assertions:        ${ENABLE_ASSERTIONS}"
echo "Werror:            ${ENABLE_WERROR}"
echo "REAL(16):          ${ENABLE_REAL16}"
echo "LLVM targets:      ${LLVM_TARGETS}"
echo "C compiler:        ${CC}"
echo "C++ compiler:      ${CXX}"
echo "Linker:            $(if [[ ${USE_LLD} -eq 1 ]]; then echo "lld"; else echo "ld"; fi)"
echo "ccache:            $(if [[ ${USE_CCACHE} -eq 1 ]]; then echo "enabled"; else echo "disabled"; fi)"
echo "Memory limit:      ${MEMORY_LIMIT_MB} MB"
if [[ ${#EXTRA_CMAKE_ARGS[@]} -gt 0 ]]; then
    echo "Extra CMake args:  ${EXTRA_CMAKE_ARGS[*]}"
fi
echo "=============================================="
echo ""
echo "For help and available options, run: $(basename "$0") --help"
echo ""

# Always ask for confirmation unless -y/--yes was specified
if ! confirm "Proceed with this configuration?"; then
    echo "Aborted by user."
    exit 0
fi
echo ""

# Handle install-only mode
if [[ "${INSTALL_ONLY}" -eq 1 ]]; then
    echo "Running install only..."
    cd "${BUILDDIR}"
    ninja install
    echo "latest" > "${INSTALLDIR}/bin/versionrc"
    echo "Installation complete: ${INSTALLDIR}"
    exit 0
fi

# Create root directory
mkdir -p "${ROOTDIR}"
cd "${ROOTDIR}"

# Clone or update source if requested
if [[ "${DO_CLONE}" -eq 1 ]]; then
    if [[ -d "${SRCDIR}" ]]; then
        echo "Updating existing repository..."
        cd "${SRCDIR}"
        git pull --rebase || echo "Warning: git pull failed, continuing with existing source"
        cd "${ROOTDIR}"
    else
        echo "Cloning llvm-project..."
        git clone https://github.com/llvm/llvm-project.git "${SRCDIR}"
    fi
else
    if [[ ! -d "${SRCDIR}" ]]; then
        echo "Error: Source directory ${SRCDIR} does not exist."
        echo "Use --clone to clone the llvm-project repository."
        exit 1
    fi
    echo "Using existing source directory: ${SRCDIR}"
fi

# Clean build directories if requested
if [[ "${CLEAN_BUILD}" -eq 1 ]]; then
    echo "Cleaning build directories..."
    rm -rf "${BUILDDIR}"
    rm -rf "${INSTALLDIR}"
fi

# Create build and install directories
mkdir -p "${BUILDDIR}"
mkdir -p "${INSTALLDIR}"

# Configure with CMake
echo "Configuring with CMake..."
cd "${BUILDDIR}"

CMAKE_ARGS=(
    -G Ninja
    -DCMAKE_BUILD_TYPE="${BUILD_TYPE}"
    -DCMAKE_INSTALL_PREFIX="${INSTALLDIR}"
    -DCMAKE_EXPORT_COMPILE_COMMANDS=ON
    -DCMAKE_C_COMPILER="${CC}"
    -DCMAKE_CXX_COMPILER="${CXX}"
    -DLLVM_ENABLE_ASSERTIONS="${ENABLE_ASSERTIONS}"
    -DLLVM_TARGETS_TO_BUILD="${LLVM_TARGETS}"
    -DLLVM_LIT_ARGS=-v
    -DLLVM_ENABLE_PROJECTS="clang;mlir;flang;lld;clang-tools-extra"
    -DFLANG_ENABLE_WERROR="${ENABLE_WERROR}"
    -DLLVM_BUILD_DOCS=OFF
    -DLLVM_BUILD_EXAMPLES=OFF
    -DLLVM_ENABLE_DOXYGEN=OFF
    -DLLVM_ENABLE_IDE=ON
    -DLLVM_ENABLE_SPHINX=OFF
    -DLLVM_INCLUDE_TESTS=ON
    -DFLANG_INCLUDE_TESTS=ON
    -DLLVM_OPTIMIZED_TABLEGEN=ON
    -DLLVM_LINK_LLVM_DYLIB=ON
    -DLLVM_BUILD_LLVM_DYLIB=ON
)

# Add REAL(16) support if enabled
if [[ "${ENABLE_REAL16}" == "ON" ]]; then
    CMAKE_ARGS+=(-DFLANG_RUNTIME_F128_MATH_LIB=libquadmath)
fi

# Add default runtimes
CMAKE_ARGS+=(-DLLVM_ENABLE_RUNTIMES="compiler-rt;flang-rt;openmp")

# Add rpath for dynamic linking
if [[ -n "${LD_LIBRARY_PATH}" ]]; then
    CMAKE_ARGS+=(-DCMAKE_CXX_LINK_FLAGS="-Wl,-rpath,${LD_LIBRARY_PATH}")
fi

# Use lld if available
if [[ "${USE_LLD}" -eq 1 ]]; then
    CMAKE_ARGS+=(-DLLVM_USE_LINKER=lld)
fi

# Use ccache if available
if [[ "${USE_CCACHE}" -eq 1 ]]; then
    CMAKE_ARGS+=(-DLLVM_CCACHE_BUILD=ON)
fi

# Add extra CMake arguments (these can override defaults)
if [[ ${#EXTRA_CMAKE_ARGS[@]} -gt 0 ]]; then
    CMAKE_ARGS+=("${EXTRA_CMAKE_ARGS[@]}")
fi

# Print CMake command if requested
if [[ ${PRINT_CMAKE_CMD} -eq 1 ]]; then
    echo ""
    echo "=============================================="
    echo "CMake Command:"
    echo "=============================================="
    echo "cmake \\"
    for arg in "${CMAKE_ARGS[@]}"; do
        echo "  ${arg} \\"
    done
    echo "  ${SRCDIR}/llvm"
    echo "=============================================="
    echo ""
fi

cmake "${CMAKE_ARGS[@]}" "${SRCDIR}/llvm"

# Build with memory limit using systemd-run if available, otherwise ulimit
echo "Building with ${PARALLEL_JOBS} parallel jobs (memory limit: ${MEMORY_LIMIT_MB} MB)..."

if command -v systemd-run &> /dev/null && systemd-run --user --scope true &> /dev/null; then
    # Use systemd-run for memory limiting (more reliable)
    systemd-run --user --scope -p MemoryMax="${MEMORY_LIMIT_MB}M" \
        ninja -j "${PARALLEL_JOBS}"
else
    # Fall back to ulimit (virtual memory limit, less precise)
    MEMORY_LIMIT_KB=$((MEMORY_LIMIT_MB * 1024))
    (
        ulimit -v ${MEMORY_LIMIT_KB} 2>/dev/null || echo "Warning: Could not set memory limit with ulimit"
        ninja -j "${PARALLEL_JOBS}"
    )
fi

# Run tests if requested
if [[ "${RUN_TESTS}" -eq 1 ]]; then
    echo "Running Flang tests..."
    ninja check-flang check-flang-rt
fi

# Install
echo "Installing..."
ninja install

# Create version file
echo "latest" > "${INSTALLDIR}/bin/versionrc"

echo "=============================================="
echo "Build complete!"
echo "=============================================="
echo "Flang installed to: ${INSTALLDIR}"
echo ""
echo "To use Flang, add to your PATH:"
echo "  export PATH=\"${INSTALLDIR}/bin:\$PATH\""
echo ""
echo "To run tests later:"
echo "  cd ${BUILDDIR} && ninja check-flang check-flang-rt"
echo "=============================================="
