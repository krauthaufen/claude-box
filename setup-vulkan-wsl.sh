# Vulkan on the GPU for Windows hosts (claude-box --gpu): builds Mesa's D3D12-based Vulkan driver ("dozen"),
# which Debian doesn't package. Only the Vulkan driver is built; it installs to /usr/local.
set -e
MESA=25.0.7
BUILD_DEPS="build-essential meson ninja-build pkg-config python3-mako python3-yaml bison flex glslang-tools libdrm-dev zlib1g-dev libexpat1-dev xz-utils"
apt-get update && apt-get install -y --no-install-recommends libvulkan1 libdrm2 zlib1g libexpat1 git ca-certificates curl
dpkg-query -W -f '${Package}\n' | sort > /tmp/pkgs.before
apt-get install -y --no-install-recommends $BUILD_DEPS
cd /tmp && curl -fsSL --retry 5 "https://archive.mesa3d.org/mesa-$MESA.tar.xz" | tar xJ && cd "mesa-$MESA"
meson setup build --prefix=/usr/local --buildtype=release -Dvulkan-drivers=microsoft-experimental \
  -Dgallium-drivers= -Dplatforms= -Dglx=disabled -Degl=disabled -Dgbm=disabled -Dgles1=disabled -Dgles2=disabled \
  -Dopengl=false -Dllvm=disabled -Dvalgrind=disabled -Dlibunwind=disabled -Dzstd=disabled -Dvideo-codecs= \
  --wrap-mode=default
ninja -C build && ninja -C build install
cd / && rm -rf "/tmp/mesa-$MESA"
# remove only what this script added (keeps build tools you installed via the packages file)
dpkg-query -W -f '${Package}\n' | sort | comm -13 /tmp/pkgs.before - | xargs -r apt-get purge -y
rm -rf /var/lib/apt/lists/* /tmp/pkgs.before
