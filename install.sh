#!/usr/bin/env bash
set -Eeuo pipefail

# One-click updater for the original wyx2685/V2bX installation.
#
# The only download source is the Xray geo-file source used by v2rayN:
# Loyalsoldier/v2ray-rules-dat. If either download fails or is invalid, the
# current geoip.dat and geosite.dat are left untouched.

V2BX_DIR=${V2BX_DIR:-/etc/V2bX}
V2BX_SERVICE=${V2BX_SERVICE:-V2bX.service}
UPDATER_PATH=${V2BX_GEO_UPDATER:-/usr/local/sbin/v2bx-update-geo}
MANAGER_PATH=${V2BX_GEO_MANAGER:-/usr/local/bin/v2bx-geo}
BACKUP_DIR=${V2BX_GEO_BACKUP_DIR:-/var/backups/V2bX-geo}
VERSION='1.0.1'
GEOIP_URL='https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat'
GEOSITE_URL='https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat'

log() {
  printf '[v2bx-geo] %s\n' "$*"
  if command -v logger >/dev/null 2>&1; then
    logger -t v2bx-geo -- "$*" || true
  fi
}

fail() {
  log "ERROR: $*"
  exit 1
}

require_root() {
  if [[ ${EUID} -ne 0 ]]; then
    echo '请使用 root 运行此命令。' >&2
    exit 1
  fi
}

usage() {
  cat <<'EOF'
V2bX Xray Geo 文件管理器

用法：
  一键安装：bash install.sh
  安装：    v2bx-geo install
  更新：    v2bx-geo update
  状态：    v2bx-geo status
  日志：    v2bx-geo log
  卸载：    v2bx-geo uninstall
  版本：    v2bx-geo version
EOF
}

install_dependencies() {
  if ! command -v curl >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update -y
      apt-get install -y curl ca-certificates
    elif command -v dnf >/dev/null 2>&1; then
      dnf install -y curl ca-certificates
    elif command -v yum >/dev/null 2>&1; then
      yum install -y curl ca-certificates
    elif command -v apk >/dev/null 2>&1; then
      apk add --no-cache curl ca-certificates
    else
      fail '未找到可用的软件包管理器，无法安装 curl。'
    fi
  fi

  command -v curl >/dev/null 2>&1 || fail 'curl 安装失败。'
  command -v systemctl >/dev/null 2>&1 || fail '未找到 systemctl；原版 V2bX 需要 systemd 服务。'
}

download_and_validate() {
  local label=$1
  local url=$2
  local output=$3
  local bytes

  log "下载 ${label}..."
  if ! curl -fL --retry 3 --retry-delay 5 --connect-timeout 20 \
    --max-time 600 -A 'v2bx-geo-updater/1.0' -o "${output}" "${url}"; then
    log "${label} 下载失败，保留现有 geo 文件。"
    return 1
  fi

  bytes=$(wc -c <"${output}")
  if [[ ${bytes} -lt 1024 ]]; then
    log "${label} 下载结果过小（${bytes} bytes），保留现有 geo 文件。"
    return 1
  fi

  if LC_ALL=C head -c 1024 "${output}" | grep -aEiq '<!doctype|<html|rate.?limit'; then
    log "${label} 下载结果疑似错误页面，保留现有 geo 文件。"
    return 1
  fi

  log "${label} 校验通过（${bytes} bytes）。"
}

update_geo() (
  geoip_path=${V2BX_DIR}/geoip.dat
  geosite_path=${V2BX_DIR}/geosite.dat
  work_dir=''
  stage_geoip=${V2BX_DIR}/.geoip.dat.v2bx.new.$$
  stage_geosite=${V2BX_DIR}/.geosite.dat.v2bx.new.$$
  geoip_old=0
  geosite_old=0
  geoip_changed=1
  geosite_changed=1

  [[ -d ${V2BX_DIR} ]] || fail "V2bX 配置目录不存在：${V2BX_DIR}"
  command -v curl >/dev/null 2>&1 || fail 'curl 未安装'
  command -v systemctl >/dev/null 2>&1 || fail 'systemctl 未安装'

  work_dir=$(mktemp -d /tmp/v2bx-geo-update.XXXXXX)
  cleanup() {
    rm -rf "${work_dir}"
    rm -f "${stage_geoip}" "${stage_geosite}"
  }
  trap cleanup EXIT

  # Both downloads must pass before either target is touched.
  download_and_validate geoip.dat "${GEOIP_URL}" "${work_dir}/geoip.dat" || return 1
  download_and_validate geosite.dat "${GEOSITE_URL}" "${work_dir}/geosite.dat" || return 1

  if [[ -f ${geoip_path} ]]; then
    cp -a "${geoip_path}" "${work_dir}/geoip.previous" || return 1
    geoip_old=1
    if cmp -s "${work_dir}/geoip.dat" "${geoip_path}"; then
      geoip_changed=0
    fi
  fi
  if [[ -f ${geosite_path} ]]; then
    cp -a "${geosite_path}" "${work_dir}/geosite.previous" || return 1
    geosite_old=1
    if cmp -s "${work_dir}/geosite.dat" "${geosite_path}"; then
      geosite_changed=0
    fi
  fi

  if [[ ${geoip_changed} -eq 0 && ${geosite_changed} -eq 0 ]]; then
    log 'geoip.dat 和 geosite.dat 均无变化，不重启 V2bX。'
    return 0
  fi

  install -d -m 0700 "${BACKUP_DIR}" || return 1
  if [[ ${geoip_old} -eq 1 ]]; then
    install -m 0644 "${work_dir}/geoip.previous" "${BACKUP_DIR}/geoip.dat.previous" || return 1
  fi
  if [[ ${geosite_old} -eq 1 ]]; then
    install -m 0644 "${work_dir}/geosite.previous" "${BACKUP_DIR}/geosite.dat.previous" || return 1
  fi

  rollback() {
    log '更新或重启失败，恢复原来的 geo 文件。'
    if [[ ${geoip_old} -eq 1 ]]; then
      install -m 0644 "${work_dir}/geoip.previous" "${geoip_path}" || true
    else
      rm -f "${geoip_path}"
    fi
    if [[ ${geosite_old} -eq 1 ]]; then
      install -m 0644 "${work_dir}/geosite.previous" "${geosite_path}" || true
    else
      rm -f "${geosite_path}"
    fi
  }

  if [[ ${geoip_changed} -eq 1 ]]; then
    install -m 0644 "${work_dir}/geoip.dat" "${stage_geoip}" || {
      rollback
      return 1
    }
  fi
  if [[ ${geosite_changed} -eq 1 ]]; then
    install -m 0644 "${work_dir}/geosite.dat" "${stage_geosite}" || {
      rollback
      return 1
    }
  fi

  if [[ ${geoip_changed} -eq 1 ]] && ! mv -f "${stage_geoip}" "${geoip_path}"; then
    rollback
    return 1
  fi
  if [[ ${geosite_changed} -eq 1 ]] && ! mv -f "${stage_geosite}" "${geosite_path}"; then
    rollback
    return 1
  fi

  if systemctl is-active --quiet "${V2BX_SERVICE}"; then
    if ! systemctl restart "${V2BX_SERVICE}"; then
      rollback
      systemctl restart "${V2BX_SERVICE}" || log 'ERROR: 原文件恢复后 V2bX 仍未恢复，请检查 v2bx log。'
      return 1
    fi
    log 'geo 文件已更新，V2bX 已重启并加载新文件。'
  else
    log "geo 文件已更新；${V2BX_SERVICE} 当前未运行，未主动启动服务。"
  fi
)

command=${1:-install}

case "${command}" in
  --update|update)
    require_root
    update_geo
    exit $?
    ;;
  status)
    require_root
    systemctl status v2bx-geo-update.timer --no-pager -l
    systemctl list-timers v2bx-geo-update.timer --no-pager
    exit 0
    ;;
  log)
    require_root
    journalctl -u v2bx-geo-update.service -n 100 --no-pager
    exit 0
    ;;
  uninstall)
    require_root
    systemctl disable --now v2bx-geo-update.timer 2>/dev/null || true
    rm -f /etc/systemd/system/v2bx-geo-update.service \
      /etc/systemd/system/v2bx-geo-update.timer \
      "${UPDATER_PATH}" "${MANAGER_PATH}"
    systemctl daemon-reload
    echo '已卸载定时更新服务；/var/backups/V2bX-geo/ 保留未删除。'
    exit 0
    ;;
  version)
    echo "v2bx-geo ${VERSION}"
    exit 0
    ;;
  install)
    require_root
    ;;
  help|-h|--help)
    usage
    exit 0
    ;;
  *)
    usage >&2
    exit 1
    ;;
esac

install_dependencies
[[ -d ${V2BX_DIR} ]] || {
  echo "未找到 V2bX 配置目录：${V2BX_DIR}" >&2
  exit 1
}

script_path=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/$(basename -- "$0")
install -d -m 0755 "$(dirname -- "${UPDATER_PATH}")"
install -d -m 0755 "$(dirname -- "${MANAGER_PATH}")"

copy_script() {
  local source_path=$1
  local target_path=$2
  if [[ "${source_path}" == "${target_path}" ]]; then
    chmod 0755 "${target_path}"
  else
    install -m 0755 "${source_path}" "${target_path}"
  fi
}

copy_script "${script_path}" "${UPDATER_PATH}"
copy_script "${script_path}" "${MANAGER_PATH}"

service_tmp=$(mktemp)
timer_tmp=$(mktemp)
trap 'rm -f "${service_tmp}" "${timer_tmp}"' EXIT

cat >"${service_tmp}" <<EOF
[Unit]
Description=Update V2bX Xray geo files from the v2rayN source
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=${UPDATER_PATH} --update
EOF

cat >"${timer_tmp}" <<EOF
[Unit]
Description=Daily V2bX Xray geo update at Beijing time 04:00

[Timer]
OnCalendar=*-*-* 04:00:00 Asia/Shanghai
AccuracySec=1s
Persistent=true
Unit=v2bx-geo-update.service

[Install]
WantedBy=timers.target
EOF

install -m 0644 "${service_tmp}" /etc/systemd/system/v2bx-geo-update.service
install -m 0644 "${timer_tmp}" /etc/systemd/system/v2bx-geo-update.timer

systemctl daemon-reload
systemctl enable --now v2bx-geo-update.timer

# Verify immediately; the timer repeats this every day at 04:00 Asia/Shanghai.
"${UPDATER_PATH}" --update

echo
echo '安装完成。'
echo '更新时间：每天北京时间 04:00。'
echo "管理命令：${MANAGER_PATH} status|update|log|uninstall"
echo '失败容灾：下载失败或校验失败时，继续使用原来的 geo 文件，不切换其他源。'
