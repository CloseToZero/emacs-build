/* Exercise a real windowless TIMERPROC on Emacs's GUI thread.
   Build as a module; load in a GUI Emacs, call w32-thread-timer-start,
   wait with sleep-for, then inspect w32-thread-timer-result.  */
#include <windows.h>
#include <emacs-module.h>

int plugin_is_GPL_compatible;
static HINSTANCE instance;
static HHOOK hook;
static volatile LONG started, fired;
static HWND frame;

BOOL WINAPI
DllMain (HINSTANCE dll, DWORD reason, LPVOID reserved)
{
  if (reason == DLL_PROCESS_ATTACH)
    instance = dll;
  return TRUE;
}

static void CALLBACK
timer_proc (HWND hwnd, UINT message, UINT_PTR id, DWORD time)
{
  KillTimer (NULL, id);
  InterlockedIncrement (&fired);
}

static LRESULT CALLBACK
call_hook (int code, WPARAM wparam, LPARAM lparam)
{
  if (code >= 0)
    {
      CWPSTRUCT *msg = (CWPSTRUCT *) lparam;
      if (msg->hwnd == frame && msg->message == WM_NULL
          && InterlockedCompareExchange (&started, 1, 0) == 0)
        {
          if (!SetTimer (NULL, 0, 20, timer_proc))
            InterlockedExchange (&started, -1);
        }
    }
  return CallNextHookEx (hook, code, wparam, lparam);
}

static BOOL CALLBACK
find_frame (HWND hwnd, LPARAM ignored)
{
  DWORD pid;
  char name[64];
  GetWindowThreadProcessId (hwnd, &pid);
  if (pid == GetCurrentProcessId ()
      && GetClassNameA (hwnd, name, sizeof name)
      && lstrcmpA (name, "Emacs") == 0)
    {
      frame = hwnd;
      return FALSE;
    }
  return TRUE;
}

static emacs_value
start (emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *data)
{
  EnumWindows (find_frame, 0);
  if (!frame || hook)
    return env->intern (env, "nil");
  hook = SetWindowsHookExA (WH_CALLWNDPROC, call_hook, instance,
                           GetWindowThreadProcessId (frame, NULL));
  return env->intern (env, hook && SendMessageTimeout (frame, WM_NULL, 0, 0,
                                               SMTO_ABORTIFHUNG, 1000, NULL)
                     ? "t" : "nil");
}

static emacs_value
result (emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *data)
{
  if (hook)
    {
      UnhookWindowsHookEx (hook);
      hook = NULL;
    }
  /* 1 means setup succeeded but the callback was lost; 2 means success.  */
  LONG state = InterlockedCompareExchange (&started, 0, 0);
  return env->make_integer (env, state == 1
                           ? 1 + InterlockedCompareExchange (&fired, 0, 0)
                           : state);
}

int
emacs_module_init (struct emacs_runtime *runtime)
{
  emacs_env *env = runtime->get_environment (runtime);
  emacs_value bindings[2];
  bindings[0] = env->intern (env, "w32-thread-timer-start");
  bindings[1] = env->make_function (env, 0, 0, start, "Start GUI timer probe.", NULL);
  env->funcall (env, env->intern (env, "fset"), 2, bindings);
  bindings[0] = env->intern (env, "w32-thread-timer-result");
  bindings[1] = env->make_function (env, 0, 0, result, "Read GUI timer probe.", NULL);
  env->funcall (env, env->intern (env, "fset"), 2, bindings);
  return 0;
}
