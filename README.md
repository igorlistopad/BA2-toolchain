# Build instructions

## Requirements

The repository contains the historical BA2 binutils 2.22 and GCC 4.7.4
sources. The supported compiler-only build produces a `ba-elf` cross-toolchain
with binutils, GCC and newlib. GDB and JTAG remain available through the legacy
`Build.sh` script.

On macOS, install Xcode Command Line Tools and the required GNU utilities:

```
brew install autoconf automake libtool texinfo gawk
```

On Debian/Ubuntu:

```
sudo apt-get install autoconf automake bison clang flex gawk make gettext \
  libgmp-dev libmpc-dev libmpfr-dev texinfo xz-utils
```

The host build is performed with Clang (`clang`/`clang++`); the script and CI
workflow do not install or use a host GCC.

## Build

```
./Build_toolchain.sh --prefix "$HOME/toolchains/ba-elf-ba2"
export PATH="$HOME/toolchains/ba-elf-ba2/bin:$PATH"
```

Use `--jobs N` to control parallelism and `--keep-work` to preserve the
intermediate sources and build directories for debugging. Add the `PATH` line
to your shell profile to use the toolchain in future sessions.

The same compiler-only build runs in GitHub Actions for macOS ARM64, macOS
AMD64, Linux AMD64, Linux ARM64 and Windows AMD64. Each job publishes a platform-specific
`ba-elf-ba2-r36379-*.tar.gz` artifact.
