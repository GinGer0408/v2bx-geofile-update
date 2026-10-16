#!/usr/bin/env bash
# Unmodified 1.3.0 upgrade functions, retained to test the migration bridge.
VERSION='1.3.0'
install_script_pair() (
  local_source=$1
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
      code=1
    fi
    [[ -z ${updater_stage} ]] || rm -f "${updater_stage}"
    [[ -z ${manager_stage} ]] || rm -f "${manager_stage}"
    if [[ ${pair_recovery_failed} -eq 1 ]]; then
      log "错误：脚本回滚失败，原版本保留在 ${pair_dir}，请手动恢复。"
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
  install -m 0755 "${local_source}" "${updater_stage}" || return 1
  install -m 0755 "${local_source}" "${manager_stage}" || return 1
  pair_pending=1
  mv -f "${updater_stage}" "${UPDATER_PATH}" || return 1
  mv -f "${manager_stage}" "${MANAGER_PATH}" || return 1
  pair_pending=0
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
    log "当前已是最新版本 ${VERSION}。"
    return 0
  fi
  [[ ${newest} == "${new_version}" ]] || {
    log "远程版本 ${new_version} 低于当前版本 ${VERSION}，拒绝降级。"; return 1;
  }
  install_script_pair "${temp_dir}/install.sh" || return 1
  log "脚本已从 ${VERSION} 更新到 ${new_version}，下次运行使用新版本。"
)

