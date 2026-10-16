#!/usr/bin/env bash
# Optional live download verification; never installs units or touches V2bX data.
set -Eeuo pipefail
# shellcheck source=../install.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../install.sh"
smoke_dir=$(mktemp -d /tmp/v2bx-geo-live.XXXXXX)
trap 'rm -rf "${smoke_dir}"' EXIT
resolve_release
printf 'Release: %s\n' "${release_base}"
download_and_validate geoip.dat "${release_base}/geoip.dat" "${smoke_dir}/geoip.dat"
download_and_validate geosite.dat "${release_base}/geosite.dat" "${smoke_dir}/geosite.dat"
