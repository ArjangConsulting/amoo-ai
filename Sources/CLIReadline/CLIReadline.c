#include "CLIReadline.h"

#if __has_include(<editline/readline.h>) && __has_include(<histedit.h>)
#include <editline/readline.h>
#define CLIREADLINE_HAS_LIBEDIT 1
#else
#include <stdio.h>
#define CLIREADLINE_HAS_LIBEDIT 0
#endif

#include <stdbool.h>
#include <string.h>

#if CLIREADLINE_HAS_LIBEDIT

typedef struct {
    char *command;
    char **items;
    size_t count;
} CLICommandCompletion;

static char **g_root_items = NULL;
static size_t g_root_count = 0;
static CLICommandCompletion *g_command_items = NULL;
static size_t g_command_count = 0;
static char **g_active_items = NULL;
static size_t g_active_count = 0;
static bool g_active_prefer_prefix = true;
static char g_completion_append_character = '\0';
static bool g_completion_configured = false;

int cli_completion_candidate_matches(const char *candidate, const char *text, int prefer_prefix) {
    if (!candidate || !text) {
        return 0;
    }

    size_t text_length = strlen(text);
    if (text_length == 0) {
        return 1;
    }

    if (strncmp(candidate, text, text_length) == 0) {
        return 1;
    }

    if (prefer_prefix) {
        return 0;
    }

    return strstr(candidate, text) != NULL;
}

static void cli_free_items(char **items, size_t count) {
    if (!items) {
        return;
    }

    for (size_t i = 0; i < count; i++) {
        free(items[i]);
    }
    free(items);
}

static char **cli_parse_items(const char *items, size_t *count) {
    *count = 0;
    if (!items || !*items) {
        return NULL;
    }

    char *copy = strdup(items);
    if (!copy) {
        return NULL;
    }

    size_t parsed_count = 0;
    char *saveptr = NULL;
    for (char *token = strtok_r(copy, "\n", &saveptr); token; token = strtok_r(NULL, "\n", &saveptr)) {
        if (*token) {
            parsed_count += 1;
        }
    }
    free(copy);

    if (parsed_count == 0) {
        return NULL;
    }

    char **parsed = calloc(parsed_count, sizeof(char *));
    if (!parsed) {
        return NULL;
    }

    copy = strdup(items);
    if (!copy) {
        free(parsed);
        return NULL;
    }

    size_t index = 0;
    saveptr = NULL;
    for (char *token = strtok_r(copy, "\n", &saveptr); token; token = strtok_r(NULL, "\n", &saveptr)) {
        if (!*token) {
            continue;
        }
        parsed[index++] = strdup(token);
    }
    free(copy);

    *count = index;
    return parsed;
}

static void cli_free_command_items(void) {
    if (!g_command_items) {
        return;
    }

    for (size_t i = 0; i < g_command_count; i++) {
        free(g_command_items[i].command);
        cli_free_items(g_command_items[i].items, g_command_items[i].count);
    }
    free(g_command_items);
    g_command_items = NULL;
    g_command_count = 0;
}

static CLICommandCompletion *cli_find_command_items(const char *command) {
    if (!command) {
        return NULL;
    }

    for (size_t i = 0; i < g_command_count; i++) {
        if (strcmp(g_command_items[i].command, command) == 0) {
            return &g_command_items[i];
        }
    }

    return NULL;
}

static char *cli_completion_generator(const char *text, int state) {
    static size_t index = 0;

    if (state == 0) {
        index = 0;
    }

    while (index < g_active_count) {
        const char *candidate = g_active_items[index++];
        if (cli_completion_candidate_matches(candidate, text, g_active_prefer_prefix ? 1 : 0)) {
            return strdup(candidate);
        }
    }

    return NULL;
}

static char **cli_attempted_completion(const char *text, int start, int end) {
    (void) end;

    rl_attempted_completion_over = 1;

    if (start > 0 && rl_line_buffer[start - 1] == '=') {
        return NULL;
    }

    if (strchr(text, '=') != NULL) {
        return NULL;
    }

    if (start == 0) {
        g_active_items = g_root_items;
        g_active_count = g_root_count;
        g_completion_append_character = ' ';
    } else {
        const char *buffer = rl_line_buffer;
        while (*buffer == ' ' || *buffer == '\t') {
            buffer += 1;
        }

        size_t command_length = strcspn(buffer, " \t");
        if (command_length == 0) {
            return NULL;
        }

        char command[256];
        if (command_length >= sizeof(command)) {
            command_length = sizeof(command) - 1;
        }
        memcpy(command, buffer, command_length);
        command[command_length] = '\0';

        CLICommandCompletion *entry = cli_find_command_items(command);
        if (!entry) {
            return NULL;
        }

        g_active_items = entry->items;
        g_active_count = entry->count;
        g_completion_append_character = '\0';
    }

    if (g_active_count == 0) {
        return NULL;
    }

    rl_completion_append_character = g_completion_append_character;

    g_active_prefer_prefix = true;
    char **matches = rl_completion_matches(text, cli_completion_generator);
    if (matches) {
        return matches;
    }

    g_active_prefer_prefix = false;
    return rl_completion_matches(text, cli_completion_generator);
}

static void cli_configure_completions_if_needed(void) {
    if (g_completion_configured) {
        return;
    }

    // Keep `_` within the same token so commands like `tap_element` complete
    // as a single word instead of being truncated after `tap`.
    rl_basic_word_break_characters = " \t\n";
    rl_completer_word_break_characters = " \t\n";
    rl_attempted_completion_function = cli_attempted_completion;
    g_completion_configured = true;
}

char *cli_readline(const char *prompt) {
    char *line = readline(prompt);
    if (line && *line) {
        add_history(line);
    }
    return line;
}

void cli_save_history(const char *path) {
    write_history(path);
}

void cli_load_history(const char *path) {
    read_history(path);
}

void cli_reset_completions(void) {
    cli_free_items(g_root_items, g_root_count);
    g_root_items = NULL;
    g_root_count = 0;
    cli_free_command_items();
}

void cli_set_root_completions(const char *items) {
    cli_configure_completions_if_needed();
    cli_free_items(g_root_items, g_root_count);
    g_root_items = cli_parse_items(items, &g_root_count);
}

void cli_set_command_completions(const char *command, const char *items) {
    cli_configure_completions_if_needed();

    if (!command || !*command) {
        return;
    }

    char **parsed_items = NULL;
    size_t parsed_count = 0;
    parsed_items = cli_parse_items(items, &parsed_count);

    CLICommandCompletion *existing = cli_find_command_items(command);
    if (existing) {
        cli_free_items(existing->items, existing->count);
        existing->items = parsed_items;
        existing->count = parsed_count;
        return;
    }

    CLICommandCompletion *resized = realloc(g_command_items, sizeof(CLICommandCompletion) * (g_command_count + 1));
    if (!resized) {
        cli_free_items(parsed_items, parsed_count);
        return;
    }

    g_command_items = resized;

    // strdup can return NULL under memory pressure; we must check before
    // installing the entry, otherwise cli_find_command_items would later
    // dereference NULL during strcmp.
    char *command_copy = strdup(command);
    if (!command_copy) {
        cli_free_items(parsed_items, parsed_count);
        return;
    }

    g_command_items[g_command_count].command = command_copy;
    g_command_items[g_command_count].items = parsed_items;
    g_command_items[g_command_count].count = parsed_count;
    g_command_count += 1;
}

#else

int cli_completion_candidate_matches(const char *candidate, const char *text, int prefer_prefix) {
    if (!candidate || !text) {
        return 0;
    }

    size_t text_length = strlen(text);
    if (text_length == 0) {
        return 1;
    }

    if (strncmp(candidate, text, text_length) == 0) {
        return 1;
    }

    if (prefer_prefix) {
        return 0;
    }

    return strstr(candidate, text) != NULL;
}

char *cli_readline(const char *prompt) {
    if (prompt && *prompt) {
        fputs(prompt, stdout);
        fflush(stdout);
    }

    char *line = NULL;
    size_t capacity = 0;
    ssize_t length = getline(&line, &capacity, stdin);
    if (length < 0) {
        free(line);
        return NULL;
    }

    while (length > 0 && (line[length - 1] == '\n' || line[length - 1] == '\r')) {
        line[length - 1] = '\0';
        length -= 1;
    }

    return line;
}

void cli_save_history(const char *path) {
    (void) path;
}

void cli_load_history(const char *path) {
    (void) path;
}

void cli_reset_completions(void) {}

void cli_set_root_completions(const char *items) {
    (void) items;
}

void cli_set_command_completions(const char *command, const char *items) {
    (void) command;
    (void) items;
}

#endif
