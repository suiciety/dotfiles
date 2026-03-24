#!/usr/bin/env sh
# shell_common.sh — shared interactive-shell config for bash, zsh, and other POSIX shells
# Managed by bootstrap.sh — https://github.com/suiciety/dotfiles
#
# Sourced from ~/.bashrc, ~/.zshrc, etc.
# Provides: VS Code guard, PATH setup, oh-my-posh prompt, tmux auto-attach

# ── VS Code integrated terminal ───────────────────────────────────────────────
# VS Code sets TERM_PROGRAM=vscode. Return early — no prompt theme, no tmux.
# 'return' exits the sourced file; 2>/dev/null silences the error if run directly.
if [ "${TERM_PROGRAM}" = "vscode" ]; then
    return 2>/dev/null
fi

# ── PATH ──────────────────────────────────────────────────────────────────────
# ~/.local/bin — oh-my-posh and other user-installed tools
case ":${PATH}:" in
    *":${HOME}/.local/bin:"*) ;;
    *) export PATH="${HOME}/.local/bin:${PATH}" ;;
esac

# macOS Homebrew prefix (Apple Silicon: /opt/homebrew; Intel: /usr/local)
if command -v brew >/dev/null 2>&1; then
    _brew_prefix="$(brew --prefix)"
    case ":${PATH}:" in
        *":${_brew_prefix}/bin:"*) ;;
        *) export PATH="${_brew_prefix}/bin:${PATH}" ;;
    esac
    unset _brew_prefix
fi

# ── oh-my-posh prompt ─────────────────────────────────────────────────────────
if command -v oh-my-posh >/dev/null 2>&1; then
    # Detect running shell name; strip leading '-' from login shells (e.g. -bash → bash)
    _omp_shell="$(ps -p $$ -o comm= 2>/dev/null | sed 's/^-//')"
    [ -z "${_omp_shell}" ] && _omp_shell="$(basename "${SHELL:-sh}")"
    eval "$(oh-my-posh init "${_omp_shell}" --config "${HOME}/.config/omp/atomic.omp.json" 2>/dev/null)"
    unset _omp_shell
fi

# ── tmux auto-attach ──────────────────────────────────────────────────────────
# Attach to the 'default' session or create it.
# Only runs when: shell is interactive, not already inside tmux, tmux is installed.
case "$-" in
    *i*)
        if [ -z "${TMUX}" ] && command -v tmux >/dev/null 2>&1; then
            tmux attach -t default 2>/dev/null || tmux new -s default
        fi
        ;;
esac
