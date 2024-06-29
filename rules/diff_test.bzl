# Copyright 2019 The Bazel Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""A test rule that compares two binary files.

The rule uses a Bash command (diff) on Linux/macOS/non-Windows, and a cmd.exe
command (fc.exe) on Windows (no Bash is required).
"""

load("//lib:shell.bzl", "shell")

def _runfiles_path(f):
    if f.root.path:
        return f.path[len(f.root.path) + 1:]  # generated file
    else:
        return f.path  # source file

def _ignore_line_endings(ctx):
    ignore_line_endings = "0"
    if ctx.attr.ignore_line_endings:
        ignore_line_endings = "1"
    return ignore_line_endings

def _diff_test_impl(ctx):
    if ctx.attr.is_windows:
        bash_bin = ctx.toolchains["@bazel_tools//tools/sh:toolchain_type"].path
        test_bin = ctx.actions.declare_file(ctx.label.name + "-test.bat")
        ctx.actions.write(
            output = test_bin,
            content = """@rem Generated by diff_test.bzl, do not edit.
@echo off
SETLOCAL ENABLEEXTENSIONS
SETLOCAL ENABLEDELAYEDEXPANSION
set PATH=%SYSTEMROOT%\\system32
if defined RUNFILES_MANIFEST_FILE (
    set MF=%RUNFILES_MANIFEST_FILE:/=\\%
) else (
    if exist MANIFEST (
        set MF=MANIFEST
    ) else (
        if exist ..\\MANIFEST (
            set MF=..\\MANIFEST
        )
    )
)
if not exist %MF% (
    echo Manifest file %MF% not found
    exit /b 1
)
echo using %MF%
set F1={file1}
set F2={file2}
if "!F1:~0,9!" equ "external/" (set F1=!F1:~9!) else (set F1=!TEST_WORKSPACE!/!F1!)
if "!F2:~0,9!" equ "external/" (set F2=!F2:~9!) else (set F2=!TEST_WORKSPACE!/!F2!)
for /F "tokens=2* usebackq" %%i in (`findstr.exe /l /c:"!F1! " "%MF%"`) do (
  set RF1=%%i
  set RF1=!RF1:/=\\!
)
if "!RF1!" equ "" (
  if "%RUNFILES_MANIFEST_ONLY%" neq "1" if exist "%RUNFILES_DIR%\\%F1%" (
    set RF1="%RUNFILES_DIR%\\%F1%"
  ) else (
    if exist "{file1}" (
      set RF1="{file1}"
    )
  )
  if "!RF1!" neq "" (
    set RF1=!RF1:/=\\!
  ) else (
    echo>&2 ERROR: !F1! not found
    exit /b 1
  )
)
for /F "tokens=2* usebackq" %%i in (`findstr.exe /l /c:"!F2! " "%MF%"`) do (
  set RF2=%%i
  set RF2=!RF2:/=\\!
)
if "!RF2!" equ "" (
  if "%RUNFILES_MANIFEST_ONLY%" neq "1" if exist "%RUNFILES_DIR%\\%F2%" (
    set RF2="%RUNFILES_DIR%\\%F2%"
  ) else (
    if exist "{file2}" (
      set RF2="{file2}"
    )
  )
  if "!RF2!" neq "" (
    set RF2=!RF2:/=\\!
  ) else (
    echo>&2 ERROR: !F2! not found
    exit /b 1
  )
)
rem use tr command from msys64 package, msys64 is a bazel recommendation
rem todo: in future better to pull in diff.exe to align with non-windows path
if "{ignore_line_endings}"=="1" (
  if exist {bash_bin} (
    for %%f in ({bash_bin}) do set "TR=%%~dpf\\tr.exe"
  ) else (
    rem match bazel's algorithm to find unix tools
    set "TR=C:\\msys64\\usr\\bin\\tr.exe"
  )
  if not exist !TR! (
    echo>&2 WARNING: ignore_line_endings set but !TR! not found; line endings will be compared
  ) else (
    for %%f in (!RF1!) do set RF1_TEMP=%TEST_TMPDIR%\\%%~nxf_lf1
    for %%f in (!RF2!) do set RF2_TEMP=%TEST_TMPDIR%\\%%~nxf_lf2
    type "!RF1!" | !TR! -d "\\r" > "!RF1_TEMP!"
    type "!RF2!" | !TR! -d "\\r" > "!RF2_TEMP!"
    set "RF1=!RF1_TEMP!"
    set "RF2=!RF2_TEMP!"
    rem echo original file !RF1! replaced by !RF1_TEMP!
    rem echo original file !RF2! replaced by !RF2_TEMP!
  )
)
fc.exe 2>NUL 1>NUL /B "!RF1!" "!RF2!"
if %ERRORLEVEL% neq 0 (
  if %ERRORLEVEL% equ 1 (
    set "FAIL_MSG={fail_msg}"
    if "!FAIL_MSG!"=="" (
        set "FAIL_MSG=why? diff ^"!RF1!^" ^"!RF2!^" ^| cat -v"
    )
    echo>&2 FAIL: files "{file1}" and "{file2}" differ. !FAIL_MSG!
    exit /b 1
  ) else (
    fc.exe /B "!RF1!" "!RF2!"
    exit /b %errorlevel%
  )
)
""".format(
                # TODO(arostovtsev): use shell.escape_for_bat when https://github.com/bazelbuild/bazel-skylib/pull/363 is merged
                fail_msg = ctx.attr.failure_message,
                file1 = _runfiles_path(ctx.file.file1),
                file2 = _runfiles_path(ctx.file.file2),
                ignore_line_endings = _ignore_line_endings(ctx),
                bash_bin = bash_bin
            ),
            is_executable = True,
        )
    else:
        test_bin = ctx.actions.declare_file(ctx.label.name + "-test.sh")
        ctx.actions.write(
            output = test_bin,
            content = r"""#!/usr/bin/env bash
set -euo pipefail
F1="{file1}"
F2="{file2}"
[[ "$F1" =~ ^external/* ]] && F1="${{F1#external/}}" || F1="$TEST_WORKSPACE/$F1"
[[ "$F2" =~ ^external/* ]] && F2="${{F2#external/}}" || F2="$TEST_WORKSPACE/$F2"
if [[ -d "${{RUNFILES_DIR:-/dev/null}}" && "${{RUNFILES_MANIFEST_ONLY:-}}" != 1 ]]; then
  RF1="$RUNFILES_DIR/$F1"
  RF2="$RUNFILES_DIR/$F2"
elif [[ -f "${{RUNFILES_MANIFEST_FILE:-/dev/null}}" ]]; then
  RF1="$(grep -F -m1 "$F1 " "$RUNFILES_MANIFEST_FILE" | sed 's/^[^ ]* //')"
  RF2="$(grep -F -m1 "$F2 " "$RUNFILES_MANIFEST_FILE" | sed 's/^[^ ]* //')"
elif [[ -f "$TEST_SRCDIR/$F1" && -f "$TEST_SRCDIR/$F2" ]]; then
  RF1="$TEST_SRCDIR/$F1"
  RF2="$TEST_SRCDIR/$F2"
else
  echo >&2 "ERROR: could not find \"{file1}\" and \"{file2}\""
  exit 1
fi
if ! diff {strip_trailing_cr}"$RF1" "$RF2"; then
  MSG={fail_msg}
  if [[ "${{MSG}}"=="" (
      MSG="why? diff {strip_trailing_cr}"${{RF1}}" "${{RF2}}" | cat -v"
  )
  echo >&2 "FAIL: files \"{file1}\" and \"{file2}\" differ. ${{MSG}}"
  exit 1
fi
""".format(
                fail_msg = shell.quote(ctx.attr.failure_message),
                file1 = _runfiles_path(ctx.file.file1),
                file2 = _runfiles_path(ctx.file.file2),
                strip_trailing_cr = "--strip-trailing-cr " if ctx.attr.ignore_line_endings else ""
            ),
            is_executable = True,
        )
    return DefaultInfo(
        executable = test_bin,
        files = depset(direct = [test_bin]),
        runfiles = ctx.runfiles(files = [test_bin, ctx.file.file1, ctx.file.file2]),
    )

_diff_test = rule(
    attrs = {
        "failure_message": attr.string(),
        "file1": attr.label(
            allow_single_file = True,
            mandatory = True,
        ),
        "file2": attr.label(
            allow_single_file = True,
            mandatory = True,
        ),
        "ignore_line_endings": attr.bool(
            default = True,
        ),
        "is_windows": attr.bool(mandatory = True),
    },
    toolchains = [
        "@bazel_tools//tools/sh:toolchain_type",
    ],
    test = True,
    implementation = _diff_test_impl,
)

def diff_test(name, file1, file2, failure_message = None, ignore_line_endings = True, **kwargs):
    """A test that compares two files.

    The test succeeds if the files' contents match.

    Args:
      name: The name of the test rule.
      file1: Label of the file to compare to `file2`.
      file2: Label of the file to compare to `file1`.
      ignore_line_endings: Ignore differences between CRLF and LF line endings. On windows, this is 
          forced to False if the 'tr' command can't be found in the bash installation on the host.
      failure_message: Additional message to log if the files' contents do not match.
      **kwargs: The [common attributes for tests](https://bazel.build/reference/be/common-definitions#common-attributes-tests).
    """
    _diff_test(
        name = name,
        file1 = file1,
        file2 = file2,
        ignore_line_endings = ignore_line_endings,
        failure_message = failure_message,
        is_windows = select({
            "@bazel_tools//src/conditions:host_windows": True,
            "//conditions:default": False,
        }),
        **kwargs
    )
