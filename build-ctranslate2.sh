#!/bin/bash
# Build ctranslate2 from source with CUDA support (for Jetson / aarch64).
# Usage: bash build-ctranslate2.sh /path/to/venv/bin/python
set -e

VENV_PYTHON="${1:?Usage: build-ctranslate2.sh /path/to/venv/bin/python}"

# Install build deps
sudo apt-get install -y build-essential cmake git

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

# Build and install Python wheel into the target venv
cd "$BUILD_DIR/python"
"$VENV_PYTHON" -m pip install -r install_requirements.txt
"$VENV_PYTHON" setup.py bdist_wheel
"$VENV_PYTHON" -m pip install dist/ctranslate2*.whl

rm -rf "$BUILD_DIR"
echo "ctranslate2 installed with CUDA support."
