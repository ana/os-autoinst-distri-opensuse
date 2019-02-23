# SUSE's openQA tests
#
# Copyright © 2009-2013 Bernhard M. Wiedemann
# Copyright © 2012-2019 SUSE LLC
#
# Copying and distribution of this file, with or without modification,
# are permitted in any medium without royalty provided the copyright
# notice and this notice are preserved.  This file is offered as-is,
# without any warranty.

# Summary: QA automation scheduler stress test
# Maintainer: Yong Sun <yosun@suse.com>

use base 'stress_validation';
use strict;
use warnings;

sub test_run_list {
    return qw(_reboot_off sched_stress);
}

1;

