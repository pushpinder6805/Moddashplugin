#!/usr/bin/env bash
set -euo pipefail

# Match Discourse's official ImageMagick source/version/checksum. The Ubuntu
# runner provides ImageMagick 6, while this core revision requires `magick` (7).
version=7.1.2-27
source_sha=485dad5226fda2417ea65f3eb6e3f63e7d5dfacacdf6f57f9c39b6ef1e3cb667
archive="$RUNNER_TEMP/imagemagick-source.tar.gz"
package="$RUNNER_TEMP/imagemagick-package"
cache="$HOME/.cache/moddashplugin-imagemagick-$version.tar.gz"

if [[ ! -f "$cache" ]]; then
  curl --fail --location --retry 2 "https://github.com/ImageMagick/ImageMagick/archive/$version.tar.gz" -o "$archive"
  echo "$source_sha  $archive" | sha256sum --check
  tar -xzf "$archive" -C "$RUNNER_TEMP"
  cd "$RUNNER_TEMP/ImageMagick-$version"
  ./configure --prefix=/usr/local --disable-shared --enable-static \
    --without-magick-plus-plus --without-perl --without-x --disable-openmp \
    --with-freetype --with-fontconfig --with-png --with-jpeg --with-webp > configure.log
  make --silent -j2
  make --silent DESTDIR="$package" install
  mkdir -p "$(dirname "$cache")"
  tar -czf "$cache" -C "$package" usr/local
fi

sudo tar -xzf "$cache" -C /
magick --version
