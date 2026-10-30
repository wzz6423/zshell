# Shell completion remains inside ZLE so quoting and cursor edits use the shell.
(( ${+_zshell_completions_loaded} )) && return
typeset -g _zshell_completions_loaded=1
typeset -g _zshell_completion_resources=${${(%):-%x}:A:h}

_zshell_initialize_completions() {
  emulate -L zsh
  local directory=$_zshell_completion_resources/completions
  (( ${fpath[(Ie)$directory]} )) || fpath+=($directory)
  if (( ! ${+_comps} || ! ${+functions[_main_complete]} )); then
    autoload -Uz compinit
    # Do not write a dump or bypass compaudit in the user's configuration.
    compinit -D -i || return
  else
    # A user's cached compinit may predate the bundled functions. Register only
    # missing commands through compdef, leaving user definitions and widgets intact.
    local file header name
    local -a definitions
    for file in $directory/_*(N); do
      IFS= read -r header < "$file"
      [[ $header == '#compdef '* ]] || continue
      definitions=(${(z)${header#\#compdef }})
      autoload -Uz ${file:t}
      for name in $definitions; do
        [[ $name == -* ]] && break
        (( ${+_comps[${name%%=*}]} )) || compdef ${file:t} "$name"
      done
    done
  fi
}
_zshell_initialize_completions
unfunction _zshell_initialize_completions

_zshell_has_suggestion_provider() {
  local widget
  (( ${+functions[_zsh_autosuggest_start]} || ${+functions[_zsh_autosuggest_bind_widgets]} )) && return 0
  for widget in ${(k)widgets}; do
    [[ ${widget:l} == *autosuggest* || ${widgets[$widget]:l} == *autosuggest* ]] && return 0
  done
  (( ${+functions[_autocomplete__init]} || ${+functions[_autocomplete__main]} \
      || ${+functions[_fig_start]} || ${+functions[_q_autosuggest_start]} ))
}

if ! _zshell_has_suggestion_provider; then
  # Completion comes first; history fills contexts without completion functions.
  (( ${+ZSH_AUTOSUGGEST_STRATEGY} )) || typeset -ga ZSH_AUTOSUGGEST_STRATEGY=(completion history)
  (( ${+ZSH_AUTOSUGGEST_BUFFER_MAX_SIZE} )) || typeset -g ZSH_AUTOSUGGEST_BUFFER_MAX_SIZE=1024
  (( ${+ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE} )) || typeset -g ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE='fg=244'
  source "$_zshell_completion_resources/zsh-autosuggestions.zsh"
  ZSH_AUTOSUGGEST_CLEAR_WIDGETS+=(menu-complete)
  typeset -g _zshell_owns_suggestions=1

  _zshell_dismiss_suggestion() {
    typeset -g _zshell_dismissed_buffer=$BUFFER
    zle autosuggest-clear
  }
  zle -N _zshell_dismiss_suggestion
  # An asynchronous result must not resurrect a dismissed or mid-buffer hint.
  _zshell_suggestion_before_redraw() {
    [[ ${_zshell_dismissed_buffer-} != "$BUFFER" ]] && unset _zshell_dismissed_buffer
    if (( CURSOR != ${#BUFFER} || REGION_ACTIVE )) || (( ${+_zshell_dismissed_buffer} )); then
      zle autosuggest-clear
    fi
  }
  autoload -Uz add-zle-hook-widget
  add-zle-hook-widget line-pre-redraw _zshell_suggestion_before_redraw
fi
unfunction _zshell_has_suggestion_provider

_zshell_completion_bindings() {
  emulate -L zsh
  local keymap binding
  local -a menu_style
  if ! zstyle -a ':completion:*' menu menu_style; then
    zstyle ':completion:*' menu select=2
  fi
  zmodload zsh/complist || return
  for keymap in emacs viins; do
    binding=$(bindkey -M "$keymap" '^I')
    if [[ $binding == *' expand-or-complete' || $binding == *' complete-word' ]]; then
      bindkey -M "$keymap" '^I' menu-complete
    fi
    if (( ${+_zshell_owns_suggestions} )); then
      binding=$(bindkey -M "$keymap" $'\e')
      [[ $binding == *' undefined-key' ]] && bindkey -M "$keymap" $'\e' _zshell_dismiss_suggestion
    fi
  done
  # Only supply unclaimed cancellation keys in the shell's existing menu map.
  for binding in $'\e' $'\x07'; do
    [[ $(bindkey -M menuselect "$binding") == *' undefined-key' ]] && \
      bindkey -M menuselect "$binding" send-break
  done
}
_zshell_completion_bindings
autoload -Uz add-zsh-hook
add-zsh-hook precmd _zshell_completion_bindings
