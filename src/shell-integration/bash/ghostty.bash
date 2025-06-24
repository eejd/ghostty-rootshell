# Parts of this script are based on Kitty's bash integration. Kitty is
# distributed under GPLv3, so this file is also distributed under GPLv3.
# The license header is reproduced below:
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

# We need to be in interactive mode to proceed.
if [[ "$-" != *i* ]] ; then builtin return; fi

# When automatic shell integration is active, we were started in POSIX
# mode and need to manually recreate the bash startup sequence.
if [ -n "$GHOSTTY_BASH_INJECT" ]; then
  # Store a temporary copy of our startup flags and unset these global
  # environment variables so we can safely handle reentrancy.
  builtin declare __ghostty_bash_flags="$GHOSTTY_BASH_INJECT"
  builtin unset ENV GHOSTTY_BASH_INJECT

  # Restore bash's default 'posix' behavior. Also reset 'inherit_errexit',
  # which doesn't happen as part of the 'posix' reset.
  builtin set +o posix
  builtin shopt -u inherit_errexit 2>/dev/null

  # Unexport HISTFILE if it was set by the shell integration code.
  if [[ -n "$GHOSTTY_BASH_UNEXPORT_HISTFILE" ]]; then
    builtin export -n HISTFILE
    builtin unset GHOSTTY_BASH_UNEXPORT_HISTFILE
  fi

  # Manually source the startup files. See INVOCATION in bash(1) and
  # run_startup_files() in shell.c in the Bash source code.
  if builtin shopt -q login_shell; then
    if [[ $__ghostty_bash_flags != *"--noprofile"* ]]; then
      [ -r /etc/profile ] && builtin source "/etc/profile"
      for __ghostty_rcfile in "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile"; do
        [ -r "$__ghostty_rcfile" ] && { builtin source "$__ghostty_rcfile"; break; }
      done
    fi
  else
    if [[ $__ghostty_bash_flags != *"--norc"* ]]; then
      # The location of the system bashrc is determined at bash build
      # time via -DSYS_BASHRC and can therefore vary across distros:
      #  Arch, Debian, Ubuntu use /etc/bash.bashrc
      #  Fedora uses /etc/bashrc sourced from ~/.bashrc instead of SYS_BASHRC
      #  Void Linux uses /etc/bash/bashrc
      #  Nixos uses /etc/bashrc
      for __ghostty_rcfile in /etc/bash.bashrc /etc/bash/bashrc /etc/bashrc; do
        [ -r "$__ghostty_rcfile" ] && { builtin source "$__ghostty_rcfile"; break; }
      done
      if [[ -z "$GHOSTTY_BASH_RCFILE" ]]; then GHOSTTY_BASH_RCFILE="$HOME/.bashrc"; fi
      [ -r "$GHOSTTY_BASH_RCFILE" ] && builtin source "$GHOSTTY_BASH_RCFILE"
    fi
  fi

  builtin unset __ghostty_rcfile
  builtin unset __ghostty_bash_flags
  builtin unset GHOSTTY_BASH_RCFILE
fi

# Sudo
if [[ "$GHOSTTY_SHELL_FEATURES" == *"sudo"* && -n "$TERMINFO" ]]; then
  # Wrap `sudo` command to ensure Ghostty terminfo is preserved.
  #
  # This approach supports wrapping a `sudo` alias, but the alias definition
  # must come _after_ this function is defined. Otherwise, the alias expansion
  # will take precedence over this function, and it won't be wrapped.
  function sudo {
    builtin local sudo_has_sudoedit_flags="no"
    for arg in "$@"; do
      # Check if argument is '-e' or '--edit' (sudoedit flags)
      if [[ "$arg" == "-e" || $arg == "--edit" ]]; then
        sudo_has_sudoedit_flags="yes"
        builtin break
      fi
      # Check if argument is neither an option nor a key-value pair
      if [[ "$arg" != -* && "$arg" != *=* ]]; then
        builtin break
      fi
    done
    if [[ "$sudo_has_sudoedit_flags" == "yes" ]]; then
      builtin command sudo "$@";
    else
      builtin command sudo TERMINFO="$TERMINFO" "$@";
    fi
  }
fi

# SSH Integration
if [[ "$GHOSTTY_SHELL_FEATURES" =~ ssh-(env|terminfo) ]]; then
  # Only define cache functions and variable if ssh-terminfo is enabled
  if [[ "$GHOSTTY_SHELL_FEATURES" =~ ssh-terminfo ]]; then
    _cache="${XDG_STATE_HOME:-$HOME/.local/state}/ghostty/terminfo_hosts"

    # Cache operations and utilities
    _ghst_cache() {
      case $2 in
      chk) [[ -f $_cache ]] && grep -qFx "$1" "$_cache" 2>/dev/null ;;
      add)
        mkdir -p "${_cache%/*}"
        {
          [[ -f $_cache ]] && cat "$_cache"
          builtin echo "$1"
        } | sort -u >"$_cache.tmp" && mv "$_cache.tmp" "$_cache" && chmod 600 "$_cache"
        ;;
      esac
    }

    function ghostty_ssh_cache_clear() { 
      rm -f "$_cache" 2>/dev/null && builtin echo "Ghostty SSH terminfo cache cleared." || builtin echo "No Ghostty SSH terminfo cache found."
    }

    function ghostty_ssh_cache_list() { 
      [[ -s $_cache ]] && builtin echo "Hosts with Ghostty terminfo installed:" && cat "$_cache" || builtin echo "No cached hosts found."
    }
  fi

  # SSH wrapper
  ssh() {
    local e=() o=() c=() t

    # Get target
    t=$(builtin command ssh -G "$@" 2>/dev/null | awk '/^(user|hostname) /{print $2}' | paste -sd'@')

    # Set up env vars first so terminfo installation inherits them
    if [[ "$GHOSTTY_SHELL_FEATURES" =~ ssh-env ]]; then
      builtin export COLORTERM=${COLORTERM:-truecolor} TERM_PROGRAM=${TERM_PROGRAM:-ghostty} ${GHOSTTY_VERSION:+TERM_PROGRAM_VERSION=$GHOSTTY_VERSION}
      for v in COLORTERM=truecolor TERM_PROGRAM=ghostty ${GHOSTTY_VERSION:+TERM_PROGRAM_VERSION=$GHOSTTY_VERSION}; do
        o+=(-o "SendEnv ${v%=*}" -o "SetEnv $v")
      done
    fi

    # Install terminfo if needed, reuse control connection for main session
    if [[ "$GHOSTTY_SHELL_FEATURES" =~ ssh-terminfo ]]; then
      if [[ -n $t ]] && _ghst_cache "$t" chk; then
        e+=(TERM=xterm-ghostty)
      elif builtin command -v infocmp >/dev/null 2>&1; then
        builtin local ti
        ti=$(infocmp -x xterm-ghostty 2>/dev/null) || builtin echo "Warning: xterm-ghostty terminfo not found locally." >&2
        if [[ -n $ti ]]; then
          builtin echo "Setting up Ghostty terminfo on remote host..." >&2
          builtin local cp
          cp="/tmp/ghostty-ssh-$USER-$RANDOM-$(date +%s)"
          case $(builtin echo "$ti" | builtin command ssh "${o[@]}" -o ControlMaster=yes -o ControlPath="$cp" -o ControlPersist=60s "$@" '
            infocmp xterm-ghostty >/dev/null 2>&1 && echo OK && exit
            command -v tic >/dev/null 2>&1 || { echo NO_TIC; exit 1; }
            mkdir -p ~/.terminfo 2>/dev/null && tic -x - 2>/dev/null && echo OK || echo FAIL
          ') in
          OK)
            builtin echo "Terminfo setup complete." >&2
            [[ -n $t ]] && _ghst_cache "$t" add
            e+=(TERM=xterm-ghostty)
            c+=(-o "ControlPath=$cp")
            ;;
          *) builtin echo "Warning: Failed to install terminfo." >&2 ;;
          esac
        fi
      else
        builtin echo "Warning: infocmp not found locally. Terminfo installation unavailable." >&2
      fi
    fi

    # Fallback TERM only if terminfo didn't set it
    if [[ "$GHOSTTY_SHELL_FEATURES" =~ ssh-env ]]; then
      [[ $TERM == xterm-ghostty && ! " ${e[*]} " =~ " TERM=" ]] && e+=(TERM=xterm-256color)
    fi

    # Execute
    if [[ ${#e[@]} -gt 0 ]]; then
      env "${e[@]}" ssh "${o[@]}" "${c[@]}" "$@"
    else
      builtin command ssh "${o[@]}" "${c[@]}" "$@"
    fi
  }

  # If 'ssh-terminfo' flag is enabled, wrap ghostty to provide 'ghostty ssh-cache-list' and `ghostty ssh-cache-clear` utility commands
  if [[ "$GHOSTTY_SHELL_FEATURES" =~ ssh-terminfo ]]; then
    ghostty() {
      case "$1" in
        ssh-cache-list) ghostty_ssh_cache_list ;;
        ssh-cache-clear) ghostty_ssh_cache_clear ;;
        *) builtin command ghostty "$@" ;;
      esac
    }
  fi
fi

# Import bash-preexec, safe to do multiple times
builtin source "$(dirname -- "${BASH_SOURCE[0]}")/bash-preexec.sh"

# This is set to 1 when we're executing a command so that we don't
# send prompt marks multiple times.
_ghostty_executing=""
_ghostty_last_reported_cwd=""

function __ghostty_precmd() {
    local ret="$?"
    if test "$_ghostty_executing" != "0"; then
      _GHOSTTY_SAVE_PS0="$PS0"
      _GHOSTTY_SAVE_PS1="$PS1"
      _GHOSTTY_SAVE_PS2="$PS2"

      # Marks
      PS1=$PS1'\[\e]133;B\a\]'
      PS2=$PS2'\[\e]133;B\a\]'

      # bash doesn't redraw the leading lines in a multiline prompt so
      # mark the last line as a secondary prompt (k=s) to prevent the
      # preceding lines from being erased by ghostty after a resize.
      if [[ "${PS1}" == *"\n"* || "${PS1}" == *$'\n'* ]]; then
        PS1=$PS1'\[\e]133;A;k=s\a\]'
      fi

      # Cursor
      if [[ "$GHOSTTY_SHELL_FEATURES" == *"cursor"* ]]; then
        PS1=$PS1'\[\e[5 q\]'
        PS0=$PS0'\[\e[0 q\]'
      fi

      # Title (working directory)
      if [[ "$GHOSTTY_SHELL_FEATURES" == *"title"* ]]; then
        PS1=$PS1'\[\e]2;\w\a\]'
      fi
    fi

    if test "$_ghostty_executing" != ""; then
      # End of current command. Report its status.
      builtin printf "\e]133;D;%s;aid=%s\a" "$ret" "$BASHPID"
    fi

    # unfortunately bash provides no hooks to detect cwd changes
    # in particular this means cwd reporting will not happen for a
    # command like cd /test && cat. PS0 is evaluated before cd is run.
    if [[ "$_ghostty_last_reported_cwd" != "$PWD" ]]; then
      _ghostty_last_reported_cwd="$PWD"
      builtin printf "\e]7;kitty-shell-cwd://%s%s\a" "$HOSTNAME" "$PWD"
    fi

    # Fresh line and start of prompt.
    builtin printf "\e]133;A;aid=%s\a" "$BASHPID"
    _ghostty_executing=0
}

function __ghostty_preexec() {
    builtin local cmd="$1"

    PS0="$_GHOSTTY_SAVE_PS0"
    PS1="$_GHOSTTY_SAVE_PS1"
    PS2="$_GHOSTTY_SAVE_PS2"

    # Title (current command)
    if [[ -n $cmd && "$GHOSTTY_SHELL_FEATURES" == *"title"* ]]; then
      builtin printf "\e]2;%s\a" "${cmd//[[:cntrl:]]}"
    fi

    # End of input, start of output.
    builtin printf "\e]133;C;\a"
    _ghostty_executing=1
}

preexec_functions+=(__ghostty_preexec)
precmd_functions+=(__ghostty_precmd)
