#!/usr/bin/env bash
#
# This is forked from Kitty's bash integration and is therefore licensed
# under the same GPLv3 as Kitty:
# https://github.com/kovidgoyal/kitty/blob/master/shell-integration/bash/kitty.bash

if [[ "$-" != *i* ]] ; then builtin return; fi  # check in interactive mode

# Load the normal bash startup files
if [[ -n "$GHOSTTY_BASH_INJECT" ]]; then
    builtin declare ghostty_bash_inject="$GHOSTTY_BASH_INJECT"
    builtin unset GHOSTTY_BASH_INJECT ENV
    if [[ -z "$HOME" ]]; then HOME=~; fi
    if [[ -z "$GHOSTTY_BASH_ETC_LOCATION" ]]; then GHOSTTY_BASH_ETC_LOCATION="/etc"; fi

    _ghostty_sourceable() {
        [[ -f "$1" && -r "$1" ]] && builtin return 0; builtin return 1;
    }

    if [[ "$ghostty_bash_inject" == *"posix"* ]]; then
        _ghostty_sourceable "$GHOSTTY_BASH_POSIX_ENV" && {
            builtin source "$GHOSTTY_BASH_POSIX_ENV"
            builtin export ENV="$GHOSTTY_BASH_POSIX_ENV"
        }
    else
        builtin set +o posix
        builtin shopt -u inherit_errexit 2>/dev/null  # resetting posix does not clear this
        if [[ -n "$GHOSTTY_BASH_UNEXPORT_HISTFILE" ]]; then
            builtin export -n HISTFILE
            builtin unset GHOSTTY_BASH_UNEXPORT_HISTFILE
        fi

        # See run_startup_files() in shell.c in the Bash source code
        if builtin shopt -q login_shell; then
            if [[ "$ghostty_bash_inject" != *"no-profile"* ]]; then
                _ghostty_sourceable "$GHOSTTY_BASH_ETC_LOCATION/profile" && builtin source "$GHOSTTY_BASH_ETC_LOCATION/profile"
                for _ghostty_i in "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile"; do
                    _ghostty_sourceable "$_ghostty_i" && { builtin source "$_ghostty_i"; break; }
                done
            fi
        else
            if [[ "$ghostty_bash_inject" != *"no-rc"* ]]; then
                # Linux distros build bash with -DSYS_BASHRC. Unfortunately, there is
                # no way to to probe bash for it and different distros use different files
                # Arch, Debian, Ubuntu use /etc/bash.bashrc
                # Fedora uses /etc/bashrc sourced from ~/.bashrc instead of SYS_BASHRC
                # Void Linux uses /etc/bash/bashrc
                for _ghostty_i in "$GHOSTTY_BASH_ETC_LOCATION/bash.bashrc" "$GHOSTTY_BASH_ETC_LOCATION/bash/bashrc" ; do
                    _ghostty_sourceable "$_ghostty_i" && { builtin source "$_ghostty_i"; break; }
                done
                if [[ -z "$GHOSTTY_BASH_RCFILE" ]]; then GHOSTTY_BASH_RCFILE="$HOME/.bashrc"; fi
                _ghostty_sourceable "$GHOSTTY_BASH_RCFILE" && builtin source "$GHOSTTY_BASH_RCFILE"
            fi
        fi
    fi
    builtin unset GHOSTTY_BASH_RCFILE GHOSTTY_BASH_POSIX_ENV GHOSTTY_BASH_ETC_LOCATION
    builtin unset -f _ghostty_sourceable
    builtin unset _ghostty_i ghostty_bash_inject
fi


if [ "${BASH_VERSINFO:-0}" -lt 4 ]; then
    builtin printf "%s\n" "Bash version ${BASH_VERSION} too old, Ghostty shell integration disabled" > /dev/stderr
    builtin return
fi

if [[ "${_ghostty_prompt[sourced]}" == "y" ]]; then
    # we have already run
    builtin return
fi

# this is defined outside _ghostty_main to make it global without using declare -g
# which is not available on older bash
builtin declare -A _ghostty_prompt
_ghostty_prompt=(
    [cursor]='y' [title]='y' [mark]='y' [cwd]='y' [ps0]='' [ps0_suffix]='' [ps1]='' [ps1_suffix]='' [ps2]=''
    [hostname_prefix]='' [sourced]='y' [last_reported_cwd]=''
)

_ghostty_main() {
    _ghostty_set_mark() {
        _ghostty_prompt["${1}_mark"]="\[\e]133;k;${1}_ghostty\a\]"
    }

    _ghostty_set_mark start
    _ghostty_set_mark end
    _ghostty_set_mark start_secondary
    _ghostty_set_mark end_secondary
    _ghostty_set_mark start_suffix
    _ghostty_set_mark end_suffix
    builtin unset -f _ghostty_set_mark
    _ghostty_prompt[secondary_prompt]="\n${_ghostty_prompt[start_secondary_mark]}\[\e]133;A;k=s\a\]${_ghostty_prompt[end_secondary_mark]}"

    _ghostty_prompt_command() {
        # we first remove any previously added ghostty code from the prompt variables and then add
        # it back, to ensure we have only a single instance
        if [[ -n "${_ghostty_prompt[ps0]}" ]]; then
            PS0=${PS0//\\\[\\e\]133;k;start_ghostty\\a\\\]*end_ghostty\\a\\\]}
            PS0="${_ghostty_prompt[ps0]}$PS0"
        fi
        if [[ -n "${_ghostty_prompt[ps0_suffix]}" ]]; then
            PS0=${PS0//\\\[\\e\]133;k;start_suffix_ghostty\\a\\\]*end_suffix_ghostty\\a\\\]}
            PS0="${PS0}${_ghostty_prompt[ps0_suffix]}"
        fi
        # restore PS1 to its pristine state without our additions
        if [[ -n "${_ghostty_prompt[ps1]}" ]]; then
            PS1=${PS1//\\\[\\e\]133;k;start_ghostty\\a\\\]*end_ghostty\\a\\\]}
            PS1=${PS1//\\\[\\e\]133;k;start_secondary_ghostty\\a\\\]*end_secondary_ghostty\\a\\\]}
        fi
        if [[ -n "${_ghostty_prompt[ps1_suffix]}" ]]; then
            PS1=${PS1//\\\[\\e\]133;k;start_suffix_ghostty\\a\\\]*end_suffix_ghostty\\a\\\]}
        fi
        if [[ -n "${_ghostty_prompt[ps1]}" ]]; then
            if [[ "${_ghostty_prompt[mark]}" == "y" && ( "${PS1}" == *"\n"* || "${PS1}" == *$'\n'* ) ]]; then
                builtin local oldval
                oldval=$(builtin shopt -p extglob)
                builtin shopt -s extglob
                # bash does not redraw the leading lines in a multiline prompt so
                # mark the last line as a secondary prompt. Otherwise on resize the
                # lines before the last line will be erased by ghostty.
                # the first part removes everything from the last \n onwards
                # the second part appends a newline with the secondary marking
                # the third part appends everything after the last newline
                PS1=${PS1%@('\n'|$'\n')*}${_ghostty_prompt[secondary_prompt]}${PS1##*@('\n'|$'\n')}
                builtin eval "$oldval"
            fi
            PS1="${_ghostty_prompt[ps1]}$PS1"
        fi
        if [[ -n "${_ghostty_prompt[ps1_suffix]}" ]]; then
            PS1="${PS1}${_ghostty_prompt[ps1_suffix]}"
        fi
        if [[ -n "${_ghostty_prompt[ps2]}" ]]; then
            PS2=${PS2//\\\[\\e\]133;k;start_ghostty\\a\\\]*end_ghostty\\a\\\]}
            PS2="${_ghostty_prompt[ps2]}$PS2"
        fi

        if [[ "${_ghostty_prompt[cwd]}" == "y" ]]; then
            # unfortunately bash provides no hooks to detect cwd changes
            # in particular this means cwd reporting will not happen for a
            # command like cd /test && cat. PS0 is evaluated before cd is run.
            if [[ "${_ghostty_prompt[last_reported_cwd]}" != "$PWD" ]]; then
                _ghostty_prompt[last_reported_cwd]="$PWD"
                builtin printf "\e]7;kitty-shell-cwd://%s%s\a" "$HOSTNAME" "$PWD"
            fi
        fi
    }

    if [[ "${_ghostty_prompt[cursor]}" == "y" ]]; then
        _ghostty_prompt[ps1_suffix]+="\[\e[5 q\]"  # blinking bar cursor
        _ghostty_prompt[ps0_suffix]+="\[\e[0 q\]"  # blinking default cursor
    fi

    if [[ "${_ghostty_prompt[title]}" == "y" ]]; then
        # see https://www.gnu.org/software/bash/manual/html_node/Controlling-the-Prompt.html#Controlling-the-Prompt
        # we use suffix here because some distros add title setting to their bashrc files by default
        _ghostty_prompt[ps1_suffix]+="\[\e]2;${_ghostty_prompt[hostname_prefix]}\w\a\]"
        _ghostty_get_current_command() {
            builtin local last_cmd
            last_cmd=$(HISTTIMEFORMAT= builtin history 1)
            last_cmd="${last_cmd#*[[:digit:]]*[[:space:]]}"  # remove leading history number
            last_cmd="${last_cmd#"${last_cmd%%[![:space:]]*}"}"  # remove remaining leading whitespace
            builtin printf "\e]2;%s%s\a" "${_ghostty_prompt[hostname_prefix]@P}" "${last_cmd//[[:cntrl:]]}"  # remove any control characters
        }
        _ghostty_prompt[ps0_suffix]+='$(_ghostty_get_current_command)'
    fi

    if [[ "${_ghostty_prompt[mark]}" == "y" ]]; then
        _ghostty_prompt[ps1]+="\[\e]133;A\a\]"
        _ghostty_prompt[ps2]+="\[\e]133;A;k=s\a\]"
        _ghostty_prompt[ps0]+="\[\e]133;C\a\]"
    fi

    # wrap our prompt additions in markers we can use to remove them using
    # bash's anemic pattern substitution
    if [[ -n "${_ghostty_prompt[ps0]}" ]]; then
        _ghostty_prompt[ps0]="${_ghostty_prompt[start_mark]}${_ghostty_prompt[ps0]}${_ghostty_prompt[end_mark]}"
    fi
    if [[ -n "${_ghostty_prompt[ps0_suffix]}" ]]; then
        _ghostty_prompt[ps0_suffix]="${_ghostty_prompt[start_suffix_mark]}${_ghostty_prompt[ps0_suffix]}${_ghostty_prompt[end_suffix_mark]}"
    fi
    if [[ -n "${_ghostty_prompt[ps1]}" ]]; then
        _ghostty_prompt[ps1]="${_ghostty_prompt[start_mark]}${_ghostty_prompt[ps1]}${_ghostty_prompt[end_mark]}"
    fi
    if [[ -n "${_ghostty_prompt[ps1_suffix]}" ]]; then
        _ghostty_prompt[ps1_suffix]="${_ghostty_prompt[start_suffix_mark]}${_ghostty_prompt[ps1_suffix]}${_ghostty_prompt[end_suffix_mark]}"
    fi
    if [[ -n "${_ghostty_prompt[ps2]}" ]]; then
        _ghostty_prompt[ps2]="${_ghostty_prompt[start_mark]}${_ghostty_prompt[ps2]}${_ghostty_prompt[end_mark]}"
    fi
    # BASH aborts the entire script when doing unset with failglob set, somebody should report this upstream
    oldval=$(builtin shopt -p failglob)
    builtin shopt -u failglob
    builtin unset _ghostty_prompt[start_mark] _ghostty_prompt[end_mark] _ghostty_prompt[start_suffix_mark] _ghostty_prompt[end_suffix_mark] _ghostty_prompt[start_secondary_mark] _ghostty_prompt[end_secondary_mark]
    builtin eval "$oldval"

    # install our prompt command, using an array if it is unset or already an array,
    # otherwise append a string. We check if _ghostty_prompt_command exists as some shell
    # scripts stupidly export PROMPT_COMMAND making it inherited by all programs launched
    # from the shell
    builtin local pc
    pc='builtin declare -F _ghostty_prompt_command > /dev/null 2> /dev/null && _ghostty_prompt_command'
    if [[ -z "${PROMPT_COMMAND}" ]]; then
        PROMPT_COMMAND=([0]="$pc")
    elif [[ $(builtin declare -p PROMPT_COMMAND 2> /dev/null) =~ 'declare -a PROMPT_COMMAND' ]]; then
        PROMPT_COMMAND+=("$pc")
    else
        builtin local oldval
        oldval=$(builtin shopt -p extglob)
        builtin shopt -s extglob
        PROMPT_COMMAND="${PROMPT_COMMAND%%+([[:space:]])}"
        PROMPT_COMMAND="${PROMPT_COMMAND%%+(;)}"
        builtin eval "$oldval"
        PROMPT_COMMAND+="; $pc"
    fi
}
_ghostty_main
builtin unset -f _ghostty_main
