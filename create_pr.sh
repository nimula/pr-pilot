#!/usr/bin/env zsh
# Author : nimula+github@gmail.com
#
set -Eeuo pipefail

source print_utils.sh

function usage() {
  setopt local_options posix_argzero

  cat <<EOF
git pull requests

Create a pull request from @{push} against @{upstream}.

$(tput bold)USAGE$(tput sgr0)
  $(tput bold; tput setaf 74)$(basename "$0") <command> [augments] [options]$(tput sgr0)

$(tput bold)COMMAND$(tput sgr0)
  create:             Create a pull request
  edit:               Update an existing pull request body
  open:               Opens the pull request URL for the current branch in the browser

$(tput bold)OPTIONS$(tput sgr0)
  -B, --base branch   The branch into which you want your code merged
  -d, --draft         Creates a draft pull request (only applies when creating a new PR)
  -H, --head branch   The branch that contains commits for your pull request (default [current branch])
  -n, --no-prompt     Do not prompt for input
  -s, --silent        Silent mode (do not prompt for input)

  --help              Show this help message
EOF
}

function main() {
  # Read command line options
  parser_options "$@"
  # Check environment and dependencies
  environment_check

  case "$ACTION" in
    create)
      create_pr "${ARGS[@]}"
      ;;
    edit)
      edit_pr "${ARGS[@]}"
      ;;
    open)
      open_pr "${ARGS[@]}"
      ;;
    *)
      print_error "Unknown command: $ACTION"
      usage
      exit 1
      ;;
  esac
}

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
ARGS=()
ACTION="create"
DRAFT=false
NO_PROMPT=false

# ==============================================================================
# Functions
# ==============================================================================

# MARK: Environment Check
function environment_check() {
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
    gh auth login
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
    set -o allexport
    source .env
    set +o allexport
  fi

  # 如果尚未設置 OPENAI_API_KEY，嘗試從 pass 取得
  if [ -z "${OPENAI_API_KEY:-}" ] && command -v pass >/dev/null 2>&1; then
    api_key_from_pass=$(pass show openai/key 2>/dev/null)
    if [ -n "$api_key_from_pass" ]; then
      OPENAI_API_KEY="$api_key_from_pass"
    fi
  fi

  # 檢查是否設置了 OPENAI_API_KEY 環境變數
  if [ -z "${OPENAI_API_KEY:-}" ]; then
    echo "警告: 未設置 OPENAI_API_KEY 環境變數，將無法使用 AI 生成標題建議"
    HAS_AI=false
  else
    HAS_AI=true
  fi

  # TODO: stop setting this once `gh` gains decent up/push branch recognition.
  # Set GH_REPO and GH_HOST environment variables based on the upstream remote
  # Ref: https://github.com/cli/cli/issues/7216#issuecomment-1479568670
  local up_ref=$(branch_ref "@{upstream}") # e.g. up/main
  local up_remote=${up_ref%%/*} # e.g. up
  export GH_REPO=$(remote_url "$up_remote")
}

# MARK: Parse Command Line Options
function parser_options() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      create | edit | open)
        ACTION="$1"
        ;;
      -B|--base)
        TARGET_BRANCH="$2"
        print_default "設定目標分支為: $TARGET_BRANCH"
        shift
        ;;
      -H|--head)
        CURRENT_BRANCH="$2"
        print_default "設定當前分支為: $CURRENT_BRANCH"
        shift
        ;;
      -d|--draft)
        DRAFT=true
        print_info "Draft mode enabled. PR will be created as a draft."
        ;;
      -n|--no-prompt)
        NO_PROMPT=true
        print_info "No prompt mode enabled. No user input will be requested."
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      -*)
        print_error "Unknown option: $1"
        usage
        exit 1
        ;;
      *)
        ARGS+=("$1")
        ;;
    esac
    shift
  done

  if [[ -n "${ARGS[*]}" && -z "$ACTION" ]]; then
    ACTION="${ARGS[0]}"
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
  local temp_file=$(mktemp /tmp/edit_msg.XXXXXX)
  trap "rm -f "$temp_file"" EXIT
  # 寫入預設提示內容（可自訂）
  cat > "$temp_file" <<EOF
$1
# 請輸入內容，儲存並離開編輯器後將繼續...
EOF

  # Launch the editor to allow user to edit the message, tty is used to ensure the editor can read input
  "${EDITOR:-vim}" "$temp_file" < /dev/tty > /dev/tty && true
  local rc=$?
  # If the editor was closed with an error, return the error code
  if [[ $rc != 0 ]]; then
    return $rc
  fi

  # Lines starting with '#' will be ignored, then only remove the empty lines between first non-empty line and second non-empty line
  local content=$(awk '
  /^[[:space:]]*#/ { next }          # skip lines starting with #
  /^[[:space:]]*$/ {                  # blank lines
    if (started == 0) next           # skip leading blanks
    if (nonempty == 1) next          # skip blanks between first and second nonempty
  }
  {
    started = 1
    if ($0 !~ /^[[:space:]]*$/) nonempty++
    print
  }
' "$temp_file")

  # 回傳內容（標準輸出）
  echo "$content"
}

# MARK: Create PR Function
function create_pr() {
  # if target branch is not provided, use the default target branch
  TARGET_BRANCH="${TARGET_BRANCH:-$DEFAULT_TARGET_BRANCH}"
  # 檢查目標分支是否存在
  if ! git show-ref --verify --quiet "refs/heads/$TARGET_BRANCH"; then
    print_error "錯誤: 目標分支 '$TARGET_BRANCH' 不存在"
    exit 1
  fi

  # 獲取當前分支
  CURRENT_BRANCH="${CURRENT_BRANCH:-$(git symbolic-ref --short HEAD)}"
  # 檢查當前分支是否存在
  if ! git show-ref --verify --quiet "refs/heads/$CURRENT_BRANCH"; then
    print_error "錯誤: 當前分支 '$CURRENT_BRANCH' 不存在"
    exit 1
  fi

  print_info "當前分支: $CURRENT_BRANCH => 目標分支: $TARGET_BRANCH"

  local commit_count=$(git rev-list --count origin/$TARGET_BRANCH..$CURRENT_BRANCH)
  if [ "$commit_count" -eq 0 ]; then
    print_error "錯誤: 當前分支 '$CURRENT_BRANCH' 沒有新的提交"
    exit 1
  fi

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
    RESPONSE=$(generate_pr_title_with_ai "$CURRENT_BRANCH" "$COMMITS")
    # RESPONSE=$(generate_pr_title_with_dummy "$CURRENT_BRANCH" "$COMMITS")

    HTTP_BODY=$(echo "$RESPONSE" | sed '$d')
    HTTP_STATUS=$(echo "$RESPONSE" | tail -n1)

    # 檢查 API 是否返回錯誤
    if [[ "$HTTP_STATUS" -ne 200 ]]; then
      print_warning "API 調用出錯："
      print_default "$HTTP_BODY"
    else
      # 解析 API 回應
      AI_SUGGESTION=$(echo -E "$HTTP_BODY" | jq -r '.choices[0].message.content')
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
  LABEL_PREFIXES=$(printf "%s\n" "${LABEL_CONFIG[@]}" | cut -d':' -f1 | tr '\n' '|' | sed 's/|$//')

    # 移除重複的標籤前綴
    FIXED_PR_TITLE=$(echo "$PR_TITLE" | sed -E "s/^($LABEL_PREFIXES): .*($LABEL_PREFIXES)\([^)]*\): /\1: /" || echo "$PR_TITLE")

    # if FIXED_PR_TITLE is not empty and not equal to PR_TITLE, then update PR_TITLE
    if [[ -n "$FIXED_PR_TITLE" && "$FIXED_PR_TITLE" != "$PR_TITLE" ]]; then
      print_default "\n移除重複標籤前綴後的標題: $FIXED_PR_TITLE"
      PR_TITLE="$FIXED_PR_TITLE"
    fi
  fi

  # MARK: Manual input
  # 讓使用者選擇是否要手動輸入 PR 標題和內文
  if [ "$NO_PROMPT" = true ]; then
    MANUAL_TITLE="n"
  else
    print_default "\n是否要手動輸入PR標題及內文? (y/N)"
    read -r MANUAL_TITLE
    MANUAL_TITLE=$(echo "$MANUAL_TITLE" | tr '[:upper:]' '[:lower:]')
  fi

  if [[ "$MANUAL_TITLE" == "y" ]]; then
    read -r -d "" MESSAGE << EOP || true
$PR_TITLE

# Please enter the PR title and body for your change.
# First line should be the title, followed by a blank line, then the body.
# You can use the following format:
# TYPE: Your title ISSUE_NUM
# Lines starting with '#' will be ignored, and empty lines between title and body will be skipped.
EOP

    # use edit_message function to allow user to edit the message
    USER_INPUT=$(edit_message "$MESSAGE")

    # first line is PR_TITLE, the rest is PR_BODY
    PR_TITLE=$(echo "$USER_INPUT" | sed -n '1p' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    PR_BODY=$(echo "$USER_INPUT" | sed '1d')
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

  # MARK: PR ready to create
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
  PR_CMD_ARRAY=(gh pr create --title "$PR_TITLE" --body "$PR_BODY" --base "$TARGET_BRANCH" --head "$CURRENT_BRANCH")

  if [[ "$DRAFT" = true ]]; then
    PR_CMD_ARRAY+=(--draft)
  fi
  # If label provided, add to command
  # 如果提供了標籤，則添加到命令中
  if [ -n "$PR_LABEL" ]; then
    PR_CMD_ARRAY+=(--label "$PR_LABEL")
    print_default "將添加標籤: $PR_LABEL"
  fi

  # Execute PR creation command
  # 執行PR創建命令
  PR_URL=$("${PR_CMD_ARRAY[@]}")

  print_success "PR創建完成: $PR_URL"

  # 提取PR編號以便後續使用
  PR_NUMBER=$(echo $PR_URL | grep -oE '[0-9]+$')
  if [ -n "$PR_NUMBER" ]; then
    print_success "PR編號: $PR_NUMBER"
  fi

  open_pr "$PR_NUMBER"
}

# MARK: Edit PR Function
function edit_pr() {
  local pr_number="${1:-$(get_pr_number)}"

  if [[ -z "$pr_number" ]]; then
    print_error "錯誤: 未提供 PR 編號"
    exit 1
  fi
  if ! [[ "$pr_number" =~ ^[0-9]+$ ]]; then
    print_error "錯誤: PR 編號必須是數字"
    exit 1
  fi

  print_default "開始處理 PR: $pr_number"
  print_default "正在獲取PR的reviews..."
  local reviews=$(gh pr view $pr_number --json reviews,comments)
  local review_count=$(echo -E "$reviews" | jq '.reviews | length')
  print_default "找到 $review_count 個 reviews"

  print_default "正在尋找 gemini-code-assist 的 Summary of Changes..."
  # 先從 reviews 中尋找
  local gemini_review=$(echo -E "$reviews" | jq -r '.reviews[] | select(.author.login == "gemini-code-assist") | .body' || true)

  # 如果在 reviews 中沒找到，就從 comments 中尋找
  if [ -z "$gemini_review" ]; then
    print_default "未在 reviews 中找到 gemini-code-assist 的內容，正在尋找 comments..."
    gemini_review=$(echo -E "$reviews" | jq -r '.comments[] | select(.author.login == "gemini-code-assist") | .body' || true)
  fi

  if [ -n "$gemini_review" ]; then
    print_default "找到 gemini-code-assist 的 summary"
  else
    print_default "未找到 gemini-code-assist 的 summary"
    exit 1
  fi

  print_default "Gemini Review Content:"
  echo "$gemini_review" | sed 's/^/  /' | head -n 5

  print_default "正在更新PR描述..."
  # update RP description on the origin repo without set default remote repository
  gh pr edit $pr_number --body "$gemini_review"
  open_pr $pr_number
}

# MARK: Open PR Function
function open_pr() {
  # if $1 is provided, use it as the PR number else get the PR number from the current branch
  local pr_number="${1:-$(get_pr_number)}"

  print_default "Opening PR #$pr_number in browser..."
  if [[ -z "$pr_number" ]]; then
    print_error "錯誤: 未提供 PR 編號"
    exit 1
  fi
  if ! [[ "$pr_number" =~ ^[0-9]+$ ]]; then
    print_error "錯誤: PR 編號必須是數字"
    exit 1
  fi

  # if the SSH_CONNECTION variable is not set, it means we are not in an SSH session and we can open the PR in the default web browser
  if [[ -z "${SSH_CONNECTION:-}" ]]; then
    gh pr view -w $pr_number
  else
    print_success "PR 已更新，請在本地瀏覽器中查看"
    print_default "PR URL: $(gh pr view --json url --jq '.url' $pr_number)"
  fi
}

function branch_ref() {
  git rev-parse --abbrev-ref --symbolic-full-name "$1"
}

function remote_url() {
  git remote get-url "$1"
}

# Remote hostname, used for setting GH_HOST.
function remote_host() {
  git remote get-url ${1:?} | sed -e 's/^git@//' -e 's|https://||' -e 's/:.*//' -e 's|/.*||'
}

function remote_org() {
  git remote get-url $1 | awk -F ':|/' '{if ($NF) {print $(NF-1)} else {print $(NF-2)}}'
}

function remote_repo() {
  git remote get-url $1 | sed -e 's|/$||' -e 's|.*/||' -e 's/.git$//'
}

function get_pr_number() {
  local push_ref=$(branch_ref "@{push}")
  local push_remote=${push_ref%%/*}
  local push_branch=${push_ref#*/}
  local push_org=$(remote_org "$push_remote")
  # You should be able to just run this:
  # gh pr view -w
  # But gh can't detect push branches, e.g. https://github.com/cli/cli/issues/575
  # Try to get open PR first
  gh pr list \
    --state=open \
    --limit=1 \
    --head="$push_org:$push_branch" \
    --json=number | jq -e '.[0].number' ||

  # Fallback to any (open or closed) PR
  gh pr list \
    --state=all \
    --limit=1 \
    --head="$push_branch" \
    --json=number | jq -e '.[0].number' ||

  { print_error "Failed to get PR number"; exit 1; }
}

main "$@"
