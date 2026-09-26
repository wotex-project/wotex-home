/* Exercise the actual bridge reader, including its incremental scan offset. */
#define EX_MAUDE_TEST
#define main maude_bridge_main
#include "maude_bridge.c"
#undef main
#include <assert.h>

static void test_fragmented_prompt(void) {
  char output[] = "payload Maude> marker\nMaude> ";
  const size_t length = strlen(output);
  for (size_t split = 0; split < length; split++) {
    assert(find_prompt_boundary(output, split, 0) == NULL);
    size_t start = split >= PROMPT_LEN ? split - PROMPT_LEN + 1 : 0;
    assert(find_prompt_boundary(output, length, start) == output + 22);
  }
}

static void test_linear_response_scan(void) {
  int descriptors[2];
  assert(pipe(descriptors) == 0);
  pid_t writer = fork();
  assert(writer >= 0);
  if (writer == 0) {
    close(descriptors[0]);
    char chunk[4096];
    memset(chunk, 'x', sizeof(chunk));
    for (int index = 0; index < 32; index++)
      assert(write(descriptors[1], chunk, sizeof(chunk)) ==
             (ssize_t)sizeof(chunk));
    assert(write(descriptors[1], "\nMaude> ", 8) == 8);
    close(descriptors[1]);
    _exit(0);
  }

  close(descriptors[1]);
  maude.stdout_fd = descriptors[0];
  size_t size = 128 * 1024;
  size_t capacity = 0;
  char *output = NULL;
  scanned_windows = 0;
  int length = read_until_prompt(&output, &capacity, 1000, size + 1);
  assert(length == (int)size);
  for (size_t index = 0; index < size; index++)
    assert(output[index] == 'x');
  assert(scanned_windows < size * 2);
  free(output);
  close(descriptors[0]);
  int status;
  assert(waitpid(writer, &status, 0) == writer);
  assert(WIFEXITED(status) && WEXITSTATUS(status) == 0);
}

int main(void) {
  test_fragmented_prompt();
  test_linear_response_scan();
  puts("C prompt framing and linear scan regressions passed");
  return 0;
}
