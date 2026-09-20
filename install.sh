#!/usr/bin/env bash
set -Eeuo pipefail

# V2bX Xray Geo 文件自动更新和管理脚本。
#
# 仅使用 v2rayN 使用的 Xray Geo 文件源：Loyalsoldier/v2ray-rules-dat。
# 任一文件下载失败或校验失败时，都不会修改当前正在使用的文件。

V2BX_DIR=${V2BX_DIR:-/etc/V2bX}
V2BX_SERVICE=${V2BX_SERVICE:-V2bX.service}
UPDATER_PATH=${V2BX_GEO_UPDATER:-/usr/local/sbin/v2bx-update-geo}
MANAGER_PATH=${V2BX_GEO_MANAGER:-/usr/local/bin/v2bx-geo}
BACKUP_DIR=${V2BX_GEO_BACKUP_DIR:-/var/backups/V2bX-geo}
VERSION='1.1.0'
GEOIP_URL='https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat'
GEOSITE_URL='https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat'

log() {
  printf '[v2bx-geo] %s\n' "$*"
  if command -v logger >/dev/null 2>&1; then
    logger -t v2bx-geo -- "$*" || true
  fi
}

fail() {
  log "错误：$*"
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
V2bX Geo 文件管理脚本

用法：
  一键安装：bash install.sh
  交互菜单：v2bx-geo
  安装：    v2bx-geo install
  立即更新：v2bx-geo update
  查看状态：v2bx-geo status
  查看日志：v2bx-geo log
  卸载：    v2bx-geo uninstall
  查看版本：v2bx-geo version
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

  log "正在下载 ${label}..."
  if ! curl -fL --retry 3 --retry-delay 5 --connect-timeout 20 \
    --max-time 600 --silent -A 'v2bx-geo-updater/1.1' -o "${output}" "${url}" 2>/dev/null; then
    log "${label} 下载失败，继续使用原有文件。"
    return 1
  fi

  bytes=$(wc -c <"${output}")
  if [[ ${bytes} -lt 1024 ]]; then
    log "${label} 下载结果过小（${bytes} 字节），继续使用原有文件。"
    return 1
  fi

  if LC_ALL=C head -c 1024 "${output}" | grep -aEiq '<!doctype|<html|rate.?limit'; then
    log "${label} 下载结果疑似错误页面，继续使用原有文件。"
    return 1
  fi

  log "${label} 校验通过（${bytes} 字节）。"
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

  # 两个文件都通过校验后，才允许替换目标文件。
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
      systemctl restart "${V2BX_SERVICE}" || log '错误：原文件恢复后 V2bX 仍未恢复，请检查 V2bX 日志。'
      return 1
    fi
    log 'geo 文件已更新，V2bX 已重启并加载新文件。'
  else
    log "geo 文件已更新；${V2BX_SERVICE} 当前未运行，未主动启动服务。"
  fi
)

uninstall_geo() {
  require_root
  systemctl disable --now v2bx-geo-update.timer 2>/dev/null || true
  rm -f /etc/systemd/system/v2bx-geo-update.service \
    /etc/systemd/system/v2bx-geo-update.timer \
    "${UPDATER_PATH}" "${MANAGER_PATH}"
  systemctl daemon-reload
  echo '已卸载 Geo 自动更新任务；备份目录 /var/backups/V2bX-geo/ 未删除。'
}

show_version() {
  echo "V2bX Geo 管理脚本版本：${VERSION}"
}

show_status() {
  local timer_state='未运行'
  local timer_enabled='否'
  local v2bx_state='未运行'
  local v2bx_enabled='否'
  local next_time=''
  local last_time=''

  if systemctl is-active --quiet v2bx-geo-update.timer; then
    timer_state='运行中'
  fi
  if systemctl is-enabled --quiet v2bx-geo-update.timer; then
    timer_enabled='是'
  fi
  if systemctl is-active --quiet "${V2BX_SERVICE}"; then
    v2bx_state='已运行'
  fi
  if systemctl is-enabled --quiet "${V2BX_SERVICE}"; then
    v2bx_enabled='是'
  fi

  next_time=$(systemctl show v2bx-geo-update.timer -p NextElapseUSecRealtime --value 2>/dev/null || true)
  last_time=$(systemctl show v2bx-geo-update.timer -p LastTriggerUSecRealtime --value 2>/dev/null || true)

  echo
  echo 'V2bX Geo 自动更新状态'
  echo '--------------------------------'
  echo "V2bX 状态：${v2bx_state}"
  echo "V2bX 开机自启：${v2bx_enabled}"
  echo "Geo 定时任务：${timer_state}"
  echo "Geo 开机自启：${timer_enabled}"
  echo '更新时间：每天北京时间凌晨 4:00'
  if [[ -n ${last_time} && ${last_time} != 'n/a' ]]; then
    echo "上次执行：${last_time}"
  else
    echo '上次执行：暂无记录'
  fi
  if [[ -n ${next_time} && ${next_time} != 'n/a' ]]; then
    echo "下次执行：${next_time}"
  else
    echo '下次执行：暂时无法获取'
  fi
  echo "Geo 文件目录：${V2BX_DIR}"
}

show_log() {
  echo
  echo 'V2bX Geo 最近更新日志'
  echo '--------------------------------'
  if command -v journalctl >/dev/null 2>&1; then
    journalctl -u v2bx-geo-update.service -n 100 --no-pager -o cat || true
  else
    echo '当前系统没有找到日志查看工具 journalctl。'
  fi
}

show_geo_info() {
  local file_name path size modified

  echo
  echo 'V2bX Geo 文件信息'
  echo '--------------------------------'
  for file_name in geoip.dat geosite.dat; do
    path="${V2BX_DIR}/${file_name}"
    if [[ -f ${path} ]]; then
      if size=$(stat -c '%s' "${path}" 2>/dev/null); then
        :
      else
        size='未知'
      fi
      if modified=$(stat -c '%y' "${path}" 2>/dev/null); then
        modified=${modified%%.*}
      else
        modified='未知'
      fi
      echo "${file_name}：已存在，大小 ${size} 字节，修改时间 ${modified}"
    else
      echo "${file_name}：不存在"
    fi
  done
}

reload_timer() {
  require_root
  if systemctl daemon-reload && systemctl enable --now v2bx-geo-update.timer; then
    echo 'Geo 自动更新任务已重新加载并启用。'
  else
    echo 'Geo 自动更新任务重载失败，请检查 systemd 状态。' >&2
    return 1
  fi
}

pause_menu() {
  read -r -p '按回车键返回菜单...' _ || true
}

show_menu() {
  local choice confirm timer_state v2bx_state timer_enabled

  while true; do
    clear 2>/dev/null || true
    timer_state='未运行'
    v2bx_state='未运行'
    timer_enabled='否'
    if systemctl is-active --quiet v2bx-geo-update.timer; then
      timer_state='运行中'
    fi
    if systemctl is-active --quiet "${V2BX_SERVICE}"; then
      v2bx_state='已运行'
    fi
    if systemctl is-enabled --quiet v2bx-geo-update.timer; then
      timer_enabled='是'
    fi

    echo
    echo 'V2bX Geo 文件管理脚本'
    echo '--- https://github.com/GinGer0408/v2bx-geofile-update ---'
    echo '--------------------------------'
    echo "V2bX 状态：${v2bx_state}"
    echo "Geo 定时任务：${timer_state}"
    echo "是否开机自启：${timer_enabled}"
    echo '--------------------------------'
    echo '0. 立即更新 Geo 文件'
    echo '1. 查看自动更新状态'
    echo '2. 查看更新日志'
    echo '3. 重载自动更新任务'
    echo '4. 查看 Geo 文件信息'
    echo '5. 卸载自动更新任务'
    echo '6. 查看脚本版本'
    echo '7. 退出脚本'
    echo '--------------------------------'
    read -r -p '请输入选择 [0-7]：' choice || return 0
    echo

    case ${choice} in
      0)
        update_geo || echo 'Geo 文件更新失败，原文件未被替换。'
        pause_menu
        ;;
      1)
        show_status
        pause_menu
        ;;
      2)
        show_log
        pause_menu
        ;;
      3)
        reload_timer || true
        pause_menu
        ;;
      4)
        show_geo_info
        pause_menu
        ;;
      5)
        read -r -p '确定要卸载 Geo 自动更新任务吗？请输入 y 确认：' confirm || confirm=''
        if [[ ${confirm} == 'y' || ${confirm} == 'Y' ]]; then
          uninstall_geo
          return 0
        fi
        echo '已取消卸载。'
        pause_menu
        ;;
      6)
        show_version
        pause_menu
        ;;
      7)
        echo '已退出脚本。'
        return 0
        ;;
      *)
        echo '输入无效，请输入 0 到 7。'
        pause_menu
        ;;
    esac
  done
}

invoked_path=$0
resolved_path=''
if [[ ${invoked_path} != */* ]]; then
  resolved_path=$(command -v -- "${invoked_path}" 2>/dev/null || true)
  if [[ -n ${resolved_path} ]]; then
    invoked_path=${resolved_path}
  fi
fi
script_path=$(CDPATH= cd -- "$(dirname -- "${invoked_path}")" && pwd)/$(basename -- "${invoked_path}")

if [[ $# -eq 0 && ${script_path} == "${MANAGER_PATH}" ]]; then
  require_root
  show_menu
  exit $?
fi

action=${1:-install}

case "${action}" in
  --update|update)
    require_root
    update_geo
    exit $?
    ;;
  status)
    require_root
    show_status
    exit 0
    ;;
  log)
    require_root
    show_log
    exit 0
    ;;
  uninstall)
    uninstall_geo
    exit 0
    ;;
  version)
    show_version
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
Description=从 v2rayN 兼容源更新 V2bX Xray Geo 文件
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=${UPDATER_PATH} --update
EOF

cat >"${timer_tmp}" <<EOF
[Unit]
Description=每天北京时间凌晨 4 点更新 V2bX Xray Geo 文件

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

# 安装完成后立即执行一次，之后由定时任务每天北京时间凌晨 4 点执行。
"${UPDATER_PATH}" --update

echo
echo '安装完成。'
echo '更新时间：每天北京时间凌晨 4:00。'
echo "管理命令：${MANAGER_PATH}（直接运行可打开中文管理菜单）"
echo '失败容灾：下载失败或校验失败时，继续使用原有 Geo 文件，不切换其他源。'
