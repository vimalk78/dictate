#!/bin/bash
# Build ctranslate2 from source with CUDA support (for Jetson / aarch64).
# Saves the wheel to ~/.local/share/dictate/wheels/ for install.sh to pick up.
set -e

WHEEL_DIR="$HOME/.local/share/dictate/wheels"
mkdir -p "$WHEEL_DIR"

# Install build deps
sudo apt-get install -y build-essential cmake git python3-pip python3-venv

# Clone and build C++ library
BUILD_DIR="/tmp/ctranslate2-build"
rm -rf "$BUILD_DIR"
git clone --recursive https://github.com/OpenNMT/CTranslate2.git "$BUILD_DIR"
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
