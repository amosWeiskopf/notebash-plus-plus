#!/usr/bin/env python3
"""open big csv files in several tools and time what you would notice.

every tool runs in the same 120 by 30 tmux terminal. for each run the script
measures three things:

- first screen: seconds from starting the tool until the second data row is
  on the screen,
- last row: seconds from pressing the tool's end key (repeated every half
  second) until the file's last row is on the screen,
- peak memory: the largest resident set of the tool's processes, in mb.

a run that goes over 3.5 gb of memory is stopped and recorded as 'memory'; a
run over 90 seconds as 'timeout'. tools that are not installed are skipped.

usage: tools/benchmark.py WORK_FOLDER [sizes] [tools]
       sizes like 100mb,1gb,5gb; tools like 'notebash++,less'.
       RUNS=3 sets the runs per tool and size. results go to
       WORK_FOLDER/results.json, medians are printed as a table.
"""

from __future__ import annotations

import json
import os
import pathlib
import shlex
import shutil
import statistics
import subprocess
import sys
import tempfile
import time
from collections.abc import Callable

REPOSITORY = pathlib.Path(__file__).resolve().parent.parent
TMUX = ['tmux', '-L', 'notebashpp-benchmark', '-f', '/dev/null']
MEMORY_GUARD_KB = 3_500_000
TIMEOUT_SECONDS = 90.0
SIZES = {'100mb': 100e6, '1gb': 1e9, '2gb': 2e9, '5gb': 5e9}
LAST_ROW = '999999999,the very last customer,Bisbee,0.01,"end, finally"\n'


def make_csv(path: pathlib.Path, size: float) -> None:
    """rows like 7,customer 7,Haifa,2.59,"note, with a comma 7", then a last row."""
    cities = ['Tel Aviv', 'Haifa', 'Nicosia', 'Reno', 'Laughlin', 'Las Vegas', 'Bisbee']
    block = ''.join(
        f'{number},customer {number},{cities[number % 7]},'
        f'{(number * 37) % 100000 / 100:.2f},"note, with a comma {number}"\n'
        for number in range(10000)
    ).encode()
    with path.open('wb') as csv_file:
        csv_file.write(b'id,name,city,amount,note\n')
        written = 0
        while written < size:
            csv_file.write(block)
            written += len(block)
        csv_file.write(LAST_ROW.encode())


def notebash_command(profile: pathlib.Path) -> Callable[[pathlib.Path], list[str]]:
    def command(path: pathlib.Path) -> list[str]:
        return [
            'env',
            'NVIM_APPNAME=notebashpp-benchmark',
            f'XDG_CONFIG_HOME={profile}/config',
            f'XDG_DATA_HOME={profile}/data',
            f'XDG_STATE_HOME={profile}/state',
            'NOTEBASHPP_TEST=1',
            'NOTEBASHPP_NO_SESSION=1',
            'nvim',
            '--',
            str(path),
        ]

    return command


def tools(profile: pathlib.Path) -> dict[str, tuple[str, Callable[[pathlib.Path], list[str]], str]]:
    """name: (program that must exist, command for a file, end key)."""
    return {
        'Notebash++': ('nvim', notebash_command(profile), 'C-End'),
        'Neovim': ('nvim', lambda path: ['nvim', '--clean', '--', str(path)], 'G'),
        'Vim': ('vim', lambda path: ['vim', '--clean', '--', str(path)], 'G'),
        'VisiData': ('vd', lambda path: ['vd', str(path)], 'G'),
        'csvlens': ('csvlens', lambda path: ['csvlens', '-d', ',', str(path)], 'G'),
        'less': ('less', lambda path: ['less', '--', str(path)], 'G'),
    }


def processes_under(root: int) -> list[int]:
    children: dict[int, list[int]] = {}
    for entry in os.listdir('/proc'):
        if entry.isdigit():
            try:
                fields = pathlib.Path(f'/proc/{entry}/stat').read_text().rsplit(')', 1)[1].split()
            except OSError:
                continue
            children.setdefault(int(fields[1]), []).append(int(entry))
    found, waiting = [], [root]
    while waiting:
        process = waiting.pop()
        found.append(process)
        waiting.extend(children.get(process, []))
    return found


def resident_kb(processes: list[int]) -> int:
    total = 0
    for process in processes:
        try:
            for line in pathlib.Path(f'/proc/{process}/status').read_text().splitlines():
                if line.startswith('VmRSS:'):
                    total += int(line.split()[1])
        except OSError:
            pass
    return total


def screen_text() -> str:
    return subprocess.run([*TMUX, 'capture-pane', '-p'], capture_output=True, text=True).stdout


def wait_for(
    text: str, pane: int, started: float, peak: list[int], end_key: str | None = None
) -> float | str:
    last_press = time.monotonic()
    while True:
        if end_key and time.monotonic() - last_press > 0.5:
            subprocess.run([*TMUX, 'send-keys', end_key])
            last_press = time.monotonic()
        peak[0] = max(peak[0], resident_kb(processes_under(pane)))
        if peak[0] > MEMORY_GUARD_KB:
            return 'memory'
        if time.monotonic() - started > TIMEOUT_SECONDS:
            return 'timeout'
        if text in screen_text():
            return time.monotonic() - started
        time.sleep(0.01)


def run_once(command: list[str], end_key: str) -> dict[str, float | str]:
    subprocess.run([*TMUX, 'kill-server'], capture_output=True)
    started = time.monotonic()
    shell_command = shlex.join(['env', 'TERM=xterm-256color', *command])
    subprocess.run([*TMUX, 'new-session', '-d', '-x', '120', '-y', '30', shell_command], check=True)
    pane = int(
        subprocess.run(
            [*TMUX, 'display', '-p', '#{pane_pid}'], capture_output=True, text=True
        ).stdout
    )
    peak = [0]
    result: dict[str, float | str] = {'first_screen': wait_for('customer 1,', pane, started, peak)}
    if result['first_screen'] == 'timeout':
        result['first_screen'] = wait_for('customer 1', pane, started, peak)
    if isinstance(result['first_screen'], float):
        settle = time.monotonic()
        while time.monotonic() - settle < 1.5:
            peak[0] = max(peak[0], resident_kb(processes_under(pane)))
            time.sleep(0.05)
        jump_started = time.monotonic()
        subprocess.run([*TMUX, 'send-keys', end_key])
        result['last_row'] = wait_for('the very last customer', pane, jump_started, peak, end_key)
    result['peak_memory_mb'] = round(peak[0] / 1024, 1)
    subprocess.run([*TMUX, 'kill-server'], capture_output=True)
    return result


def median_text(values: list[float | str]) -> str:
    numbers = [value for value in values if isinstance(value, float)]
    if not numbers:
        return str(values[0]) if values else '-'
    return f'{statistics.median(numbers):.2f}'


def main() -> None:
    work = pathlib.Path(sys.argv[1]).resolve()
    work.mkdir(parents=True, exist_ok=True)
    sizes = (sys.argv[2] if len(sys.argv) > 2 else '100mb,1gb,5gb').split(',')
    profile = pathlib.Path(tempfile.mkdtemp(prefix='notebashpp-benchmark-'))
    (profile / 'config').mkdir()
    (profile / 'config' / 'notebashpp-benchmark').symlink_to(REPOSITORY)
    known_tools = tools(profile)
    chosen = (sys.argv[3] if len(sys.argv) > 3 else ','.join(known_tools)).split(',')
    runs = int(os.environ.get('RUNS', '3'))
    results_path = work / 'results.json'
    results = json.loads(results_path.read_text()) if results_path.exists() else {}
    for size in sizes:
        path = work / f'data_{size}.csv'
        if not path.exists():
            make_csv(path, SIZES[size])
        for tool in chosen:
            program, command_for, end_key = known_tools[tool]
            if not shutil.which(program):
                print(f'{tool}: {program} not found, skipped')
                continue
            attempts = []
            for _ in range(runs):
                attempt = run_once(command_for(path), end_key)
                attempts.append(attempt)
                print(f'{tool} {size}: {attempt}', flush=True)
                if not isinstance(attempt['first_screen'], float):
                    break
            results[f'{tool} | {size}'] = attempts
            results_path.write_text(json.dumps(results, indent=1))
    print('\n| tool | size | first screen (s) | last row (s) | peak memory (MB) |')
    print('|---|---|---|---|---|')
    for key, attempts in results.items():
        tool, size = key.split(' | ')
        first = median_text([attempt['first_screen'] for attempt in attempts])
        last = median_text([attempt.get('last_row', '-') for attempt in attempts])
        memory = median_text([float(attempt['peak_memory_mb']) for attempt in attempts])
        print(f'| {tool} | {size} | {first} | {last} | {memory} |')
    shutil.rmtree(profile, ignore_errors=True)


if __name__ == '__main__':
    main()
