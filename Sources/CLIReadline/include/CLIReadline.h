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
