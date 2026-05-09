# dotfiles bash_profile — sourced from ~/.bashrc by install.sh

# ---------------------------------------------------------------------------
# Pager: -R keeps colors, -F quits if output fits one screen, -X no clear
# ---------------------------------------------------------------------------
export PAGER='less -RFX'
export LESS='-RFX'
export GIT_PAGER='delta'

# Editor
export EDITOR='vim'
export VISUAL='vim'

# History
export HISTSIZE=50000
export HISTFILESIZE=100000
export HISTCONTROL=ignoreboth:erasedups
shopt -s histappend 2>/dev/null || true

# Aliases
alias ll='ls -lah --color=auto'
alias la='ls -A --color=auto'
alias l='ls -CF --color=auto'
alias gs='git status -sb'
alias gd='git diff'
alias gl='git lg'
alias glo='git lol'
alias lg='lazygit'
alias gco='git checkout'
alias gsw='git switch'

# Reload this file
alias reload='source ~/.bashrc'

# Codespaces-friendly prompt: short cwd + branch + dirty marker
__git_branch_dirty() {
  local b
  b=$(git symbolic-ref --quiet --short HEAD 2>/dev/null) || \
  b=$(git rev-parse --short HEAD 2>/dev/null) || return
  local dirty=''
  [ -n "$(git status --porcelain 2>/dev/null)" ] && dirty='*'
  printf ' (%s%s)' "$b" "$dirty"
}
PS1='\[\e[36m\]\W\[\e[33m\]$(__git_branch_dirty)\[\e[0m\] $ '

# Source local overrides if present
[ -f "$HOME/bash_profile.local" ] && source "$HOME/bash_profile.local"
