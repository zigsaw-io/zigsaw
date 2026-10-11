#!/usr/bin/env python3
# Rnote's build-aux/cargo_build.py, without the Unix tools: the original runs
# `env <vars> cargo build ...` and `cp` through os.system, which on Windows is
# cmd.exe, where neither exists. Same arguments, split at spaces as the shell
# would have split them (upstream passes Windows paths, so no shlex).

import os
import shutil
import subprocess
import sys

project_build_root = sys.argv[1]
project_src_root = sys.argv[2]
cargo_env = sys.argv[3]
cargo_cmd = sys.argv[4]
cargo_options = sys.argv[5]
bin_output = sys.argv[6]
output_file = sys.argv[7]

env = dict(os.environ)
for assignment in cargo_env.split():
    name, _, value = assignment.partition("=")
    env[name] = value

cargo_call = [cargo_cmd, "build"] + cargo_options.split()
print(" ".join(cargo_call), file=sys.stderr)
res = subprocess.run(cargo_call, env=env).returncode
if res != 0:
    print(f"cargo call failed, code {res}", file=sys.stderr)
    sys.exit(1)

# cargo names the executable <name>.exe; MSYS2's cp, which upstream uses,
# adds the .exe itself.
if not os.path.exists(bin_output) and os.path.exists(bin_output + ".exe"):
    bin_output += ".exe"
print(f"copying {bin_output} to {output_file}", file=sys.stderr)
shutil.copyfile(bin_output, output_file)
