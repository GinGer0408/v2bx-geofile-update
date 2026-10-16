#!/usr/bin/env bash
# V2BX_GEO_SCRIPT
set -Eeuo pipefail
export TZ=CST-8
export LC_TIME=C

# V2bX Xray Geo 文件自动更新和管理脚本。
#
# 仅使用 v2rayN 使用的 Xray Geo 文件源：Loyalsoldier/v2ray-rules-dat。
# 任一文件下载失败或校验失败时，都不会修改当前正在使用的文件。

V2BX_DIR=${V2BX_DIR:-/etc/V2bX}
V2BX_SERVICE=${V2BX_SERVICE:-V2bX.service}
UPDATER_PATH=${V2BX_GEO_UPDATER:-/usr/local/sbin/v2bx-update-geo}
MANAGER_PATH=${V2BX_GEO_MANAGER:-/usr/local/bin/v2bx-geo}
BACKUP_DIR=${V2BX_GEO_BACKUP_DIR:-/var/backups/V2bX-geo}
STATE_DIR=${V2BX_GEO_STATE_DIR:-/var/lib/v2bx-geo}
UNIT_DIR=${V2BX_GEO_UNIT_DIR:-/etc/systemd/system}
SCRIPT_URL='https://raw.githubusercontent.com/GinGer0408/v2bx-geofile-update/main/install.sh'
VERSION='1.4.0'
GEOIP_URL='https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat'

log() {
  local line
  line="[$(date '+%Y-%m-%d %H:%M:%S 北京时间')] [v2bx-geo] $*"
  printf '%s\n' "${line}"
  if [[ ${write_log:-0} -eq 1 ]]; then
    printf '%s\n' "${line}" >>"${STATE_DIR}/update.log" || printf '警告：无法写入更新日志。\n' >&2
  fi
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
  更新脚本：v2bx-geo self-update
EOF
}

format_time() {
  local value=${1:-}
  [[ -n ${value} && ${value} != 'n/a' && ${value} != '0' ]] || return 1
  if [[ ${value} =~ ^[0-9]+$ ]]; then
    value="@${value}"
  fi
  LC_ALL=C date -d "${value}" '+%Y-%m-%d %H:%M:%S 北京时间' 2>/dev/null
}

acquire_lock() {
  command -v flock >/dev/null 2>&1 || fail '缺少 flock，请安装 util-linux。'
  install -d -m 0700 "${STATE_DIR}" || return 1
  # 锁文件保持原位；即使 V2bX 目录已移除，也应能卸载管理任务。
  exec 9>"${STATE_DIR}/.lock" || return 1
  if [[ ${1:-} == wait ]]; then
    flock 9 || return 1
  elif ! flock -n 9; then
    log '另一个 Geo 管理任务正在运行，请稍后重试。'
    return 1
  fi
}

load_state() {
  local key value
  last_attempt=0 last_success=0 last_result='unknown'
  last_release='' last_geoip_hash='' last_geosite_hash=''
  [[ -f ${STATE_DIR}/status ]] || return 0
  while IFS=$'\t' read -r key value; do
    case ${key} in
      attempt) [[ ${value} =~ ^[0-9]+$ ]] && last_attempt=${value} ;;
      success) [[ ${value} =~ ^[0-9]+$ ]] && last_success=${value} ;;
      result) last_result=${value} ;;
      release) [[ ${value} =~ ^[[:alnum:]._-]+$ ]] && last_release=${value} ;;
      geoip_sha256) [[ ${value} =~ ^[[:xdigit:]]{64}$ ]] && last_geoip_hash=${value} ;;
      geosite_sha256) [[ ${value} =~ ^[[:xdigit:]]{64}$ ]] && last_geosite_hash=${value} ;;
    esac
  done <"${STATE_DIR}/status"
  return 0
}

save_state() {
  local state_tmp
  state_tmp=$(mktemp "${STATE_DIR}/.status.XXXXXX") || return 1
  if printf 'attempt\t%s\nsuccess\t%s\nresult\t%s\nrelease\t%s\ngeoip_sha256\t%s\ngeosite_sha256\t%s\n' \
    "${last_attempt}" "${last_success}" "${last_result}" \
    "${last_release}" "${last_geoip_hash}" "${last_geosite_hash}" >"${state_tmp}" &&
    mv -f "${state_tmp}" "${STATE_DIR}/status"; then
    return 0
  fi
  rm -f "${state_tmp}"
  return 1
}

prepare_state() {
  install -d -m 0700 "${STATE_DIR}" || return 1
  # 保留当前和上一份日志，避免长期运行无限增长。
  if [[ -f ${STATE_DIR}/update.log ]] && [[ $(stat -c %s "${STATE_DIR}/update.log") -ge 1048576 ]]; then
    mv -f "${STATE_DIR}/update.log" "${STATE_DIR}/update.log.1" || return 1
  fi
  write_log=1
}

restart_v2bx() {
  local check
  systemctl restart "${V2BX_SERVICE}" || return 1
  # Type=simple 的 restart 成功不代表初始化成功，观察短时间内的退出。
  for ((check=0; check<3; check++)); do
    sleep 1
    systemctl is-active --quiet "${V2BX_SERVICE}" || return 1
  done
}

install_dependencies() {
  command -v systemctl >/dev/null 2>&1 || fail '未找到 systemctl；本脚本仅支持 systemd。'
  [[ -d /run/systemd/system ]] || fail 'systemd 当前未运行，无法安装定时任务。'
  [[ -f /usr/share/zoneinfo/Asia/Shanghai ]] || fail '缺少 Asia/Shanghai 时区数据，请安装 tzdata。'
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
  command -v flock >/dev/null 2>&1 || fail '缺少 flock，请安装 util-linux。'
  command -v sha256sum >/dev/null 2>&1 || fail '缺少 sha256sum，请安装 coreutils。'
}

download_and_validate() {
  local label=$1
  local url=$2
  local output=$3
  local bytes expected actual

  local current=${4:-}
  validated_hash=''
  if ! curl -fL --proto '=https' --proto-redir '=https' --retry 3 --retry-delay 5 --connect-timeout 20 \
    --max-time 60 --silent --show-error -o "${output}.sha256sum" "${url}.sha256sum"; then
    log "${label} 校验文件下载失败，继续使用原有文件。"
    return 1
  fi
  read -r expected _ <"${output}.sha256sum" || {
    log "${label} 校验文件格式错误。"
    return 1
  }
  if [[ ! ${expected} =~ ^[[:xdigit:]]{64}$ ]]; then
    log "${label} 校验文件格式错误。"
    return 1
  fi
  expected=${expected,,}
  if [[ -n ${current} && -f ${current} && ! -L ${current} ]]; then
    actual=$(sha256sum -- "${current}") || return 1
    actual=${actual%% *}
  else
    actual=''
  fi
  if [[ ${actual} == "${expected}" ]]; then
    log "${label} 与上游校验和一致，跳过数据下载。"
    cp -- "${current}" "${output}" || return 1
  else
    log "正在下载 ${label}..."
    if ! curl -fL --proto '=https' --proto-redir '=https' --retry 3 --retry-delay 5 --connect-timeout 20 \
      --max-time 600 --silent --show-error -A "v2bx-geo-updater/${VERSION}" -o "${output}" "${url}"; then
      log "${label} 下载失败，继续使用原有文件。"
      return 1
    fi
  fi

  bytes=$(wc -c <"${output}")
  if [[ ${bytes} -lt 1024 ]]; then
    log "${label} 下载结果过小（${bytes} 字节），继续使用原有文件。"
    return 1
  fi

  LC_ALL=C head -c 1024 "${output}" >"${output}.head" || return 1
  if LC_ALL=C grep -aEiq '<!doctype|<html|rate.?limit' "${output}.head"; then
    log "${label} 下载结果疑似错误页面，继续使用原有文件。"
    return 1
  fi

  actual=$(sha256sum -- "${output}") || return 1
  actual=${actual%% *}
  if [[ ${actual,,} != "${expected,,}" ]]; then
    log "${label} SHA-256 校验失败，继续使用原有文件。"
    return 1
  fi
  validated_hash=${actual,,}
  log "${label} SHA-256 校验通过（${bytes} 字节，${validated_hash}）。"
}

resolve_release() {
  local target
  target=$(curl -fI --retry 3 --retry-delay 5 --connect-timeout 20 --max-time 60 \
    --silent --show-error --output /dev/null --write-out '%{redirect_url}' "${GEOIP_URL}") || return 1
  if [[ ! ${target} =~ ^https://github\.com/Loyalsoldier/v2ray-rules-dat/releases/download/[^/]+/geoip\.dat$ ]]; then
    log '无法确定上游发布版本，停止更新。' >&2
    return 1
  fi
  release_base=${target%/*}
}

update_geo() (
  acquire_lock "${1:-}" || return 1
  if [[ ${1:-} == wait && ! -f ${UNIT_DIR}/v2bx-geo-update.timer ]]; then
    log '定时任务已卸载，跳过等待中的更新。'
    return 0
  fi
  update_geo_locked
)

# 内部入口：调用方必须持有管理锁；安装首次检查复用同一把锁。
# 状态通过 save_state/load_state 文件交换，不依赖子 shell 变量传播。
# shellcheck disable=SC2030
update_geo_locked() (
  local last_attempt last_success last_result last_release last_geoip_hash last_geosite_hash
  local candidate_geoip_hash='' candidate_geosite_hash=''
  local release_base
  geoip_path=${V2BX_DIR}/geoip.dat
  geosite_path=${V2BX_DIR}/geosite.dat
  work_dir=''
  stage_geoip=${V2BX_DIR}/.geoip.dat.v2bx.new.$$
  stage_geosite=${V2BX_DIR}/.geosite.dat.v2bx.new.$$
  geoip_old=0
  geosite_old=0
  geoip_changed=1
  geosite_changed=1
  transaction_pending=0
  restart_attempted=0
  recovery_failed=0

  [[ -d ${V2BX_DIR} ]] || fail "V2bX 配置目录不存在：${V2BX_DIR}"
  command -v curl >/dev/null 2>&1 || fail 'curl 未安装'
  command -v systemctl >/dev/null 2>&1 || fail 'systemctl 未安装'
  command -v flock >/dev/null 2>&1 || fail 'flock 未安装，请安装 util-linux'
  command -v sha256sum >/dev/null 2>&1 || fail 'sha256sum 未安装，请安装 coreutils'

  prepare_state || return 1
  load_state
  if [[ ${last_result} == recovery_failed || ${last_result} == running ]]; then
    log "上次更新未完成恢复，暂停后续更新以保护备份。请检查 ${STATE_DIR}/update.log，手动恢复并确认服务正常后删除 ${STATE_DIR}/status，再重新更新。"
    return 1
  fi
  last_attempt=$(date +%s)
  last_result=running
  save_state || return 1
  # EXIT trap 调用；ShellCheck 无法跟踪间接调用。
  # shellcheck disable=SC2317
  cleanup() {
    local code=$?
    trap - EXIT INT TERM HUP
    if [[ ${transaction_pending} -eq 1 ]]; then
      if rollback; then
        if [[ ${restart_attempted} -eq 1 ]]; then
          if ! restart_v2bx; then
            recovery_failed=1
            log '错误：原文件恢复后 V2bX 仍未恢复，暂停后续更新，请检查 V2bX 日志。'
          fi
        fi
      else
        recovery_failed=1
      fi
      code=1
    fi
    if [[ ${recovery_failed} -eq 1 ]]; then
      last_result=recovery_failed
      log "保留恢复现场：${work_dir}"
    else
      [[ -z ${work_dir} ]] || rm -rf "${work_dir}"
      if [[ ${code} -ne 0 ]]; then
        last_result=failed
        log '本次 Geo 更新失败，请查看前面的错误和恢复结果。'
      elif [[ ${last_result} != running ]]; then
        last_success=$(date +%s)
        last_release=${release_base##*/}
        last_geoip_hash=${candidate_geoip_hash}
        last_geosite_hash=${candidate_geosite_hash}
      fi
    fi
    save_state || { log '错误：无法保存执行状态。'; code=1; }
    rm -f "${stage_geoip}" "${stage_geosite}"
    exit "${code}"
  }
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM HUP
  work_dir=$(mktemp -d /tmp/v2bx-geo-update.XXXXXX) || return 1
  for path in "${geoip_path}" "${geosite_path}"; do
    [[ ! -L ${path} && ( ! -e ${path} || -f ${path} ) ]] || fail "Geo 目标不是普通文件：${path}"
  done

  # 两个文件都通过校验后，才允许替换目标文件。
  resolve_release || return 1
  log "正在检查上游发布：${release_base##*/}"
  download_and_validate geoip.dat "${release_base}/geoip.dat" "${work_dir}/geoip.dat" "${geoip_path}" || return 1
  candidate_geoip_hash=${validated_hash}
  download_and_validate geosite.dat "${release_base}/geosite.dat" "${work_dir}/geosite.dat" "${geosite_path}" || return 1
  candidate_geosite_hash=${validated_hash}

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
    last_result=unchanged
    return 0
  fi

  install -d -m 0700 "${BACKUP_DIR}" || return 1
  if [[ ${geoip_old} -eq 1 ]]; then
    install -m 0644 "${work_dir}/geoip.previous" "${BACKUP_DIR}/geoip.dat.previous" || return 1
  fi
  if [[ ${geosite_old} -eq 1 ]]; then
    install -m 0644 "${work_dir}/geosite.previous" "${BACKUP_DIR}/geosite.dat.previous" || return 1
  fi

  # 由 EXIT trap 在提交失败或收到信号时调用。
  # shellcheck disable=SC2317
  rollback() {
    local failed=0
    transaction_pending=0
    log '更新或重启失败，恢复原来的 geo 文件。'
    if [[ ${geoip_old} -eq 1 ]]; then
      install -m 0644 "${work_dir}/geoip.previous" "${stage_geoip}" &&
        mv -f "${stage_geoip}" "${geoip_path}" || failed=1
    else
      rm -f "${geoip_path}" || failed=1
    fi
    if [[ ${geosite_old} -eq 1 ]]; then
      install -m 0644 "${work_dir}/geosite.previous" "${stage_geosite}" &&
        mv -f "${stage_geosite}" "${geosite_path}" || failed=1
    else
      rm -f "${geosite_path}" || failed=1
    fi
    if [[ ${failed} -ne 0 ]]; then
      recovery_failed=1
      log "错误：回滚未完成！请从 ${BACKUP_DIR} 手动恢复文件并检查 V2bX。"
      return 1
    fi
    log '原来的 Geo 文件已恢复。'
  }

  if [[ ${geoip_changed} -eq 1 ]]; then
    install -m 0644 "${work_dir}/geoip.dat" "${stage_geoip}" || {
      return 1
    }
  fi
  if [[ ${geosite_changed} -eq 1 ]]; then
    install -m 0644 "${work_dir}/geosite.dat" "${stage_geosite}" || {
      return 1
    }
  fi

  transaction_pending=1
  if [[ ${geoip_changed} -eq 1 ]] && ! mv -f "${stage_geoip}" "${geoip_path}"; then
    return 1
  fi
  if [[ ${geosite_changed} -eq 1 ]] && ! mv -f "${stage_geosite}" "${geosite_path}"; then
    return 1
  fi

  if systemctl is-active --quiet "${V2BX_SERVICE}"; then
    restart_attempted=1
    if ! restart_v2bx; then
      return 1
    fi
    log 'geo 文件已更新，V2bX 已重启并加载新文件。'
  else
    log "geo 文件已更新；${V2BX_SERVICE} 当前未运行，未主动启动服务。"
  fi
  transaction_pending=0
  last_result=updated
)

install_script_pair() (
  local_source=${1:-}
  unit_source=${2:-}
  unit_path=${UNIT_DIR}/v2bx-geo-update.service
  unit_stage=''
  [[ ${UPDATER_PATH} != "${MANAGER_PATH}" ]] || fail '管理和更新脚本路径不能相同。'
  install -d -m 0755 "$(dirname -- "${UPDATER_PATH}")" "$(dirname -- "${MANAGER_PATH}")" || return 1
  pair_dir=$(mktemp -d /tmp/v2bx-geo-script.XXXXXX) || return 1
  updater_stage=''
  manager_stage=''
  pair_pending=0
  pair_recovery_failed=0
  updater_exists=0 manager_exists=0
  # shellcheck disable=SC2317
  cleanup_pair() {
    local code=$?
    trap - EXIT INT TERM HUP
    if [[ ${pair_pending} -eq 1 ]]; then
      if [[ ${updater_exists} -eq 1 ]]; then
        install -m 0755 "${pair_dir}/updater" "${updater_stage}" &&
          mv -f "${updater_stage}" "${UPDATER_PATH}" || pair_recovery_failed=1
      else
        rm -f "${UPDATER_PATH}" || pair_recovery_failed=1
      fi
      if [[ ${manager_exists} -eq 1 ]]; then
        install -m 0755 "${pair_dir}/manager" "${manager_stage}" &&
          mv -f "${manager_stage}" "${MANAGER_PATH}" || pair_recovery_failed=1
      else
        rm -f "${MANAGER_PATH}" || pair_recovery_failed=1
      fi
      if [[ -n ${unit_source} ]]; then
        cp -p -- "${pair_dir}/service" "${unit_stage}" &&
          mv -f "${unit_stage}" "${unit_path}" || pair_recovery_failed=1
        systemctl daemon-reload || pair_recovery_failed=1
      fi
      code=1
    fi
    [[ -z ${unit_stage} ]] || rm -f "${unit_stage}"
    [[ -z ${updater_stage} ]] || rm -f "${updater_stage}"
    [[ -z ${manager_stage} ]] || rm -f "${manager_stage}"
    if [[ ${pair_recovery_failed} -eq 1 ]]; then
      log "错误：脚本或服务回滚失败，原版本保留在 ${pair_dir}，请手动恢复。"
    else
      rm -rf "${pair_dir}"
    fi
    exit "${code}"
  }
  trap cleanup_pair EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM HUP
  for path in "${UPDATER_PATH}" "${MANAGER_PATH}"; do
    [[ ! -L ${path} && ( ! -e ${path} || -f ${path} ) ]] || fail "脚本目标不是普通文件：${path}"
  done
  if [[ -f ${UPDATER_PATH} ]]; then
    cp -- "${UPDATER_PATH}" "${pair_dir}/updater" || return 1
    updater_exists=1
  fi
  if [[ -f ${MANAGER_PATH} ]]; then
    cp -- "${MANAGER_PATH}" "${pair_dir}/manager" || return 1
    manager_exists=1
  fi
  updater_stage=$(mktemp "${UPDATER_PATH}.new.XXXXXX") || return 1
  manager_stage=$(mktemp "${MANAGER_PATH}.new.XXXXXX") || return 1
  if [[ -n ${local_source} ]]; then
    install -m 0755 "${local_source}" "${updater_stage}" || return 1
    install -m 0755 "${local_source}" "${manager_stage}" || return 1
  else
    install -m 0755 "${pair_dir}/updater" "${updater_stage}" || return 1
    install -m 0755 "${pair_dir}/manager" "${manager_stage}" || return 1
  fi
  if [[ -n ${unit_source} ]]; then
    [[ -f ${unit_path} && ! -L ${unit_path} ]] || fail '更新服务配置不是普通文件。'
    cp -p -- "${unit_path}" "${pair_dir}/service" || return 1
    unit_stage=$(mktemp "${unit_path}.new.XXXXXX") || return 1
    cp -p -- "${unit_path}" "${unit_stage}" || return 1
    cat "${unit_source}" >"${unit_stage}" || return 1
  fi
  pair_pending=1
  mv -f "${updater_stage}" "${UPDATER_PATH}" || return 1
  mv -f "${manager_stage}" "${MANAGER_PATH}" || return 1
  if [[ -n ${unit_source} ]]; then
    mv -f "${unit_stage}" "${unit_path}" || return 1
    systemctl daemon-reload || return 1
  fi
  pair_pending=0
)

service_needs_migration() {
  grep -Eq '^[[:space:]]*ExecStart=.*[[:space:]]--update[[:space:]]*$' \
    "${UNIT_DIR}/v2bx-geo-update.service"
}

# 调用方持锁。只迁移已知旧参数，保留 Environment、调度、drop-in 和 timer 状态。
upgrade_installation() (
  local candidate=${1:-} migration_dir
  local service_path=${UNIT_DIR}/v2bx-geo-update.service
  [[ -f ${service_path} && ! -L ${service_path} ]] || fail '更新服务配置缺失或不是普通文件，请检查安装。'
  if service_needs_migration; then
    [[ $(grep -Ec '^[[:space:]]*ExecStart=' "${service_path}") -eq 1 ]] || fail '服务包含自定义多条 ExecStart，无法自动迁移。'
    migration_dir=$(mktemp -d /tmp/v2bx-geo-migrate.XXXXXX) || return 1
    trap 'rm -rf "${migration_dir}"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM HUP
    sed -E 's/^([[:space:]]*ExecStart=.*[[:space:]])--update[[:space:]]*$/\1--scheduled-update/' \
      "${service_path}" >"${migration_dir}/service" || return 1
    install_script_pair "${candidate}" "${migration_dir}/service" || return 1
    log '已迁移定时更新配置，保留原有路径、调度和 timer 启用状态。'
  else
    grep -Eq '^[[:space:]]*ExecStart=.*[[:space:]]--scheduled-update[[:space:]]*$' \
      "${service_path}" || fail '无法识别更新服务启动配置，未修改脚本或服务，请手动检查。'
    [[ -z ${candidate} ]] || install_script_pair "${candidate}" || return 1
  fi
)

# 1.3.0 的自更新仅复制脚本：新版首次运行时补迁移，不要求重新安装。
ensure_installation_current() (
  service_needs_migration || return 0
  acquire_lock || return 1
  prepare_state || return 1
  upgrade_installation
)

self_update() (
  require_root
  acquire_lock || return 1
  prepare_state || return 1
  local temp_dir new_version newest
  temp_dir=$(mktemp -d /tmp/v2bx-geo-self.XXXXXX) || return 1
  trap 'rm -rf "${temp_dir}"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM HUP
  log '正在检查 GitHub 上的脚本版本...'
  curl -fL --proto '=https' --proto-redir '=https' --retry 3 --retry-delay 5 \
    --connect-timeout 20 --max-time 120 --silent --show-error \
    -o "${temp_dir}/install.sh" "${SCRIPT_URL}" || {
    log '脚本下载失败，保留当前版本。'; return 1;
  }
  # 只静态检查下载内容；校验完成前不执行远程脚本。
  bash -n "${temp_dir}/install.sh" || { log '新版脚本语法检查失败，保留当前版本。'; return 1; }
  grep -qx '# V2BX_GEO_SCRIPT' "${temp_dir}/install.sh" || {
    log '下载内容缺少脚本标识，保留当前版本。'; return 1;
  }
  new_version=$(sed -n "s/^VERSION='\([0-9][0-9.]*\)'$/\1/p" "${temp_dir}/install.sh")
  [[ ${new_version} =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    log '下载内容版本号无效，保留当前版本。'; return 1;
  }
  newest=$(printf '%s\n%s\n' "${VERSION}" "${new_version}" | sort -V | tail -n 1)
  if [[ ${new_version} == "${VERSION}" ]]; then
    upgrade_installation || return 1
    log "当前已是最新版本 ${VERSION}，安装配置已检查。"
    return 0
  fi
  [[ ${newest} == "${new_version}" ]] || {
    log "远程版本 ${new_version} 低于当前版本 ${VERSION}，拒绝降级。"; return 1;
  }
  upgrade_installation "${temp_dir}/install.sh" || return 1
  log "脚本已从 ${VERSION} 更新到 ${new_version}，下次运行使用新版本。"
)

uninstall_geo() (
  require_root
  acquire_lock || return 1
  # 与更新和自更新共用锁，不删除正在使用的脚本。
  systemctl disable --now v2bx-geo-update.timer || return 1
  rm -f "${UNIT_DIR}/v2bx-geo-update.service" \
    "${UNIT_DIR}/v2bx-geo-update.timer" \
    "${UPDATER_PATH}" "${MANAGER_PATH}" || return 1
  systemctl daemon-reload || return 1
  echo "已卸载 Geo 自动更新任务；备份 ${BACKUP_DIR} 和执行记录 ${STATE_DIR} 已保留。"
)

show_version() {
  echo "V2bX Geo 管理脚本版本：${VERSION}"
}

# 每次都由 load_state 从磁盘重新读取状态。
# shellcheck disable=SC2031
show_status() {
  local last_attempt last_success last_result last_release last_geoip_hash last_geosite_hash
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

  next_time=$(LC_ALL=C systemctl show v2bx-geo-update.timer -p NextElapseUSecRealtime --value 2>/dev/null || true)
  load_state
  last_time=$(format_time "${last_attempt}" || true)
  if [[ -z ${last_time} ]]; then
    last_time=$(LC_ALL=C systemctl show v2bx-geo-update.timer -p LastTriggerUSec --value 2>/dev/null || true)
    if [[ -z ${last_time} || ${last_time} == 'n/a' ]]; then
      last_time=$(LC_ALL=C systemctl show v2bx-geo-update.service -p ExecMainStartTimestamp --value 2>/dev/null || true)
    fi
    last_time=$(format_time "${last_time}" || true)
  fi
  next_time=$(format_time "${next_time}" || true)

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
    echo '上次执行：尚无可用记录，请运行一次 v2bx-geo update'
  fi
  case ${last_result} in
    updated) echo '上次结果：成功，Geo 文件已更新' ;;
    unchanged) echo '上次结果：成功，文件无变化' ;;
    failed) echo '上次结果：更新失败，请查看日志' ;;
    recovery_failed) echo '上次结果：文件或服务恢复失败，需要手动处理，请查看日志' ;;
    running) echo '上次结果：执行中（若任务已退出，则上次执行被中断）' ;;
    *) echo '上次结果：旧版本未保存执行结果' ;;
  esac
  echo "最近成功：$(format_time "${last_success}" || echo '尚无成功记录')"
  if [[ -n ${next_time} && ${next_time} != 'n/a' ]]; then
    echo "下次执行：${next_time}"
  else
    echo '下次执行：暂时无法获取'
  fi
  echo "Geo 文件目录：${V2BX_DIR}"
  echo "最近成功验证的上游版本：${last_release:-暂无记录}"
  echo "最近成功验证的 GeoIP SHA-256：${last_geoip_hash:-暂无记录}"
  echo "最近成功验证的 GeoSite SHA-256：${last_geosite_hash:-暂无记录}"
}

show_log() {
  echo
  echo 'V2bX Geo 最近更新日志'
  echo '--------------------------------'
  if [[ -f ${STATE_DIR}/update.log ]]; then
    tail -n 100 "${STATE_DIR}/update.log"
  elif command -v journalctl >/dev/null 2>&1; then
    journalctl -u v2bx-geo-update.service -n 100 --no-pager -o short-iso || true
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
      if modified=$(stat -c '%Y' "${path}" 2>/dev/null); then
        modified=$(format_time "${modified}" || echo '未知')
      else
        modified='未知'
      fi
      echo "${file_name}：已存在，大小 ${size} 字节，修改时间 ${modified}"
    else
      echo "${file_name}：不存在"
    fi
  done
}

reload_timer() (
  require_root
  acquire_lock || return 1
  if systemctl daemon-reload && systemctl enable --now v2bx-geo-update.timer; then
    echo 'Geo 自动更新任务已重新加载并启用。'
  else
    echo 'Geo 自动更新任务重载失败，请检查 systemd 状态。' >&2
    return 1
  fi
)

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
    echo '8. 更新管理脚本版本'
    echo '--------------------------------'
    read -r -p '请输入选择 [0-8]：' choice || return 0
    echo

    case ${choice} in
      0)
        update_geo || echo 'Geo 文件更新失败，请检查上述日志中的恢复结果。'
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
      8)
        if self_update; then
          exec bash "${MANAGER_PATH}"
        fi
        echo '脚本更新失败，请查看上述日志。'
        pause_menu
        ;;
      *)
        echo '输入无效，请输入 0 到 8。'
        pause_menu
        ;;
    esac
  done
}

unit_escape() {
  local value=$1
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//%/%%}
  value=${value//$'\n'/\\n}
  value=${value//$'\r'/\\r}
  printf '%s' "${value}"
}

install_geo() (
  install_dependencies
  [[ -d ${V2BX_DIR} ]] || {
    echo "未找到 V2bX 配置目录：${V2BX_DIR}" >&2
    exit 1
  }

  acquire_lock
  install_script_pair "${script_path}"
  install -d -m 0755 "${UNIT_DIR}"

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
TimeoutStartSec=2h
Environment=TZ=CST-8
ExecStart="$(unit_escape "${UPDATER_PATH//\$/\$\$}")" --scheduled-update
EOF

  # 与手动更新使用相同配置，防止自定义路径只在安装时有效。
  for setting in \
    "V2BX_DIR=${V2BX_DIR}" "V2BX_SERVICE=${V2BX_SERVICE}" \
    "V2BX_GEO_BACKUP_DIR=${BACKUP_DIR}" "V2BX_GEO_STATE_DIR=${STATE_DIR}" \
    "V2BX_GEO_UPDATER=${UPDATER_PATH}" "V2BX_GEO_MANAGER=${MANAGER_PATH}" \
    "V2BX_GEO_UNIT_DIR=${UNIT_DIR}"; do
    printf 'Environment="%s"\n' "$(unit_escape "${setting}")" >>"${service_tmp}"
  done

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

  install -m 0644 "${service_tmp}" "${UNIT_DIR}/v2bx-geo-update.service"
  install -m 0644 "${timer_tmp}" "${UNIT_DIR}/v2bx-geo-update.timer"

  systemctl daemon-reload
  # 安装全程持锁，首次检查直接复用锁；启用 timer 后退出时再释放。
  initial_ok=1
  update_geo_locked || initial_ok=0
  systemctl enable --now v2bx-geo-update.timer

  echo
  echo '安装完成。'
  echo '更新时间：每天北京时间凌晨 4:00。'
  echo "管理命令：${MANAGER_PATH}（直接运行可打开中文管理菜单）"
  echo '失败容灾：下载失败或校验失败时，继续使用原有 Geo 文件，不切换其他源。'
  if [[ ${initial_ok} -eq 0 ]]; then
    echo '注意：定时任务已安装，但首次更新失败；请查看 v2bx-geo log 并重试。' >&2
    exit 1
  fi
)

if [[ ${BASH_SOURCE[0]} != "$0" ]]; then
  return 0
fi

invoked_path=$0
resolved_path=''
if [[ ${invoked_path} != */* ]]; then
  resolved_path=$(command -v -- "${invoked_path}" 2>/dev/null || true)
  if [[ -n ${resolved_path} ]]; then
    invoked_path=${resolved_path}
  fi
fi
script_path=$(CDPATH='' cd -- "$(dirname -- "${invoked_path}")" && pwd)/$(basename -- "${invoked_path}")

if [[ ${EUID} -eq 0 && ${script_path} == "${MANAGER_PATH}" && ${1:-} != uninstall &&
      ${1:-} != install && ${1:-} != self-update && ${1:-} != help && ${1:-} != --help && ${1:-} != -h ]]; then
  ensure_installation_current || exit 1
fi

if [[ $# -eq 0 && ${script_path} == "${MANAGER_PATH}" ]]; then
  require_root
  show_menu
  exit $?
fi

action=${1:-install}

case "${action}" in
  --scheduled-update)
    require_root
    update_geo wait
    exit $?
    ;;
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
  self-update)
    self_update
    exit $?
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

install_geo
