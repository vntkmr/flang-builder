# Flang Builder

A robust Bash script to build the LLVM Flang compiler and runtime from source.

## Features

*   **Automated Dependency Detection**: Detects available C/C++ compilers (Clang/GCC), linkers (LLD/LD), and ccache.
*   **Resource Management**: Automatically calculates optimal parallel jobs and sets memory limits to prevent OOM kills (uses `systemd-run` if available, falls back to `ulimit`).
*   **OpenMP Offload Support**: Optional configuration for building with OpenMP offload support for NVIDIA and AMD GPUs.
*   **Flexible Configuration**: customizable install paths, build types, and CMake arguments.

## Prerequisites

Before running the script, ensure the following are installed:

*   **CMake** (Required)
*   **Ninja** (Required)
*   **C/C++ Compiler**: `clang`/`clang++` (Recommended) or `gcc`/`g++`
*   **Linker**: `lld` (Recommended) or `ld`
*   **Git** (For cloning/updating sources)
*   **ccache** (Optional, recommended for faster rebuilds)
*   **libquadmath** (Optional, required for full REAL(16) support)

### OpenMP Offload Requirements

To build with OpenMP offload support (`--openmp-offload`), you must have the following preinstalled on your host:

*   **NVIDIA CUDA Toolkit**: For NVPTX targets.
*   **AMD ROCm Toolkit**: For AMDGPU targets.

> **Warning:** Building OpenMP offload support is **experimental**. It may cause compiler errors or configuration issues depending on your host environment.

## Usage

```bash
./build-flang.sh [OPTIONS]
```

### Options

| Option | Description | Default |
|--------|-------------|---------|
| `-h, --help` | Show help message | |
| `-j, --jobs NUM` | Number of parallel build jobs | `min(nproc/4, 64)` |
| `-t, --type TYPE` | Build type (Release, Debug, RelWithDebInfo) | `Release` |
| `-r, --root DIR` | Root directory for build | Current directory |
| `-i, --install DIR` | Installation directory | `<root>/install` |
| `-m, --memory MB` | Memory limit in MB | Half of system RAM |
| `-c, --clean` | Clean build directories before building | Off |
| `--clone` | Clone or update the `llvm-project` repository | Off |
| `--no-assertions` | Disable LLVM assertions | On |
| `--no-werror` | Disable treating warnings as errors | On |
| `--no-real16` | Disable REAL(16) support | On |
| `--openmp-offload` | Enable OpenMP offload support | Off |
| `--targets LIST` | Semicolon-separated list of LLVM targets | `host` |
| `--cmake-args "ARGS"` | Additional CMake arguments | |
| `--print-cmake-command` | Print CMake command without executing | Off |
| `--test` | Run tests after build | Off |
| `--install-only` | Only run install step (skips build) | Off |
| `--build-only` | Only run build step (skips install) | Off |
| `-y, --yes` | Assume yes to all prompts | Off |

### Examples

**Basic Build:**
Clone the repository and build Release version:
```bash
./build-flang.sh --clone
```

**Custom Install Path & Jobs:**
```bash
./build-flang.sh -j 16 --install /opt/flang-18
```

**Debug Build with Specific Targets:**
```bash
./build-flang.sh --type Debug --targets "X86;NVPTX"
```

**OpenMP Offload Build:**
```bash
./build-flang.sh --openmp-offload
```

## Documentation

For detailed information about the Flang building process, please refer to the [official Flang documentation](https://flang.llvm.org/docs/GettingStarted.html).
