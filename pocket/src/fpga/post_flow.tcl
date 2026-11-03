# Runs after every full Quartus compile of the Pocket project
# (POST_FLOW_SCRIPT_FILE in ap_core.qsf). Writes output_files/timing_paths.txt
# with every failing path (setup, then hold), using the MiSTer project's
# script. Any problem here only prints a message; it never fails the compile.
if {[catch {
    set proj [lindex $quartus(args) 1]
    set rev  [lindex $quartus(args) 2]
    set sta  [file join $quartus(binpath) quartus_sta]
    set tcl  [file join [pwd] .. .. .. scripts quartus timing_paths_sta.tcl]
    exec $sta -t $tcl $proj $rev
} msg]} {
    puts "post_flow.tcl: timing path report not written: $msg"
}
