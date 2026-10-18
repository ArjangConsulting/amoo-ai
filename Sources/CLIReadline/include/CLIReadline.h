#pragma once
#include <stdlib.h>

/// Displays `prompt`, reads a line with full terminal editing (arrow keys,
/// history, Ctrl-A/E/K/U/W, Alt-Backspace, etc.) via libedit.
///
/// - Returns a heap-allocated C string the caller must free(), or NULL on EOF.
/// - Non-empty lines are automatically added to the in-session history.
char *cli_readline(const char *prompt);

/// Persist the current history to `path` (creates/truncates the file).
void cli_save_history(const char *path);

/// Load history from `path` into the current session.
void cli_load_history(const char *path);

/// Clear all configured completion entries.
void cli_reset_completions(void);

/// Configure root-level completions (newline-delimited command list).
void cli_set_root_completions(const char *items);

/// Configure argument completions for a command (newline-delimited values).
void cli_set_command_completions(const char *command, const char *items);

/// Returns non-zero when `candidate` should match `text` for completion.
/// Prefix matches win; substring matches are only accepted when prefix mode is disabled.
int cli_completion_candidate_matches(const char *candidate, const char *text, int prefer_prefix);

/// Line-buffers stdout. Swift 6's strict concurrency checking flags a direct
/// `setvbuf(stdout, ...)` from Swift as touching non-Sendable global state on Linux (Glibc's
/// `stdout` isn't annotated the way Darwin's is); doing it in C sidesteps that entirely.
void cli_line_buffer_stdout(void);

/// Reads and echoes one terminal key, restoring terminal settings before returning.
/// Returns -1 on EOF/Ctrl-D, -2 when terminal input is unavailable.
int cli_read_character(void);

/// Whether stdin/stdout support the interactive selection UI.
int cli_selection_available(void);
/// Reads a selection key without echo. Arrows return 1001 (up), 1002 (down).
/// Escape, Ctrl-C, Ctrl-D and EOF return -1. Restores terminal settings on return.
int cli_selection_key(void);

/// Current terminal dimensions, with conservative defaults.
int cli_terminal_columns(void);
int cli_terminal_rows(void);
