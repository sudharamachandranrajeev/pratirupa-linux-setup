#!/usr/bin/env bash
# Run Pratirupa on clean Arch, Debian, Ubuntu, Fedora and openSUSE containers.
#
#   tests/containers.sh                 every distro
#   tests/containers.sh debian fedora   just those
#
# Needs Docker (or Podman: DOCKER=podman). For each distro it:
#   1. creates a normal user with passwordless sudo (Pratirupa refuses root),
#   2. runs `setup.sh list` and a dry run of every module, and
#   3. really installs services-security and apps-extra's package resolution,
# then reports which packages the map could not resolve, so wrong names show up.
# Nothing on the host is changed; containers are removed afterwards.

set -uo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
docker=${DOCKER:-docker}
logs=${TMPDIR:-/tmp}/pratirupa-containers
mkdir -p "$logs"

declare -A IMAGE=(
  [arch]=docker.io/library/archlinux:latest
  [debian]=docker.io/library/debian:trixie
  [ubuntu]=docker.io/library/ubuntu:24.04
  [fedora]=docker.io/library/fedora:latest
  [opensuse]=docker.io/opensuse/tumbleweed:latest
)
declare -A PREP=(
  [arch]='pacman -Syu --noconfirm --needed sudo git jq curl which pciutils >/dev/null'
  [debian]='apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq sudo git jq curl pciutils >/dev/null'
  [ubuntu]='apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq sudo git jq curl pciutils >/dev/null'
  [fedora]='dnf -y -q install sudo git jq curl pciutils >/dev/null && dnf -q makecache >/dev/null'
  # Tumbleweed keeps sudoers in /usr/etc and asks for the root password
  # (targetpw), which overrides sudoers.d; the test user's rule goes last.
  [opensuse]='zypper -n -q refresh && zypper -n -q in sudo git jq curl pciutils >/dev/null && { [ -f /etc/sudoers ] || cp /usr/etc/sudoers /etc/sudoers 2>/dev/null; true; } && echo "tester ALL=(ALL) NOPASSWD: ALL" >>/etc/sudoers'
)

distros=("$@")
((${#distros[@]})) || distros=(arch debian ubuntu fedora opensuse)

script='
set -uo pipefail
eval "$PREP"
useradd -m tester 2>/dev/null
echo "tester ALL=(ALL) NOPASSWD: ALL" >/etc/sudoers.d/tester
cp -r /src ~tester/pratirupa && chown -R tester: ~tester/pratirupa
cd ~tester/pratirupa
sudo -u tester -H sudo -n true 2>/dev/null || {
  echo "=== sudo for the test user does not work; diagnostics:"
  ls -l /etc/sudoers /usr/etc/sudoers /etc/sudoers.d 2>&1
  sudo -l -U tester 2>&1
  grep -hvE "^[[:space:]]*(#|$)" /etc/sudoers /usr/etc/sudoers 2>/dev/null
}
sudo -u tester -H bash -c "
  ./setup.sh list &&
  echo ===DRYRUN=== &&
  ./setup.sh --dry-run --yes install &&
  echo ===REAL=== &&
  ./setup.sh --yes install services-security &&
  ./setup.sh status
"
'

overall=0
for d in "${distros[@]}"; do
  [[ -n ${IMAGE[$d]:-} ]] || { echo "Unknown distro $d"; overall=1; continue; }
  echo "=== $d (${IMAGE[$d]})"
  if "$docker" run --rm -e PREP="${PREP[$d]}" -v "$repo:/src:ro" "${IMAGE[$d]}" bash -c "$script" >"$logs/$d.log" 2>&1; then
    echo "    passed"
  else
    echo "    FAILED (log: $logs/$d.log)"
    overall=1
  fi
  echo "    unresolved packages:"
  grep -oE "package '[^']+' is not available" "$logs/$d.log" | sort -u | sed "s/^/      /" || true
  grep -E 'Failed:|Error:' "$logs/$d.log" | sed 's/^/    /' || true
done
exit $overall
