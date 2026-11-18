#!/bin/bash
set -euo pipefail
root="$RUNNER_TEMP/cache-proof"
mkdir -p "$root"
fetch() {
  mkdir "$root/$3"
  curl --fail --silent --show-error --location --retry 3 "https://codeload.github.com/$1/tar.gz/$2" |
    tar -xz -C "$root/$3" --strip-components=1
}
fetch falcondev-oss/github-actions-cache-server 8786aa9a0b3d057aebad7d5932f36862d67c6299 server
fetch actions/cache caa296126883cff596d87d8935842f9db880ef25 cache
fetch actions/setup-go 924ae3a1cded613372ab5595356fb5720e22ba16 setup-go
fetch actions/upload-artifact b7c566a772e6b6bfb58ed0dc250532a479d7789f upload
cd "$root/server"
# The upstream container targets Linux. Its optional /proc metrics collector is Linux-only.
python3 - <<'PY'
from pathlib import Path
p = Path('src/metrics.rs')
s = p.read_text()
target = '        registry.register(Box::new(\n            prometheus::process_collector'
assert s.count(target) == 1
p.write_text(s.replace(target, '        #[cfg(target_os = "linux")]\n' + target))
PY
rustup toolchain install 1.99 --profile minimal
CARGO_PROFILE_DEV_DEBUG=0 cargo +1.99 build --locked --quiet --bin github-actions-cache-server
