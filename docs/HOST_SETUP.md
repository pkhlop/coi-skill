# Host setup — one-time, per machine

The container is always Linux; the **host** can be native Linux, macOS (via a Lima/Colima Linux
VM), or Windows (via WSL2). Do this once per machine. Verify at the end with `./install.sh --check`.

## Requirements

- **Incus ≥ 6.1** (Ubuntu's own repo ships 6.0 — too old; use Zabbly's repo).
- The user in the **`incus-admin`** group (log out/in after adding).
- A running **SSH agent** (any flavour).
- **`jq`** on the host.

## 1. Install Incus (≥ 6.1)

### Ubuntu / Debian

Ubuntu noble's main/ESM repo ships 6.0. Install from [Zabbly stable](https://github.com/zabbly/incus):

```bash
# Add Zabbly's repo (see their README for the current key/source lines), then:
sudo apt update && sudo apt install -y incus
```

If `apt-cache policy incus` still shows 6.0 as Candidate (Ubuntu Pro/ESM pins it at priority 510),
add a pin — see `references/troubleshooting.md §1.1`.

### Fedora

```bash
sudo dnf install -y incus incus-agent
sudo systemctl enable --now incus
```

### Arch

```bash
sudo pacman -S incus
sudo systemctl enable --now incus
```

### openSUSE

```bash
sudo zypper install incus
sudo systemctl enable --now incus
```

### macOS (host = macOS, container = Linux in a VM)

Incus is Linux-native, so on macOS you run it inside a lightweight Linux VM:

1. Install [Lima](https://lima-vm.org/) or [Colima](https://github.com/abiosoft/colima).
2. Bring up a Linux VM and install Incus inside it (Ubuntu/Debian steps above).
3. COI auto-detects Lima/Colima and disables UID-shift (virtiofs doesn't support idmapped mounts) —
   `.coi.toml` `[incus] disable_shift` is handled for you.

Performance and idmap behaviour differ from native Linux; the workflow is otherwise identical.

### Windows (host = Windows, container = Linux in WSL2)

Run everything **inside WSL2** (Ubuntu). From the WSL2 shell, follow the Ubuntu/Debian steps.
There is no native-Windows Incus; WSL2 *is* the Linux host from COI's point of view.

## 2. Initialize Incus

```bash
sudo incus admin init --minimal      # creates default storage pool + bridge + root disk profile
sudo usermod -aG incus-admin "$USER" # then log out and back in
```

Skipping `admin init` makes every `coi build` fail with `No root device could be found`.

> **Storage tip:** the default `--minimal` pool can be a small loop file. For daily use, back it with
> a real directory or a `btrfs`/`zfs` pool — see `references/troubleshooting.md §1.6` and §6.2.

## 3. Install the `coi` binary

```bash
curl -fsSL https://raw.githubusercontent.com/mensfeld/code-on-incus/master/install.sh | bash
```

Review the installer before piping to `bash`. It installs to `/usr/local/bin` (may prompt for
sudo) and defaults to the latest release. There is **no `coi self-update`** — re-run this script to
upgrade the binary. (`coi build` rebuilds the container *image*, which is separate.)

Then build the base image (5–10 min, don't kill it early):

```bash
coi build
coi health          # every CRITICAL entry should be [OK]
```

## 4. `jq`

```bash
sudo apt install -y jq     # or dnf/pacman/zypper/brew install jq
```

## 5. SSH agent on a known socket path

COI proxies the host SSH agent into the container. The Makefile targets default to
`/tmp/ssh-agent-$USER.sock`. Make that path stable by adding to your `~/.bashrc` / `~/.zshrc`:

```bash
export SSH_AUTH_SOCK=/tmp/ssh-agent-$USER.sock
if [ ! -S "$SSH_AUTH_SOCK" ]; then
  ssh-agent -a "$SSH_AUTH_SOCK" >/dev/null
fi
```

Then `ssh-add` once per login (`ssh-add -t 8h` to auto-expire, `ssh-add -c` to confirm each use).
If your agent lives elsewhere, override `COI_SSH_SOCK` instead (see `docs/PORTABILITY.md`).

## 6. Verify

```bash
./install.sh --check
```

All green → `./install.sh` to install the skill, then `./install.sh --project <repo>` to onboard a
project. Anything red → the line points at the fix (this doc or `references/troubleshooting.md`).

## When something breaks

`references/troubleshooting.md` is the runbook: Incus version pin (§1.1), `No root device` (§1.2),
IPv6-only / DHCP failures with firewalld or Docker (§1.3), slow apt/npm from the IPv6
happy-eyeballs timeout (§6), SSH agent re-attach (§2), Docker socket perms (§3), X11/audio (§4),
the security monitor auto-pause (§8), and the Playwright crashpad workaround (§9).
