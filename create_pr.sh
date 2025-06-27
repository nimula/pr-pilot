#!/usr/bin/env bash
#
# create_pr.sh
# A script to create a pull request with AI-generated title and labels.
#
set -Eeuo pipefail

# ==============================================================================
# MARK: Environment Setup
# ==============================================================================

# 預設分支名稱
# 如果沒有提供分支名稱，則使用 main 作為預設目標分支
DEFAULT_TARGET_BRANCH="main"
# Define open ai model
DEFAULT_MODEL="gpt-4.1"
# 預設標籤配置
DEFAULT_LABEL_CONFIG=(
  "build:build"
  "ci:ci"
  "docs:documentation"
  "feat:feature"
  "fix:bug"
  "perf:enhancement"
  "refactor:enhancement"
  "style:enhancement"
  "test:test"
)
# PROMPT for AI title generation
read -r -d '' PROMPT <<'EOP' || true
You are a pull request title generation. Based on the provided context, summary a concise title.

Rules:
- Use English
- Focus only on the main change direction
- Don't list details or use semicolons
- Follow conventional commit format.
  *Only* use one of: build:, ci:, docs:, feat:, fix:, perf:, refactor:, style:, test:
- Format should be 'type: brief description  (#issue)'
- Remove (#issue) if no issue exists
- Return title directly
EOP

# Command line options
NO_PROMPT=false
SILENT=false

# ==============================================================================
# Functions
# ==============================================================================

function print_default() {
  echo -e "$*"
}

function print_info() {
  echo -e "\e[1;36m[INFO] $*\e[m" # cyan
}

function print_notice() {
  echo -e "\e[1;35m$*\e[m" # magenta
}

function print_success() {
  echo -e "\e[1;32m$*\e[m" # green
}

function print_warning() {
  echo -e "\e[1;33m[WARN] $*\e[m" # yellow
}

function print_error() {
  echo -e "\e[1;31m[ERROR] $*\e[m" # red
}

function print_help() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  -n     Do not prompt for input
  -s     Silent mode (do not prompt for input)
  -h     Show this help message
EOF
}

function parser_options() {
  while getopts ":nsh" opt; do
    case "$opt" in
      n) NO_PROMPT=true ;;
      s) SILENT=true ;;
      h)
        print_help
        exit 0
        ;;
      \?)
        echo "Unknown option: -$OPTARG" >&2
        print_help
        exit 1
        ;;
    esac
  done
  shift $((OPTIND - 1))

  if [ "$NO_PROMPT" != false ]; then
    NO_PROMPT=true
    print_info "No prompt mode enabled. No user input will be requested."
  fi
  if [ "$SILENT" != false ]; then
    SILENT=true
    print_info "Silent mode enabled. No prompts will be shown."
  fi
}

# MARK: Ensure Label Exists
function ensure_label_exists() {
  local label="$1"
  local color="${2:-"0366d6"}"  # 預設使用 GitHub 的藍色
  local description="${3:-""}"

  # 檢查標籤是否存在
  if ! gh api "repos/:owner/:repo/labels/$label" &>/dev/null; then
    print_info "標籤 '$label' 不存在，正在創建..."
    gh api --silent repos/:owner/:repo/labels \
      -f name="$label" \
      -f color="$color" \
      -f description="$description" || {
      print_error "警告: 無法創建標籤 '$label'"
      return 1
    }
  fi
}

# MARK: Generate PR Title with AI
function generate_pr_title_with_ai() {
  local branch="$1"
  local commits="$2"

  read -r -d "" commit_info << EOP || true
Branch name: $branch
Commits:
$commits
EOP

  local json_prompt=$(jq -n \
    --arg sys "$PROMPT" \
    --arg usr "$commit_info" \
    '[
      { "role": "system", "content": $sys },
      { "role": "user", "content": $usr }
    ]'
  )

  RESPONSE=$(curl -s -w "\n%{http_code}" https://api.openai.com/v1/chat/completions \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $OPENAI_API_KEY" \
    -d @- <<EOF
{
  "model": "$DEFAULT_MODEL",
  "messages": $json_prompt,
  "max_completion_tokens": 100,
  "temperature": 0.7
}
EOF
)
  echo "$RESPONSE"
}

# MARK: Generate PR Title with Dummy Data
# This function simulates the AI response for testing purposes
function generate_pr_title_with_dummy() {
  read -r -d "" RESPONSE << EOP || true
{
  "id": "chatcmpl-BmZt7jlBimwrFitsI1LsfsZNVBRmo",
  "object": "chat.completion",
  "created": 1750917397,
  "model": "gpt-4.1-2025-04-14",
  "choices": [
    {
      "index": 0,
      "message": {
        "role": "assistant",
        "content": "feat: add setuptools-scm versioning and improve UI layout",
        "refusal": null,
        "annotations": []
      },
      "logprobs": null,
      "finish_reason": "stop"
    }
  ],
  "usage": {
    "prompt_tokens": 275,
    "completion_tokens": 12,
    "total_tokens": 287,
    "prompt_tokens_details": {
      "cached_tokens": 0,
      "audio_tokens": 0
    },
    "completion_tokens_details": {
      "reasoning_tokens": 0,
      "audio_tokens": 0,
      "accepted_prediction_tokens": 0,
      "rejected_prediction_tokens": 0
    }
  },
  "service_tier": "default",
  "system_fingerprint": "fp_51e1070cf2"
}

200
EOP
  echo "$RESPONSE"
}

# MARK: Edit Message Function
function edit_message() {
  local temp_file
  temp_file=$(mktemp /tmp/edit_msg.XXXXXX)

  # 寫入預設提示內容（可自訂）
  cat > "$temp_file" <<EOF
$1
# 請輸入內容，儲存並離開編輯器後將繼續...
EOF

  # 啟動編輯器（使用 $EDITOR 或預設 vim）使用 tty 確保互動式終端操作
  "${EDITOR:-vim}" "$temp_file" < /dev/tty > /dev/tty

  # 讀取檔案內容到變數（並移除註解與空白行）
  local content
  content=$(grep -v '^\s*#' "$temp_file" | sed '/^\s*$/d')

  # 清除暫存檔
  rm "$temp_file"

  # 回傳內容（標準輸出）
  echo "$content"
}

# ==============================================================================
# MARK: Environment Checks
# ==============================================================================

# 檢查是否安裝了gh CLI
if ! command -v gh &> /dev/null; then
  print_error "錯誤: GitHub CLI (gh) 未安裝"
  print_default "請安裝 GitHub CLI: https://cli.github.com/"
  exit 1
fi

# 檢查是否安裝了jq
if ! command -v jq &> /dev/null; then
  print_error "錯誤: 未安裝 jq 工具，無法解析 JSON 回應"
  exit 1
fi

# 檢查是否已登錄GitHub
if ! gh auth status &> /dev/null; then
  print_info "請先登錄GitHub:"
  # gh auth login
fi

# 嘗試讀取本地配置文件
if [ -f ".pr-labels" ]; then
  # 讀取自定義標籤配置
  mapfile -t LABEL_CONFIG < ".pr-labels"
else
  LABEL_CONFIG=("${DEFAULT_LABEL_CONFIG[@]}")
fi

# Load .env if present
if [[ -f .env ]]; then
  export $(grep -v '^#' .env | xargs)
fi

# 如果尚未設置 OPENAI_API_KEY，嘗試從 pass 取得
if [ -z "$OPENAI_API_KEY" ]; then
  api_key_from_pass=$(pass show openai/key 2>/dev/null)
  if [ -n "$api_key_from_pass" ]; then
    OPENAI_API_KEY="$api_key_from_pass"
  fi
fi

# 檢查是否設置了 OPENAI_API_KEY 環境變數
if [ -z "$OPENAI_API_KEY" ]; then
  echo "警告: 未設置 OPENAI_API_KEY 環境變數，將無法使用 AI 生成標題建議"
  HAS_AI=false
else
  HAS_AI=false
fi

# Read command line options
parser_options "$@"

# ==============================================================================
# MARK: Main Script Execution
# Environment setup completed, start create PR process
# ==============================================================================

# if $1 is provided, use it as the target branch
TARGET_BRANCH="${1:-$DEFAULT_TARGET_BRANCH}"

# 檢查目標分支是否存在
if ! git show-ref --verify --quiet "refs/heads/$TARGET_BRANCH"; then
  print_error "錯誤: 目標分支 '$TARGET_BRANCH' 不存在"
  exit 1
fi

# 獲取當前分支
CURRENT_BRANCH=$(git symbolic-ref --short HEAD)
print_info "當前分支: $CURRENT_BRANCH => 目標分支: $TARGET_BRANCH"

# 獲取所有commit的標題
COMMITS=$(git log origin/$TARGET_BRANCH..$CURRENT_BRANCH --pretty=format:"%s")

# 顯示所有commits供參考
print_default "當前分支的所有commits:"
git log origin/$TARGET_BRANCH..$CURRENT_BRANCH --pretty=format:"%h %s"

# 分析所有commit來決定主要改動類型
if echo "$COMMITS" | grep -iq "fix\|bug\|hotfix"; then
  TYPE="fix"
elif echo "$COMMITS" | grep -iq "feat\|feature"; then
  TYPE="feat"
elif echo "$COMMITS" | grep -iq "refactor"; then
  TYPE="refactor"
elif echo "$COMMITS" | grep -iq "docs\|doc"; then
  TYPE="docs"
else
  TYPE="feat"
fi

# 提取issue編號（如果有的話）
ISSUE_NUM=$(echo "$CURRENT_BRANCH $COMMITS" | grep -oE '#[0-9]+' || true | head -1)

AI_SUGGESTION=""
# 如果有設置 OPENAI_API_KEY，則使用 AI 生成標題建議
if [ "$HAS_AI" = true ]; then
  print_default "\n正在使用 AI 生成標題建議..."

  # 使用函式產生 PR 標題
  # RESPONSE=$(generate_pr_title_with_ai "$CURRENT_BRANCH" "$COMMITS")
  RESPONSE=$(generate_pr_title_with_dummy "$CURRENT_BRANCH" "$COMMITS")

  HTTP_BODY=$(echo "$RESPONSE" | sed '$d')
  HTTP_STATUS=$(echo "$RESPONSE" | tail -n1)

  # 檢查 API 是否返回錯誤
  if [[ "$HTTP_STATUS" -ne 200 ]]; then
    print_warning "API 調用出錯："
    print_default "$HTTP_BODY"
  else
    # 解析 API 回應
    AI_SUGGESTION=$(echo "$HTTP_BODY" | jq -r '.choices[0].message.content')
    if [[ -z "$AI_SUGGESTION" || "$AI_SUGGESTION" == "null" ]]; then
      print_default ""
      print_warning "無法從 API 獲得有效的標題建議："
      print_default "$HTTP_BODY"
    else
      print_default "\nAI 建議的標題: $AI_SUGGESTION"
    fi
  fi
else
  print_default "\n未設置 OPENAI_API_KEY，無法使用 AI 生成標題建議"
fi

# 如果 AI 建議的標題為空，則使用預設標題
if [[ -z "$AI_SUGGESTION" || "$AI_SUGGESTION" == "null" ]]; then
  MAIN_COMMIT=$(git log -1 --pretty=%s)
  if [ -n "$ISSUE_NUM" ]; then
    AI_SUGGESTION="$TYPE: $MAIN_COMMIT ($ISSUE_NUM)"
  else
    AI_SUGGESTION="$TYPE: $MAIN_COMMIT"
  fi
  print_default "使用預設標題: $AI_SUGGESTION"
fi

PR_TITLE="$AI_SUGGESTION"
PR_BODY=""

# 移除重複的標籤前綴
if [ -n "$PR_TITLE" ]; then
  # 使用LABEL_CONFIG提取標籤前綴
  LABEL_PREFIXES=$(printf "%s\n" "${LABEL_CONFIG[@]}" | cut -d':' -f1 | tr '\n' '|')

  # 移除重複的標籤前綴
  FIXED_PR_TITLE=$(echo "$PR_TITLE" | sed -E "s/^($LABEL_PREFIXES): .*($LABEL_PREFIXES)\([^)]*\): /\1: /" || echo "$PR_TITLE")

  # if FIXED_PR_TITLE is not empty and not equal to PR_TITLE, then update PR_TITLE
  if [[ -n "$FIXED_PR_TITLE" && "$FIXED_PR_TITLE" != "$PR_TITLE" ]]; then
    print_default "\n移除重複標籤前綴後的標題: $FIXED_PR_TITLE"
    PR_TITLE="$FIXED_PR_TITLE"
  fi
fi

# 讓使用者選擇是否要手動輸入標題
print_default "\n是否要手動輸入PR標題? (y/N)"
read -r MANUAL_TITLE
MANUAL_TITLE=$(echo "$MANUAL_TITLE" | tr '[:upper:]' '[:lower:]')

if [[ "$MANUAL_TITLE" == "y" ]]; then
  read -r -d "" MESSAGE << EOP || true
$PR_TITLE

# Please enter the PR title and body for your change.
# First line should be the title, followed by a blank line, then the body.
# You can use the following format:
# TYPE: Your title ISSUE_NUM
# Lines starting with '#' will be ignored, and empty lines will be skipped.
EOP

  # 使用編輯器讓用戶輸入PR標題
  USER_INPUT=$(edit_message "$MESSAGE")
  # 提取標題和描述
  PR_TITLE=$(echo "$USER_INPUT" | sed -n '1p')
  PR_BODY=$(echo "$USER_INPUT" | sed '1d' | sed '/^\s*$/d')
fi

# 確保PR標題不為空
if [ -z "$PR_TITLE" ]; then
  print_error "錯誤：PR標題不能為空"
  exit 1
fi

# MARK: Generate PR Label
# 嘗試從分支名或commit中提取標籤類型
PR_LABEL="${LABEL_CONFIG[3]#*:}"  # 使用 feature 類型作為預設

for label_mapping in "${LABEL_CONFIG[@]}"; do
  type="${label_mapping%%:*}"
  label="${label_mapping#*:}"
  if echo "$CURRENT_BRANCH $PR_TITLE" | grep -iq "$type"; then
    PR_LABEL="$label"
    break
  fi
done

print_default "PR title: $PR_TITLE"
print_default "PR label: $PR_LABEL"
if [ -n "$PR_BODY" ]; then
  print_default "PR body: $PR_BODY"
fi

# 確保本地更改已提交
# if [[ -n $(git status -uno --porcelain) ]]; then
#   echo "有未提交的更改。是否要提交這些更改? (y/N)"
#   read -r COMMIT_CHANGES
#   COMMIT_CHANGES=$(echo "$MANUAL_TITLE" | tr '[:upper:]' '[:lower:]')

#   if [[ "$COMMIT_CHANGES" == "y" ]]; then
#     echo "請輸入提交信息:"
#     read -r COMMIT_MSG
#     git add -u
#     git commit
#   else
#     echo "請先提交或儲藏您的更改再繼續"
#     exit 1
#   fi
# fi

exit 0

# 推送當前分支到遠程
print_default "正在推送分支 $CURRENT_BRANCH 到遠程..."
git push -u origin "$CURRENT_BRANCH"

# 創建PR
print_default "正在創建PR從 $CURRENT_BRANCH 到 $TARGET_BRANCH..."

# 如果提供了標籤，確保標籤存在
if [ -n "$PR_LABEL" ]; then
  # 移除可能的引號
  PR_LABEL=$(echo "$PR_LABEL" | tr -d '"')
  # 確保標籤存在
  ensure_label_exists "$PR_LABEL"
fi

# 準備PR創建命令
PR_CMD="gh pr create --title \"$PR_TITLE\" --body \"$PR_BODY\" --base \"$TARGET_BRANCH\" --head \"$CURRENT_BRANCH\""

# 如果提供了標籤，則添加到命令中
if [ -n "$PR_LABEL" ]; then
  PR_CMD="$PR_CMD --label \"$PR_LABEL\""
  print_default "將添加標籤: $PR_LABEL"
fi

# 執行PR創建命令
PR_URL=$(eval $PR_CMD)

print_success "PR創建完成: $PR_URL"

# 提取PR編號以便後續使用
PR_NUMBER=$(echo $PR_URL | grep -oE '[0-9]+$')
if [ -n "$PR_NUMBER" ]; then
  print_success "PR編號: $PR_NUMBER"
fi
