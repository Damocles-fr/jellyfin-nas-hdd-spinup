#!/bin/sh
# test_spinup_manual.sh - manually wake the data disks the same way the watcher does.
# It only issues SCSI START UNIT (sg_start --start). It does NOT read from md or files.
PATH=/bin:/sbin:/usr/bin:/usr/sbin

# Set FORCE_MD to e.g. "md3" or "md3 md2" to target specific array(s).
# Leave empty to auto-detect the largest data array.
FORCE_MD=""

MDSTAT="${MDSTAT:-/proc/mdstat}"

# Auto-pick the largest data md array (excludes known QNAP system arrays).
pick_data_md() {
  awk '
    /^md[0-9]+ :/ {m=$1; next}
    /blocks/ && m!=""{print m,$1; m=""}
  ' "$MDSTAT" 2>/dev/null \
  | grep -Ev '^(md9|md13|md321) ' \
  | sort -k2,2n | tail -1 | awk '{print $1}'
}

# Return the base block devices of a given md array (e.g. md3 -> /dev/sda /dev/sdb ...).
md_bases() {
  M="$1"
  [ -z "$M" ] && return 0
  line="$(awk -v M="$M" '$1==M{print;exit}' "$MDSTAT" 2>/dev/null)"
  [ -z "$line" ] && return 0
  BASES=""
  for part in $(echo "$line" | grep -Eo '([shv]d[a-z]+[0-9]+)'); do
    b="/dev/$(echo "$part" | sed 's/[0-9]\+$//')"
    echo "$BASES" | grep -qw "$b" || BASES="$BASES $b"
  done
  echo "$BASES"
}

if [ -n "$FORCE_MD" ]; then
  MD_LIST="$FORCE_MD"
else
  MD_LIST="$(pick_data_md)"
fi
[ -n "$MD_LIST" ] || { echo "No data md array found in $MDSTAT"; exit 1; }

if ! command -v sg_start >/dev/null 2>&1; then
  echo "sg_start not found (install sg3_utils)"; exit 1
fi

for MD in $MD_LIST; do
  echo "Array $MD:"
  for d in $(md_bases "$MD"); do
    [ -b "$d" ] || { echo "  skip $d (not a block device)"; continue; }
    echo "  sg_start --start $d"
    sg_start --start "$d"
  done
done
echo "Done."
