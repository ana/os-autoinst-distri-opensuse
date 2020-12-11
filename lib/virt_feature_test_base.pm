# VIRSH TEST MODULE BASE PACKAGE
#
# Copyright © 2019 SUSE LLC
#
# Copying and distribution of this file, with or without modification,
# are permitted in any medium without royalty provided the copyright
# notice and this notice are preserved. This file is offered as-is,
# without any warranty.
#
# Summary: This is the base package for virsh test modules, for example,
# tests/virtualization/universal/hotplugging.pm
# tests/virt_autotest/virsh_internal_snapshot.pm
# tests/virt_autotest/virsh_external_snapshot.pm
# and etc.
#
# The elements that author of newly developed feature test can customize
# are:
# 1. $self->{test_results}->{$guest}->{CUSTOMIZED_TEST1}->{status} which can
# be given 'SKIPPED', 'FAILED', 'PASSED', 'SOFTFAILED', 'TIMEOUT' or 'UNKNOWN'.
# 2. $self->{test_results}->{$guest}->{CUSTOMIZED_TEST1}->{test_time} which
# should be given time cost duration in format like 'XXmYYs'.
# 3. $self->{test_results}->{$guest}->{CUSTOMIZED_TEST1}->{error} which can
# be given any customized error message that is suitable to be placed in
# system-err section.
# 4. $self->{test_results}->{$guest}->{CUSTOMIZED_TEST1}->{output} which can
# be given any customized output message that is suitable to be placed in
# system-out section.
# Maintainer: Wayne Chen <wchen@suse.com>

package virt_feature_test_base;

use base "consoletest";
use strict;
use warnings;
use POSIX 'strftime';
use File::Basename;
use Data::Dumper;
use XML::Writer;
use IO::File;
use List::Util 'first';
use testapi;
use utils;
use virt_utils;
use virt_autotest::common;
use virt_autotest::utils;
use version_utils 'is_sle';

sub run_test {
    die('Please override this subroutine in children modules to run desired tests.');
}

sub prepare_run_test {
    my $self = shift;

    script_run("rm -f /root/{commands_history,commands_failure}");
    assert_script_run("history -c");

    virt_utils::cleanup_host_and_guest_logs;
    virt_utils::start_monitor_guest_console;
}

sub run {
    my ($self) = @_;

    $self->prepare_run_test if (!(get_var("TEST", '') =~ /qam/) && (is_xen_host() || is_kvm_host()));

    $self->{"start_run"} = time();
    $self->run_test;
    $self->{"stop_run"} = time();

    virt_utils::stop_monitor_guest_console if (!(get_var("TEST", '') =~ /qam/) && (is_xen_host() || is_kvm_host()));

    #(caller(0))[3] can help pass calling subroutine name into called subroutine
    $self->junit_log_provision((caller(0))[3]) if get_var("VIRT_AUTOTEST");
}

sub junit_log_provision {
    my ($self, $runsub) = @_;
    my $overall_status = eval { $runsub =~ /post_fail_hook/img ? 'FAILED' : 'PASSED' };
    $self->analyzeResult($overall_status);
    $self->junit_log_params_provision;
    ###Load instance attributes into %stats
    my %stats;
    foreach (keys %{$self}) {
        if (defined($self->{$_})) {
            if (ref($self->{$_}) eq 'HASH') {
                %{$stats{$_}} = %{$self->{$_}};
            }
            elsif (ref($self->{$_}) eq 'ARRAY') {
                @{$stats{$_}} = @{$self->{$_}};
            }
            else {
                $stats{$_} = $self->{$_};
            }
        }
        else {
            next;
        }
    }
    print "The data to be used for xml generation:", Dumper(\%stats);
    my %tc_result  = %{$stats{test_results}};
    my $xml_result = generateXML_from_data(\%tc_result, \%stats);
    script_run "echo \'$xml_result\' > /tmp/output.xml";
    save_screenshot;
    parse_junit_log("/tmp/output.xml");
}

sub junit_log_params_provision {
    my $self = shift;

    my $start_time = $self->{"start_run"};
    my $stop_time  = $self->{"stop_run"};
    $self->{"test_time"}         = strftime("\%H:\%M:\%S", gmtime($stop_time - $start_time));
    $self->{"product_tested_on"} = script_output("cat /etc/issue | grep -io \"SUSE.*\$(arch))\"");
    $self->{"product_name"}      = ref($self);
    $self->{"package_name"}      = ref($self);
}

sub analyzeResult {
    my ($self, $status) = @_;

    #Initialize all test status counters to zero
    #Then count up all counters by the number of tests in corresponding status
    my @test_item_status_array = ('pass', 'fail', 'skip', 'softfail', 'timeout', 'unknown');
    $self->{$_ . '_nums'} = 0 foreach (@test_item_status_array);
    foreach my $guest (keys %virt_autotest::common::guests) {
        foreach my $item (keys %{$self->{test_results}->{$guest}}) {
            my $item_status      = $self->{test_results}->{$guest}->{$item}->{status};
            my $test_item_status = first { $item_status =~ /^$_/i } @test_item_status_array;
            $self->{$test_item_status . '_nums'} += 1;
        }
    }

    #If test failed at undefined checkpoint, it still needs to be counted in to maintain
    #the correctness and effectivenees of entire JUnit log
    if ($status eq 'FAILED' && $self->{"fail_nums"} eq '0') {
        $self->{"fail_nums"} = '1';
        my $uncheckpoint_failure       = script_output("cat /root/commands_history | tail -3 | head -1");
        my @involved_failure_guest     = grep { $uncheckpoint_failure =~ /$_/img } (keys %virt_autotest::common::guests);
        my $uncheckpoint_failure_guest = "";
        if (!scalar @involved_failure_guest) {
            $uncheckpoint_failure_guest = "NO SPECIFIC TEST GUEST INVOLVED";
        }
        else {
            $uncheckpoint_failure_guest = join(' ', @involved_failure_guest);
        }
        diag "The accidental failure happended at: $uncheckpoint_failure involves: $uncheckpoint_failure_guest";
        script_run("($uncheckpoint_failure) 2>&1 | tee -a /root/commands_failure", quiet => 1);
        my $uncheckpoint_failure_error = script_output("cat /root/commands_failure", type_command => 0, proceed_on_failure => 1, quiet => 1);
        $self->{test_results}->{$uncheckpoint_failure_guest}->{$uncheckpoint_failure}->{status} = 'FAILED';
        $self->{test_results}->{$uncheckpoint_failure_guest}->{$uncheckpoint_failure}->{error}  = $uncheckpoint_failure_error;
    }

    if ($status eq 'PASSED' and !defined $self->{test_results}) {
        $self->{test_results}->{'ALL GUESTS'}->{'ALL TESTS'}->{status} = 'PASSED';
        $self->{test_results}->{'ALL GUESTS'}->{'ALL TESTS'}->{error}  = 'NONE';
    }
}

sub post_fail_hook {
    my ($self) = shift;

    $self->{"stop_run"} = time();
    assert_script_run("history -w /root/commands_history");
    virt_utils::stop_monitor_guest_console() if (!(get_var("TEST", '') =~ /qam/) && (is_xen_host() || is_kvm_host()));
    #(caller(0))[3] can help pass calling subroutine name into called subroutine
    $self->junit_log_provision((caller(0))[3]) if get_var("VIRT_AUTOTEST");
    collect_virt_system_logs();

    virt_utils::collect_host_and_guest_logs;
    upload_logs("/var/log/clean_up_virt_logs.log");
    save_screenshot;
    upload_logs("/var/log/guest_console_monitor.log");
    save_screenshot;
    script_run("rm -f -r /var/log/clean_up_virt_logs.log /var/log/guest_console_monitor.log");
    save_screenshot;
    $self->upload_coredumps;
    save_screenshot;
}

sub get_free_mem {
    if (check_var('SYSTEM_ROLE', 'xen')) {
        # ensure the free memory size on xen host
        my $mem = script_output q@xl info | grep ^free_memory | awk '{print $3}'@;
        $mem = int($mem / 1024);
        return $mem;
    }
}

sub get_active_pool_and_available_space {
    # get some debug info about hard disk topology
    script_run 'df -h';
    script_run 'df -h /var/lib/libvirt/images/';
    script_run 'lsblk -f';
    # get some debug info about storage pool
    script_run 'virsh pool-list --details';
    # ensure the available disk space size for active pool
    my $active_pool    = script_output("virsh pool-list --persistent | grep active | awk '{print \$1}'");
    my $available_size = script_output("virsh pool-info $active_pool | grep ^Available | awk '{print \$2}'");
    my $pool_unit      = script_output("virsh pool-info $active_pool | grep ^Available | awk '{print \$3}'");
    # default available pool unit as GiB
    $available_size = ($pool_unit eq "TiB") ? int($available_size * 1024) : int($available_size);
    return ($active_pool, $available_size);
}

sub get_virt_disk_and_available_space {
    # ensure the available disk space size for virt disk - /var/lib/libvirt
    my $virt_disk_name      = script_output 'lsblk -rnoPKNAME $(findmnt -nrvoSOURCE /var/lib/libvirt)';
    my $virt_available_size = script_output("df -k | grep libvirt | awk '{print \$4}'");
    # default available virt disk unit as GiB
    $virt_available_size = int($virt_available_size / 1048576);
    return ($virt_disk_name, $virt_available_size);
}

1;
