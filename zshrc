# System zsh baseline for the code-server sandbox image (→ /etc/zsh/zshrc).
# Loaded for every interactive shell before any ~/.zshrc, so EVERY user gets a
# working shell with no dotfiles. Personal configs (chezmoi/host) layer on top.

# PATH: user-local bins (claude + code-server are already on PATH via /usr/local/bin)
export PATH="$HOME/.local/bin:$PATH"

# History
export HISTFILE="$HOME/.zsh_history"
export HISTSIZE=50000 SAVEHIST=50000
setopt INC_APPEND_HISTORY SHARE_HISTORY HIST_IGNORE_DUPS HIST_IGNORE_SPACE

# Sensible options
setopt AUTO_CD INTERACTIVE_COMMENTS
export EDITOR=vi LANG=C.UTF-8

# Claude Code: classic scrolling renderer. The default flicker-free renderer
# repaints with absolute cursor addressing and never scrolls finalized
# transcript lines off the top, so tmux history and the browser terminal's
# scrollback stay empty — scrolling up (mobile especially) shows torn repaint
# fragments instead of the conversation. The classic renderer commits the
# transcript to scrollback as it goes.
export CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN=1

# Completion
autoload -Uz compinit && compinit -d "$HOME/.zcompdump"
zstyle ':completion:*' menu select

# Tools shipped in the image
command -v zoxide >/dev/null && eval "$(zoxide init zsh)"
if command -v fzf >/dev/null; then
  if fzf --zsh >/dev/null 2>&1; then          # fzf >= 0.48
    source <(fzf --zsh)
  elif [ -f /usr/share/doc/fzf/examples/key-bindings.zsh ]; then
    source /usr/share/doc/fzf/examples/key-bindings.zsh
    [ -f /usr/share/doc/fzf/examples/completion.zsh ] && source /usr/share/doc/fzf/examples/completion.zsh
  fi
fi

# Aliases
alias ll='ls -alh'
alias gs='git status'
alias gd='git diff'
alias k='kubectl'

# Heavy build/test runs in disposable pods via `k8s-run` (see its skill).

# Simple git-aware prompt
autoload -Uz vcs_info; precmd() { vcs_info }
setopt PROMPT_SUBST
zstyle ':vcs_info:git:*' formats ' (%b)'
PROMPT='%F{cyan}%~%f%F{yellow}${vcs_info_msg_0_}%f %# '
