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

    # SSH Integration for Fish Shell
    if string match -q '*ssh-env*' -- "$GHOSTTY_SHELL_FEATURES"; or string match -q '*ssh-terminfo*' -- "$GHOSTTY_SHELL_FEATURES"
        set -g GHOSTTY_SSH_CACHE_TIMEOUT (test -n "$GHOSTTY_SSH_CACHE_TIMEOUT"; and echo $GHOSTTY_SSH_CACHE_TIMEOUT; or echo 5)
        set -g GHOSTTY_SSH_CHECK_TIMEOUT (test -n "$GHOSTTY_SSH_CHECK_TIMEOUT"; and echo $GHOSTTY_SSH_CHECK_TIMEOUT; or echo 3)

        # SSH wrapper that preserves Ghostty features across remote connections
        function ssh --wraps=ssh --description "SSH wrapper with Ghostty integration"
            set -l ssh_env
            set -l ssh_opts

            # Configure environment variables for remote session
            if string match -q '*ssh-env*' -- "$GHOSTTY_SHELL_FEATURES"
                set -l ssh_env_vars \
                    "COLORTERM=truecolor" \
                    "TERM_PROGRAM=ghostty"
                
                if test -n "$TERM_PROGRAM_VERSION"
                    set -a ssh_env_vars "TERM_PROGRAM_VERSION=$TERM_PROGRAM_VERSION"
                end

                # Store original values for restoration
                set -l ssh_exported_vars
                for ssh_v in $ssh_env_vars
                    set -l ssh_var_name (string split -m1 '=' -- $ssh_v)[1]
                    
                    if set -q $ssh_var_name
                        set -a ssh_exported_vars "$ssh_var_name="(eval echo \$$ssh_var_name)
                    else
                        set -a ssh_exported_vars $ssh_var_name
                    end

                    # Export the variable
                    set -gx (string split -m1 '=' -- $ssh_v)

                    # Use both SendEnv and SetEnv for maximum compatibility
                    set -a ssh_opts -o "SendEnv $ssh_var_name"
                    set -a ssh_opts -o "SetEnv $ssh_v"
                end

                set -a ssh_env $ssh_env_vars
            end

            # Install terminfo on remote host if needed
            if string match -q '*ssh-terminfo*' -- "$GHOSTTY_SHELL_FEATURES"
                set -l ssh_config (command ssh -G $argv 2>/dev/null)
                set -l ssh_user (echo $ssh_config | while read -l ssh_key ssh_value
                    test "$ssh_key" = "user"; and echo $ssh_value; and break
                end)
                set -l ssh_hostname (echo $ssh_config | while read -l ssh_key ssh_value
                    test "$ssh_key" = "hostname"; and echo $ssh_value; and break
                end)
                set -l ssh_target "$ssh_user@$ssh_hostname"

                if test -n "$ssh_hostname"
                    # Detect timeout command (BSD compatibility)
                    set -l ssh_timeout_cmd
                    if command -v timeout >/dev/null 2>&1
                        set ssh_timeout_cmd timeout
                    else if command -v gtimeout >/dev/null 2>&1
                        set ssh_timeout_cmd gtimeout
                    end

                    # Check if terminfo is already cached
                    set -l ssh_cache_check_success false
                    if command -v ghostty >/dev/null 2>&1
                        if test -n "$ssh_timeout_cmd"
                            if $ssh_timeout_cmd "$GHOSTTY_SSH_CHECK_TIMEOUT"s ghostty +ssh-cache --host="$ssh_target" >/dev/null 2>&1
                                set ssh_cache_check_success true
                            end
                        else
                            if ghostty +ssh-cache --host="$ssh_target" >/dev/null 2>&1
                                set ssh_cache_check_success true
                            end
                        end
                    end

                    if test "$ssh_cache_check_success" = "true"
                        set -a ssh_env TERM=xterm-ghostty
                    else if command -v infocmp >/dev/null 2>&1
                        # Generate terminfo data (BSD base64 compatibility)
                        set -l ssh_terminfo
                        if base64 --help 2>&1 | grep -q GNU
                            set ssh_terminfo (infocmp -0 -Q2 -q xterm-ghostty 2>/dev/null | base64 -w0 2>/dev/null)
                        else
                            set ssh_terminfo (infocmp -0 -Q2 -q xterm-ghostty 2>/dev/null | base64 2>/dev/null | tr -d '\n')
                        end

                        if test -n "$ssh_terminfo"
                            echo "Setting up Ghostty terminfo on remote host..." >&2
                            set -l ssh_cpath_dir (mktemp -d "/tmp/ghostty-ssh-$ssh_user.XXXXXX" 2>/dev/null; or echo "/tmp/ghostty-ssh-$ssh_user."(random))
                            set -l ssh_cpath "$ssh_cpath_dir/socket"

                            set -l ssh_base64_decode_cmd
                            if base64 --help 2>&1 | grep -q GNU
                                set ssh_base64_decode_cmd "base64 -d"
                            else
                                set ssh_base64_decode_cmd "base64 -D"
                            end

                            if echo "$ssh_terminfo" | eval $ssh_base64_decode_cmd | command ssh $ssh_opts -o ControlMaster=yes -o ControlPath="$ssh_cpath" -o ControlPersist=60s $argv '
                                infocmp xterm-ghostty >/dev/null 2>&1 && exit 0
                                command -v tic >/dev/null 2>&1 || exit 1
                                mkdir -p ~/.terminfo 2>/dev/null && tic -x - 2>/dev/null && exit 0
                                exit 1
                            ' 2>/dev/null
                                echo "Terminfo setup complete." >&2
                                set -a ssh_env TERM=xterm-ghostty
                                set -a ssh_opts -o "ControlPath=$ssh_cpath"

                                # Cache successful installation
                                if test -n "$ssh_target"; and command -v ghostty >/dev/null 2>&1
                                    fish -c "
                                        if test -n '$ssh_timeout_cmd'
                                            $ssh_timeout_cmd '$GHOSTTY_SSH_CACHE_TIMEOUT's ghostty +ssh-cache --add='$ssh_target' >/dev/null 2>&1; or true
                                        else
                                            ghostty +ssh-cache --add='$ssh_target' >/dev/null 2>&1; or true
                                        end
                                    " &
                                end
                            else
                                echo "Warning: Failed to install terminfo." >&2
                                set -a ssh_env TERM=xterm-256color
                            end
                        else
                            echo "Warning: Could not generate terminfo data." >&2
                            set -a ssh_env TERM=xterm-256color
                        end
                    else
                        echo "Warning: ghostty command not available for cache management." >&2
                        set -a ssh_env TERM=xterm-256color
                    end
                else
                    if string match -q '*ssh-env*' -- "$GHOSTTY_SHELL_FEATURES"
                        set -a ssh_env TERM=xterm-256color
                    end
                end
            end

            # Ensure TERM is set when using ssh-env feature
            if string match -q '*ssh-env*' -- "$GHOSTTY_SHELL_FEATURES"
                set -l ssh_term_set false
                for ssh_v in $ssh_env
                    if string match -q 'TERM=*' -- $ssh_v
                        set ssh_term_set true
                        break
                    end
                end
                if test "$ssh_term_set" = "false"; and test "$TERM" = "xterm-ghostty"
                    set -a ssh_env TERM=xterm-256color
                end
            end

            command ssh $ssh_opts $argv
            set -l ssh_ret $status

            # Restore original environment variables
            if string match -q '*ssh-env*' -- "$GHOSTTY_SHELL_FEATURES"
                for ssh_v in $ssh_exported_vars
                    if string match -q '*=*' -- $ssh_v
                        set -gx (string split -m1 '=' -- $ssh_v)
                    else
                        set -e $ssh_v
                    end
                end
            end

            return $ssh_ret
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
