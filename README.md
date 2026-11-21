# jx

[![CI](https://github.com/Zittersplitter/jx/actions/workflows/ci.yml/badge.svg)](https://github.com/Zittersplitter/jx/actions/workflows/ci.yml)

A small Bash wrapper around `journalctl` that turns the most common log queries into short, memorable subcommands and prints them in a readable column layout.

```bash
jx err              # errors from the current boot
jx unit nginx       # logs of a unit, jumping to the end
jx crash            # how did the previous boot end?
jx err -1 -u nginx  # any journalctl option can be added
```

```
$ jx warn
── Fri 20 Nov 2026 ─────────────────────────────────────────
08:28:54  WARN   canonical-livepatchd Error in livepatch check state: check-failed.
08:29:10  ERR    sddm-helper          gkr-pam: unable to locate daemon control file
08:29:10  WARN   kernel               kauditd_printk_skb: 261 callbacks suppressed
08:29:10  WARN   sddm-helper          Failed to write utmpx:  No such file or directory
08:29:12  WARN   org_kde_powerdevil   [  2937] Watching for DPMS state changes unimplemented
11:43:25  ERR    canonical-livepatchd Error receiving netlink message: no buffer space available.
```

In a terminal, levels are colored (ERR red, WARN yellow) and the source is cyan.

## Requirements

- Linux with systemd (`journalctl`, `systemctl`)
- Bash 4.4+
- `jq` 1.6+ for the column layout and `top` (optional otherwise; without it jx falls back to the compact style)
- `less` as pager (optional)
- `sudo` if your user isn't in `systemd-journal`, `adm` or `wheel`

## Installation

```bash
git clone https://github.com/Zittersplitter/jx.git
cd jx
sudo install -m 755 jx /usr/local/bin/jx
jx help
```

To update, `git pull` and run the `install` line again. To uninstall, `sudo rm /usr/local/bin/jx`.

### Shell completion

Completes commands, unit names, and boot offsets.

```bash
# bash: add to ~/.bashrc
source <(jx completion bash)

# zsh: add to ~/.zshrc (after compinit)
source <(jx completion zsh)
# or install it as a function file on your $fpath
jx completion zsh > ~/.zfunc/_jx
```

## Usage

```
jx [--raw|--compact] [--no-pager] [--yes] <command> [arguments] [journalctl options]
```

**Boot selector `N`:** `0` = current boot (default), `-1` = previous, `-2` = the one before, `+1` = the first recorded boot, a boot ID from `jx boots`, or `all` for every boot. N goes right after the command (after the pattern, PID, binary or file for `grep`, `pid`, `exe`, `export`). A negative N is also recognized further back, so `jx err -q -1` works like `jx err -1 -q`.

**Extra options go to journalctl.** Anything after a command's own arguments is passed through, so every command can be narrowed further. Options that change the journal or write a file (`--vacuum-*`, `--rotate`, `--flush`, `--sync`, `--relinquish-var`, `--setup-keys`, `--update-catalog`, `--cursor-file`, also abbreviated) are refused there, since with `sudo` they would run as root without any question; use `jx vacuum`, `jx rotate` or journalctl itself.

```bash
jx err -1 -u nginx                 # errors of nginx in the previous boot
jx unit nginx -p warning           # only warnings and worse
jx follow -p err                   # follow errors only
jx grep timeout 0 --since "1h ago" # search the last hour
jx top -1 -p warning               # who warned most in the previous boot
```

### Viewing

| Command | Description | journalctl equivalent |
|---|---|---|
| `jx boot [N]` | Logs of boot N | `-b N` |
| `jx boots` | List all recorded boots | `--list-boots` |
| `jx err [N]` | Priority `err` and higher | `-b N -p err` |
| `jx warn [N]` | Priority `warning` and higher | `-b N -p warning` |
| `jx kernel [N]` | Kernel messages (dmesg replacement) | `-b N -k` |
| `jx tail [n]` | Last n lines (default 50) | `-n n --no-pager` |
| `jx follow [unit]` | Follow live, optionally one unit | `-f [-u unit]` |

### Filtering

| Command | Description | journalctl equivalent |
|---|---|---|
| `jx unit <name> [since]` | Logs of a unit, optionally from a time | `-u name -e` / `-u name --since …` |
| `jx since <from> [until]` | Time range | `--since … --until …` |
| `jx last <duration>` | Recent entries, e.g. `30min`, `2h`, `1d` | `--since -duration` |
| `jx grep <pattern> [N]` | Case-insensitive regex search, matches highlighted | `-b N --grep … --case-sensitive=false` |
| `jx pid <pid> [N]` | Logs of a process (current boot by default, as PIDs are reused) | `-b N _PID=pid` |
| `jx exe <name\|path> [N]` | Logs of a binary; names are looked up in `PATH` and `sbin` | `-b N /path/to/bin` |
| `jx user` | Your user units | `--user -e` |
| `jx ssh` | SSH logins (green), failures and probes (red) of the last 24 hours | `-u ssh -u sshd -u 'ssh@*' -u 'sshd@*' -u 'sshd-*@*' --since -24h --grep …` |

`--since`/`--until` take anything journalctl accepts: `"2026-11-20 08:00"`, `08:00`, `today`, `yesterday`, `"1h ago"`.

`jx ssh` reads only the SSH units (`ssh` on Debian and Ubuntu, `sshd` elsewhere, the per-connection units, and systemd's `sshd-vsock@` and the like). Their unit is recorded by journald itself, so other programs can't add lines to this view. A login is green only when the message starts with `Accepted`, so a user name like `Accepted publickey for root` can't pass for one. To look further back: `jx ssh --since "7 days ago"`.

When `--grep` is combined with `-n` (for example `jx grep oom -n 20`), journalctl itself lists the matches newest first. Without `-n` they are in normal order.

### Diagnosis

| Command | Description |
|---|---|
| `jx failed` | Failed system and user units, each with its last 20 lines |
| `jx crash [N]` | How boot N ended (default `-1`): time range, whether it shut down cleanly, its last errors, its last lines, and coredumps from that boot |
| `jx top [N]` | Which sources log the most in boot N, with error and warning counts. Useful before `vacuum`. |

`crash` reports a clean shutdown when the boot reached `poweroff.target`, `reboot.target`, `halt.target`, `kexec.target` or `soft-reboot.target`. If none of them was reached, it says *no clean shutdown recorded: crash, freeze, power loss or hard reset*. Only records of PID 1 running as root count (`_PID=1 _UID=0`, fields journald sets itself), so a program can't fake a clean shutdown by logging such a message. If journalctl or coredumpctl fail, their error is shown instead of a verdict.

```
$ jx crash
Boot -1  a282560b036142b38d6f4a976172b82d
  from   Sun 2026-11-15 21:00:47 CET
  to     Sun 2026-11-15 21:07:09 CET
  ended  clean shutdown (poweroff.target)

── Last errors of that boot ──
── Sun 15 Nov 2026 ─────────────────────────────────────────
21:01:01  ERR    org_kde_powerdevil   [  2974] Error EACCES(-13): Permission denied opening /dev/i2c-4
…
21:07:08  ERR    canonical-livepatchd daemon shutting down

── Last lines of that boot ──
── Sun 15 Nov 2026 ─────────────────────────────────────────
…
21:07:09  INFO   systemd-journald     Received SIGTERM from PID 1 (systemd-shutdow).
21:07:09  INFO   systemd-journald     Journal stopped

── Coredumps during that boot ──
None.
```

```
$ jx top
  COUNT  SHARE    ERR   WARN  SOURCE
   1694  20.4%      1    122  kernel
   1575  18.9%      1     17  systemd
   1261  15.2%      0      0  sbkeysync
    525   6.3%      0     15  NetworkManager
    496   6.0%      0      0  plasmashell
…
   8315 entries from 108 sources
```

`top` shows 20 rows by default; set `JX_TOP` to a positive number to change that. Extra options narrow what is counted, e.g. `jx top 0 --since "1h ago"`.

### Maintenance

| Command | Description | journalctl equivalent |
|---|---|---|
| `jx disk` | Disk space used by the journal | `--disk-usage` |
| `jx vacuum <size\|age>` | Delete old archived journal files | `--vacuum-size=…` / `--vacuum-time=…` |
| `jx verify` | Check journal file consistency | `--verify` |
| `jx rotate` | Rotate journal files now | `--rotate` |

`vacuum` shows the current usage and the exact command, and asks for confirmation before deleting anything. The value decides the mode:

- **Size** (upper-case unit): `500M`, `2G`, `1.5G`, `500MB`
- **Age** (spelled-out unit): `30min`, `12h`, `7d`, `2weeks`, `6months`, `1y`

Ambiguous values such as `500m` (megabytes or minutes?) or a bare `500` are rejected. Only archived files are removed; add `--rotate` to archive the active files first: `jx vacuum 500M --rotate`.

### Export

| Command | Description |
|---|---|
| `jx json <unit> [n]` | Last n entries of a unit as pretty JSON (default 20) |
| `jx export <file> [N]` | Write boot N to a text file with ISO timestamps and hostname; asks before overwriting, and leaves an existing file untouched if the export fails. The file is readable only by you (mode 600), as the journal can hold secrets such as passwords typed as user names; `chmod` it to share it |

### Other

| Command | Description |
|---|---|
| `jx completion bash\|zsh` | Print a shell completion script |
| `jx help` | Show help |
| `jx version` | Show version |

## Output styles

| Style | How to select | Looks like |
|---|---|---|
| `columns` (default) | — | `10:24:56  ERR    sshd   message`, with a separator line per day and per boot |
| `compact` | `--compact` or `JX_STYLE=compact` | journalctl's own output without the hostname |
| `raw` | `--raw` or `JX_STYLE=raw` | Unchanged journalctl output |

In the column view a separator line appears whenever the day changes; when a new boot begins, it also shows the boot ID:

```
21:07:09  INFO   systemd-journald     Received SIGTERM from PID 1 (systemd-shutdow).
21:07:09  INFO   systemd-journald     Journal stopped

── Fri 20 Nov 2026 · boot 9eb497f6 ─────────────────────────
08:28:15  NOTE   kernel               Linux version 7.0.0-43-generic …
```

- The column view leaves out the hostname and PID; use `--raw` when you need them. Day names follow your locale (`LC_TIME`).
- Log entries are untrusted: any program can write them. Terminal escape sequences (colors, window titles, cursor movement) are removed, other control characters are shown as `^X`, and invisible or text-direction characters (`U+200B`, `U+202E`, …) as `<U+200B>`, so a log entry can neither control your terminal nor hide or reorder text. A newline in a source name is shown as `^J`. This also applies to `top`.
- The source is the name a program gives itself (`SYSLOG_IDENTIFIER`), and any program can choose any name. Only `kernel` can be checked: a program posing as the kernel is shown as `kernel(its process name)`. To select by what journald records itself, use `jx unit`, `jx exe` or `jx pid`; `--raw -o verbose` shows all fields.
- Messages are shown in full up to 64 KiB, longer ones are cut. jq may use at most 1 GiB of memory (it normally needs a few MB), so a gigantic entry stops the view with a message instead of filling the memory; `--raw` shows such an entry as blob data.
- The column layout needs `jq`; without it jx uses `compact`.
- If you pass your own output format (`-o json`, `-o verbose`, …) or `-x`, jx switches to raw output for that call.
- Colors are used only when writing to a terminal and are disabled by [`NO_COLOR`](https://no-color.org).
- Long output is shown in a pager. In the column view and for `failed` and `crash`, jx uses `less` (or `JX_PAGER`), which exits right away if everything fits on one screen. In the `compact` and `raw` styles journalctl's own pager is used (`SYSTEMD_PAGER` / `PAGER`). `jx unit` and `jx user` start at the end.

## Examples

```bash
# What went wrong during the last boot, and did it crash?
jx err -1
jx crash

# nginx logs from the last hour
jx unit nginx "1h ago"

# Follow a service while restarting it
jx follow docker

# Search all boots for OOM kills and segfaults
jx grep "oom|segfault" all

# Everything between 08:00 and 10:00 today
jx since "08:00" "10:00"

# Find what fills the journal, then shrink it to 200 MB
jx top
jx disk
jx vacuum 200M

# Attach a boot log to a ticket
jx export boot.log -1

# Pipe plain output into other tools
jx --raw --no-pager err | grep -i usb
```

## Configuration

| Flag | Environment | Effect |
|---|---|---|
| `--raw` / `--compact` | `JX_STYLE=columns\|compact\|raw` | Output style |
| `--no-pager` | `JX_NOPAGER=1` | Disable the pager |
| `-y`, `--yes` | | Don't ask for confirmation (`vacuum`, `export`) |
| `--` | | Take everything after it as it is, e.g. `jx grep -- --yes` |
| | `JX_PAGER` | Pager jx uses itself (column view, `failed`, `crash`); default `less -FRXMK`. Ignored when jx runs as root for another user |
| | `JX_TOP` | Rows shown by `jx top`, a positive number (default 20) |
| | `NO_COLOR` | Disable colors |

Flags can go anywhere on the command line before a `--`. When jx is not run from a terminal (scripts, cron), `vacuum` and overwriting with `export` can't ask and stop unless `--yes` is given.

## Permissions

`jx` uses `sudo` for reading only when needed: when you are not root and the system journal isn't readable for you. jx checks the journal files themselves, because which groups may read them differs between distributions: `systemd-journal` everywhere, `adm` on Debian and Ubuntu, `wheel` on Fedora and Arch. If you can't read the journal and `sudo` isn't installed, jx warns that you see only your own messages. To read logs without `sudo`, add yourself to the `systemd-journal` group and log in again:

```bash
sudo usermod -aG systemd-journal "$USER"
```

`vacuum` and `rotate` change the journal and always run with `sudo`.

**Don't allow jx in sudoers** (e.g. for "read-only" log access): it's an interactive tool with a pager and passes options through to journalctl. Give such users the `systemd-journal` group instead. When jx does run as root for another user (`sudo`, `doas`, `pkexec`, `su`), its pager runs in secure mode (no shell commands, pipes or saving to files) and `JX_PAGER` is ignored, as systemd does for its own pager.

## Persistent journal

Commands that look at earlier boots (`jx err -1`, `jx crash`, `jx boots`) need a persistent journal. If `jx boots` lists only one boot, the journal is probably kept in memory only (`/run/log/journal`) and is lost on reboot. To make it persistent:

```bash
sudo mkdir -p /var/log/journal
sudo systemd-tmpfiles --create --prefix /var/log/journal
sudo systemctl restart systemd-journald
```

This works with the default `Storage=auto`. Alternatively set `Storage=persistent` in `/etc/systemd/journald.conf`.

## Changes

### 0.3

- **Pass-through options:** options that change the journal or write a file (`--vacuum-*`, `--rotate`, `--flush`, …) are refused by the reading commands; use `jx vacuum`, `jx rotate` or journalctl itself. `--` ends jx's own flags.
- **`ssh`** covers the last 24 hours instead of today, includes the per-connection units, and shows logins in green, failures and probes in red.
- **`crash`** counts only shutdown records of PID 1 running as root, so a clean shutdown can't be faked, and shows journalctl or coredumpctl errors instead of a verdict.
- **Untrusted log entries:** invisible and text-direction characters are shown as `<U+XXXX>`, a program posing as the kernel as `kernel(its process name)`, and messages over 64 KiB are cut; jq may use at most 1 GiB of memory. This also applies to `top`.
- **`export`** writes the file readable only by you (mode 600).
- **`vacuum`** shows the exact command before asking.
- **Permissions:** jx checks whether the journal files are readable instead of guessing from group names, and warns when it can show only your own messages. When run as root for another user, the pager runs in secure mode and `JX_PAGER` is ignored.
- **Tests:** `tests/run.sh` runs jx against a fake journalctl, sudo and coredumpctl.

### 0.2: upgrading from the first version

The first version of jx reported itself as `jx 1.0`; 0.2 was the first release with the new numbering.

- **Output:** the column view is the new default. Use `--raw` or `JX_STYLE=raw` for the old output.
- **Language:** help and messages are in English.
- **Extra arguments** are passed to journalctl instead of being silently ignored.
- **`vacuum`** rejects ambiguous values like `500m`, asks before deleting, and always uses `sudo`.
- **`pid` and `exe`** search the current boot by default; add `all` for every boot.
- **`ssh`** no longer guesses between `ssh` and `sshd`; it queries both.
- **`export`** asks before overwriting an existing file.
- **New:** `crash`, `top`, `completion`, `--yes`, and the boot selector `all`. `failed` now includes user units.

## Development

CI runs `shellcheck`, checks that both completion scripts parse, and runs a smoke test of the main commands (`.github/workflows/ci.yml`). Locally:

```bash
shellcheck jx tests/run.sh
./jx completion bash | bash -n
./jx completion zsh | zsh -n
tests/run.sh
```

`tests/run.sh` runs jx against a fake `journalctl`, `sudo` and `coredumpctl`, so it needs neither a journal nor root (only `jq` and `script`). The test for running as root for another user runs only where `sudo` works without a password, as in CI.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).
