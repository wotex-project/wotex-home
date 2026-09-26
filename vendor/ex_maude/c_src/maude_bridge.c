/*
 * ExMaude C-Node Bridge
 *
 * A C-Node process that manages a Maude subprocess and communicates
 * with the Erlang/Elixir VM using Erlang distribution protocol.
 *
 * The distribution envelope is binary, while commands and responses remain
 * Maude text and are parsed by the Elixir layer. The bridge and Maude both run
 * outside the BEAM.
 *
 * Usage:
 *   ./maude_bridge <node_name> <maude_path> <erlang_node>
 *
 * The Erlang distribution cookie is read from stdin as a four-byte,
 * big-endian length followed by that many bytes. Keeping the cookie out of
 * argv prevents it from being exposed by local process-listing tools.
 *
 * Protocol (v2 — every request carries a ref that is echoed back, so the
 * Elixir side can selectively receive its own reply and ignore stale ones):
 *   {execute, Ref, Command :: binary(), TimeoutMs :: integer(),
 *             MaxResponseBytes :: integer()}
 *       -> {Ref, {:ok, Output :: binary()} | {:error, Reason}}
 *   {load_file, Ref, Path :: binary(), TimeoutMs :: integer(),
 *               MaxResponseBytes :: integer()}
 *       -> {Ref, :ok | {:error, Reason | Output :: binary()}}
 *   {ping, Ref} -> {Ref, :pong}
 *   stop -> ok   (bare atom, fire-and-forget from terminate)
 */

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <netinet/in.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#include <ei.h>

/* Forward declarations */
static void handle_message(int fd, erlang_msg *emsg, ei_x_buff *buf);
static int read_until_prompt(char **output, size_t *capacity, int timeout_ms,
                             size_t max_response_size);
static int send_command(const char *cmd, size_t len, int64_t deadline);
static int write_all(int fd, const char *data, size_t len, int64_t deadline);
static int read_exact(int fd, void *data, size_t len);
static int read_cookie(char *cookie, size_t capacity);
static char *build_load_command(const char *path, size_t length,
                                size_t *command_length);
static void clear_secret(void *data, size_t len);
static int64_t monotonic_ms(void);
static int reap_with_timeout(pid_t pid, int timeout_ms);
static char *find_prompt_boundary(char *output, size_t length, size_t start);
static void encode_ok(ei_x_buff *response, const char *data, int data_len);
static void encode_error(ei_x_buff *response, const char *reason);

#define INITIAL_BUFSIZE 65536
#define MAX_COMMAND_SIZE (16UL * 1024 * 1024)
#define DEFAULT_MAX_RESPONSE_SIZE (16UL * 1024 * 1024)
#define PROMPT "Maude> "
#define PROMPT_LEN 7
#define MAX_COOKIE_SIZE 255

/* Maude process state */
typedef struct {
  pid_t pid;
  int stdin_fd;
  int stdout_fd;
} MaudeProcess;

static MaudeProcess maude = {0};
static volatile sig_atomic_t running = 1;

#ifdef EX_MAUDE_TEST
static size_t scanned_windows = 0;
#endif

static int read_exact(int fd, void *data, size_t len) {
  size_t offset = 0;
  char *buffer = data;

  while (offset < len) {
    ssize_t count = read(fd, buffer + offset, len - offset);

    if (count > 0) {
      offset += (size_t)count;
    } else if (count < 0 && errno == EINTR) {
      continue;
    } else {
      return -1;
    }
  }

  return 0;
}

static int read_cookie(char *cookie, size_t capacity) {
  uint32_t encoded_length;

  if (read_exact(STDIN_FILENO, &encoded_length, sizeof(encoded_length)) < 0) {
    return -1;
  }

  uint32_t length = ntohl(encoded_length);
  if (length == 0 || length > MAX_COOKIE_SIZE || length >= capacity) {
    return -1;
  }

  if (read_exact(STDIN_FILENO, cookie, length) < 0) {
    return -1;
  }

  cookie[length] = '\0';
  return 0;
}

static char *build_load_command(const char *path, size_t length,
                                size_t *command_length) {
  if (length > (SIZE_MAX - 11) / 2)
    return NULL;

  size_t capacity = (length * 2) + 11;
  char *command = malloc(capacity);
  if (command == NULL)
    return NULL;

  size_t position = 0;
  memcpy(command + position, "load \"", 6);
  position += 6;

  for (size_t index = 0; index < length; index++) {
    if (path[index] == '\\' || path[index] == '"')
      command[position++] = '\\';
    command[position++] = path[index];
  }

  memcpy(command + position, "\" .", 3);
  position += 3;
  command[position] = '\0';
  *command_length = position;
  return command;
}

/* Use a volatile pointer so the compiler cannot optimize away the wipe. */
static void clear_secret(void *data, size_t len) {
  volatile unsigned char *cursor = data;
  while (len-- > 0) {
    *cursor++ = 0;
  }
}

/* Signal handler for graceful shutdown */
static void handle_signal(int sig) {
  (void)sig;
  running = 0;
}

/* Set file descriptor to non-blocking mode */
static int set_nonblocking(int fd) {
  int flags = fcntl(fd, F_GETFL, 0);
  if (flags == -1)
    return -1;
  return fcntl(fd, F_SETFL,
               (int)((unsigned int)flags | (unsigned int)O_NONBLOCK));
}

/* Start the Maude subprocess */
static int start_maude(const char *maude_path) {
  int stdin_pipe[2], stdout_pipe[2];

  if (pipe(stdin_pipe) < 0 || pipe(stdout_pipe) < 0) {
    perror("pipe");
    return -1;
  }

  maude.pid = fork();
  if (maude.pid < 0) {
    perror("fork");
    return -1;
  }

  if (maude.pid == 0) {
    /* Child process */
    close(stdin_pipe[1]);
    close(stdout_pipe[0]);

    dup2(stdin_pipe[0], STDIN_FILENO);
    dup2(stdout_pipe[1], STDOUT_FILENO);
    dup2(stdout_pipe[1], STDERR_FILENO);

    close(stdin_pipe[0]);
    close(stdout_pipe[1]);

    /* Set MAUDE_LIB to the directory containing the Maude binary
     * so that Maude can find prelude.maude and other library files */
    char maude_lib[4096];
    strncpy(maude_lib, maude_path, sizeof(maude_lib) - 1);
    maude_lib[sizeof(maude_lib) - 1] = '\0';
    char *last_slash = strrchr(maude_lib, '/');
    if (last_slash != NULL) {
      *last_slash = '\0';
      setenv("MAUDE_LIB", maude_lib, 1);
    }

    /* Execute Maude with options to suppress banner and enable interactive mode
     */
    execl(maude_path, "maude", "-no-banner", "-no-wrap", "-no-advise",
          "-interactive", NULL);

    /* If execl fails */
    perror("execl");
    _exit(1);
  }

  /* Parent process */
  close(stdin_pipe[0]);
  close(stdout_pipe[1]);

  maude.stdin_fd = stdin_pipe[1];
  maude.stdout_fd = stdout_pipe[0];
  /* Set stdout to non-blocking for select() */
  set_nonblocking(maude.stdout_fd);
  set_nonblocking(maude.stdin_fd);

  return 0;
}

/* Stop the Maude subprocess */
static void stop_maude(void) {
  if (maude.pid > 0) {
    close(maude.stdin_fd);

    if (!reap_with_timeout(maude.pid, 100)) {
      kill(maude.pid, SIGTERM);

      if (!reap_with_timeout(maude.pid, 200)) {
        kill(maude.pid, SIGKILL);
        waitpid(maude.pid, NULL, 0);
      }
    }

    close(maude.stdout_fd);
    maude.pid = 0;
  }
}

static int reap_with_timeout(pid_t pid, int timeout_ms) {
  int64_t deadline = monotonic_ms() + timeout_ms;

  while (monotonic_ms() < deadline) {
    pid_t result = waitpid(pid, NULL, WNOHANG);
    if (result == pid || (result < 0 && errno == ECHILD))
      return 1;
    if (result < 0 && errno != EINTR)
      return 0;
    usleep(5000);
  }

  return 0;
}

/* Send command to Maude */
static int send_command(const char *cmd, size_t len, int64_t deadline) {
  if (write_all(maude.stdin_fd, cmd, len, deadline) < 0) {
    perror("write to maude");
    return -1;
  }

  /* Ensure command ends with newline */
  if (len == 0 || cmd[len - 1] != '\n') {
    if (write_all(maude.stdin_fd, "\n", 1, deadline) < 0) {
      perror("write newline to maude");
      return -1;
    }
  }

  return 0;
}

static int write_all(int fd, const char *data, size_t len, int64_t deadline) {
  size_t total = 0;
  while (total < len && running) {
    int64_t remaining = deadline - monotonic_ms();
    if (remaining <= 0) {
      errno = ETIMEDOUT;
      return -1;
    }
    fd_set writefds;
    FD_ZERO(&writefds);
    FD_SET(fd, &writefds);
    struct timeval tv = {(long)(remaining / 1000),
                         (suseconds_t)((remaining % 1000) * 1000)};
    int ready = select(fd + 1, NULL, &writefds, NULL, &tv);
    if (ready < 0 && errno == EINTR)
      continue;
    if (ready == 0) {
      errno = ETIMEDOUT;
      return -1;
    }
    if (ready < 0)
      return -1;
    ssize_t written = write(fd, data + total, len - total);
    if (written < 0) {
      if (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK)
        continue;
      return -1;
    }
    if (written == 0)
      return -1;
    total += (size_t)written;
  }
  return total == len ? 0 : -1;
}

static int64_t monotonic_ms(void) {
  struct timespec now;
  if (clock_gettime(CLOCK_MONOTONIC, &now) < 0)
    return -1;
  return ((int64_t)now.tv_sec * 1000) + (now.tv_nsec / 1000000);
}

/* Read from Maude until we see the prompt
 * Returns: >= 0 on success (number of output bytes before prompt)
 *          -1 on timeout (no prompt found)
 *          -2 on read error
 *          -3 on EOF (Maude closed)
 *          -4 when the configured response ceiling is exceeded
 *          -5 on allocation failure
 */
static int read_until_prompt(char **output, size_t *capacity, int timeout_ms,
                             size_t max_response_size) {
  size_t total = 0;
  fd_set readfds;
  struct timeval tv;
  int prompt_found = 0;
  int64_t deadline = monotonic_ms() + timeout_ms;

  if (*output == NULL) {
    *capacity = INITIAL_BUFSIZE;
    *output = malloc(*capacity);
    if (*output == NULL)
      return -5;
  }

  while (running) {
    int64_t remaining = deadline - monotonic_ms();
    if (remaining <= 0)
      break;

    FD_ZERO(&readfds);
    FD_SET(maude.stdout_fd, &readfds);

    tv.tv_sec = (long)(remaining / 1000);
    tv.tv_usec = (suseconds_t)((remaining % 1000) * 1000);

    int ready = select(maude.stdout_fd + 1, &readfds, NULL, NULL, &tv);

    if (ready < 0) {
      if (errno == EINTR)
        continue;
      perror("select");
      (*output)[total] = '\0';
      return -2; /* Read error */
    }

    if (ready == 0) {
      /* Timeout - no more data available */
      break;
    }

    char buf[4096];
    ssize_t n = read(maude.stdout_fd, buf, sizeof(buf));

    if (n < 0) {
      if (errno == EAGAIN || errno == EWOULDBLOCK)
        continue;
      perror("read from maude");
      (*output)[total] = '\0';
      return -2; /* Read error */
    }

    if (n == 0) {
      /* EOF - Maude closed */
      (*output)[total] = '\0';
      return -3;
    }

    if ((size_t)n > SIZE_MAX - total - 1)
      return -4;
    size_t needed = total + (size_t)n + 1;

    if (max_response_size > SIZE_MAX - PROMPT_LEN - 1)
      return -4;
    size_t maximum_buffer_size = max_response_size + PROMPT_LEN + 1;

    if (needed > maximum_buffer_size)
      return -4;

    if (needed > *capacity) {
      size_t new_capacity = *capacity;
      while (new_capacity < needed && new_capacity <= SIZE_MAX / 2)
        new_capacity *= 2;
      if (new_capacity < needed || new_capacity > maximum_buffer_size)
        new_capacity = maximum_buffer_size;

      char *resized = realloc(*output, new_capacity);
      if (resized == NULL)
        return -5;
      *output = resized;
      *capacity = new_capacity;
    }

    size_t scan_start = total >= PROMPT_LEN ? total - PROMPT_LEN + 1 : 0;
    memcpy(*output + total, buf, (size_t)n);
    total += (size_t)n;

    (*output)[total] = '\0';

    char *prompt_pos = find_prompt_boundary(*output, total, scan_start);
    if (prompt_pos != NULL) {
      total = (size_t)(prompt_pos - *output);
      if (total > max_response_size)
        return -4;
      *prompt_pos = '\0';
      prompt_found = 1;
      break;
    }
  }

  (*output)[total] = '\0';

  /* Trim leading/trailing whitespace */
  while (total > 0 &&
         ((*output)[total - 1] == '\n' || (*output)[total - 1] == '\r' ||
          (*output)[total - 1] == ' ')) {
    (*output)[--total] = '\0';
  }

  char *start = *output;
  while (*start == '\n' || *start == '\r' || *start == ' ') {
    start++;
  }

  if (start != *output) {
    memmove(*output, start, strlen(start) + 1);
    total = strlen(*output);
  }

  if (!prompt_found) {
    return -1; /* Timeout without finding prompt */
  }

  return (int)total; /* Success - return output length (may be 0) */
}

/* A protocol prompt is complete only at the start of a line. Prompt-like
 * bytes inside a valid Maude result remain part of that result. */
static char *find_prompt_boundary(char *output, size_t length, size_t start) {
  if (length < PROMPT_LEN)
    return NULL;

  for (size_t index = start; index <= length - PROMPT_LEN; index++) {
#ifdef EX_MAUDE_TEST
    scanned_windows++;
#endif
    int at_line_start =
        index == 0 || output[index - 1] == '\n' || output[index - 1] == '\r';

    if (at_line_start && memcmp(output + index, PROMPT, PROMPT_LEN) == 0)
      return output + index;
  }

  return NULL;
}

/* Wait for initial Maude prompt after startup */
static int wait_for_ready(void) {
  char *buf = NULL;
  size_t capacity = 0;

  /* Interactive Maude emits its initial prompt without input. Sending a
   * newline here races that prompt and can leave a second empty response in
   * the pipe, where it would be mistaken for the first real command. */
  int result =
      read_until_prompt(&buf, &capacity, 10000, DEFAULT_MAX_RESPONSE_SIZE);
  if (result >= 0) {
    fprintf(stderr, "Maude ready (startup output %d bytes): '%s'\n", result,
            buf);
  } else if (result == -1) {
    fprintf(stderr,
            "Maude startup: timeout waiting for prompt (no 'Maude>' found)\n");
    fprintf(stderr, "Partial output received: '%s'\n", buf == NULL ? "" : buf);
  } else if (result == -2) {
    fprintf(stderr, "Maude startup: read error\n");
  } else if (result == -3) {
    fprintf(stderr, "Maude startup: process closed (EOF)\n");
  }
  free(buf);
  return result;
}

/* Encode an Erlang ok tuple: {:ok, data} */
static void encode_ok(ei_x_buff *response, const char *data, int data_len) {
  ei_x_encode_tuple_header(response, 2);
  ei_x_encode_atom(response, "ok");
  ei_x_encode_binary(response, data, data_len);
}

/* Encode an Erlang error tuple: {:error, reason} */
static void encode_error(ei_x_buff *response, const char *reason) {
  ei_x_encode_tuple_header(response, 2);
  ei_x_encode_atom(response, "error");
  ei_x_encode_atom(response, reason);
}

/* Clamp a requested per-command timeout to a sane range */
static int clamp_timeout(long timeout_ms) {
  if (timeout_ms < 1)
    return 1;
  if (timeout_ms > INT_MAX)
    return INT_MAX;
  return (int)timeout_ms;
}

static size_t clamp_response_limit(long max_response_bytes) {
  if (max_response_bytes <= 0)
    return DEFAULT_MAX_RESPONSE_SIZE;
  if (max_response_bytes > INT_MAX - PROMPT_LEN - 1)
    return (size_t)(INT_MAX - PROMPT_LEN - 1);
  return (size_t)max_response_bytes;
}

/* Handle incoming Erlang message */
static void handle_message(int fd, erlang_msg *emsg, ei_x_buff *buf) {
  int index = 0;
  int version;
  char cmd[256];
  int arity;

  ei_x_buff response;
  ei_x_new_with_version(&response);

  /* Decode version */
  if (ei_decode_version(buf->buff, &index, &version) < 0) {
    encode_error(&response, "decode_version_failed");
    goto send_response;
  }

  /* Decode tuple header */
  if (ei_decode_tuple_header(buf->buff, &index, &arity) < 0) {
    /* Not a tuple, check if it's just an atom (like :stop) */
    index = 0;
    ei_decode_version(buf->buff, &index, &version);

    if (ei_decode_atom(buf->buff, &index, cmd) == 0) {
      if (strcmp(cmd, "ping") == 0) {
        ei_x_encode_atom(&response, "pong");
        goto send_response;
      } else if (strcmp(cmd, "stop") == 0) {
        running = 0;
        ei_x_encode_atom(&response, "ok");
        goto send_response;
      }
    }

    encode_error(&response, "invalid_message_format");
    goto send_response;
  }

  /* Decode command atom */
  if (ei_decode_atom(buf->buff, &index, cmd) < 0) {
    encode_error(&response, "decode_command_failed");
    goto send_response;
  }

  /* Decode the request ref. Replies before this point go out unwrapped;
   * the Elixir side's selective receive simply never matches them and the
   * caller times out — acceptable for protocol bugs. */
  erlang_ref ref;
  if (ei_decode_ref(buf->buff, &index, &ref) < 0) {
    encode_error(&response, "decode_ref_failed");
    goto send_response;
  }

  /* Every reply from here on is {Ref, Payload}; each branch below must
   * encode exactly one payload term. */
  ei_x_encode_tuple_header(&response, 2);
  ei_x_encode_ref(&response, &ref);

  if (strcmp(cmd, "execute") == 0) {
    /* Decode command binary */
    int type, size;
    if (ei_get_type(buf->buff, &index, &type, &size) < 0) {
      encode_error(&response, "get_type_failed");
      goto send_response;
    }

    if (type != ERL_BINARY_EXT || size < 0 || (size_t)size > MAX_COMMAND_SIZE) {
      encode_error(&response, "invalid_command");
      goto send_response;
    }

    char *command = malloc((size_t)size + 1);
    if (!command) {
      encode_error(&response, "malloc_failed");
      goto send_response;
    }

    long bin_size;
    if (ei_decode_binary(buf->buff, &index, command, &bin_size) < 0) {
      free(command);
      encode_error(&response, "decode_binary_failed");
      goto send_response;
    }
    command[bin_size] = '\0';

    /* Decode per-command timeout */
    long timeout_ms = 30000;
    if (ei_decode_long(buf->buff, &index, &timeout_ms) < 0) {
      timeout_ms = 30000;
    }

    long max_response_bytes = DEFAULT_MAX_RESPONSE_SIZE;
    if (ei_decode_long(buf->buff, &index, &max_response_bytes) < 0) {
      max_response_bytes = DEFAULT_MAX_RESPONSE_SIZE;
    }

    /* Send command to Maude */
    int64_t command_deadline = monotonic_ms() + clamp_timeout(timeout_ms);
    if (send_command(command, bin_size, command_deadline) < 0) {
      free(command);
      encode_error(&response,
                   errno == ETIMEDOUT ? "read_timeout" : "send_failed");
      goto send_response;
    }
    free(command);

    /* Read response up to the caller's deadline */
    char *output = NULL;
    size_t output_capacity = 0;
    int out_len = read_until_prompt(&output, &output_capacity,
                                    (int)(command_deadline - monotonic_ms()),
                                    clamp_response_limit(max_response_bytes));

    if (out_len == -1) {
      encode_error(&response, "read_timeout");
    } else if (out_len == -3) {
      encode_error(&response, "maude_eof");
    } else if (out_len < 0) {
      encode_error(&response,
                   out_len == -4 ? "response_too_large" : "read_failed");
    } else {
      encode_ok(&response, output, out_len);
    }
    free(output);

  } else if (strcmp(cmd, "ping") == 0) {
    ei_x_encode_atom(&response, "pong");

  } else if (strcmp(cmd, "stop") == 0) {
    running = 0;
    ei_x_encode_atom(&response, "ok");

  } else if (strcmp(cmd, "load_file") == 0) {
    /* Decode file path */
    int type, size;
    if (ei_get_type(buf->buff, &index, &type, &size) < 0 ||
        type != ERL_BINARY_EXT || size < 0 || (size_t)size > MAX_COMMAND_SIZE) {
      encode_error(&response, "invalid_path");
      goto send_response;
    }

    char *path = malloc((size_t)size + 1);
    if (!path) {
      encode_error(&response, "malloc_failed");
      goto send_response;
    }

    long bin_size;
    if (ei_decode_binary(buf->buff, &index, path, &bin_size) < 0) {
      free(path);
      encode_error(&response, "decode_path_failed");
      goto send_response;
    }
    path[bin_size] = '\0';

    /* Decode per-command timeout */
    long timeout_ms = 30000;
    if (ei_decode_long(buf->buff, &index, &timeout_ms) < 0) {
      timeout_ms = 30000;
    }

    long max_response_bytes = DEFAULT_MAX_RESPONSE_SIZE;
    if (ei_decode_long(buf->buff, &index, &max_response_bytes) < 0) {
      max_response_bytes = DEFAULT_MAX_RESPONSE_SIZE;
    }

    size_t command_length;
    char *command = build_load_command(path, (size_t)bin_size, &command_length);
    free(path);

    if (command == NULL) {
      encode_error(&response, "malloc_failed");
      goto send_response;
    }

    /* Send load command to Maude */
    int64_t command_deadline = monotonic_ms() + clamp_timeout(timeout_ms);
    if (send_command(command, command_length, command_deadline) < 0) {
      free(command);
      encode_error(&response,
                   errno == ETIMEDOUT ? "read_timeout" : "load_send_failed");
      goto send_response;
    }
    free(command);

    /* Read response */
    char *output = NULL;
    size_t output_capacity = 0;
    int out_len = read_until_prompt(&output, &output_capacity,
                                    (int)(command_deadline - monotonic_ms()),
                                    clamp_response_limit(max_response_bytes));

    if (out_len == -1) {
      encode_error(&response, "read_timeout");
    } else if (out_len == -3) {
      encode_error(&response, "maude_eof");
    } else if (out_len < 0) {
      encode_error(&response,
                   out_len == -4 ? "response_too_large" : "read_failed");
    } else {
      /* Leave semantic diagnostics to the shared Elixir parser. */
      encode_ok(&response, output, out_len);
    }
    free(output);

  } else {
    encode_error(&response, "unknown_command");
  }

send_response:
  ei_send(fd, &emsg->from, response.buff, response.index);
  ei_x_free(&response);
}

/* Connect to Erlang node with retry logic and exponential backoff */
static int connect_with_retry(ei_cnode *ec, char *nodename, int max_retries) {
  int fd;
  int delay_ms = 100; /* Start with 100ms */

  for (int attempt = 1; attempt <= max_retries; attempt++) {
    fd = ei_connect_tmo(ec, nodename, 5000); /* 5 second timeout per attempt */
    if (fd >= 0) {
      return fd; /* Success */
    }

    fprintf(
        stderr,
        "Connection attempt %d/%d failed (errno: %d), retrying in %dms...\n",
        attempt, max_retries, erl_errno, delay_ms);

    usleep(delay_ms * 1000); /* Convert to microseconds */
    delay_ms *= 2;           /* Exponential backoff */
    if (delay_ms > 2000)
      delay_ms = 2000; /* Cap at 2 seconds */
  }

  return -1; /* All retries exhausted */
}

/* Main entry point */
int main(int argc, char **argv) {
  if (argc < 4) {
    fprintf(stderr, "Usage: %s <node_name> <maude_path> <erlang_node>\n",
            argv[0]);
    fprintf(stderr, "\n");
    fprintf(stderr, "Arguments:\n");
    fprintf(stderr,
            "  node_name    - Name for this C-Node (e.g., maude_bridge_1)\n");
    fprintf(stderr, "  maude_path   - Path to Maude executable\n");
    fprintf(stderr, "  erlang_node  - Full Erlang node name to connect to\n");
    fprintf(stderr, "The Erlang distribution cookie is read from stdin.\n");
    return 1;
  }

  char *node_name = argv[1];
  char *maude_path = argv[2];
  char *erlang_node = argv[3];
  char cookie[MAX_COOKIE_SIZE + 1] = {0};

  /* Setup signal handlers */
  signal(SIGTERM, handle_signal);
  signal(SIGINT, handle_signal);
  signal(SIGPIPE, SIG_IGN);

  /* Initialize ei library (required since OTP 21) */
  if (ei_init() != 0) {
    fprintf(stderr, "Failed to initialize ei library\n");
    return 1;
  }

  /* Start Maude subprocess */
  fprintf(stderr, "Starting Maude: %s\n", maude_path);
  if (start_maude(maude_path) < 0) {
    fprintf(stderr, "Failed to start Maude\n");
    return 1;
  }

  /* Wait for Maude to be ready */
  fprintf(stderr, "Waiting for Maude ready...\n");
  fflush(stderr);
  int ready_result = wait_for_ready();
  fprintf(stderr, "wait_for_ready returned: %d\n", ready_result);
  fflush(stderr);
  if (ready_result < 0) {
    fprintf(stderr, "Maude did not become ready\n");
    stop_maude();
    return 1;
  }
  fprintf(stderr, "Maude ready\n");
  fflush(stderr);

  if (read_cookie(cookie, sizeof(cookie)) < 0) {
    fprintf(stderr, "Failed to read Erlang distribution cookie\n");
    clear_secret(cookie, sizeof(cookie));
    stop_maude();
    return 1;
  }

  /* Initialize C-Node */
  ei_cnode ec;
  char full_node_name[256];
  /* Extract hostname from erlang_node (e.g., "test@studio" -> "studio") */
  char hostname[128] = "localhost";
  char *at_sign = strchr(erlang_node, '@');
  if (at_sign != NULL) {
    strncpy(hostname, at_sign + 1, sizeof(hostname) - 1);
    hostname[sizeof(hostname) - 1] = '\0';
  }
  snprintf(full_node_name, sizeof(full_node_name), "%s@%s", node_name,
           hostname);

  if (ei_connect_init(&ec, node_name, cookie, 0) < 0) {
    fprintf(stderr, "Failed to init C-Node connection\n");
    clear_secret(cookie, sizeof(cookie));
    stop_maude();
    return 1;
  }
  clear_secret(cookie, sizeof(cookie));

  /* Connect to Erlang node with retry logic */
  fprintf(stderr, "Connecting to Erlang node: %s (with retry)\n", erlang_node);
  int fd = connect_with_retry(&ec, erlang_node, 10);
  if (fd < 0) {
    fprintf(
        stderr,
        "Failed to connect to Erlang node after 10 retries: %s (errno: %d)\n",
        erlang_node, erl_errno);
    stop_maude();
    return 1;
  }
  fprintf(stderr, "Connected to Erlang node\n");

  /* Signal ready to parent process */
  printf("READY\n");
  fflush(stdout);

  /* Main message loop */
  erlang_msg emsg;
  ei_x_buff buf;
  ei_x_new(&buf);

  while (running) {
    /* Use timeout variant - handles select internally */
    int got = ei_xreceive_msg_tmo(fd, &emsg, &buf, 1000); /* 1 second timeout */

    if (got == ERL_TICK) {
      /* Heartbeat, ignore */
      continue;
    } else if (got == ERL_ERROR) {
      if (erl_errno == ETIMEDOUT) {
        /* Timeout is normal, check running flag and continue */
        continue;
      }
      fprintf(stderr, "Connection error (errno: %d)\n", erl_errno);
      break;
    } else if (got == ERL_MSG) {
      handle_message(fd, &emsg, &buf);
      ei_x_free(&buf);
      ei_x_new(&buf);
    }
  }

  /* Cleanup */
  fprintf(stderr, "Shutting down...\n");
  ei_x_free(&buf);
  close(fd);
  stop_maude();

  fprintf(stderr, "Goodbye\n");
  return 0;
}
