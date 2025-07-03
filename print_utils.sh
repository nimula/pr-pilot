#!/usr/bin/env bash
# Author : nimula+github@gmail.com
#

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

function print_debug() {
  if [[ "$VERBOSE" = true || "$DEBUG" = true ]]; then
    echo -e "\e[1;34m[DEBUG] $*\e[m" # blue
  fi
}
