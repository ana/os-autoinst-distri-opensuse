# SUSE's openQA tests
#
# Copyright 2016-2024 SUSE LLC
# SPDX-License-Identifier: FSFAP
#
package update_package;
# Summary: update_package: Update all packages and use real repo as guest installation source before test.
# Maintainer: qe-virt@suse.com

use strict;
use warnings;
use testapi;
use base "virt_autotest_base";
use utils 'is_uefi_boot';
use version_utils 'is_sle';
use virt_utils;
use ipmi_backend_utils;
use Utils::Architectures;
use virt_autotest::utils qw(is_xen_host is_kvm_host is_registered_sles);

sub update_package {
    my $self = shift;
    my $test_type = get_var('TEST_TYPE', 'Milestone');
    my $update_pkg_cmd = "source /usr/share/qa/virtautolib/lib/virtlib;update_virt_rpms";
    my $ret;
    if ($test_type eq 'Milestone') {
        $update_pkg_cmd = $update_pkg_cmd . " off on off";
    }
    else {
        $update_pkg_cmd = $update_pkg_cmd . " off off on";
    }

    $update_pkg_cmd = $update_pkg_cmd . " 2>&1 | tee /tmp/update_virt_rpms.log ";
    if (is_s390x) {
        lpar_cmd("$update_pkg_cmd");
        upload_asset "/tmp/update_virt_rpms.log", 1, 1;
    }
    else {
        $self->execute_script_run($update_pkg_cmd, 7200);
        upload_logs("/tmp/update_virt_rpms.log");
        save_screenshot;
        if ($self->{script_output} !~ /Need to reboot system to make the rpms work/m) {
            die " Update virt rpms fail, going to terminate following test!";
        }
    }

}

sub run {
    my $self = shift;
    #workaroud: skip update package for registered sles as the packages are already up-to-date
    $self->update_package() unless is_registered_sles && !is_s390x;
    if (is_registered_sles && !is_s390x) {
        my @files_to_upload = ("/boot/grub2/grub.cfg", "/etc/default/grub");
        push(@files_to_upload, script_output("ls /boot/efi/efi/sles/xen-*.cfg")) if is_xen_host and is_uefi_boot;
        upload_logs($_, failok => 1) foreach (@files_to_upload);
    } elsif (!is_s390x) {
        set_grub_on_vh('', '', 'xen') if is_xen_host;
        set_grub_on_vh('', '', 'kvm') if is_kvm_host;
    }
    update_guest_configurations_with_daily_build();

    # turn on debug for libvirtd & enable journal with previous reboot
    enable_debug_logging if is_x86_64;

    #workaround of bsc#1177790
    #disable DNSSEC validation as it is turned on by default but the forwarders donnot support it, refer to bsc#1177790
    if (is_sle('>=12-sp5')) {
        if (is_s390x) {
            lpar_cmd("sed -i 's/#dnssec-validation auto;/dnssec-validation no;/g' /etc/named.conf");
            lpar_cmd("grep 'dnssec-validation' /etc/named.conf");
            lpar_cmd("systemctl restart named");
        } else {
            script_run "sed -i 's/#dnssec-validation auto;/dnssec-validation no;/g' /etc/named.conf";
            script_run "grep 'dnssec-validation' /etc/named.conf";
            script_run "systemctl restart named";
        }
        save_screenshot;
    }

}

sub test_flags {
    return {fatal => 1};
}

1;
