#!/usr/bin/env bash
#
# Build NGINX (with the ACME dynamic module) for Anolis OS 7.9 (RHEL 7 / CentOS 7
# compatible, glibc 2.17). Intended to run inside the openanolis/anolisos:7.9
# container image, invoked from the GitHub Actions workflow.
#
# The system toolchain and libraries are too old for some components, so we
# bundle and compile OpenSSL 1.1.1 (system 1.0.2k has no TLS 1.3) and PCRE2
# (system 10.23 is too old) as part of the NGINX build.
#
set -euo pipefail

NGINX_VERSION="${1:?Usage: build-anolis.sh <nginx-version>}"
PCRE2_VERSION="10.44"
OPENSSL_VERSION="1.1.1w"
OS_TAG="anolis79"

# --- Build dependencies (system gcc 4.8 is sufficient for NGINX itself) ---
yum install -y gcc gcc-c++ make perl wget git curl ca-certificates \
    zlib-devel tar gzip

# --- Rust toolchain for the ACME module ---
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal
source "$HOME/.cargo/env"

cd "$(dirname "$0")/.."

# --- Download sources ---
wget -q http://nginx.org/download/nginx-$NGINX_VERSION.tar.gz
wget -q https://github.com/PCRE2Project/pcre2/releases/download/pcre2-$PCRE2_VERSION/pcre2-$PCRE2_VERSION.tar.gz
wget -q https://www.openssl.org/source/old/1.1.1/openssl-$OPENSSL_VERSION.tar.gz
git clone --depth 1 https://github.com/nginx/nginx-acme.git

tar -zxf nginx-$NGINX_VERSION.tar.gz
tar -zxf pcre2-$PCRE2_VERSION.tar.gz
tar -zxf openssl-$OPENSSL_VERSION.tar.gz

cd nginx-$NGINX_VERSION

BUILD_PATH=$(pwd)
CC_OPT_VALUE="-g -O2 -ffile-prefix-map=$BUILD_PATH=. -fstack-protector-strong -Wformat -Werror=format-security -Wp,-D_FORTIFY_SOURCE=2 -fPIC"

# Same portable layout as the Debian build, but with bundled OpenSSL/PCRE2.
./configure \
  --with-cc-opt="$CC_OPT_VALUE" \
  --with-ld-opt='-Wl,-z,relro -Wl,-z,now -Wl,--as-needed -fPIC' \
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
  --with-pcre-jit \
  --with-openssl=../openssl-$OPENSSL_VERSION \
  --with-pcre=../pcre2-$PCRE2_VERSION \
  --with-http_ssl_module \
  --with-http_stub_status_module \
  --with-http_realip_module \
  --with-http_auth_request_module \
  --with-http_v2_module \
  --add-dynamic-module=../nginx-acme/

make -j"$(nproc)"

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

ARTIFACT_DIR=../artifact
mkdir -p "$ARTIFACT_DIR"
mv "$ARTIFACT_NAME" "$ARTIFACT_DIR/"
sha256sum "$ARTIFACT_DIR/$ARTIFACT_NAME" > "$ARTIFACT_DIR/$ARTIFACT_NAME.sha256"

echo "Done: $ARTIFACT_DIR/$ARTIFACT_NAME"
