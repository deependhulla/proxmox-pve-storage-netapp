package PVE::Storage::ZFSPoolPlugin;

use strict;
use warnings;
use IO::File;
use POSIX;
use PVE::Tools qw(run_command);
use PVE::Storage::Plugin;


use base qw(PVE::Storage::Plugin);

sub type {
    return 'zfspool';
}

sub plugindata {
    return {
	content => [ {images => 1, rootdir => 1}, {images => 1 , rootdir => 1}],
	format => [ { raw => 1, subvol => 1 } , 'raw' ],
    };
}

sub properties {
    return {
	blocksize => {
	    description => "block size",
	    type => 'string',
	},
	sparse => {
	    description => "use sparse volumes",
	    type => 'boolean',
	},
    };
}

sub options {
    return {
	pool => { fixed => 1 },
	blocksize => { optional => 1 },
	sparse => { optional => 1 },
	nodes => { optional => 1 },
	disable => { optional => 1 },
        maxfiles => { optional => 1 },
	content => { optional => 1 },
    };
}

# static zfs helper methods

sub zfs_parse_size {
    my ($text) = @_;

    return 0 if !$text;
    
    if ($text =~ m/^(\d+(\.\d+)?)([TGMK])?$/) {

	my ($size, $reminder, $unit) = ($1, $2, $3);
	
	if ($unit) {
	    if ($unit eq 'K') {
		$size *= 1024;
	    } elsif ($unit eq 'M') {
		$size *= 1024*1024;
	    } elsif ($unit eq 'G') {
		$size *= 1024*1024*1024;
	    } elsif ($unit eq 'T') {
		$size *= 1024*1024*1024*1024;
	    } else {
		die "got unknown zfs size unit '$unit'\n";
	    }
	}

	if ($reminder) {
	    $size = ceil($size);
	}
	
	return $size;
    
    }

    warn "unable to parse zfs size '$text'\n";

    return 0;
}

sub zfs_parse_zvol_list {
    my ($text) = @_;

    my $list = ();

    return $list if !$text;

    my @lines = split /\n/, $text;
    foreach my $line (@lines) {
	my ($dataset, $size, $origin, $type, $refquota) = split(/\s+/, $line);
	next if !($type eq 'volume' || $type eq 'filesystem');

	my $zvol = {};
	my @parts = split /\//, $dataset;
	next if scalar(@parts) < 2; # we need pool/name
	my $name = pop @parts;
	my $pool = join('/', @parts);

	next unless $name =~ m!^(vm|base|subvol)-(\d+)-(\S+)$!;
	$zvol->{owner} = $2;

	$zvol->{pool} = $pool;
	$zvol->{name} = $name;
	if ($type eq 'filesystem') {
	    if ($refquota eq 'none') {
		$zvol->{size} = 0;
	    } else {
		$zvol->{size} = zfs_parse_size($refquota);
	    }
	    $zvol->{format} = 'subvol';
	} else {
	    $zvol->{size} = zfs_parse_size($size);
	    $zvol->{format} = 'raw';
	}
	if ($origin !~ /^-$/) {
	    $zvol->{origin} = $origin;
	}
	push @$list, $zvol;
    }

    return $list;
}

sub parse_volname {
    my ($class, $volname) = @_;

    if ($volname =~ m/^(((base|vm)-(\d+)-\S+)\/)?((base)?(vm|subvol)?-(\d+)-\S+)$/) {
	my $format = $7 && $7 eq 'subvol' ? 'subvol' : 'raw';
	return ('images', $5, $8, $2, $4, $6, $format);
    }

    die "unable to parse zfs volume name '$volname'\n";
}

# virtual zfs methods (subclass can overwrite them)

sub path {
    my ($class, $scfg, $volname, $storeid, $snapname) = @_;

    my ($vtype, $name, $vmid) = $class->parse_volname($volname);

    my $path = '';

    if ($vtype eq "images") {
	if ($volname =~ m/^subvol-/) {
	    $path = "/$scfg->{pool}/$volname";
	    $path .= "/.zfs/snapshot/$snapname" if defined($snapname);
	} else {
	    $path = "/dev/zvol/$scfg->{pool}/$volname";
	    $path .= "\@$snapname" if defined($snapname);
	}
    } else {
	die "$vtype is not allowed in ZFSPool!";
    }

    return ($path, $vmid, $vtype);
}

sub zfs_request {
    my ($class, $scfg, $timeout, $method, @params) = @_;

    $timeout = 5 if !$timeout;

    my $cmd = [];

    if ($method eq 'zpool_list') {
	push @$cmd, 'zpool', 'list';
    } else {
	push @$cmd, 'zfs', $method;
    }

    push @$cmd, @params;
 
    my $msg = '';

    my $output = sub {
        my $line = shift;
        $msg .= "$line\n";
    };

    run_command($cmd, errmsg => "zfs error", outfunc => $output, timeout => $timeout);

    return $msg;
}

sub alloc_image {
    my ($class, $storeid, $scfg, $vmid, $fmt, $name, $size) = @_;

    my $volname = $name;
    
    if ($fmt eq 'raw') {

	die "illegal name '$volname' - sould be 'vm-$vmid-*'\n"
	    if $volname && $volname !~ m/^vm-$vmid-/;
	$volname = $class->zfs_find_free_diskname($storeid, $scfg, $vmid, $fmt) 
	    if !$volname;

	$class->zfs_create_zvol($scfg, $volname, $size);
	my $devname = "/dev/zvol/$scfg->{pool}/$volname";

	run_command("udevadm trigger --subsystem-match block");
	system("udevadm settle --timeout 10 --exit-if-exists=${devname}");

    } elsif ( $fmt eq 'subvol') {

	die "illegal name '$volname' - sould be 'subvol-$vmid-*'\n"
	    if $volname && $volname !~ m/^subvol-$vmid-/;
	$volname = $class->zfs_find_free_diskname($storeid, $scfg, $vmid, $fmt) 
	    if !$volname;

	die "illegal name '$volname' - sould be 'subvol-$vmid-*'\n"
	    if $volname !~ m/^subvol-$vmid-/;

	$class->zfs_create_subvol($scfg, $volname, $size);	
	
    } else {
	die "unsupported format '$fmt'";
    }

    return $volname;
}

sub free_image {
    my ($class, $storeid, $scfg, $volname, $isBase) = @_;

    my (undef, $name, undef) = $class->parse_volname($volname);

    $class->zfs_delete_zvol($scfg, $name);

    return undef;
}

sub list_images {
    my ($class, $storeid, $scfg, $vmid, $vollist, $cache) = @_;

    $cache->{zfs} = $class->zfs_list_zvol($scfg) if !$cache->{zfs};
    my $zfspool = $scfg->{pool};
    my $res = [];

    if (my $dat = $cache->{zfs}->{$zfspool}) {

	foreach my $image (keys %$dat) {

	    my $volname = $dat->{$image}->{name};
	    my $parent = $dat->{$image}->{parent};

	    my $volid = undef;
            if ($parent && $parent =~ m/^(\S+)@(\S+)$/) {
		my ($basename) = ($1);
		$volid = "$storeid:$basename/$volname";
	    } else {
		$volid = "$storeid:$volname";
	    }

	    my $owner = $dat->{$volname}->{vmid};
	    if ($vollist) {
		my $found = grep { $_ eq $volid } @$vollist;
		next if !$found;
	    } else {
		next if defined ($vmid) && ($owner ne $vmid);
	    }

	    my $info = $dat->{$volname};
	    $info->{volid} = $volid;
	    push @$res, $info;
	}
    }
    return $res;
}

sub zfs_get_pool_stats {
    my ($class, $scfg) = @_;

    my $available = 0;
    my $used = 0;

    my $text = $class->zfs_request($scfg, undef, 'get', '-o', 'value', '-Hp',
               'available,used', $scfg->{pool});

    my @lines = split /\n/, $text;

    if($lines[0] =~ /^(\d+)$/) {
	$available = $1;
    }

    if($lines[1] =~ /^(\d+)$/) {
	$used = $1;
    }

    return ($available, $used);
}

sub zfs_create_zvol {
    my ($class, $scfg, $zvol, $size) = @_;
    
    my $cmd = ['create'];

    push @$cmd, '-s' if $scfg->{sparse};

    push @$cmd, '-b', $scfg->{blocksize} if $scfg->{blocksize};

    push @$cmd, '-V', "${size}k", "$scfg->{pool}/$zvol";

    $class->zfs_request($scfg, undef, @$cmd);
}

sub zfs_create_subvol {
    my ($class, $scfg, $volname, $size) = @_;

    my $dataset = "$scfg->{pool}/$volname";
    
    my $cmd = ['create', '-o', 'acltype=posixacl', '-o', 'xattr=sa',
	       '-o', "refquota=${size}k", $dataset];

    $class->zfs_request($scfg, undef, @$cmd);
}

sub zfs_delete_zvol {
    my ($class, $scfg, $zvol) = @_;

    my $err;

    for (my $i = 0; $i < 6; $i++) {

	eval { $class->zfs_request($scfg, undef, 'destroy', '-r', "$scfg->{pool}/$zvol"); };
	if ($err = $@) {
	    if ($err =~ m/^zfs error:(.*): dataset is busy.*/) {
		sleep(1);
	    } elsif ($err =~ m/^zfs error:.*: dataset does not exist.*$/) {
		$err = undef;
		last;
	    } else {
		die $err;
	    }
	} else {
	    last;
	}
    }

    die $err if $err;
}

sub zfs_list_zvol {
    my ($class, $scfg) = @_;

    my $text = $class->zfs_request($scfg, 10, 'list', '-o', 'name,volsize,origin,type,refquota', '-t', 'volume,filesystem', '-Hr');
    my $zvols = zfs_parse_zvol_list($text);
    return undef if !$zvols;

    my $list = ();
    foreach my $zvol (@$zvols) {
	my $pool = $zvol->{pool};
	my $name = $zvol->{name};
	my $parent = $zvol->{origin};
	if($zvol->{origin} && $zvol->{origin} =~ m/^$scfg->{pool}\/(\S+)$/){
	    $parent = $1;
	}

	$list->{$pool}->{$name} = {
	    name => $name,
	    size => $zvol->{size},
	    parent => $parent,
	    format => $zvol->{format},
            vmid => $zvol->{owner},
        };
    }

    return $list;
}

sub zfs_find_free_diskname {
    my ($class, $storeid, $scfg, $vmid, $format) = @_;

    my $name = undef;
    my $volumes = $class->zfs_list_zvol($scfg);

    my $disk_ids = {};
    my $dat = $volumes->{$scfg->{pool}};

    foreach my $image (keys %$dat) {
        my $volname = $dat->{$image}->{name};
        if ($volname =~ m/(vm|base|subvol)-$vmid-disk-(\d+)/){
            $disk_ids->{$2} = 1;
        }
    }

    for (my $i = 1; $i < 100; $i++) {
        if (!$disk_ids->{$i}) {
            return $format eq 'subvol' ? "subvol-$vmid-disk-$i" : "vm-$vmid-disk-$i";
        }
    }

    die "unable to allocate an image name for VM $vmid in storage '$storeid'\n";
}

sub zfs_get_latest_snapshot {
    my ($class, $scfg, $volname) = @_;

    # abort rollback if snapshot is not the latest
    my @params = ('-t', 'snapshot', '-o', 'name', '-s', 'creation');
    my $text = $class->zfs_request($scfg, undef, 'list', @params);
    my @snapshots = split(/\n/, $text);

    my $recentsnap;
    foreach (@snapshots) {
        if (/$scfg->{pool}\/$volname/) {
            s/^.*@//;
            $recentsnap = $_;
        }
    }

    return $recentsnap;
}

sub status {
    my ($class, $storeid, $scfg, $cache) = @_;

    my $total = 0;
    my $free = 0;
    my $used = 0;
    my $active = 0;

    eval {
	($free, $used) = $class->zfs_get_pool_stats($scfg);
	$active = 1;
	$total = $free + $used;
    };
    warn $@ if $@;

    return ($total, $free, $used, $active);
}

sub volume_size_info {
    my ($class, $scfg, $storeid, $volname, $timeout) = @_;

    my (undef, undef, undef, undef, undef, undef, $format) =
        $class->parse_volname($volname);

    my $attr = $format eq 'subvol' ? 'refquota' : 'volsize';
    my $text = $class->zfs_request($scfg, undef, 'get', '-Hp', $attr, "$scfg->{pool}/$volname");

    if ($text =~ /\s$attr\s(\d+)\s/) {
	return $1;
    }

    die "Could not get zfs volume size\n";
}

sub volume_snapshot {
    my ($class, $scfg, $storeid, $volname, $snap) = @_;

    $class->zfs_request($scfg, undef, 'snapshot', "$scfg->{pool}/$volname\@$snap");
}

sub volume_snapshot_delete {
    my ($class, $scfg, $storeid, $volname, $snap, $running) = @_;

    $class->deactivate_volume($storeid, $scfg, $volname, $snap, {});
    $class->zfs_request($scfg, undef, 'destroy', "$scfg->{pool}/$volname\@$snap");
}

sub volume_snapshot_rollback {
    my ($class, $scfg, $storeid, $volname, $snap) = @_;

    $class->zfs_request($scfg, undef, 'rollback', "$scfg->{pool}/$volname\@$snap");
}

sub volume_rollback_is_possible {
    my ($class, $scfg, $storeid, $volname, $snap) = @_; 
    
    my $recentsnap = $class->zfs_get_latest_snapshot($scfg, $volname);
    if ($snap ne $recentsnap) {
	die "can't rollback, more recent snapshots exist\n";
    }

    return 1; 
}

sub activate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;

    my @param = ('-o', 'name', '-H');

    my $text = $class->zfs_request($scfg, undef, 'zpool_list', @param);

    # Note: $scfg->{pool} can include dataset <pool>/<dataset>
    my $pool = $scfg->{pool};
    $pool =~ s!/.*$!!;

    if ($text !~ $pool) {
	run_command("zpool import -d /dev/disk/by-id/ -a");
    }
    return 1;
}

sub deactivate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;
    return 1;
}

sub activate_volume {
    my ($class, $storeid, $scfg, $volname, $snapname, $cache) = @_;
    return 1;
}

sub deactivate_volume {
    my ($class, $storeid, $scfg, $volname, $snapname, $cache) = @_;
    return 1;
}

sub clone_image {
    my ($class, $scfg, $storeid, $volname, $vmid, $snap) = @_;

    $snap ||= '__base__';

    my ($vtype, $basename, $basevmid, undef, undef, $isBase, $format) =
        $class->parse_volname($volname);

    die "clone_image only works on base images\n" if !$isBase;

    my $name = $class->zfs_find_free_diskname($storeid, $scfg, $vmid, $format);

    $class->zfs_request($scfg, undef, 'clone', "$scfg->{pool}/$basename\@$snap", "$scfg->{pool}/$name");

    return $name;
}

sub create_base {
    my ($class, $storeid, $scfg, $volname) = @_;

    my $snap = '__base__';

    my ($vtype, $name, $vmid, $basename, $basevmid, $isBase) =
        $class->parse_volname($volname);

    die "create_base not possible with base image\n" if $isBase;

    my $newname = $name;
    $newname =~ s/^vm-/base-/;

    my $newvolname = $basename ? "$basename/$newname" : "$newname";

    $class->zfs_request($scfg, undef, 'rename', "$scfg->{pool}/$name", "$scfg->{pool}/$newname");

    my $running  = undef; #fixme : is create_base always offline ?

    $class->volume_snapshot($scfg, $storeid, $newname, $snap, $running);

    return $newvolname;
}

sub volume_resize {
    my ($class, $scfg, $storeid, $volname, $size, $running) = @_;

    my $new_size = int($size/1024);

    my (undef, undef, undef, undef, undef, undef, $format) =
        $class->parse_volname($volname);

    my $attr = $format eq 'subvol' ? 'refquota' : 'volsize';

    $class->zfs_request($scfg, undef, 'set', "$attr=${new_size}k", "$scfg->{pool}/$volname");

    return $new_size;
}

sub volume_has_feature {
    my ($class, $scfg, $feature, $storeid, $volname, $snapname, $running) = @_;

    my $features = {
	snapshot => { current => 1, snap => 1},
	clone => { base => 1},
	template => { current => 1},
	copy => { base => 1, current => 1},
    };

    my ($vtype, $name, $vmid, $basename, $basevmid, $isBase) =
	$class->parse_volname($volname);

    my $key = undef;

    if ($snapname) {
	$key = 'snap';
    } else {
	$key = $isBase ? 'base' : 'current';
    }

    return 1 if $features->{$feature}->{$key};

    return undef;
}

1;
