use Test2::V0;
use v5.38;

use Test2::Harness2::SystemLoad;

# SystemLoad samples cpu/mem/load. CPU% is a delta between two readings, so the
# first sample has no percentage. /proc (linux) and sysctl (bsd) reads are
# overridable test seams so the math is exercised on any host.

# --- Linux backend, fed canned /proc files ---

package FakeLinux {
    our @ISA = ('Test2::Harness2::SystemLoad');
    sub _read_file ($self, $path) { return $self->{files}{$path} }
}

sub linux_src (%files) {
    return FakeLinux->new(os => 'linux', files => {%files});
}

subtest linux_cpu_delta => sub {
    my $src = linux_src(
        '/proc/stat'    => "cpu 100 0 50 1000 0 0 0 0 0 0\ncpu0 1 1 1 1\ncpu1 1 1 1 1\n",
        '/proc/meminfo' => "MemTotal: 1000 kB\nMemAvailable: 400 kB\n",
        '/proc/loadavg' => "0.50 0.40 0.30 1/100 1234\n",
    );

    my $a = $src->sample;
    is($a->{cpu_pct}, undef, "first sample has no cpu_pct (baseline)");
    is($a->{ncpu}, 2, "counts cpu cores");
    is($a->{load_avg}, [0.50, 0.40, 0.30], "load averages parsed");
    is($a->{mem_total}, 1000 * 1024, "mem_total in bytes");
    is($a->{mem_available}, 400 * 1024, "mem_available in bytes");
    is($a->{mem_used}, 600 * 1024, "mem_used derived");
    is($a->{mem_pct}, 60, "mem_pct derived");

    # Advance counters: total +550, idle +400 -> busy = (550-400)/550 = 27.27%
    $src->{files}{'/proc/stat'} = "cpu 200 0 100 1400 0 0 0 0 0 0\n";
    my $b = $src->sample;
    is($b->{cpu_pct}, within(27.27, 0.01), "cpu_pct from the delta");
};

subtest linux_meminfo_fallback => sub {
    my $src = linux_src(
        '/proc/stat'    => "cpu 1 1 1 1 1\n",
        '/proc/meminfo' => "MemTotal: 1000 kB\nMemFree: 100 kB\nBuffers: 50 kB\nCached: 150 kB\n",
        '/proc/loadavg' => "0.0 0.0 0.0 1/1 1\n",
    );
    my $s = $src->sample;
    is($s->{mem_available}, (100 + 50 + 150) * 1024, "falls back to free+buffers+cached");
};

# --- BSD backend, fed canned sysctl values ---

package FakeBSD {
    our @ISA = ('Test2::Harness2::SystemLoad');
    sub _read_sysctl ($self, $name) { return $self->{sysctl}{$name} }
}

sub bsd_src (%sysctl) {
    return FakeBSD->new(os => 'bsd', sysctl => {%sysctl});
}

subtest bsd_cpu_idle_is_last => sub {
    # 5-state (FreeBSD/NetBSD): user nice sys intr idle
    my $src = bsd_src(
        'kern.cp_time' => "100 0 50 0 1000",
        'hw.ncpu'      => "8",
        'vm.loadavg'   => "{ 0.50 0.40 0.30 }",
        'hw.physmem'   => "1000000",
        'hw.pagesize'  => "4096",
        'vm.stats.vm.v_free_count'     => "100",
        'vm.stats.vm.v_inactive_count' => "50",
        'vm.stats.vm.v_cache_count'    => "10",
    );

    my $a = $src->sample;
    is($a->{cpu_pct}, undef, "baseline");
    is($a->{ncpu}, 8, "hw.ncpu");
    is($a->{load_avg}, [0.50, 0.40, 0.30], "vm.loadavg parsed");
    is($a->{mem_total}, 1000000, "hw.physmem");
    is($a->{mem_available}, (100 + 50 + 10) * 4096, "available from page counts");

    # total +550, idle +400 -> 27.27%
    $src->{sysctl}{'kern.cp_time'} = "200 0 100 0 1400";
    my $b = $src->sample;
    is($b->{cpu_pct}, within(27.27, 0.01), "cpu_pct from the delta");
};

subtest bsd_six_state_cp_time => sub {
    # 6-state (OpenBSD): user nice sys spin intr idle -- idle still last
    my $src = bsd_src('kern.cp_time' => "100 0 50 0 0 1000", 'hw.ncpu' => "4");
    $src->sample;
    $src->{sysctl}{'kern.cp_time'} = "200 0 100 0 0 1400";
    my $b = $src->sample;
    is($b->{cpu_pct}, within(27.27, 0.01), "idle taken as the last field regardless of state count");
};

subtest bsd_missing_mem_counters => sub {
    my $src = bsd_src('kern.cp_time' => "1 0 1 0 1", 'hw.physmem' => "2048", 'hw.ncpu' => "1");
    my $s = $src->sample;
    is($s->{mem_total}, 2048, "physmem still read");
    is($s->{mem_available}, undef, "available undef when page counters absent");
};

done_testing;
