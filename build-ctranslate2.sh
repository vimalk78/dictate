#!/bin/bash
# Build ctranslate2 from source with CUDA support (for Jetson / aarch64).
# Saves the wheel to ~/.local/share/dictate/wheels/ for install.sh to pick up.
set -e

WHEEL_DIR="$HOME/.local/share/dictate/wheels"
mkdir -p "$WHEEL_DIR"

# Build the same version requirements.lock pins, so the wheel matches the
# rest of the locked dependencies (install.sh uses this wheel in its place)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CT2_VERSION=$(sed -n 's/^ctranslate2==\([0-9.]*\).*/\1/p' "$SCRIPT_DIR/requirements.lock" | head -1)
[ -n "$CT2_VERSION" ] || { echo "ERROR: no ctranslate2 pin in requirements.lock"; exit 1; }
echo "Building ctranslate2 v$CT2_VERSION"

# Install build deps
sudo apt-get install -y build-essential cmake git python3-pip python3-venv

# Clone and build C++ library
BUILD_DIR="/tmp/ctranslate2-build"
rm -rf "$BUILD_DIR"
git clone --recursive --depth 1 --shallow-submodules --branch "v$CT2_VERSION" \
    https://github.com/OpenNMT/CTranslate2.git "$BUILD_DIR"
cd "$BUILD_DIR"
mkdir build && cd build
cmake .. -DWITH_CUDA=ON -DWITH_CUDNN=ON -DWITH_MKL=OFF -DOPENMP_RUNTIME=COMP
make -j$(nproc)
sudo make install
sudo ldconfig

# Build Python wheel
cd "$BUILD_DIR/python"
python3 -m pip install -r install_requirements.txt
python3 setup.py bdist_wheel

# Save wheel
cp dist/ctranslate2*.whl "$WHEEL_DIR/"
rm -rf "$BUILD_DIR"

echo ""
echo "Wheel saved to $WHEEL_DIR/"
ls "$WHEEL_DIR"/ctranslate2*.whl
echo ""
echo "Now run: bash install.sh"
