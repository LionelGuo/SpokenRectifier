#!/usr/bin/env bash
# Nightly fidelity-eval entry point (工单 10). Writes a dated report
# under .scratch/eval/ (not committed; machine local — excluded on this
# machine via .git/info/exclude) and appends a one-line verdict to the
# log. Exit code follows sr-eval: 0 all pass, 1 failures, 2 setup
# errors.
#
# WSL cron line:
#   17 3 * * * /home/lionel/Code/SpokenRectifier/scripts/nightly-eval.sh
#
# Windows Task Scheduler (run once from cmd/PowerShell; wsl.exe boots
# the distro on demand, and the task fires only while the user is
# logged on — asleep/off at 03:17 means the run is simply missed):
#   schtasks /Create /TN SpokenRectifierEval /SC DAILY /ST 03:17 ^
#     /TR "wsl.exe -d Ubuntu_D -e bash /home/lionel/Code/SpokenRectifier/scripts/nightly-eval.sh"

set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo"

export PATH="$HOME/.cargo/bin:$PATH"
mkdir -p .scratch/eval

date_tag="$(date +%Y%m%d)"
report=".scratch/eval/nightly-${date_tag}.md"

# Propagate sr-eval's own exit code (0 pass / 1 failures / 2 setup
# error) — the scheduler's pass/fail signal.
rc=0
# On-form only: the 94.3% anchor must not mix with the off-form arm
# (ADR-0014). Off-form probes go `--form off` by hand.
cargo run -q -p sr-replay --bin sr-eval -- --form on --report "$report" >> .scratch/eval/nightly.log 2>&1 || rc=$?
if [ "$rc" -eq 0 ]; then
    verdict=PASS
else
    verdict=FAIL
fi

echo "$(date '+%Y-%m-%d %H:%M:%S') ${date_tag} ${verdict} rc=${rc} report=${report}" >> .scratch/eval/nightly.log
exit "$rc"
