// The setup Zshell makes unnecessary: completions and autosuggestions ship
// with it, and panes, sessions and agents are native instead of tmux glue.
// The lines are ordinary zsh and tmux syntax, not anyone's real dotfiles.

export type LegacyFile = { name: string; lines: string[]; x: number; y: number; rotate: number; at: number };

export const LEGACY_FILES: LegacyFile[] = [
  {
    name: '~/.zshrc',
    x: -430,
    y: -150,
    rotate: -4,
    at: 22,
    lines: [
      'export ZSH="$HOME/.oh-my-zsh"',
      'ZSH_THEME="powerlevel10k/powerlevel10k"',
      'plugins=(git z fzf docker zsh-autosuggestions)',
      'source $ZSH/oh-my-zsh.sh',
      'autoload -Uz compinit && compinit',
      'source ~/.zsh/zsh-syntax-highlighting.zsh',
      'eval "$(starship init zsh)"',
    ],
  },
  {
    name: '~/.tmux.conf',
    x: 400,
    y: -60,
    rotate: 3,
    at: 58,
    lines: [
      'unbind C-b',
      'set -g prefix C-a',
      'bind | split-window -h -c "#{pane_current_path}"',
      'bind - split-window -v -c "#{pane_current_path}"',
      "set -g @plugin 'tmux-plugins/tpm'",
      "set -g @plugin 'tmux-plugins/tmux-resurrect'",
      "run-shell '~/.tmux/plugins/tpm/tpm'",
    ],
  },
  {
    name: '~/.zsh/aliases.zsh',
    x: -90,
    y: 210,
    rotate: -2,
    at: 94,
    lines: [
      "alias ta='tmux attach -t'",
      "alias agent1='tmux new -s agent1'",
      "alias agent2='tmux new -s agent2'",
      "alias review='git diff | less -R'",
      "bindkey '^R' fzf-history-widget",
      'export EDITOR=nvim',
    ],
  },
];

export const LEGACY_LINE_COUNT = LEGACY_FILES.reduce((sum, file) => sum + file.lines.length, 0);
