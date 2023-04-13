#=================================================
#
# File: checkout_preop_litho2.pl
#
# Synopsis: Check if element may be checked out.
#
# All information:
#  See pod data at the end of the file.
#
#=================================================

# Standard libraries.
use File::Basename;
use strict;
use integer;

# CPAN modules
#use lib '/sdev/user/lib/site_perl';
#use ClearCase::CtCmd; # Clearcase interface

# Find out library path
my $libpath;
BEGIN { $libpath = dirname($0); }
# Import the functions that are required for myself only from the general module
use lib $libpath;
use Trgmod::General 0.01 qw(vprint eprint getEnv);

# CC-Git libraries
my $CC_GIT_LIB_PATH;
BEGIN
{
    $CC_GIT_LIB_PATH = $ENV{'CC2GIT_TEST_PATH'} ? $ENV{'CC2GIT_TEST_PATH'}.'/src' : '/sdev/user/lib/site_asml';
} # BEGIN
use lib $CC_GIT_LIB_PATH;
use ccGit;

#=================================================
# Constant variables
#=================================================
my $CQPERL='';
if(-e '/opt/hcl/compass/bin/cqperl'){
   $CQPERL="/opt/hcl/compass/bin/cqperl";
}elsif(-e '/opt/rational/clearquest/bin/cqperl'){
   $CQPERL="/opt/rational/clearquest/bin/cqperl";
}
use constant GRANT_CHECK_WI => scalar $CQPERL.' /sdev/user/sbin/triggers/cqchk_grant.pl';
use constant GRANT_CHECK_STREAM => scalar $CQPERL.' /sdev/user/sbin/triggers/cqchk_grant_stream.pl';
use constant BBCC_CHECK_WI => scalar $CQPERL.' /sdev/user/sbin/triggers/cqchk_bbcc.pl';
use constant BBCC_CHECK_STREAM => scalar $CQPERL.' /sdev/user/sbin/triggers/cqchk_bbcc_stream.pl';

#====================================================
# Global variables (used in 2 or more of the checks).
#====================================================

# Obtain basic info (element, (p-)operation, cmd-line, view-tag, activity). Note that
# not all of them are filled at both checkout and mkbranch time (!).
# my $op_kind = $ENV{'CLEARCASE_OP_KIND'};
# my $pop_kind = $ENV{'CLEARCASE_POP_KIND'};
my $cmd_line = $ENV{'CLEARCASE_CMDLINE'};
my $pathname = $ENV{'CLEARCASE_PN'};
my $view_tag = $ENV{'CLEARCASE_VIEW_TAG'};
my $webserver = 'http://techwiki.asml.com/index.php';
my $ifshare = 'https://interface-viewer.asml.com/html';

# And (safety first) put the return values on NOK.
my $fndmrg_rv = 1;
my $icc_rv = 1;
my $bbcc_rv = 1;
my $bsc_rv = 1;
my $cclck_rv = 1;

my $in_agr_rv = 0;

#=========================
# Platform specific stuff
#=========================
# Not required here

#=================================================
# SUBROUTINES
#=================================================

# Does the BBCC check (is a 11nc identifier present in the approved_list).
#
# Input: $the_bb_11nc, $the_11nc_list, both strings
# Output: None
# Return: 0 (it's there), otherwise 1
#
sub bbcc_check
{
  my $the_bb_11nc = $_[0];
  my $the_11nc_list =  $_[1];

  # First check the wildcard and BBCC disabled.
  if ( ($the_11nc_list eq 'ALL') || ($the_11nc_list eq 'NOBBCC') )
  {
    return 0;
  }
  else
  {
    # Check list for 11nc presence.
    my @approved_11ncs = split(' ', $the_11nc_list);
    my @found_11ncs = grep { $the_bb_11nc eq $_ } @approved_11ncs;

    # Return result.
    if ( $#found_11ncs >= 0 )
    {
      return 0;
    }
    else
    {
      return 1;
    }
  }
}

#=======================================================================
# MAIN  ...  starts with processing to set the remainder of the globals
# that are used in two or more of the checks.
#=======================================================================

# Some more debug stuff...
vprint("EXEC=$0\n");
#vprint("OPERATION=$op_kind\n");
#vprint("POPERATION=$pop_kind\n");
vprint("CMDLINE=$cmd_line\n");
vprint("PN=$pathname\n");

# ------------------------------------------------------------------------
#
# Clone check. We want to let our clone engine continue unconditionally.
# Most important reason is the ASML refactor move: if no BB approval
# was given yet on the new location a clone will fail. This must be
# absolutely avoided. We exit OK if cloning is active.
#
# ------------------------------------------------------------------------

if ( getEnv('SCM_CCCLONE') eq 'TRUE' )
{
  vprint("Clone engine active, checkout allowed.");
  exit(0);
}

# Set a view identifier for lsact/stream alike cleartool operations.
my $view_opt;
if ( $view_tag )
{
  vprint("VIEW=$view_tag\n");
  $view_opt = "-view $view_tag";
}
else
{
  vprint("EV 'CLEARCASE_VIEW_TAG' is not set, using current view\n");
  $view_opt = "-cview";
}

# Get fully qualified project name, together with the ASML CC lock attribute.
# Note that the attribute does not have to be present !
(my $project_desc = `cleartool lsproject -obs -fmt "%Xn;%[CCS_lock]SNa" $view_opt`)=~s/\n.*//g;
my @project_record = split(";",$project_desc);
my $x_project = $project_record[0];
my $locked_asml_ccs = '';            # locked ASML component list (for WIP blocker functionality).
if ( $#project_record == 1 )
{
  $locked_asml_ccs = $project_record[1];
}
vprint("PROJECT=$x_project\n");
vprint("LOCKED_CCS=$locked_asml_ccs\n");

# Get current fully qualified activity  (we default use the env. var, not lsact -cact
# because this fails when delivering or rebasing (we want UCM utility activity)).
# If the env-var is empty then the trigger is fired by mkbranch, and we use lsact
# (this works). Another important reason for first using the env-var is performance.
my $x_activity;
my $clearcase_activity = getEnv('CLEARCASE_ACTIVITY');
if ( $clearcase_activity ne '' )
{
  $x_activity = "activity:$clearcase_activity";
}
else
{
  ($x_activity = `cleartool lsact -cact -fmt "%Xn" $view_opt`)=~s/\n.*//g;     # EXPENSIVE CALL!
}
(my $bare_activity = $x_activity)=~s/activity:(.*?)@.*$/$1/;
vprint("ACTIVITY=$x_activity\n");

# Get activity comment (if any), used to detect rebases.
my $activity_comment = '';
if ( $x_activity ne '' )
{
  $activity_comment = `cleartool describe -fmt "%c" "$x_activity"`;
  chomp($activity_comment);
}
vprint("ACTIVITY_COMMENT=$activity_comment\n");

# Determine if we're in a rebase.
my $rebase_active = 'FALSE';
if ($activity_comment =~ /^Integration activity created by rebase on /)
{
  $rebase_active = 'TRUE';
}
vprint("REBASE_ACTIVE=$rebase_active\n");

# Set flag to denote that the element already was checked-out
# before on this branch (stream). Note the reg-exp, if we look
# and version 0 on the branch then it's NOT checked-out before.
# Also store stream in a global.
my $tmp = `cleartool lsstream -fmt "%n;%[BSC_list]SNa" $view_opt`;
my ($stream, $buildscope) = split(';', $tmp);

my $checkedout_before = 'FALSE';
my $xpathname = $ENV{CLEARCASE_XPN};
if ( $xpathname =~ /\/$stream\/[^0]+/ )
{
  $checkedout_before = 'TRUE';
}
vprint("CHECKED_OUT_BEFORE=$checkedout_before\n");

# ClearQuest database.
my $cqdatabase = `cleartool describe -fmt "%[crm_database]p" $x_project`;
vprint("cqdatabase=$cqdatabase\n");


# Component to check (BBCC, buildscope check) + path to vob
# (/view/view_tag/vobs/vb1), or without view tag (/vobs/vb1).
# CLEARCASE_VOB_PN is not suitable for this because if we
# checkout using the view extended path it returns for example
# /vobs/vb1, which is unusable in that case.
my $path_to_vob_root_of_cc = '';
my $asml11nc = '';
my $asmlcc = '';

# ASML component oid and locked ASML component list (for WIP blocker functionality).
my $asmlcc_eloid = '';

# Determine if we're in an ASML component and if so, determine
# the vob-root path that leads to this location. NOTE: vob-
# root only determined if we're in an ASML CC (and only
# used later on if we're in an ASML CC).

# Backstop test: skip /xscm/ directory is not a component dir.
if ( ( $pathname !~ /.*\/vobs\/\w+\/xscm\/*/ ) &&
     ( $pathname !~ /.*\/vobs\/\w+\/xrelease\/*/ ) &&
     ( $pathname !~ /.*\/vobs\/\w+\/xplatform\/*/ )
   ){
  if ( $pathname =~ /(.*\/vobs\/\w+)\/(\w+)\/([A-Z]{2}[^\/]*)/ )
  {
    # Get path to vob root.
    $path_to_vob_root_of_cc = $1;

    # Get the matched pattern: <ucm-comp>/<asml_comp>
    $asml11nc = $2;
    $asmlcc = $2.'/'.$3;

    # And get the oid of the directory element. Note that we can
    # not append the path to vob root to the oid because it might
    # contain the view extended path. Instead we use the env-var.
    $asmlcc_eloid = `cleartool describe -fmt "%On" "$path_to_vob_root_of_cc/$asmlcc@@"`;
    $asmlcc_eloid = "$asmlcc_eloid\@$ENV{CLEARCASE_VOB_PN}";
  }
}
vprint("PATH_TO_VOB_ROOT_OF_CC=$path_to_vob_root_of_cc\n");
vprint("ASML 11NC=$asml11nc\n");
vprint("ASML COMPONENT=$asmlcc\n");
vprint("ASML COMPONENT ELEMENT OID=$asmlcc_eloid\n");

# ------------------------------------------------------------------------
#
# Findmerge check.
#
# Only allow when called from dedicated scripts.
#
# ------------------------------------------------------------------------

# Safeguard for empty command line.
if ( $cmd_line ne '' )
{
  my @cmd_line_params = split(' ',$cmd_line);
  if ($cmd_line_params[0] eq 'findmerge' || $cmd_line_params[0] eq "merge")
  {
    if ( getEnv('SCM_CCSYNC_PATCH') ne 'TRUE' )
    {
      eprint("\nERROR: (find)merge command is not allowed, it potentially breaks the\n");
      eprint("       consistency of version trees. Use ccsync_patch instead.\n\n");
      $fndmrg_rv = 1;
    }
    else
    {
      $fndmrg_rv = 0;
    }
  }
  else
  {
    $fndmrg_rv = 0;
  }
}
else
{
  $fndmrg_rv = 0;
}

# ------------------------------------------------------------------------
#
# BBCC Check.
#
# Behaviour with respect to rebase: we do NOT check during a rebase (we
# even don't check existence of the location file), and allow all
# check-outs if checked-out before.
#
# ------------------------------------------------------------------------

# Skip BBCC stuff if no CQ database is set or if we found a findmerge hit.
if ( ($fndmrg_rv == 0) && ( $cqdatabase ne '' ) && ( $cqdatabase ne ": CRM Suspended" ) )
{

# Create a block to bailout in a fast way.
CHECKITEMS: {

    # Only enter the BBCC stuff if we're not in a deliver (otherwise a lot of deliver
    # checkouts would be preceded by a CQ query, which is pretty expensive !
#    if ($activity_comment =~ /^Created automatically as a result of / ) {
    if ($activity_comment =~ /^Integration activity created by deliver on / ) {
        # We're in a deliver, set flag on OK.
        $bbcc_rv = 0;
        vprint("Deliver active, skipping BBCC check\n");
        last CHECKITEMS;
    }

    # Analysis only if we're in an ASML component.
    if ( $asmlcc eq '' ) {
        # Not in an ASML component, return OK.
        $bbcc_rv = 0;
        vprint("Checkout outside ASML component, skipping BBCC check\n");
        last CHECKITEMS;
    }

    # Skip further analysis if we're in its xinc, xddf etc. (x*) subdirs,
    # because we don't want to force approvals of changed required I/F stuff.
    if ( $pathname =~ /\/vobs\/\w+\/\w+\/[A-Z]{2}\w*\/x\w*/ ) {
        # Checkout of x* directory, BBCC not required here, return OK.
        $bbcc_rv = 0;
        vprint ("Checkout of x* directory, skipping BBCC check\n");
        last CHECKITEMS;
    }

    # Analysis proceed only if we're NOT in a rebase or if we're in a rebase with
    # a yet un-modified element (i.e. an explicit command-line check-out).
    if ( ! ( ($rebase_active ne 'TRUE') || ( $rebase_active eq 'TRUE' && $checkedout_before eq 'FALSE' ) ) ) {
        # Rebase active but checked-out before, we allow the checkout (change was OK in the past
        # and we assume it's still valid).
        eprint("\nBBCC: File was changed in this stream, assuming this is still allowed.\n\n");
        # And return OK.
        $bbcc_rv = 0;
        last CHECKITEMS;
    }

    my $bb_id = '';
    my $bb_11nc = '';

    # Check if we're in a 11nc style directory or have a location.bbl file.
    if ( $asml11nc =~ m/^[\d]{11,12}$/ ) {
        # We got an 11nc, use that one.
        vprint ("Got 11nc path\n");
        $bb_11nc = $asml11nc;
    } else {

        # Only proceed BBCC thread of control if the component has a location file.
        # If not we assume BBCC is not required. Note that we use the vob_root var
        # here, it's only set when we're in an ASML CC.
        my $location_file = "$path_to_vob_root_of_cc/$asmlcc/.scm/location.bbl";
        if ( ! -f $location_file ) {
            vprint ("Location file=$location_file\n");
            # Location file does not exist, assuming BBCC not required here, return OK.
            $bbcc_rv = 0;
            vprint ("No location file found, skipping BBCC check\n");
            last CHECKITEMS;
        } else {
            vprint ("Found location bbl\n");
            # Process location file.
            if (open(LOCFILE,"< $location_file")) {

                my @lines = <LOCFILE>;
                foreach my $line (@lines) {
                    if ( $line =~ m/^BBID:[\s]*(.*)/ ) {
                        # Put result in bb-id var.
                        $bb_id = $1;
                        vprint("Location file BBID field=$bb_id\n");
                        next;
                    }
                    if ( $line =~ m/^BB11nc:[\s]*(.*)/ ) {
                        # Put result in 11nc var.
                        $bb_11nc = $1;
                        vprint("Location file BB11nc field=$bb_11nc\n");
                        next;
                    }
              }

              # Close locfile.
              close(LOCFILE);

            } else {
                # File could not be opened, report critical error and return NOK.
                eprint("\nBBCC ERROR: location file could not be opened ($location_file)\n\n");
                $bbcc_rv = 1;
            }

            # Check if 11nc/bb-id combo was found, if not or not complete: generate
            # error message and return NOK.
            if ( ($bb_11nc eq '') || ($bb_id eq '') ) {
                eprint("\nBBCC ERROR: missing 11nc and/or bb-id in location file ($location_file)\n\n");
                $bbcc_rv = 1;
            }
        }
    }

    # Process if we've got something.
    if ($bb_11nc ne '' ) {


        # Get attribute (use the current activity) and remove quotes.
        (my $bbcc_attr = `cleartool describe -fmt "%[BBL_list]SNa" $x_activity`) =~ s/\"//g;
        vprint("BBL_list=$bbcc_attr\n");

        # Check using our subroutine.
        if ( bbcc_check($bb_11nc,$bbcc_attr) == 0 )
        {
          # Yep, result is OK.
          vprint("BB11nc matches BBL_list criteria\n");
          $bbcc_rv = 0;
        }
        else
        {
          # CQ query, depends on rebase-active or not.
          my $cq_bbcc_output;
          my $cq_bbcc_return;
          my $bbcc_tool;
          if ( $rebase_active eq 'FALSE' )
          {
            # No rebase: iexec ClearQuest activity specific query (with -l option for logging).
            # remove any cr/lf's from output.
            vprint("Executing activity specific CQ query\n");
            $bbcc_tool = BBCC_CHECK_WI;
            $cq_bbcc_output = `$bbcc_tool -l -d $cqdatabase $bare_activity $bb_11nc`;
            $cq_bbcc_return = $?;
            chomp($cq_bbcc_output);
          }
          else
          {
            # Rebase active AND not checked out before, use stream to get appropriate CQ data.
            vprint("Executing stream specific CQ query\n");
            $bbcc_tool = BBCC_CHECK_STREAM;
            $cq_bbcc_output = `$bbcc_tool -d $cqdatabase $stream $bb_11nc`;
            $cq_bbcc_return = $?;
            chomp($cq_bbcc_output);
          }

          # Handle result (note: exit 1 in tool is 256 in unix environment...).
          if ( $cq_bbcc_return == 0 || $cq_bbcc_return == 256 )
          {
            # Function ran, report a bit.
            vprint("CQ replied=$cq_bbcc_output\n");

            # Separate change and 11nc data.
            my @cq_list = split(' ', $cq_bbcc_output);
            my $change = $cq_list[0];
            shift(@cq_list);
            my $cq_actual_11ncs = join(' ',@cq_list);

            # Put it in attribute if not already there (optimization).
            my $attr_ok;
            if ( $bbcc_attr ne $cq_actual_11ncs )
            {
              vprint("Updating (using CQ reply) BBL_list with: $cq_actual_11ncs\n");
              `cleartool mkattr -nc -replace "BBL_list" '"$cq_actual_11ncs"' "$x_activity"`;
              $attr_ok = $?;
            }
            else
            {
              $attr_ok = 0;
            }

            # Check result, and re-check if we're done updating the attribute.
            if ( $attr_ok eq 0)
            {
              # OK, everything set, re-check using our subroutine.
              if ( bbcc_check($bb_11nc,$cq_actual_11ncs) == 0 )
              {
                # Yep, result is OK.
                vprint("BB11nc matches BBL_list criteria\n");
                $bbcc_rv = 0;
              }
              else
              {
                # Not found, generate clear error messaging and return NOK.
                eprint("\nBBCC WARNING: the checkout is not allowed because a change of building block\n");
                eprint("              $bb_id (11nc $bb_11nc) is not allowed according\n");
                if ( $change ne 'dummy' )
                {
                  eprint("              to change $change !\n\n");
                }
                else
                {
                  eprint("              to the changes that are coupled to your stream !\n\n");
                }
                $bbcc_rv = 1;
              }
            }
            else
            {
              # Clearcase error...
              eprint("\nBBCC ERROR: could not set BBL_list attribute\n\n");
              $bbcc_rv = 1;
            }
          }
          else
          {
            # Invalid call, generate error message and set NOK result.
            eprint("\nBBCC ERROR: invalid call to $bbcc_tool\n\n");
            $bbcc_rv = 1;
          }
        }

    } #if ($bb_11nc ne '' ) {

  } # CHECKITEMS

}
else
{
  # No CQ database (dumbo ??), set flag on OK.
  $bbcc_rv = 0;
  vprint("No CQ database, skipping BBCC check\n");
}

# ------------------------------------------------------------------------
#
# ICC Check, is also executed when BBCC failed (list all of the CQ actions
# that need to be established), not when FNDMRG failed.
#
# Behaviour with respect to rebase: we read the attribute but we don's
# check for grants if in a rebase. Check-outs are allowed if checked-out
# before.
#
# ------------------------------------------------------------------------

# Skip ICC stuff if no CQ database is set or if we have a findmerge hit.
if ( ($fndmrg_rv == 0) && ( $cqdatabase ne '' ) && ( $cqdatabase ne ': CRM Suspended' ) )
{

  # Only enter the ICC stuff if we're not in a deliver (otherwise all I/F
  # related delivers are delayed (amount of I/F controlled files is relatively
  # big, and growing. Think of the T&I delivers...)
  if ($activity_comment !~ /^Integration activity created by deliver on / )
  {
    # Get attribute (coupled to element)
    my $icc_attr = `cleartool describe -fmt "%[ACM_grant]SNa" $pathname@@`;
    vprint("ACM_grant=$icc_attr\n");

    if ( $icc_attr ne '' )
    {
      # remove quotes
      $icc_attr =~ s/\"//g;

      # Check for "once locked, give a warning"
      if ( $icc_attr eq "1" )
      {
        # remove quotes out of ACM attribute and print it
        eprint("\nICC WARNING: this element was once under Interface Change Control!\n\n");

        # This situation is OK.
        $icc_rv = 0;
      }
      else
      {
        # Check for "really locked" (2 means via qbl, 3 means cloned, 4 means via closed release).
        if ( $icc_attr eq "2" ||  $icc_attr eq "3" || $icc_attr eq "4" )
        {
          # Current activity can be empty in case of a deliver (because then the
          # activity is current in the view on the int-stream). Only proceed if
          # it is non-empty.
          if ( $x_activity ne '' )
          {
            # Do the standard ICC check if we are not in a rebase or if we're in a rebase with
            # a yet un-modified element (i.e. an explicit command-line check-out).
            if ( $rebase_active ne 'TRUE' || ( $rebase_active eq 'TRUE' && $checkedout_before eq 'FALSE' ) )
            {
              # Get object id.
              my $oid = `cleartool describe -fmt "%On" $pathname@@`;
              vprint("OID=$oid\n");

              # ClearQuest query for grant on this element. Note that an UCM utility activity for
              # a deliver falls through the CQ grant check (it's OK). We're not distinguishing be-
              # tween implicit or explicit checkouts in a deliver !
              my $icc_tool;
              my $cq_check_output;
              my $granted;
              if ( $rebase_active eq 'FALSE' )
              {
                $icc_tool = GRANT_CHECK_WI;
                $cq_check_output = `$icc_tool -d $cqdatabase $bare_activity $oid`;
                $granted = $?;
              }
              else
              {
                $icc_tool = GRANT_CHECK_STREAM;
                $cq_check_output = `$icc_tool -d $cqdatabase $stream $oid`;
                $granted = $?;
              }

              # Parse output.
              my @cq_check_fields = split(' ',"$cq_check_output");
              my $change = $cq_check_fields[0];
              my $interface_name = $cq_check_fields[1];
              vprint("change=$change\n");
              vprint("interface_name=$interface_name\n");

              # And handle result...
              if ( $granted eq 0 )
              {
                # This situation is OK (grant given or UCM utility stuff). Print change data if any.
                if ( $change ne '' )
                {
                  eprint("\nICC: Grant on $change OK.\n\n");
                }

                # And return OK.
                $icc_rv = 0;
              }
              else
              {
                # Print the error report.
                eprint("\nICC WARNING: this file is under Interface Change Control, an explicit grant\n");
                eprint("             from the appropriate Granter architect is needed:\n");
                eprint("             (<$webserver/Granters_of_interface_changes>)\n");
                (my $if_link_name = $interface_name)=~s/.txt$//g;
                eprint("             (<$ifshare/${if_link_name}.htm>)\n\n");
                eprint("             Provide the following information to the architect:\n");
                if ( $change ne "dummy" )
                {
                  eprint("             - Change: $change\n");
                }
                eprint("             - Interface: $interface_name\n");
                eprint("             - File: $pathname\n");
                eprint("             - SIA id: (TCE id)\n");
                eprint("             - SIA status: (status here)\n");
                eprint("             - Is this interface change covered by the SIA? (answer here)\n\n");

                # This situation is NOK.
                $icc_rv = 1;
              }
            }
            else
            {
              # Yes, we allow the checkout (project HAD a grant and we assume it's still valid).
              eprint("\nICC: File was changed in this stream, assuming that grant is still valid.\n\n");

              # And return OK.
              $icc_rv = 0;
            }
          }
          else
          {
            # Empty activity, retval is OK (this is the "deliver" case with
            # a current activity in the view on the int-stream).
            $icc_rv = 0;
          }
        }
        else
        {
          # Check for "put asleep"
          if ( $icc_attr eq "0" )
          {
            $icc_rv = 0;
          }
          else
          {
            # I don't know this one !!
            eprint("\nICC ERROR: unknown ACM_grant attribute value: $icc_attr\n\n");
          }
        }
      }
    }
    else
    {
      # No ACM attribute set, situation OK.
      $icc_rv = 0;
    }
  }
  else
  {
    # We're in a deliver, set flag on OK.
    $icc_rv = 0;
    vprint("Deliver active, skipping ICC check\n");
  }
}
else
{
  # No CQ database (dumbo ??), set flag on OK.
  $icc_rv = 0;
  vprint("No CQ database, skipping ICC check\n");
}

# -------------------------------------------------------------------------
#
# BuildScope check, only executed if BCC, ICC and FNDMRG are all OK.
#
# Behaviour with respect to rebase: we do check during a rebase to detect
# the following: NOT within buildscope but checked-out before, which will
# in most cases be an ASML subcomponent promotion case. We allow the update
# and generate a warning that the buildscope must be extended.
#
# -------------------------------------------------------------------------

if ( ($fndmrg_rv == 0) && ($icc_rv == 0) && ($bbcc_rv == 0) )
{
  vprint("BUILDSCOPE=$buildscope\n");

  ## The buildscope is already collected much earlier in the trigger!!
  ## if $buildscope is an empty string, partial builds are not
  ## enabled. An empty buildscope equals '""' (two quotes)
  if ( $buildscope ne '' )
  {
    vprint("Buildscope ATTR is set\n");
    $buildscope =~ s/\"//g;  ## remove quotes

    if ( $buildscope eq 'full' )
    {
      # We have a full buildscope
      $bsc_rv = 0;
    }## if 'full' buildscope
    else
    {
      ## Only check if we're in an ASML component.
      if ( $asmlcc ne '' )
      {
          # Skip the pkg and scm directory.
          if ( ($asmlcc !~ m/^pkg\/*/) && ($asmlcc !~ m/^scm\/*/) )
          {

              # Get all components
              my @comps = split(' ', $buildscope);
              # Do a match on the entire array
              my @found = grep { $asmlcc eq $_ } @comps;

              # Does the buildscope contain the component?
              if ( $#found >= 0 )
              {
                # It matches so it's inside the buildscope
                vprint("Element inside buildscope, allowed\n");
                $bsc_rv = 0;
              }
              else
              {
                # At this point a check-out of an ASML CC is attempted while it's
                # not in the buildscope. We only allow it if we're in a rebase and
                # it's checked-out before.
                if ( $rebase_active eq 'TRUE' && $checkedout_before eq 'TRUE' )
                {
                  eprint("\nWARNING: you must add $asmlcc to the buildscope AFTER rebase completion !!!!!!!!!!!!!!!!!\n\n");
                  $bsc_rv = 0;
                }
                else
                {
                  vprint("Element outside buildscope, forbidden\n");
                  $bsc_rv = 1;
                }
              }## if within buildscope

          } else {
              vprint("Element inside special trees pkg or scm, allowed\n");
              $bsc_rv = 0;
          }

      }## if element is a element within a component
      else
      {
        vprint("Element outside ASML components, allowed\n");
        $bsc_rv = 0;
      }## if..else
    }## if..else
  }## if PB enabled
  else
  {
    ## No partial build enabled
    vprint("Buildscope ATTR is not set, allowed\n");
    $bsc_rv = 0;
  }## if..else

  if ( $bsc_rv == 1 )
  {
    eprint("ERROR: Element not included in buildscope!\n");
  }## if $bsc_rv == 1

} ## if $icc_rv and $bbcc_rv == 0  (buildscope check)
else
{
  # Buildscope check "unchecked but semi-ok" if one of the others failed.
  $bsc_rv = 0;
}

# -------------------------------------------------------------------------
#
# ASML CC lock check, only executed if BCC, ICC, FNDMRG and BSC are all OK.
#
# Check is performed allways (also during rebase and deliver). Note
# that is only hits if the ASML component is located directly below
# the UCM component's root directory, so check-outs in an .eol or
# .trash directory can be performed (of cource this is intended !).
#
# -------------------------------------------------------------------------

if ( ($fndmrg_rv == 0) && ($icc_rv == 0) && ($bbcc_rv == 0) && ($bsc_rv == 0) )
{
  # Check for a match if we've got a component oid.
  if ( $asmlcc_eloid ne '' )
  {
    if ( $locked_asml_ccs =~ m/$asmlcc_eloid/ )
    {
      # For messaging get base component dirname out of asmlcc.
      my @asmlcc_nodes = split("/",$asmlcc);
      my $asmlcc_dir = $asmlcc_nodes[1];
      eprint("\nWARNING: Checkouts in ASML component $asmlcc_dir are not allowed because it is\n");
      eprint("         moved. First rebase to a more recent baseline of your project,\n");
      eprint("         after that $asmlcc_dir can be modified on the new location.\n\n");
      $cclck_rv = 1;
    }
    else
    {
      $cclck_rv = 0;
    }
  }
  else
  {
    $cclck_rv = 0;
  }
}

# ====
# Check if component has been migrated to an AGR (Authoritative Git repository).
# If so, checkout is not possible in ClearCase; changes can only be checked in into Git, which will subsequently
# be synced to ClearCase using the "AGR sync" mechanism.
#
if ($pathname =~ /(.*\/vobs\/\w+)\/(\w+)\/.*/)
{
    my $ucmCompName = $2;

    if (ccGit::IsViewUpdatedFromAgr())
    {
        my $moduleOrBb = ArchInfo::Map11ncToBB($ucmCompName);
        my $rh_locations = ccGit::GetLocations([$moduleOrBb]);
        if (exists $rh_locations->{$moduleOrBb})
        {
            eprint("\nWARNING: Checkouts in '$moduleOrBb' are not allowed because it was migrated to Git.\n");
            eprint("Please make your changes in the Git repo '".$rh_locations->{$moduleOrBb}."'.\n\n");
            $in_agr_rv = 1;
        } # if
    } # if
} # if

# And finally return result.
if ( ($fndmrg_rv == 0) && ($icc_rv == 0) && ($bbcc_rv == 0) && ($bsc_rv == 0) && ($cclck_rv == 0) && ($in_agr_rv == 0) )
{
  exit 0;
}
else
{
  exit 1;
}

__END__

# View the documentation with:
# perldoc checkout_preop_litho2.pl

=pod

=head1 NAME

checkout_preop_litho2.pl - Check if element may be checked out.

=head1 SYNOPSIS

checkout_preop_litho2.pl

=head1 DESCRIPTION

This trigger will check the following prerequisites:
	Checks whether an element is inside the build_scope.
	It checks ICC grants and BBCC approvals.

The checkout should be attached to the mkbranch and checkout event.

It will work only UNIX in dynamic views. Other types are NOT TESTED.

=head1 INSTRUCTIONS

=over 4

=item Bypassing the trigger

This trigger cannot be bypassed!

=item Installation examples

Use user account: ccadmin

Unix only:

cleartool mktrtype -element -all -preop checkout,mkbranch -c "Check permission to checkout" -execunix "/opt/rational/clearcase/bin/Perl /sdev/user/sbin/triggers/checkout_preop_litho2.pl" TR_CHECKOUT_PREOP@/vobs/v3

NOTE: ABOVE COMMAND ALSO INSTALLS ON MKBRANCH !!

=item Deinstallation example

Use user account: ccadmin

cleartool rmtype -rmall trtype:TR_CHECKOUT_PREOP@/vobs/v3

=back

=head1 EXIT STATUS

0: Command executed normally and the checkout is allowed.
1: The element may not be checkedout.

=head1 ENVIRONMENT VARIABLES

The next environment variables are used:
 CLEARCASE_TRACE_TRIGGERS
    When set to non-zero: display debug messages.
 CLEARCASE_PN
    Element name to create.
 CLEARCASE_OP_KIND
    The actual operation that cause the trigger
 CLEARCASE_ACTIVITY
    The UCM activity involved in the operation that caused the trigger (optional).
 CLEARCASE_XPN
    Vob extended path name of object.
 CLEARCASE_VIEW_TAG
    View-tag of the view in which the operation that caused the trigger to fire took place.
 CLEARCASE_CMDLINE
    The commandline during cleartool invocation.
 SCM_TRG_MSG
    Control flag for redirecting messages to STDERR or STDOUT (default)

=head1 HISTORY

V1.9 2013-03-18 HVEF (Henri de Veer)
 Use 11nc from pathname i.s.o. location.bbl for newer modules.

V1.10 2014-07-10 DGAM (Dennis Gallas)
 Exclude xplatform from the buildscope check

=head1 KNOWN ISSUES

None known.

=head1 TESTING THIS TRIGGER (csh example)

See the end of this document!

=head1 AUTHOR

Roel Kersten (Roel.Kersten@asml.com)

=head1 COPYRIGHT

Copyright (c) 2005-2013 by ASML Holding N.V. All rights reserved.

=cut


History:

V0.0 2005-07-25 ROEK (Roel Kersten)

 Initial version.

V0.1 2005-11-09 ROEK (Roel Kersten)

 Fixed bug: having an empty buildscope, a user couldn't checkout anything, instead of "elements in all components".

V0.2 2005-11-10 ROEK (Roel Kersten)

 Added DEBUG functionality (just set EV $PERL_DEBUG to nonzero)

V0.3 2006-10-13 WVEG (Willem van Veggel)

 Added functionality for Advanced Change Control (interface management).

V0.4 2007-01-02 WVEG (Willem van Veggel)

 Changed feedback when grant is not given (ICC).

V0.5 2007-02-21 WVEG (Willem van Veggel)

 Use lsact to get activity when invoked on mkbranch, otherwise we've got 0-versions.

V0.6 2007-04-25 WVEG (Willem van Veggel)

 Disallowed explicit checkouts during rebase and deliver operations.

V0.7 2007-06-27 HVEF (Henri de Veer)

 Archived in tooling1.
 Updated the debug output to be compliant with other triggers.
 Improved speed of buildscope check.

V0.8 2008-01-23 HVEF (Henri de Veer)

 Updated the buildscope check: skip pkg/*, scm/* files.

V0.9 2008-04-04 WVEG (Willem van Veggel)

 Added logic for Building Block Change Control

V1.0 2008-04-28 HVEF (Henri de Veer)

 Implement flag that controls the output of all triggers.
 Default: SCM_TRG_MSG=STDOUT  ccdeliver shall set: SCM_TRG_MSG=STDERR
 Use generic functions from Trgmod::general.

V1.1 2008-06-30 WVeg (Willem van Veggel)
 Added logic to support BBCC and ICC controlled explicit checkouts during rebase.

V1.2 2009-10-07 WVeg (Willem van Veggel)
 Added logic for WIP blocker.

V1.3 2010-06-01 WVeg (Willem van Veggel)
 Added logic for clone engine.

V1.4 2010-08-12 HVEF (Henri de Veer)
 Fix bug that we get an error on checking out the ATLAS_1.0.0 directory.
 Do some speed optimalisations.
 Improve regression tests.

V1.5 2010-08-13 HVEF (Henri de Veer)
 Bugfix was too aggressive with regexp.

V1.6 2011-11-25 Heui (Andreas Heuijerjans)
 Update of ICC warning message for AIM (DCPLN00019051)

V1.7 2012-01-12 HVEF (Henri de Veer)
 Skip /xscm/ for determining the ASML component.

V1.8 2013-01-28 HVEF (Henri de Veer)
  DCPLN00024159:  Make code portable.
  
V1.9 2017-08-16 Geeta Tavakari
  DCPLN00122255: Check for acm_grant value 4 to clock checkout for closed releases.

V1.9.1 2021-03-08 Bismita Panigrahi
  INC2675444: Replace the correct URL for Interface Viewer in Checkout trigger

V1.10 2022-09-02 Elangkumaran Sundaram
  ESWP-22141 Different cqperl path selected based on clearquest/compass installed 

V1.11 2022-09-22 Elangkumaran Sundaram
  ESWP-22141 Fix - checkout should not fail even in case of clearquest/compass not installed 
