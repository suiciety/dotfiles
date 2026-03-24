# ~/.config/fish/config.fish
# Deployed by bootstrap.sh — https://github.com/suiciety/dotfiles

# ── VS Code integrated terminal ───────────────────────────────────────────────
# VS Code sets TERM_PROGRAM=vscode. Skip everything — just a plain shell,
# no tmux, no prompt theme, no agent setup.
if test "$TERM_PROGRAM" = "vscode"
    return
end

# ── oh-my-posh prompt ─────────────────────────────────────────────────────────
oh-my-posh init fish --config ~/.config/omp/atomic.omp.json | source

# ── tmux auto-attach ──────────────────────────────────────────────────────────
# Attach to existing default session or create one.
# Skipped inside VS Code (caught above) and when already inside tmux.
if status is-interactive
    if not set -q TMUX
        tmux attach -t default || tmux new -s default
    end
end
