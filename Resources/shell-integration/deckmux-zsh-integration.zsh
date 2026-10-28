# Deckmux zsh integration. Ghostty's zsh bootstrap (ghostty/shell-integration/
# zsh/.zshenv) sources it in Deckmux terminals, after the user's .zshenv.

# Print the scrollback saved for this terminal when it was last open, once.
# Deckmux copies it to a temporary file; the shell deletes it after printing.
_deckmux_restore_scrollback_once() {
    builtin local file="${DECKMUX_RESTORE_SCROLLBACK_FILE:-}"
    [[ -n "$file" ]] || return 0
    builtin unset DECKMUX_RESTORE_SCROLLBACK_FILE
    [[ -r "$file" ]] || return 0
    # login(1) already printed "Last login" for the new shell; the history
    # goes first, so start from a clear screen.
    builtin printf '\033[H\033[J'
    /bin/cat -- "$file" 2>/dev/null
    /bin/rm -f -- "$file" 2>/dev/null
    # Leave the saved colors behind and start the prompt on a fresh line.
    builtin printf '\033[0m\n'
}
_deckmux_restore_scrollback_once
builtin unfunction _deckmux_restore_scrollback_once

# Route `claude` through the Deckmux wrapper even when .zshrc later puts
# another claude first on PATH. A function wins over PATH lookup.
if [[ -n "${DECKMUX_BIN_DIR:-}" && -x "${DECKMUX_BIN_DIR}/claude" ]]; then
    builtin unalias claude 2>/dev/null
    claude() { "${DECKMUX_BIN_DIR}/claude" "$@"; }
fi
