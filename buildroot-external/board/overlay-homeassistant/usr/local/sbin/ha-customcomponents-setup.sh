#!/bin/sh
set -eu

################################################################################
#
# 這個是 PI5 開機之後會執行的腳本，註冊在 HAOS 的 systemd 服務 ha-customcomponents-setup.service
#
################################################################################


LOG_TAG="[ha-customcomponents-setup]"
say() { echo "${LOG_TAG} $*"; }

CONFIG_DIR="/mnt/data/supervisor/homeassistant"
CUSTOM_DIR="${CONFIG_DIR}/custom_components"
STAMP_DIR="${CONFIG_DIR}/.firstboot-stamps"

# 與 hassio.mk 同版本
GIT_IMAGE="alpine/git:v2.49.1"

# 需抓取的 integrations（name|repo|ref） ref可以是 tag 或 branch
# 用 '|' 分隔（/bin/sh 友善）
# 建議 ref 用 release tag 以利可重現；此處示範 HACS 與 xiaomi_miot
# 其實不需要 HACS 就能裝 xiaomi_miot，我們可以直接從它的 repo 裝，HACS 可能要從備份還原的路來安裝，因為他需要 github 驗證碼完成安裝
INTEGRATIONS="
#hacs|https://github.com/hacs/integration|v2.0.0
xiaomi_miot|https://github.com/al-one/hass-xiaomi-miot|v1.1.0
ytube_music_player|git@github.com:togetherlearn1229/ytube_music_player.git|main
#private_comp|git@github.com:yourorg/private_comp|master
"

# 等 /mnt/data 與 Supervisor 就緒（最多 60 次）
i=0
while [ $i -lt 60 ]; do
  if [ -d "${CONFIG_DIR}" ]; then break; fi
  i=$((i+1))
  sleep 3
done

# 基本目錄
mkdir -p "${CUSTOM_DIR}" "${STAMP_DIR}"

# 確認 docker 可用
if ! command -v docker >/dev/null 2>&1; then
  say "ERROR: docker not found on host."
  exit 1
fi

# 在容器中執行 git，將內容寫回 /config
run_git() {
  SSH_VOL="-v /mnt/data/haos-ssh:/root/.ssh:ro"
  docker run --rm \
    --entrypoint /bin/sh \
    -v "${CONFIG_DIR}":/config \
    ${SSH_VOL} \
    -w /config \
    "${GIT_IMAGE}" \
    -lc "$*"
}


# 等待容器內能連外（避免 DNS/網路未就緒）
wait_net() {
  tries=0
  until run_git "wget -q --spider --timeout=5 https://github.com"; do
    tries=$((tries+1))
    [ $tries -ge 30 ] && { say "ERROR: network not ready in container"; return 1; }
    sleep 3
  done
  return 0
}

# 通用 clone（重試；自動處理 HTTPS/SSH）
do_clone() {
  repo="$1"; ref="$2"; dest="$3"

  if echo "$repo" | grep -qE '^(git@|ssh://)'; then
    SSH_ENV="GIT_SSH_COMMAND='ssh -o StrictHostKeyChecking=accept-new'"
  else
    SSH_ENV=""
  fi

  tries=0
  until run_git "${SSH_ENV} git clone --depth 1 --branch '${ref}' '${repo}' '${dest}'"; do
    tries=$((tries+1))
    [ $tries -ge 5 ] && return 1
    sleep 5
  done
  return 0
}

# 等待網路
wait_net || true


# 逐條處理
echo "${INTEGRATIONS}" | while IFS= read -r line; do
  # 跳過空白與註解
  case "$line" in
    ""|\#*) continue ;;
  esac

  name=$(echo "$line" | awk -F'|' '{print $1}' | xargs)
  repo=$(echo "$line" | awk -F'|' '{print $2}' | xargs)
  ref=$(echo  "$line" | awk -F'|' '{print $3}' | xargs)
  [ -n "${name}" ] || continue
  [ -n "${repo}" ] || continue
  [ -n "${ref}"  ] || ref="main"

  target_abs="${CUSTOM_DIR}/${name}"
  stamp="${STAMP_DIR}/.${name}.${ref}.done"

  # 已安裝過就跳過
  if [ -f "${stamp}" ]; then
    say "Skip ${name} (already installed for ref=${ref})"
    continue
  fi

  say "Installing ${name} from ${repo} (ref=${ref}) via container ${GIT_IMAGE} ..."

  # clone 到暫存資料夾（容器內目錄對應到 host 的 /config/.tmp-repos）----
  TMP_BASE="${CONFIG_DIR}/.tmp-repos"
  tmp_dir="${TMP_BASE}/${name}-${ref}"

  # 先清乾淨暫存與目標
  rm -rf "${tmp_dir}" "${target_abs}"
  mkdir -p "${TMP_BASE}" "${CUSTOM_DIR}"

  # 在容器內 clone 到 /config/.tmp-repos/<name>-<ref>
  run_git "git clone --depth 1 --branch '${ref}' '${repo}' '/config/.tmp-repos/${name}-${ref}' || true"

  # 判斷 repo 結構並只搬正確子資料夾到 custom_components/<name> ----
  src_a="${tmp_dir}/custom_components/${name}"   # 典型：repo/custom_components/<name>（xiaomi_miot 屬於此）
  src_b="${tmp_dir}"                              # 另一種：repo 根目錄本身就是整個 integration（含 manifest.json）

  if [ -d "${src_a}" ] && [ -f "${src_a}/manifest.json" ]; then
    # 2A) 有 custom_components/<name> → 複製該子資料夾
    cp -a "${src_a}" "${target_abs}"
  elif [ -f "${src_b}/manifest.json" ]; then
    # 2B) repo 根就是整個 integration → 複製根目錄內容
    mkdir -p "${target_abs}"
    cp -a "${src_b}/." "${target_abs}/"
  else
    say "ERROR: Cannot locate integration folder for '${name}' (looked for ${src_a} or ${src_b} with manifest.json)"
    rm -rf "${tmp_dir}"
    # 不觸發 stamp，讓下次重試；繼續處理下一個
    continue
  fi

  # 清掉暫存
  rm -rf "${tmp_dir}"

  # 權限與 stamp
  chown -R root:root "${target_abs}" 2>/dev/null || true
  : > "${stamp}"
  say "Installed ${name} to ${target_abs}"
done

say "All integrations done."


# 檢查日誌：
# journalctl -u ha-customcomponents-setup.service -b
# 
# 檢查檔案：
# ls /mnt/data/supervisor/homeassistant/custom_components
# 
# 更新某一個整合：刪除對應 stamp 後重開或重啟服務，例如：
# rm /mnt/data/supervisor/homeassistant/.firstboot-stamps/.xiaomi_miot.master.done





# ======== Auto-install Add-ons via HA CLI========
# 說明：
# 1) 這裡用 ha CLI 安裝/啟動你想要的「容器型 Add-ons」（與 custom_components 不同）
# 2) 舉例 VS Code（Studio Code Server）的 slug 固定為 a0d7b954_vscode

ADDONS="
a0d7b954_vscode
# 其他想裝的 slug 可一行一個加在這
"

# 等 Supervisor 就緒（ha CLI 可用）
j=0
until command -v ha >/dev/null 2>&1; do
  j=$((j+1)); [ $j -ge 60 ] && { say "WARN: ha CLI not found; skip add-ons"; break; }
  sleep 3
done

if command -v ha >/dev/null 2>&1; then
  k=0
  until ha info 2>&1 | grep -vq "System is not ready with state: setup"; do
    k=$((k+1)); [ $k -ge 60 ] && { say "WARN: supervisor still setup; skip add-ons"; break; }
    sleep 5
  done

  echo "${ADDONS}" | while IFS= read -r slug; do
    case "$slug" in ""|\#*) continue ;; esac

    if ha addons list | grep -q "\"slug\": \"${slug}\""; then
      say "Add-on ${slug} already present, ensuring started..."
      ha addons start "${slug}" || true
      continue
    fi

    say "Installing add-on ${slug} ..."
    tries=0
    until ha addons install "${slug}"; do
      tries=$((tries+1))
      [ $tries -ge 10 ] && { say "ERROR: install ${slug} failed after retries."; break; }
      sleep 6
    done
    ha addons start "${slug}" || true
  done
fi
# ======== End of Add-ons section ========
 

# ======== Reload Home Assistant Core 讀取安裝的 addons ========
if command -v ha >/dev/null 2>&1; then
  say "Restarting Home Assistant Core to apply new integrations..."
  ha core restart || say "WARN: failed to restart core."
else
  say "ha CLI not found; skip core restart."
fi
# ======== End of script ========