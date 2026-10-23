#!/bin/bash
set -u

# 接收配置文件路径
CONFIG="${1:-repos.json}"
CACHE_FILE="sync_state.json"
FORCE_SYNC="${FORCE_SYNC:-false}"

# ================= INIT =================
if [ ! -f "$CACHE_FILE" ]; then
  echo "{}" > "$CACHE_FILE"
fi

TOTAL=0
NOCHANGE=0
SUCCESS=0
FAILED=0
UPDATED_REPOS=""
FAILED_REPOS=""

# 获取东八区时间
TZ_TIME=$(TZ='Asia/Shanghai' date '+%Y-%m-%d %H:%M:%S')

# 依赖检查
if ! command -v jq &> /dev/null; then
    echo "Error: jq is not installed."
    exit 1
fi

echo "🚀 Starting Sync Job at $TZ_TIME (Force Sync: $FORCE_SYNC)"

# 转义 HTML 特殊字符
escape_html() {
    local s="$1"
    s="${s//&/&amp;}"
    s="${s//</&lt;}"
    s="${s//>/&gt;}"
    printf '%s' "$s"
}

# Telegram 消息发送函数（优先 HTML，带错误捕获与纯文本降级保护）
send_telegram() {
    local text="$1"
    local mode="${2:-HTML}"
    
    if [ -z "${TG_BOT_TOKEN:-}" ] || [ -z "${TG_CHAT_ID:-}" ]; then
        echo "⚠️ TG_BOT_TOKEN or TG_CHAT_ID is not set. Skipping Telegram notification."
        return 0
    fi

    local response
    response=$(curl -s -S -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
        -d chat_id="${TG_CHAT_ID}" \
        -d parse_mode="${mode}" \
        --data-urlencode "text=${text}" 2>&1)

    if echo "$response" | grep -q '"ok":true'; then
        echo "✅ Telegram notification sent successfully."
    else
        echo "⚠️ Telegram notification failed in ${mode} mode: $response"
        echo "🔄 Retrying in plain text mode..."
        local fallback_resp
        fallback_resp=$(curl -s -S -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
            -d chat_id="${TG_CHAT_ID}" \
            --data-urlencode "text=${text}" 2>&1)
        if echo "$fallback_resp" | grep -q '"ok":true'; then
            echo "✅ Telegram notification delivered via plain text fallback."
        else
            echo "❌ Telegram plain text fallback failed: $fallback_resp"
        fi
    fi
}

# 判定是否为自动同步生成的 bot 提交
is_bot_commit() {
    local commit="$1"
    local an ae msg
    an=$(git log -1 --format="%an" "$commit" 2>/dev/null || echo "")
    ae=$(git log -1 --format="%ae" "$commit" 2>/dev/null || echo "")
    msg=$(git log -1 --format="%s" "$commit" 2>/dev/null || echo "")

    if [[ "$an" == *"github-actions[bot]"* ]] || \
       [[ "$ae" == *"github-actions[bot]"* ]] || \
       [[ "$ae" == *"action@github.com"* ]] || \
       [[ "$msg" =~ ^Merge\ remote-tracking\ branch\ \'upstream/ ]] || \
       [[ "$msg" =~ ^chore\(sync\) ]]; then
        return 0
    fi
    return 1
}

# ================= LOOP =================
for row in $(jq -c '.[]' "$CONFIG"); do
  TOTAL=$((TOTAL + 1))

  # 解析 JSON 配置
  fork=$(echo "$row" | jq -r '.fork')
  upstream=$(echo "$row" | jq -r '.upstream')
  branch=$(echo "$row" | jq -r '.branch')
  notify=$(echo "$row" | jq -r '.notify')

  echo "------------------------------------------------"
  echo "🔍 Checking $fork ($branch)..."

  # [STEP 1] 获取 Upstream 特定分支的最新 SHA
  UPSTREAM_API="https://api.github.com/repos/$upstream/commits/$branch"
  AUTH_HEADER=""
  if [ -n "${GH_PAT:-}" ]; then
      AUTH_HEADER="Authorization: token $GH_PAT"
  fi

  if [ -n "$AUTH_HEADER" ]; then
      UPSTREAM_DATA=$(curl -s -H "$AUTH_HEADER" "$UPSTREAM_API")
  else
      UPSTREAM_DATA=$(curl -s "$UPSTREAM_API")
  fi

  UPSTREAM_SHA=$(echo "$UPSTREAM_DATA" | jq -r '.sha // empty')

  # 异常处理
  if [ -z "$UPSTREAM_SHA" ] || [ "$UPSTREAM_SHA" == "null" ]; then
      echo "⚠️ Failed to fetch upstream SHA for $upstream. Skipping."
      FAILED=$((FAILED + 1))
      FAILED_REPOS+="❌ $(escape_html "$fork ($branch)")\n"
      continue
  fi

  # [STEP 2] 读取本地缓存对比
  CACHE_KEY="${fork}:${branch}"
  LAST_SYNCED_SHA=$(jq -r --arg key "$CACHE_KEY" '.[$key] // "none"' "$CACHE_FILE")

  echo "   Upstream Latest: ${UPSTREAM_SHA:0:7}"
  echo "   Last Synced:     ${LAST_SYNCED_SHA:0:7}"

  # 缓存命中：若非强制同步且 SHA 相同，则跳过
  if [ "$FORCE_SYNC" != "true" ] && [ "$UPSTREAM_SHA" == "$LAST_SYNCED_SHA" ]; then
      echo "✅ No changes (Cache Hit). Skipping."
      NOCHANGE=$((NOCHANGE + 1))
      continue
  fi

  echo "⚡ Syncing $fork ($branch)..."

  # ================= SYNC PROCESS =================
  rm -rf repo
  LOG_FILE="../sync_error.log"
  rm -f "$LOG_FILE"
  SYNC_STATUS="success"

  if ! git clone "https://$GH_PAT@github.com/$fork.git" repo &>> "$LOG_FILE"; then
      echo "❌ Git clone failed for $fork!"
      SYNC_STATUS="fail"
  else
      cd repo || exit 1

      git config user.name  "github-actions[bot]"
      git config user.email "github-actions[bot]@users.noreply.github.com"

      git remote add upstream "https://github.com/$upstream.git"

      echo "⬇️  Fetching ONLY upstream/$branch..."
      if ! git fetch --no-tags upstream "$branch:refs/remotes/upstream/$branch" &>> "$LOG_FILE"; then
          echo "❌ Git fetch upstream failed!"
          SYNC_STATUS="fail"
      else
          echo "🔀 Checking out branch $branch..."
          if ! git checkout -B "$branch" "origin/$branch" &>> "$LOG_FILE"; then
              echo "❌ Checkout failed! (Branch might not exist on origin?)"
              SYNC_STATUS="fail"
          else
              # 核心同步与保留用户提交逻辑
              # 1. 查找基础提交：自 HEAD 向后跳过所有旧的 bot 同步提交
              CURR="HEAD"
              while is_bot_commit "$CURR"; do
                  PARENT=$(git rev-parse "${CURR}^1" 2>/dev/null || true)
                  if [ -z "$PARENT" ]; then
                      break
                  fi
                  CURR="$PARENT"
              done

              BASE_COMMIT=$(git rev-parse "$CURR")
              echo "   Base Commit: ${BASE_COMMIT:0:7}"

              # 2. 判断用户是否存在自定义提交
              if git merge-base --is-ancestor "$BASE_COMMIT" "upstream/$branch" 2>/dev/null; then
                  # 用户无自定义提交（独有 commit 均为旧 bot 提交或无额外提交）
                  # 若当前 HEAD 已与 upstream 完全一致，则无需重复 push
                  if [ "$(git rev-parse HEAD)" == "$UPSTREAM_SHA" ]; then
                      echo "✅ Already aligned with upstream. No changes needed."
                      SYNC_STATUS="skipped_push"
                  else
                      echo "🧹 Pure fork detected (no custom commits). Aligning directly with upstream..."
                      git reset --hard "upstream/$branch"
                      if ! git push --force "https://$GH_PAT@github.com/$fork.git" "$branch" &>> "$LOG_FILE"; then
                          echo "❌ Push failed!"
                          SYNC_STATUS="fail"
                      else
                          echo "✅ Successfully aligned with upstream."
                      fi
                  fi
              else
                  # 用户存在自定义提交：保留用户提交，自动同步提交有且仅保留最新的一个
                  echo "🌟 User custom commits detected! Resetting to base (${BASE_COMMIT:0:7}) and merging upstream..."
                  git reset --hard "$BASE_COMMIT"

                  # 合并 upstream，使用 -X ours 优先保障用户改动冲突时安全保留
                  if ! git merge -X ours "upstream/$branch" --no-edit --allow-unrelated-histories -m "chore(sync): sync upstream $branch" &>> "$LOG_FILE"; then
                      echo "❌ Merge failed!"
                      SYNC_STATUS="fail"
                  else
                      echo "✅ Merge success, pushing (keeping user commits + single sync commit)..."
                      if ! git push --force "https://$GH_PAT@github.com/$fork.git" "$branch" &>> "$LOG_FILE"; then
                          echo "❌ Push failed!"
                          SYNC_STATUS="fail"
                      fi
                  fi
              fi
          fi
      fi

      cd ..
      rm -rf repo
  fi

  # ================= UPDATE CACHE & REPORT =================
  if [ "$SYNC_STATUS" = "success" ] || [ "$SYNC_STATUS" = "skipped_push" ]; then
      if [ "$SYNC_STATUS" = "success" ]; then
          SUCCESS=$((SUCCESS + 1))
          UPDATED_REPOS+="✅ $(escape_html "$fork ($branch)")\n"
      else
          NOCHANGE=$((NOCHANGE + 1))
      fi

      jq --arg key "$CACHE_KEY" --arg sha "$UPSTREAM_SHA" '.[$key] = $sha' "$CACHE_FILE" > "${CACHE_FILE}.tmp" && mv "${CACHE_FILE}.tmp" "$CACHE_FILE"
  else
      FAILED=$((FAILED + 1))
      FAILED_REPOS+="❌ $(escape_html "$fork ($branch)")\n"

      ERROR_LOG=""
      if [ -f "$LOG_FILE" ]; then
          ERROR_LOG=$(tail -n 15 "$LOG_FILE")
      fi

      FAIL_MSG="❌ <b>Sync Failed</b>\n"
      FAIL_MSG+="<b>Repo:</b> $(escape_html "$fork")\n"
      FAIL_MSG+="<b>Branch:</b> $(escape_html "$branch")\n"
      FAIL_MSG+="<b>Upstream:</b> $(escape_html "$upstream")\n\n"
      FAIL_MSG+="📝 <b>Log:</b>\n<pre>$(escape_html "$ERROR_LOG")</pre>"

      send_telegram "$FAIL_MSG" "HTML"
  fi

done

# ================= FINAL REPORT =================
if [ "$TOTAL" -eq "$NOCHANGE" ]; then
    echo "ℹ️ No changes detected across all $TOTAL repositories. No Telegram notification sent."
    exit 0
fi

REPORT="📊 <b>Github 上游同步报告</b>\n"
REPORT+="🕒 <b>时间：</b>${TZ_TIME}\n\n"
REPORT+="📦 <b>仓库总数：</b>${TOTAL}\n"
REPORT+="➖ <b>无变化：</b>${NOCHANGE}\n"
REPORT+="🟢 <b>成功更新：</b>${SUCCESS}\n"
REPORT+="🔴 <b>更新失败：</b>${FAILED}\n"

if [ -n "$UPDATED_REPOS" ]; then
    REPORT+="\n🚀 <b>更新列表：</b>\n${UPDATED_REPOS}"
fi

if [ -n "$FAILED_REPOS" ]; then
    REPORT+="\n💥 <b>失败列表：</b>\n${FAILED_REPOS}"
fi

send_telegram "$REPORT" "HTML"

echo "✅ All done."
