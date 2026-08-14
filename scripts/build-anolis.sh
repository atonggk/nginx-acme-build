#!/usr/bin/env bash
#
# Build NGINX (with the ACME dynamic module) for Anolis OS 7.9 (RHEL 7 / CentOS 7
# compatible, glibc 2.17). Intended to run inside the openanolis/anolisos:7.9
# container image, invoked from the GitHub Actions workflow.
#
# The system toolchain and libraries are too old for some components, so we
# build and install OpenSSL 1.1.1 (system 1.0.2k has no TLS 1.3) and PCRE2
# (system 10.23 is too old) into /usr/local first, then link NGINX against
# them statically. Pre-installing (instead of --with-openssl/--with-pcre)
# matters: the ACME module's cargo build script compiles NGINX headers and
# needs openssl/pcre2 headers in the compiler's default include path
# (/usr/local/include), and it removes the race between the parallel library
# builds and the Rust build inside `make`.
#
set -euo pipefail

NGINX_VERSION="${1:?Usage: build-anolis.sh <nginx-version>}"
PCRE2_VERSION="10.44"
OPENSSL_VERSION="1.1.1w"
OS_TAG="anolis79"

# --- Build dependencies (system gcc 4.8 is sufficient for NGINX itself) ---
yum install -y gcc gcc-c++ make perl wget git curl ca-certificates \
    zlib-devel tar gzip rpm-build

# --- Rust toolchain for the ACME module ---
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal
source "$HOME/.cargo/env"

# --- libclang for bindgen (the ACME module's nginx-sys crate uses bindgen) ---
# CentOS 7 era repos only ship clang 7 (bindgen >= 0.72 needs libclang >= 9)
# and official LLVM builds need glibc >= 2.18. The PyPI libclang wheel is
# manylinux2010 (glibc 2.12) and bundles a modern libclang.so.
LIBCLANG_VERSION="16.0.6"
# Resolve the wheel URL from the PyPI JSON API: hardcoded files.pythonhosted
# URLs proved flaky on the CDN (intermittent 404s).
LIBCLANG_WHEEL_URL=$(curl -sf "https://pypi.org/pypi/libclang/$LIBCLANG_VERSION/json" | python -c "
import json, sys
for u in json.load(sys.stdin)['urls']:
    fn = u['filename']
    if 'manylinux' in fn and 'x86_64' in fn:
        print(u['url']); break
")
if [ -z "$LIBCLANG_WHEEL_URL" ]; then
  echo "ERROR: could not resolve libclang wheel URL from PyPI"
  exit 1
fi
echo "libclang wheel: $LIBCLANG_WHEEL_URL"
wget -q "$LIBCLANG_WHEEL_URL" -O /tmp/libclang.whl
mkdir -p /usr/local/libclang
python -c "import zipfile; zipfile.ZipFile('/tmp/libclang.whl').extractall('/usr/local/libclang')"
# Wheel layouts differ between versions (e.g. 16.x nests everything under
# libclang-<ver>.data/platlib/), so locate libclang.so after extracting.
LIBCLANG_SO=$(find /usr/local/libclang -name 'libclang.so' | head -1)
if [ -z "$LIBCLANG_SO" ]; then
  echo "ERROR: libclang.so not found in extracted wheel"
  exit 1
fi
export LIBCLANG_PATH="$(dirname "$LIBCLANG_SO")"
echo "LIBCLANG_PATH=$LIBCLANG_PATH"

# The wheel ships only libclang.so, without clang's builtin headers
# (stddef.h, stdarg.h, ...). Point bindgen at the equivalents shipped with
# the system gcc instead, otherwise parsing fails with
# "'stddef.h' file not found".
GCC_INCLUDE_DIR=$(gcc -print-file-name=include)
if [ ! -f "$GCC_INCLUDE_DIR/stddef.h" ]; then
  echo "ERROR: gcc builtin headers not found at $GCC_INCLUDE_DIR"
  exit 1
fi
export BINDGEN_EXTRA_CLANG_ARGS="-isystem $GCC_INCLUDE_DIR"

# --- Tell the Rust openssl crate about our /usr/local OpenSSL (static) ---
export OPENSSL_DIR=/usr/local
export OPENSSL_STATIC=1

cd "$(dirname "$0")/.."

# --- Download sources ---
wget -q http://nginx.org/download/nginx-$NGINX_VERSION.tar.gz
wget -q https://github.com/PCRE2Project/pcre2/releases/download/pcre2-$PCRE2_VERSION/pcre2-$PCRE2_VERSION.tar.gz
wget -q https://www.openssl.org/source/old/1.1.1/openssl-$OPENSSL_VERSION.tar.gz
git clone --depth 1 https://github.com/nginx/nginx-acme.git

tar -zxf nginx-$NGINX_VERSION.tar.gz
tar -zxf pcre2-$PCRE2_VERSION.tar.gz
tar -zxf openssl-$OPENSSL_VERSION.tar.gz

# --- Build and install OpenSSL 1.1.1w (static, PIC, into /usr/local) ---
# -fPIC is required because the archive is also linked into the ACME module
# .so (via the Rust openssl crate), not just into the nginx executable.
cd openssl-$OPENSSL_VERSION
./config --prefix=/usr/local --openssldir=/usr/local/ssl --libdir=lib no-shared -fPIC
make -j"$(nproc)"
make install_sw
cd ..

# --- Build and install PCRE2 (static, PIC, with JIT, into /usr/local) ---
cd pcre2-$PCRE2_VERSION
./configure --prefix=/usr/local --disable-shared --enable-jit --with-pic
make -j"$(nproc)"
make install
cd ..

cd nginx-$NGINX_VERSION

# gcc 4.8 does not support -ffile-prefix-map (gcc 8+) or
# -fstack-protector-strong (gcc 4.9+), hence the reduced hardening set
# compared to the Debian build.
CC_OPT_VALUE="-g -O2 -fstack-protector -Wformat -Werror=format-security -Wp,-D_FORTIFY_SOURCE=2 -fPIC -I/usr/local/include"

# Same portable layout as the Debian build. OpenSSL and PCRE2 are linked
# statically (absolute archive paths), so the shipped binary is self-contained.
LD_OPT_VALUE="-Wl,-z,relro -Wl,-z,now -Wl,--as-needed -fPIC /usr/local/lib/libssl.a /usr/local/lib/libcrypto.a /usr/local/lib/libpcre2-8.a"

./configure \
  --with-cc-opt="$CC_OPT_VALUE" \
  --with-ld-opt="$LD_OPT_VALUE" \
  --prefix=.. \
  --conf-path=nginx.conf \
  --http-log-path=logs/access.log \
  --error-log-path=logs/error.log \
  --lock-path=run/nginx.lock \
  --pid-path=run/nginx.pid \
  --modules-path=modules \
  --http-client-body-temp-path=temp/body \
  --http-fastcgi-temp-path=temp/fastcgi \
  --http-proxy-temp-path=temp/proxy \
  --http-scgi-temp-path=temp/scgi \
  --http-uwsgi-temp-path=temp/uwsgi \
  --with-compat \
  --with-debug \
  --with-http_ssl_module \
  --with-http_stub_status_module \
  --with-http_realip_module \
  --with-http_auth_request_module \
  --with-http_v2_module \
  --add-dynamic-module=../nginx-acme/

# Keep the full build log; on failure print the error context so the root
# cause is visible in the CI log even when buried in parallel make output.
if ! make -j"$(nproc)" 2>&1 | tee /ws/make.log; then
  echo ""
  echo "=================== BUILD FAILED, error context ==================="
  grep -n -i -B 3 -A 15 'error' /ws/make.log | tail -n 200
  echo "==================================================================="
  exit 1
fi

# --- Package artifacts (same layout as the Debian build) ---
MODULE_PATH="objs/ngx_http_acme_module.so"
NGINX_BINARY_PATH="objs/nginx"

if [ ! -f "$MODULE_PATH" ] || [ ! -f "$NGINX_BINARY_PATH" ]; then
  echo "ERROR: Build failed! Required files were not created."
  exit 1
fi

PACKAGE_BASE_DIR="nginx_acme"
mkdir -p "$PACKAGE_BASE_DIR/sbin" \
         "$PACKAGE_BASE_DIR/modules" \
         "$PACKAGE_BASE_DIR/vhost" \
         "$PACKAGE_BASE_DIR/acme" \
         "$PACKAGE_BASE_DIR/logs" \
         "$PACKAGE_BASE_DIR/run" \
         "$PACKAGE_BASE_DIR/temp/body" \
         "$PACKAGE_BASE_DIR/temp/proxy" \
         "$PACKAGE_BASE_DIR/temp/fastcgi" \
         "$PACKAGE_BASE_DIR/temp/scgi" \
         "$PACKAGE_BASE_DIR/temp/uwsgi"

cp "$NGINX_BINARY_PATH" "$PACKAGE_BASE_DIR/sbin/nginx"
cp "$MODULE_PATH" "$PACKAGE_BASE_DIR/modules/ngx_http_acme_module.so"
cp conf/mime.types "$PACKAGE_BASE_DIR/"
cp ../conf/nginx.conf "$PACKAGE_BASE_DIR/nginx.conf"
cp ../conf/default.conf.example "$PACKAGE_BASE_DIR/vhost/default.conf.example"
cp ../nginxctl.sh "$PACKAGE_BASE_DIR/nginxctl.sh"

chmod +x "$PACKAGE_BASE_DIR/nginxctl.sh"

cat <<'EOF' > "$PACKAGE_BASE_DIR/README.txt"
Usage: ./nginxctl.sh {start|stop|quit|reload|test|status}
Commands:
  start   - Start NGINX (tests config first)
  stop    - Stop NGINX immediately (fast shutdown)
  quit    - Stop NGINX gracefully
  reload  - Reload configuration (tests config first)
  test    - Test NGINX configuration
  status  - Show NGINX process status
EOF

ARTIFACT_NAME="nginx-${NGINX_VERSION}-acme-${OS_TAG}.tar.gz"
tar -czf "$ARTIFACT_NAME" "$PACKAGE_BASE_DIR"

# --- Also ship an RPM that installs the same tree under /opt/nginx_acme ---
RPM_RELEASE="1.an7"
RPM_TOPDIR=/tmp/rpmbuild
RPM_BUILDROOT="$RPM_TOPDIR/buildroot"
rm -rf "$RPM_TOPDIR"
mkdir -p "$RPM_BUILDROOT/opt" "$RPM_BUILDROOT/usr/lib/systemd/system" \
         "$RPM_TOPDIR/SPECS" "$RPM_TOPDIR/RPMS"
cp -a "$PACKAGE_BASE_DIR" "$RPM_BUILDROOT/opt/nginx_acme"

# systemd unit. Written for systemd 219 (Anolis 7.9 / RHEL 7): a single
# ExecReload only (multiple ExecReload lines need systemd >= 231).
cat > "$RPM_BUILDROOT/usr/lib/systemd/system/nginx-acme.service" <<'EOF'
[Unit]
Description=nginx (ACME) self-contained instance
After=network-online.target
Wants=network-online.target

[Service]
Type=forking
WorkingDirectory=/opt/nginx_acme
PIDFile=/opt/nginx_acme/run/nginx.pid
ExecStartPre=/opt/nginx_acme/sbin/nginx -p /opt/nginx_acme -c nginx.conf -t
ExecStart=/opt/nginx_acme/sbin/nginx -p /opt/nginx_acme -c nginx.conf
ExecReload=/bin/sh -c '/opt/nginx_acme/sbin/nginx -p /opt/nginx_acme -c nginx.conf -t && /opt/nginx_acme/sbin/nginx -p /opt/nginx_acme -c nginx.conf -s reload'
ExecStop=/opt/nginx_acme/sbin/nginx -p /opt/nginx_acme -c nginx.conf -s quit
LimitNOFILE=65535
TimeoutStopSec=90
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

cat > "$RPM_TOPDIR/SPECS/nginx-acme.spec" <<EOF
Name: nginx-acme
Version: $NGINX_VERSION
Release: $RPM_RELEASE
Summary: NGINX with the ACME dynamic module (portable layout)
License: BSD-2-Clause
URL: https://nginx.org/
BuildArch: x86_64

%description
NGINX $NGINX_VERSION built for Anolis OS 7.9 (RHEL 7 / CentOS 7 compatible)
with the nginx-acme dynamic module. OpenSSL 1.1.1w and PCRE2 are linked
statically; the tree is self-contained under /opt/nginx_acme.

Manage with systemd:
  systemctl enable --now nginx-acme
or directly:
  cd /opt/nginx_acme && ./nginxctl.sh {start|stop|quit|reload|test|status}

%post
systemctl daemon-reload >/dev/null 2>&1 || true
echo "Installed under /opt/nginx_acme."
echo "Enable and start with: systemctl enable --now nginx-acme"
exit 0

%preun
if [ \$1 -eq 0 ]; then
  systemctl --no-reload disable --now nginx-acme >/dev/null 2>&1 || true
fi
exit 0

%files
/opt/nginx_acme
/usr/lib/systemd/system/nginx-acme.service
EOF

rpmbuild -bb \
  --define "_topdir $RPM_TOPDIR" \
  --buildroot "$RPM_BUILDROOT" \
  "$RPM_TOPDIR/SPECS/nginx-acme.spec"

RPM_PATH=$(find "$RPM_TOPDIR/RPMS" -name '*.rpm' | head -1)
if [ -z "$RPM_PATH" ]; then
  echo "ERROR: RPM was not created."
  exit 1
fi
echo "Built RPM: $RPM_PATH"

ARTIFACT_DIR=../artifact
mkdir -p "$ARTIFACT_DIR"
mv "$ARTIFACT_NAME" "$ARTIFACT_DIR/"
cp "$RPM_PATH" "$ARTIFACT_DIR/"
sha256sum "$ARTIFACT_DIR/$ARTIFACT_NAME" > "$ARTIFACT_DIR/$ARTIFACT_NAME.sha256"
sha256sum "$ARTIFACT_DIR/$(basename "$RPM_PATH")" > "$ARTIFACT_DIR/$(basename "$RPM_PATH").sha256"

echo "Done:"
ls -l "$ARTIFACT_DIR"
