# This shell script aims to be written in a way where it can't really fail
# or all failure scenarios are handled, so that we never leave the shell in
# a weird state. If you find a way to break this, please report a bug!

function ghostty_restore_xdg_data_dir -d "restore the original XDG_DATA_DIR value"
    # If we don't have our own data dir then we don't need to do anything.
    if not set -q GHOSTTY_SHELL_INTEGRATION_XDG_DIR
        return
    end

    # If the data dir isn't set at all then we don't need to do anything.
    if not set -q XDG_DATA_DIRS
        return
    end

    # We need to do this so that XDG_DATA_DIRS turns into an array.
    set --function --path xdg_data_dirs "$XDG_DATA_DIRS"

    # If our data dir is in the list then remove it.
    if set --function index (contains --index "$GHOSTTY_SHELL_INTEGRATION_XDG_DIR" $xdg_data_dirs)
        set --erase --function xdg_data_dirs[$index]
    end

    # Re-export our data dir
    if set -q xdg_data_dirs[1]
        set --global --export --unpath XDG_DATA_DIRS "$xdg_data_dirs"
    else
        set --erase --global XDG_DATA_DIRS
    end

    set --erase GHOSTTY_SHELL_INTEGRATION_XDG_DIR
end

function ghostty_exit -d "exit the shell integration setup"
    functions -e ghostty_restore_xdg_data_dir
    functions -e ghostty_exit
    exit 0
end

# We always try to restore the XDG data dir
ghostty_restore_xdg_data_dir

# If we aren't interactive or we've already run, don't run.
status --is-interactive || ghostty_exit

# We do the full setup on the first prompt render. We do this so that other
# shell integrations that setup the prompt and modify things are able to run
# first. We want to run _last_.
function __ghostty_setup --on-event fish_prompt -d "Setup ghostty integration"
    functions -e __ghostty_setup

    set --local features (string split , $GHOSTTY_SHELL_FEATURES)

    if contains cursor $features
        # Change the cursor to a beam on prompt.
        function __ghostty_set_cursor_beam --on-event fish_prompt -d "Set cursor shape"
            echo -en "\e[5 q"
        end
        function __ghostty_reset_cursor --on-event fish_preexec -d "Reset cursor shape"
            echo -en "\e[0 q"
        end
    end

    # When using sudo shell integration feature, ensure $TERMINFO is set
    # and `sudo` is not already a function or alias
    if contains sudo $features; and test -n "$TERMINFO"; and test "file" = (type -t sudo 2> /dev/null; or echo "x")
        # Wrap `sudo` command to ensure Ghostty terminfo is preserved
        function sudo -d "Wrap sudo to preserve terminfo"
            set --function sudo_has_sudoedit_flags "no"
            for arg in $argv
                # Check if argument is '-e' or '--edit' (sudoedit flags)
                if string match -q -- "-e" "$arg"; or string match -q -- "--edit" "$arg"
                    set --function sudo_has_sudoedit_flags "yes"
                    break
                end
                # Check if argument is neither an option nor a key-value pair
                if not string match -r -q -- "^-" "$arg"; and not string match -r -q -- "=" "$arg"
                    break
                end
            end
            if test "$sudo_has_sudoedit_flags" = "yes"
                command sudo $argv
            else
                command sudo TERMINFO="$TERMINFO" $argv
            end
        end
    end

    # SSH Integration
    if string match -qr 'ssh-(env|terminfo)' "$GHOSTTY_SHELL_FEATURES"
        # Only define cache functions and variable if ssh-terminfo is enabled
        if string match -qr 'ssh-terminfo' "$GHOSTTY_SHELL_FEATURES"
            set -g _cache (test -n "$XDG_STATE_HOME" && echo "$XDG_STATE_HOME" || echo "$HOME/.local/state")/ghostty/terminfo_hosts

            # Cache operations and utilities
            function _ghst_cache
                switch $argv[2]
                    case chk
                        test -f $_cache && grep -qFx "$argv[1]" "$_cache" 2>/dev/null
                    case add
                        mkdir -p (dirname "$_cache")
                        begin
                            test -f $_cache && cat "$_cache"
                            builtin echo "$argv[1]"
                        end | sort -u >"$_cache.tmp" && mv "$_cache.tmp" "$_cache" && chmod 600 "$_cache"
                end
            end

            function ghostty_ssh_cache_clear -d "Clear Ghostty SSH terminfo cache"
                rm -f "$_cache" 2>/dev/null && builtin echo "Ghostty SSH terminfo cache cleared." || builtin echo "No Ghostty SSH terminfo cache found."
            end

            function ghostty_ssh_cache_list -d "List hosts with Ghostty terminfo installed"
                test -s $_cache && builtin echo "Hosts with Ghostty terminfo installed:" && cat "$_cache" || builtin echo "No cached hosts found."
            end
        end

        # SSH wrapper
        function ssh
            set -l e
            set -l o
            set -l c
            set -l t

            # Get target (only if ssh-terminfo enabled for caching)
            if string match -qr 'ssh-terminfo' "$GHOSTTY_SHELL_FEATURES"
                set t (builtin command ssh -G $argv 2>/dev/null | awk '/^(user|hostname) /{print $2}' | paste -sd'@')
            end

            # Set up env vars first so terminfo installation inherits them
            if string match -qr 'ssh-env' "$GHOSTTY_SHELL_FEATURES"
                set -gx COLORTERM (test -n "$COLORTERM" && echo "$COLORTERM" || echo "truecolor")
                set -gx TERM_PROGRAM (test -n "$TERM_PROGRAM" && echo "$TERM_PROGRAM" || echo "ghostty")
                test -n "$GHOSTTY_VERSION" && set -gx TERM_PROGRAM_VERSION "$GHOSTTY_VERSION"

                for v in COLORTERM=truecolor TERM_PROGRAM=ghostty (test -n "$GHOSTTY_VERSION" && echo "TERM_PROGRAM_VERSION=$GHOSTTY_VERSION")
                    set -l varname (string split -m1 '=' "$v")[1]
                    set o $o -o "SendEnv $varname" -o "SetEnv $v"
                end
            end

            # Install terminfo if needed, reuse control connection for main session
            if string match -qr 'ssh-terminfo' "$GHOSTTY_SHELL_FEATURES"
                if test -n "$t" && _ghst_cache "$t" chk
                    set e $e TERM=xterm-ghostty
                else if command -v infocmp >/dev/null 2>&1
                    set -l ti
                    set ti (infocmp -x xterm-ghostty 2>/dev/null) || builtin echo "Warning: xterm-ghostty terminfo not found locally." >&2
                    if test -n "$ti"
                        builtin echo "Setting up Ghostty terminfo on remote host..." >&2
                        set -l cp "/tmp/ghostty-ssh-$USER-"(random)"-"(date +%s)
                        set -l result (builtin echo "$ti" | builtin command ssh $o -o ControlMaster=yes -o ControlPath="$cp" -o ControlPersist=60s $argv '
                            infocmp xterm-ghostty >/dev/null 2>&1 && echo OK && exit
                            command -v tic >/dev/null 2>&1 || { echo NO_TIC; exit 1; }
                            mkdir -p ~/.terminfo 2>/dev/null && tic -x - 2>/dev/null && echo OK || echo FAIL
                        ')
                        switch $result
                            case OK
                                builtin echo "Terminfo setup complete." >&2
                                test -n "$t" && _ghst_cache "$t" add
                                set e $e TERM=xterm-ghostty
                                set c $c -o "ControlPath=$cp"
                            case '*'
                                builtin echo "Warning: Failed to install terminfo." >&2
                        end
                    end
                else
                    builtin echo "Warning: infocmp not found locally. Terminfo installation unavailable." >&2
                end
            end

            # Fallback TERM only if terminfo didn't set it
            if string match -qr 'ssh-env' "$GHOSTTY_SHELL_FEATURES"
                if test "$TERM" = xterm-ghostty && not string match -q '*TERM=*' "$e"
                    set e $e TERM=xterm-256color
                end
            end

            # Execute
            if test (count $e) -gt 0
                env $e ssh $o $c $argv
            else
                builtin command ssh $o $c $argv
            end
        end

        # Wrap ghostty command only if ssh-terminfo is enabled
        if string match -qr 'ssh-terminfo' "$GHOSTTY_SHELL_FEATURES"
            function ghostty -d "Wrap ghostty to provide cache management commands"
                switch "$argv[1]"
                    case ssh-cache-list
                        ghostty_ssh_cache_list
                    case ssh-cache-clear
                        ghostty_ssh_cache_clear
                    case "*"
                        command ghostty $argv
                end
            end
        end
    end

    # Setup prompt marking
    function __ghostty_mark_prompt_start --on-event fish_prompt --on-event fish_cancel --on-event fish_posterror
        # If we never got the output end event, then we need to send it now.
        if test "$__ghostty_prompt_state" != prompt-start
            echo -en "\e]133;D\a"
        end

        set --global __ghostty_prompt_state prompt-start
        echo -en "\e]133;A\a"
    end

    function __ghostty_mark_output_start --on-event fish_preexec
        set --global __ghostty_prompt_state pre-exec
        echo -en "\e]133;C\a"
    end

    function __ghostty_mark_output_end --on-event fish_postexec
        set --global __ghostty_prompt_state post-exec
        echo -en "\e]133;D;$status\a"
    end

    # Report pwd. This is actually built-in to fish but only for terminals
    # that match an allowlist and that isn't us.
    function __update_cwd_osc --on-variable PWD -d 'Notify capable terminals when $PWD changes'
        if status --is-command-substitution || set -q INSIDE_EMACS
            return
        end
        printf \e\]7\;file://%s%s\a $hostname (string escape --style=url $PWD)
    end

    # Enable fish to handle reflow because Ghostty clears the prompt on resize.
    set --global fish_handle_reflow 1

    # Initial calls for first prompt
    if contains cursor $features
        __ghostty_set_cursor_beam
    end
    __ghostty_mark_prompt_start
    __update_cwd_osc
end

ghostty_exit
