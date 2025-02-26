#! /usr/bin/env bash

set -euox pipefail

# check host arch
is_arm64_host() {
  [[ $(uname -m) == "arm64" ]] || [[ $(uname -m) == "aarch64" ]]
}

here="$(dirname "${BASH_SOURCE[0]}")"
this_repo="$(git -C "$here" rev-parse --show-toplevel ||
  echo -n "$GOPATH/src/github.com/keybase/client")"
client_dir="$here/../../go"

mode="$("$here/../build_mode.sh" "$@")"
binary_name="$("$here/../binary_name.sh" "$@")"

# Take the second argument as the build root, or a tmp dir if there is no
# second argument. Absolutify the build root, because we cd around in this
# script, and also because GOPATH is not allowed to be relative.
build_root="${2:-/tmp/keybase_build_$(date +%Y_%m_%d_%H%M%S)}"
mkdir -p "$build_root"
build_root="$(realpath "$build_root")"

# Record the version now, and write it to the build root. Because it uses a
# timestamp in prerelease mode, it's important that other scripts use this file
# instead of recomputing the version themselves.
version="$("$here/../version.sh" "$@")"
echo -n "$version" > "$build_root/VERSION"
echo -n "$mode" > "$build_root/MODE"

echo "Building version $version $mode in $build_root"

# Determine the Go tags.
go_tags=""
if [ "$mode" = "production" ] ; then
  go_tags="production"
elif [ "$mode" = "prerelease" ] ; then
  go_tags="production prerelease"
elif [ "$mode" = "staging" ] ; then
  go_tags="staging"
fi
echo "-tags '$go_tags'"

# Determine the LD flags.
buildmode="pie"
ldflags_client=""
ldflags_kbfs=""
ldflags_kbnm=""
strip_flag=" -s -w "
if [ "$mode" != "production" ] ; then
  # The non-production build number is everything in the version after the hyphen.
  build_number="$(echo -n "$version" | sed 's/.*-//')"
  ldflags_client="$strip_flag -X github.com/keybase/client/go/libkb.PrereleaseBuild=$build_number"
  ldflags_kbfs="$strip_flag -X github.com/keybase/client/go/kbfs/libkbfs.PrereleaseBuild=$build_number"
  # kbnm version currently defaults to the keybase client version.
  build_number_kbnm="$build_number"
  ldflags_kbnm="$strip_flag -X main.Version=$build_number_kbnm"
fi
echo "-ldflags_client '$ldflags_client'"
echo "-ldflags_kbfs '$ldflags_kbfs'"
echo "-ldflags_kbnm '$ldflags_kbnm'"

should_build_kbfs() {
  [ "$mode" != "production" ] && [[ ! -v KEYBASE_NO_KBFS ]]
}
should_build_electron() {
  [ "$mode" != "production" ] && [[ ! -v KEYBASE_NO_GUI ]]
}

# Install the electron dependencies.
if should_build_electron ; then
  echo "Installing Node modules for Electron"
  # Can't seem to get the right packages installed under NODE_ENV=production.
  export NODE_ENV=development
  export KEYBASE_SKIP_DEV_TOOLS=1
  (cd "$this_repo/shared" && yarn install --pure-lockfile --ignore-engines)
  unset KEYBASE_SKIP_DEV_TOOLS
  export NODE_ENV=production
fi

build_one_architecture() {
  layout_dir="$build_root/binaries/$debian_arch"
  mkdir -p "$layout_dir/usr/bin"

  # Assemble a custom GOPATH. Symlinks work for us here, because both the
  # client repo and the kbfs repo are fully vendored.
  export GOPATH="$build_root/gopaths/$debian_arch"
  mkdir -p "$GOPATH/src/github.com/keybase"
  ln -snf "$this_repo" "$GOPATH/src/github.com/keybase/client"

  # Build the client binary. Note that `go build` reads $GOARCH.
  echo "Building client for $GOARCH..."
  (cd "$client_dir" && go build -tags "$go_tags" -ldflags "$ldflags_client" -buildmode="$buildmode" -o \
    "$layout_dir/usr/bin/$binary_name" github.com/keybase/client/go/keybase)

  # Short-circuit if we're not building electron.
  if ! should_build_kbfs ; then
    echo "SKIPPING kbfs, kbnm, and electron."
    return
  fi

  cp "$here/run_keybase" "$layout_dir/usr/bin/"

  # In include-KBFS mode, create the /opt/keybase dir, and include post_install.sh.
  mkdir -p "$layout_dir/opt/keybase"
  cp "$here/post_install.sh" "$layout_dir/opt/keybase/"
  cp "$here/crypto_squirrel.txt" "$layout_dir/opt/keybase/"

  # Build the kbfsfuse binary. Currently, this always builds from master.
  echo "Building kbfs for $GOARCH..."
  (cd "$client_dir" && go build -tags "$go_tags" -ldflags "$ldflags_kbfs" -buildmode="$buildmode" -o \
    "$layout_dir/usr/bin/kbfsfuse" github.com/keybase/client/go/kbfs/kbfsfuse)

  # Build the git-remote-keybase binary, also from the kbfs repo.
  echo "Building git-remote-keybase for $GOARCH..."
  (cd "$client_dir" && go build -tags "$go_tags" -ldflags "$ldflags_kbfs" -buildmode="$buildmode" -o \
    "$layout_dir/usr/bin/git-remote-keybase" github.com/keybase/client/go/kbfs/kbfsgit/git-remote-keybase)

  # Short-circuit if we're doing a Docker multi-stage build
  if ! should_build_electron ; then
    echo "SKIPPING kbnm and electron."
    return
  fi

  # Build the root redirector binary.
  echo "Building keybase-redirector for $GOARCH..."
  (cd "$client_dir" && go build -tags "$go_tags" -ldflags "$ldflags_client" -buildmode="$buildmode" -o \
    "$layout_dir/usr/bin/keybase-redirector" github.com/keybase/client/go/kbfs/redirector)

  # Build the kbnm binary
  echo "Building kbnm for $GOARCH..."
  (cd "$client_dir" && go build -tags "$go_tags" -ldflags "$ldflags_kbnm" -buildmode="$buildmode" -o \
    "$layout_dir/usr/bin/kbnm" github.com/keybase/client/go/kbnm)


  if is_arm64_host ; then
    echo "is_arm64_host, building native kbnm for install"

    (cd "$client_dir" && GOARCH=arm64 CC=gcc CXX=g++ go build -tags "$go_tags" -ldflags "$ldflags_kbnm" -buildmode="$buildmode" -o \
    "$layout_dir/usr/bin/kbnm_arm64" github.com/keybase/client/go/kbnm)
    USER="$(whoami)" KBNM_INSTALL_ROOT=1 KBNM_INSTALL_OVERLAY="$layout_dir" "$layout_dir/usr/bin/kbnm_arm64" install
    rm "$layout_dir/usr/bin/kbnm_arm64"
  else
    # Write allowlists into the overlay. Note that we have to explicitly set USER
    # here, because docker doesn't do it by default, and so otherwise the
    # CGO-disabled i386 cross platform build will fail because it's unable to
    # find the current user.
    USER="$(whoami)" KBNM_INSTALL_ROOT=1 KBNM_INSTALL_OVERLAY="$layout_dir" "$layout_dir/usr/bin/kbnm" install
  fi

  # Build Electron.
  echo "Building Electron client for $electron_arch..."
  (
    cd "$this_repo/shared"
    yarn run package -- --platform=linux --arch="$electron_arch" --appVersion="$version" --network-concurrency=8
    rsync -a "desktop/release/linux-${electron_arch}/Keybase-linux-${electron_arch}/" \
      "$layout_dir/opt/keybase"
    chmod 755 "$layout_dir/opt/keybase"
    chmod 4755 "$layout_dir/opt/keybase/chrome-sandbox"
  )

  # Copy in the icon images and .saltpack file images.
  for size in 16 32 128 256 512 ; do
    icon_dest="$layout_dir/usr/share/icons/hicolor/${size}x${size}/apps"
    saltpack_dest="$layout_dir/usr/share/icons/hicolor/${size}x${size}/mimetypes"
    mkdir -p "$icon_dest"
    cp "$this_repo/media/icons/Keybase.iconset/icon_${size}x${size}.png" "$icon_dest/keybase.png"
    mkdir -p "$saltpack_dest"
    cp "$this_repo/media/icons/Saltpack.iconset/icon_${size}x${size}.png" "$saltpack_dest/application-x-saltpack.png"
  done

  # Copy in the desktop entry. Note that this is different from the autostart
  # entry, which will be created per-user the first time the service runs.
  apps_dir="$layout_dir/usr/share/applications"
  mkdir -p "$apps_dir"
  cp "$here/keybase.desktop" "$apps_dir"

  # Copy in the Saltpack file extension MIME type association.
  apps_dir="$layout_dir/usr/share/mime/packages"
  mkdir -p "$apps_dir"
  cp "$here/x-saltpack.xml" "$apps_dir"

  # Copy in the systemd unit files.
  units_dir="$layout_dir/usr/lib/systemd/user"
  mkdir -p "$units_dir"
  cp "$here/systemd"/* "$units_dir"

  # Check for whitespace in all the filenames we've copied. We don't support
  # whitespace in our later build scripts (for example RPM packaging), and even
  # if we did, it would be bad practice to use it.
  if (find "$layout_dir" | grep " ") ; then
    echo 'ERROR: whitespace in filenames! (shown above)'
    exit 1
  fi
}

# required for cross-compiling, or else the Go compiler will skip over
# resinit_nix.go and fail the i386 build
export CGO_ENABLED=1

if [ -n "${KEYBASE_BUILD_ARM_ONLY:-}" ] ; then
  echo "Keybase: Building for ARM only"
  export GOARCH=arm64
  export debian_arch=arm64
  export electron_arch=arm64
  build_one_architecture
  echo "Keybase: Built ARM; exiting..."
  exit
fi

if [ -z "${KEYBASE_SKIP_64_BIT:-}" ] ; then
  if is_arm64_host ; then
    echo "Keybase: Building for x86-64 (arm64 host cross compile)"
    export CC=x86_64-linux-gnu-gcc
    export CXX=x86_64-linux-gnu-g++
  else
    echo "Keybase: Building for x86-64"
  fi
  export GOARCH=amd64
  export debian_arch=amd64
  export electron_arch=x64
  build_one_architecture
else
  echo SKIPPING 64-bit build
fi
