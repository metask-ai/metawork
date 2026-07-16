#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define MAX_FRAME_BYTES 4096

static int read_frame(char *buffer, size_t capacity, size_t *frame_size) {
  size_t length = 0;
  int overflow = 0;

  for (;;) {
    char byte = 0;
    const ssize_t count = read(STDIN_FILENO, &byte, 1);
    if (count == 0) {
      if (length == 0 && !overflow) {
        return 0;
      }
      break;
    }
    if (count < 0) {
      return -1;
    }
    if (byte == '\n') {
      break;
    }
    if (length + 1 < capacity && !overflow) {
      buffer[length++] = byte;
    } else {
      overflow = 1;
    }
  }

  buffer[length] = '\0';
  *frame_size = length;
  return overflow ? -2 : 1;
}

static void crash_now(void) {
  fflush(stdout);
  raise(SIGABRT);
  _exit(134);
}

static int run_baseline(void) {
  char frame[MAX_FRAME_BYTES + 1];
  size_t frame_size = 0;

  printf("READY_BASELINE\t%d\tcompleted-session=completed\tactive-session=running\n",
         getpid());
  for (;;) {
    const int result = read_frame(frame, sizeof(frame), &frame_size);
    if (result == 0) {
      return 0;
    }
    if (result == -1) {
      return 2;
    }
    if (result == -2) {
      printf("ERROR\tFRAME_TOO_LARGE\t%u\n", MAX_FRAME_BYTES);
      continue;
    }
    if (strcmp(frame, "STOP") == 0) {
      printf("STOPPED_BASELINE\n");
      return 0;
    }
    if (strncmp(frame, "CRASH\t", 6) == 0 && frame[6] != '\0') {
      printf("ACTIVE\t%s\n", frame + 6);
      crash_now();
    }
    printf("ERROR\tINVALID_BASELINE_FRAME\t%zu\n", frame_size);
  }
}

static int run_worker(void) {
  char frame[MAX_FRAME_BYTES + 1];
  size_t frame_size = 0;

  printf("READY_WORKER\t%d\tmax-frame=%u\n", getpid(), MAX_FRAME_BYTES);
  for (;;) {
    const int result = read_frame(frame, sizeof(frame), &frame_size);
    if (result == 0) {
      return 0;
    }
    if (result == -1) {
      return 2;
    }
    if (result == -2) {
      printf("ERROR\tFRAME_TOO_LARGE\t%u\n", MAX_FRAME_BYTES);
      continue;
    }
    if (strcmp(frame, "STOP") == 0) {
      printf("STOPPED_WORKER\n");
      return 0;
    }

    char *save = NULL;
    char *kind = strtok_r(frame, "\t", &save);
    char *correlation_id = strtok_r(NULL, "\t", &save);
    if (kind != NULL && correlation_id != NULL &&
        strcmp(kind, "PING") == 0 && strtok_r(NULL, "\t", &save) == NULL) {
      printf("RESULT\t%s\tpong\n", correlation_id);
      continue;
    }

    char *session_id = strtok_r(NULL, "\t", &save);
    char *operation = strtok_r(NULL, "\t", &save);
    if (kind == NULL || correlation_id == NULL || session_id == NULL ||
        operation == NULL || strtok_r(NULL, "\t", &save) != NULL ||
        strcmp(kind, "RUN") != 0) {
      printf("ERROR\tINVALID_WORKER_FRAME\t%zu\n", frame_size);
      continue;
    }

    printf("ACCEPTED\t%s\t%s\t%s\n", correlation_id, session_id,
           operation);
    if (strcmp(operation, "dangerous_tool") == 0) {
      crash_now();
    }
    printf("RESULT\t%s\tok\n", correlation_id);
  }
}

int main(int argc, char **argv) {
  setvbuf(stdout, NULL, _IONBF, 0);
  if (argc != 2) {
    fprintf(stderr, "usage: fault-process --baseline|--worker\n");
    return 64;
  }
  if (strcmp(argv[1], "--baseline") == 0) {
    return run_baseline();
  }
  if (strcmp(argv[1], "--worker") == 0) {
    return run_worker();
  }
  fprintf(stderr, "unknown mode: %s\n", argv[1]);
  return 64;
}
