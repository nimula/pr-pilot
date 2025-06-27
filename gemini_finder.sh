#!/usr/bin/env bash
#
# gemini_finder.sh
# A script to find the "Summary of Changes" section in a Gemini PR and update
# the PR description with the found content.
# Usage: ./gemini_finder.sh [options] [PR_NUMBER]
#
set -Eeuo pipefail

# ==============================================================================
# MARK: Environment Setup
# ==============================================================================

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
Usage: $(basename "$0") [options] [PR_NUMBER]

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

  # radd pr_number from positional arguments
  if [ $# -gt 0 ]; then
    PR_NUMBER="$1"
    if ! [[ "$PR_NUMBER" =~ ^[0-9]+$ ]]; then
      print_error "PR_NUMBER must be a number"
      exit 1
    fi
  else
    print_error "PR_NUMBER is required"
    print_help
    exit 1
  fi

  if [ "$NO_PROMPT" != false ]; then
    NO_PROMPT=true
    print_info "No prompt mode enabled. No user input will be requested."
  fi
  if [ "$SILENT" != false ]; then
    SILENT=true
    print_info "Silent mode enabled. No prompts will be shown."
  fi
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

# Read command line options
parser_options "$@"


# 檢查是否已登錄GitHub
if ! gh auth status &> /dev/null; then
  print_info "請先登錄GitHub:"
  # gh auth login
fi

# ==============================================================================
# MARK: Main Script Execution
# Environment setup completed, start create PR process
# ==============================================================================
print_default "開始處理 PR: $PR_NUMBER"

# 獲取PR的reviews
print_default "正在獲取PR的reviews..."
REVIEWS=$(gh pr view $PR_NUMBER --json reviews,comments)
REVIEW_COUNT=$(echo "$REVIEWS" | jq '.reviews | length')
print_default "找到 $REVIEW_COUNT 個 reviews"

print_default "正在尋找 gemini-code-assist 的 Summary of Changes..."
# 先從 reviews 中尋找
GEMINI_REVIEW=$(echo "$REVIEWS" | jq -r '.reviews[] | select(.author.login == "gemini-code-assist") | .body' || true)

# 如果在 reviews 中沒找到，就從 comments 中尋找
if [ -z "$GEMINI_REVIEW" ]; then
  print_default "未在 reviews 中找到 gemini-code-assist 的內容，正在尋找 comments..."
  GEMINI_REVIEW=$(echo "$REVIEWS" | jq -r '.comments[] | select(.author.login == "gemini-code-assist") | .body' || true)
fi

if [ -n "$GEMINI_REVIEW" ]; then
  print_default "找到 gemini-code-assist 的 summary"
else
  print_default "未找到 gemini-code-assist 的 summary"
  exit 1
fi

print_default "Gemini Review Content:"
echo "$GEMINI_REVIEW" | sed 's/^/  /' | head -n 5

branch_ref() {
  git rev-parse --abbrev-ref --symbolic-full-name "$1"
}

remote_url() {
  git remote get-url "$1"
}

# Remote hostname, used for setting GH_HOST.
remote_host() {
  git remote get-url ${1:?} | sed -e 's/^git@//' -e 's|https://||' -e 's/:.*//' -e 's|/.*||'
}

# Github org for remote. `remote_org up` -> gibfahn.
remote_org() {
  git remote get-url $1 | awk -F ':|/' '{if ($NF) {print $(NF-1)} else {print $(NF-2)}}'
}

# Github repo for remote. `remote_repo up` -> dot.
remote_repo() {
  git remote get-url $1 | sed -e 's|/$||' -e 's|.*/||' -e 's/.git$//'
}


up_ref=$(branch_ref "@{upstream}") # e.g. up/main
up_remote=${up_ref%%/*} # e.g. up
print_default "上游分支: $up_ref"
print_default "上游遠端: $up_remote"

if [ -z "${GH_REPO:-}" ]; then
  export GH_REPO=$(remote_url "$up_remote")
fi
if [ -z "${GH_HOST:-}" ]; then
  export GH_HOST=$(remote_host "$up_remote")
fi
print_default "上游遠端URL: $GH_REPO"
print_default "上游遠端主機: $GH_HOST"

print_default "正在更新PR描述..."
# update RP description on theh origin repo without set default remote repository
gh pr edit "$PR_NUMBER" --body "$GEMINI_REVIEW"
gh pr view -w $PR_NUMBER
