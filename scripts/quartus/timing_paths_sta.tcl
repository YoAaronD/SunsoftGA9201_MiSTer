# Called by post_flow.tcl through quartus_sta. Can also be run by hand:
#   quartus_sta -t scripts/quartus/timing_paths_sta.tcl SunsoftGA9201 SunsoftGA9201
# Reports every failing path in every operating condition (slow 85C, slow 0C,
# fast ...): the compile summary's worst slack can come from any of them.
set proj [lindex $quartus(args) 0]
set rev  [lindex $quartus(args) 1]
project_open $proj -revision $rev
create_timing_netlist
read_sdc
set out output_files/timing_paths.txt
file delete -force $out
foreach_in_collection op [get_available_operating_conditions] {
    set_operating_conditions $op
    update_timing_netlist
    set name [get_operating_conditions_info $op -display_name]
    set f [open $out a]
    puts $f "=================== $name ==================="
    close $f
    report_timing -setup -npaths 2000 -nworst 1 -less_than_slack 0 -detail summary -file $out -append
    report_timing -hold  -npaths 2000 -nworst 1 -less_than_slack 0 -detail summary -file $out -append
}
delete_timing_netlist
project_close
