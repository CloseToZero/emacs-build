/* SPDX-FileCopyrightText: 2026 Chen Zhexuan
   SPDX-License-Identifier: GPL-3.0-or-later */

/* A retained module channel keeps a retired pipe reader's I/O outstanding.
   The child variant provides silent exits and separate stdout/stderr.  */

#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <io.h>
#include <fcntl.h>

#ifdef PIPE_PROBE_CHILD
int
main (int argc, char **argv)
{
  if (argc != 2)
    return 2;
  _setmode (_fileno (stdout), _O_BINARY);
  _setmode (_fileno (stderr), _O_BINARY);
  if (strcmp (argv[1], "output") == 0)
    {
      fputs ("stdout-complete\n", stdout);
      fputs ("stderr-complete\n", stderr);
      return 0;
    }
  if (strcmp (argv[1], "bulk") == 0)
    {
      char block[4096];
      memset (block, 'x', sizeof block);
      for (int i = 0; i < 256; i++)
        if (fwrite (block, 1, sizeof block, stdout) != sizeof block)
          return 3;
      fputs ("stderr-complete\n", stderr);
      return 0;
    }
  return strcmp (argv[1], "silent") == 0 ? 0 : 2;
}
#else
#include <emacs-module.h>

int plugin_is_GPL_compatible;

struct held_pipe { int fd; };

static emacs_value
fail (emacs_env *env, const char *text)
{
  emacs_value message = env->make_string (env, text, strlen (text));
  emacs_value data = env->funcall (env, env->intern (env, "list"), 1, &message);
  env->non_local_exit_signal (env, env->intern (env, "file-error"), data);
  return env->intern (env, "nil");
}

static void
release (void *pointer)
{
  struct held_pipe *pipe = pointer;
  if (pipe->fd >= 0)
    _close (pipe->fd);
  free (pipe);
}

static emacs_value
hold (emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *data)
{
  struct held_pipe *pipe = malloc (sizeof *pipe);
  if (!pipe)
    return fail (env, "Cannot allocate retained pipe");
  pipe->fd = env->open_channel (env, args[0]);
  if (env->non_local_exit_check (env) != emacs_funcall_exit_return)
    {
      free (pipe);
      return env->intern (env, "nil");
    }
  return env->make_user_ptr (env, release, pipe);
}

static emacs_value
write_pipe (emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *data)
{
  struct held_pipe *pipe = env->get_user_ptr (env, args[0]);
  ptrdiff_t length = 0;
  if (env->non_local_exit_check (env) != emacs_funcall_exit_return)
    return env->intern (env, "nil");
  if (pipe->fd < 0)
    return fail (env, "Retained pipe is closed");
  if (!env->copy_string_contents (env, args[1], NULL, &length))
    return env->intern (env, "nil");
  char *text = malloc (length);
  if (!text)
    return fail (env, "Cannot allocate pipe text");
  if (!env->copy_string_contents (env, args[1], text, &length))
    {
      free (text);
      return env->intern (env, "nil");
    }
  int written = _write (pipe->fd, text, (unsigned) length - 1);
  free (text);
  if (written != length - 1)
    return fail (env, "Retained pipe write failed");
  return env->intern (env, "t");
}

static emacs_value
close_pipe (emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *data)
{
  struct held_pipe *pipe = env->get_user_ptr (env, args[0]);
  if (env->non_local_exit_check (env) != emacs_funcall_exit_return)
    return env->intern (env, "nil");
  if (pipe->fd >= 0)
    {
      int fd = pipe->fd;
      pipe->fd = -1;
      if (_close (fd))
        return fail (env, "Retained pipe close failed");
    }
  return env->intern (env, "t");
}

static emacs_value
wait_child (emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *data)
{
  DWORD pid = (DWORD) env->extract_integer (env, args[0]);
  if (env->non_local_exit_check (env) != emacs_funcall_exit_return)
    return env->intern (env, "nil");
  HANDLE child = OpenProcess (SYNCHRONIZE, FALSE, pid);
  if (!child)
    return fail (env, "Cannot observe test child exit");
  DWORD result = WaitForSingleObject (child, 5000);
  CloseHandle (child);
  if (result != WAIT_OBJECT_0)
    return fail (env, "Test child did not exit");
  return env->intern (env, "t");
}

static emacs_value
handle_count (emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *data)
{
  DWORD count;
  if (!GetProcessHandleCount (GetCurrentProcess (), &count))
    return fail (env, "Cannot count test process handles");
  return env->make_integer (env, count);
}

static void
bind_function (emacs_env *env, const char *name, ptrdiff_t count,
      emacs_value (*function) (emacs_env *, ptrdiff_t, emacs_value *, void *))
{
  emacs_value values[] = {
    env->intern (env, name),
    env->make_function (env, count, count, function,
                        "Operate on an isolated pipe regression fixture.", NULL)
  };
  env->funcall (env, env->intern (env, "fset"), 2, values);
}

int
emacs_module_init (struct emacs_runtime *runtime)
{
  emacs_env *env = runtime->get_environment (runtime);
  bind_function (env, "emacsbuild-pipe-hold", 1, hold);
  bind_function (env, "emacsbuild-pipe-write", 2, write_pipe);
  bind_function (env, "emacsbuild-pipe-close", 1, close_pipe);
  bind_function (env, "emacsbuild-pipe-wait-child", 1, wait_child);
  bind_function (env, "emacsbuild-pipe-handle-count", 0, handle_count);
  return 0;
}
#endif
