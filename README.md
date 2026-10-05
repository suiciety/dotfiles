# dotfiles

Mark's personal dotfiles: tmux config, oh-my-posh theme, shared shell config
(bash/zsh/fish), FIDO2 SSH/GPG key enrollment, and bootstrap scripts for
Linux, macOS, and Windows.

## Run

### Linux / macOS

```sh
curl -fsSL https://raw.githubusercontent.com/suiciety/dotfiles/main/bootstrap.sh | bash
```

Supports Debian/Ubuntu (apt), Arch (pacman), Fedora (dnf), openSUSE (zypper),
Alpine (apk), and macOS (Homebrew). On macOS it also offers to install a
Nerd Font (`font-caskaydia-cove-nerd-font`) via `brew install --cask` so the
tmux status bar and oh-my-posh prompt glyphs render correctly — set your
terminal app's font to **CaskaydiaCove Nerd Font** afterwards (Terminal.app /
iTerm2: Preferences → Profiles → Text).

### Windows

```powershell
Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
irm https://raw.githubusercontent.com/suiciety/dotfiles/main/bootstrap.ps1 | iex
```

If running inside WSL, use the Linux command above instead, and set a Nerd
Font (e.g. `CaskaydiaCove Nerd Font`, bundled with Windows Terminal) in your
Windows Terminal profile — bootstrap.sh will print a reminder.

## What bootstrap.sh does

1. Imports the GPG public key
2. Adds the SSH public key to `~/.ssh/authorized_keys` (skips if already present)
3. Checks FIDO2 prerequisites (OpenSSH 8.2+, libfido2), deploys `.pub` files, prompts to
   insert each YubiKey in sequence and exports private stubs via `ssh-keygen -K`
4. Installs tmux if missing; prompts to build 3.6 from source if version < 3.4
   (macOS always upgrades via Homebrew instead)
5. Writes `tmux.conf` (backs up any existing config first)
6. Installs TPM and tmux plugins directly via git (tpm, tmux-sensible, armando-rios/tmux)
7. Installs unzip if missing (required by the oh-my-posh installer)
8. Installs oh-my-posh if missing
9. Deploys the `atomic.omp.json` theme
10. Deploys shell configs: `config.fish` (fish), `shell_common.sh` (bash/zsh/POSIX) with
    VS Code guard, oh-my-posh prompt, and tmux auto-attach; sources `shell_common.sh`
    from rc files
11. Configures GPG agent for GPG operations only (not SSH); removes any old
    `SSH_AUTH_SOCK` lines
12. macOS: offers to install a Nerd Font via Homebrew cask; WSL: prints a
    reminder to set a Nerd Font in Windows Terminal

## Requirements

- **Nerd Font** — required for tmux status bar icons and oh-my-posh prompt glyphs.
  - macOS: installed automatically via `brew install --cask font-caskaydia-cove-nerd-font`
    (bootstrap.sh will prompt), or grab one manually from
    [nerdfonts.com](https://www.nerdfonts.com/font-downloads).
  - Windows Terminal: ships with CaskaydiaCove/CaskaydiaMono Nerd Font already.
  - Linux terminal emulators: install a Nerd Font manually and set it as your
    terminal font.
- tmux 3.4+ (bootstrap installs/upgrades this for you)
