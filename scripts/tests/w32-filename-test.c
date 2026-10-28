/* Compile the actual conversion functions extracted from src/w32.c.
   No copied implementation and no mocked filesystem calls.  */
#include <windows.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>
#include <errno.h>

#define MAX_UTF16_PATH 32768
#define MAX_UTF8_PATH (MAX_UTF16_PATH * 4)
#define ARRAYELTS(a) (sizeof (a) / sizeof (a)[0])
#define filename_to_utf16(in, out) \
  filename_to_utf16_n (in, out, ARRAYELTS (out))

static int codepage_for_filenames (void *unused) { return CP_UTF8; }
static bool c_isalpha (int c)
{
  return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z');
}
static int (WINAPI *pMultiByteToWideChar)
  (UINT, DWORD, LPCSTR, int, LPWSTR, int) = MultiByteToWideChar;
static int (WINAPI *pWideCharToMultiByte)
  (UINT, DWORD, LPCWSTR, int, LPSTR, int, LPCSTR, LPBOOL) = WideCharToMultiByte;
static DWORD multiByteToWideCharFlags = MB_ERR_INVALID_CHARS;

#include "filename-under-test.c"

static int checks;
#define CHECK(expr) do { \
  ++checks; \
  if (!(expr)) { \
    fprintf (stderr, "FAIL line %d: %s (errno=%d, winerr=%lu)\n", \
             __LINE__, #expr, errno, GetLastError ()); \
    exit (1); \
  } \
} while (0)

static char *
long_name (size_t length)
{
  char *name = malloc (length + 1);
  if (!name) abort ();
  memset (name, 'a', length);
  memcpy (name, "C:\\", 3);
  name[length] = 0;
  return name;
}

static void
bounds_tests (void)
{
  struct { wchar_t text[4]; uint32_t guard; } wide = {{L'x'}, 0x12345678};
  struct { char text[4]; uint32_t guard; } bytes = {{'x'}, 0x12345678};
  CHECK (filename_to_utf16_n ("abcd", wide.text, 4) == -1);
  CHECK (wide.text[0] == 0 && wide.guard == 0x12345678);
  CHECK (errno == ENAMETOOLONG && GetLastError () == ERROR_FILENAME_EXCED_RANGE);
  CHECK (filename_to_utf16_n ("abc", wide.text, 4) == 0);
  CHECK (wcscmp (wide.text, L"abc") == 0 && wide.guard == 0x12345678);
  CHECK (filename_to_utf16_n ("x", wide.text, 0) == -1);
  CHECK (wide.guard == 0x12345678);
  CHECK (filename_from_utf16_n (L"abcd", bytes.text, 4) == -1);
  CHECK (bytes.text[0] == 0 && bytes.guard == 0x12345678);
  CHECK (errno == ENAMETOOLONG);
  CHECK (filename_to_ansi_n ("abcd", bytes.text, 4) == -1);
  CHECK (bytes.text[0] == 0 && bytes.guard == 0x12345678);
  CHECK (filename_from_ansi_n ("abcd", bytes.text, 4) == -1);
  CHECK (bytes.text[0] == 0 && bytes.guard == 0x12345678);
  CHECK (filename_to_utf16_n ("\xff", wide.text, 4) == -1);
  CHECK (errno == EILSEQ && wide.text[0] == 0);
  CHECK (w32_filename_from_utf16 (L"\\\\?\\UNC\\host\\share", bytes.text, 2) == -1);
  CHECK (bytes.guard == 0x12345678);
}

static void
path_tests (void)
{
  wchar_t wide[MAX_UTF16_PATH], raw[MAX_UTF16_PATH];
  char bytes[MAX_UTF8_PATH];
  const int lengths[] = {247, 248, 259, 260, 261, 262, 1024, 4096, 32763};
  for (size_t i = 0; i < ARRAYELTS (lengths); i++)
    {
      char *name = long_name (lengths[i]);
      CHECK (w32_filename_to_utf16 (name, wide, ARRAYELTS (wide)) == 0);
      CHECK ((wcsncmp (wide, L"\\\\?\\", 4) == 0) == (lengths[i] >= 248));
      CHECK (w32_filename_from_utf16 (wide, bytes, sizeof bytes) == 0);
      CHECK (strcmp (name, bytes) == 0);
      free (name);
    }
  char *name = long_name (32764);
  CHECK (w32_filename_to_utf16 (name, wide, ARRAYELTS (wide)) == -1);
  CHECK (errno == ENAMETOOLONG && wide[0] == 0);
  free (name);
  name = long_name (262);
  CHECK (w32_filename_to_utf16 (name, wide, 266) == -1);
  CHECK (w32_filename_to_utf16 (name, wide, 267) == 0);
  CHECK (wcslen (wide) == 266);
  CHECK (w32_filename_to_utf16 (name, raw, ARRAYELTS (raw)) == 0);
  CHECK (wcscmp (wide, raw) == 0); /* Independent destination buffers.  */
  free (name);

  char unc[500] = "\\\\server\\share\\";
  memset (unc + strlen (unc), 'u', 350);
  unc[364] = 0;
  CHECK (w32_filename_to_utf16 (unc, wide, ARRAYELTS (wide)) == 0);
  CHECK (wcsncmp (wide, L"\\\\?\\UNC\\server\\share\\", 21) == 0);
  CHECK (w32_filename_from_utf16 (wide, bytes, sizeof bytes) == 0);
  CHECK (strcmp (unc, bytes) == 0);

  char relative[400];
  memset (relative, 'r', sizeof relative - 1);
  relative[sizeof relative - 1] = 0;
  /* Pure transcoding preserves the semantics of a relative link target.  */
  CHECK (filename_to_utf16_n (relative, raw, ARRAYELTS (raw)) == 0);
  CHECK (raw[0] == L'r' && wcslen (raw) == strlen (relative));
  CHECK (w32_filename_to_utf16 (relative, wide, ARRAYELTS (wide)) == 0);
  CHECK (wcsncmp (wide, L"\\\\?\\", 4) == 0);

  char dotted[500] = "C:/parent/../";
  memset (dotted + strlen (dotted), 'd', 300);
  dotted[313] = 0;
  CHECK (w32_filename_to_utf16 (dotted, wide, ARRAYELTS (wide)) == 0);
  CHECK (wcsstr (wide, L"..") == NULL && wcschr (wide, L'/') == NULL);
  CHECK (wcsncmp (wide, L"\\\\?\\C:\\", 7) == 0);

  const char *unicode = "C:\\中文-\xf0\x9f\x98\x80.txt";
  CHECK (filename_to_utf16_n (unicode, raw, ARRAYELTS (raw)) == 0);
  CHECK (filename_from_utf16_n (raw, bytes, sizeof bytes) == 0);
  CHECK (strcmp (bytes, unicode) == 0);
  CHECK (wcslen (raw) == 12);

  CHECK (w32_filename_to_utf16 ("NUL", wide, ARRAYELTS (wide)) == 0);
  CHECK (wcscmp (wide, L"NUL") == 0);
  CHECK (w32_filename_to_utf16 ("\\\\?\\C:\\x", wide, ARRAYELTS (wide)) == 0);
  CHECK (wcscmp (wide, L"\\\\?\\C:\\x") == 0);
}

int
main (void)
{
  bounds_tests ();
  path_tests ();
  printf ("PASS: %d checks against the actual filename converters\n", checks);
  return 0;
}
