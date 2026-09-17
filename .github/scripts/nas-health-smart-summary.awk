# Cuts the `smart` probe verb (~16 KB for four disks) down to what check 5 of
# .github/nas-health-check.md judges, so the raw dump never enters the agent's context:
#   ssh ... 'smart' | awk -f .github/scripts/nas-health-smart-summary.awk
# Only lines known to be irrelevant are dropped; anything unrecognised passes through, so
# an unreadable device or a changed smartctl format still shows.

/^=== \/dev\// {
  in_log = ($0 ~ /selftest log/)
  entries = 0
  completed = 0
  print
  next
}
/^[ \t]*$/ || /^smartctl [0-9]/ || /^Copyright / || /^=== START OF / { next }

# ATA attribute table: the three counters the check warns on, plus the power-on clock the
# self-test age is measured against.
/^(ID# ATTRIBUTE_NAME|SMART Attributes Data Structure|Vendor Specific SMART Attributes)/ { next }
!in_log && /^ *[0-9]+ [A-Za-z_]/ {
  if ($2 ~ /^(Reallocated_Sector_Ct|Current_Pending_Sector|Offline_Uncorrectable|Power_On_Hours)$/) print
  next
}

# NVMe health log: what survives is Critical Warning, Available Spare, Percentage Used,
# Power On Hours and Media and Data Integrity Errors.
/^SMART\/Health Information/ { next }
/^(Temperature|Available Spare Threshold|Data Units (Read|Written)|Host (Read|Write) Commands|Controller Busy Time|Power Cycles|Unsafe Shutdowns|Error Information Log Entries|Warning +Comp\. Temperature Time|Critical Comp\. Temperature Time|Temperature Sensor [0-9]+|Thermal Temp\. [0-9]+ (Transition Count|Total Time)):/ { next }

# Self-test log: the column header, then the newest entries up to and including the newest
# completed one (at most five, in case a run of aborted tests precedes it).
/^(SMART Self-test log structure|Self-test Log \(NVMe|Self-test status: No self-test in progress)/ { next }
in_log && /^(# *[0-9]+|[ ]*[0-9]+) +[A-Za-z]/ {
  if (!completed && entries < 5) {
    print
    entries++
  }
  if ($0 ~ /Completed/) completed = 1
  next
}

{ print }
