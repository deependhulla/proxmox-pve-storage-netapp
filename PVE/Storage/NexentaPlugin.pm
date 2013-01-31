package PVE::Storage::NexentaPlugin;

use strict;
use warnings;
use IO::File;
use HTTP::Request;
use LWP::UserAgent;
use MIME::Base64;
use JSON;
use PVE::Tools qw(run_command file_read_firstline trim dir_glob_regex dir_glob_foreach);
use PVE::Storage::Plugin;
use PVE::JSONSchema qw(get_standard_option);

use base qw(PVE::Storage::Plugin);

sub nexenta_request {
    my ($scfg, $method, $object, @params) = @_;

    my $apicall = { method => $method, object => $object, params => [ @params ] };

    my $json = encode_json($apicall);

    my $uri = ($scfg->{ssl} ? "https" : "http") . "://" . $scfg->{portal} . ":2000/rest/nms/";
    my $req = HTTP::Request->new('POST', $uri);

    $req->header('Content-Type' => 'application/json');
    $req->content($json);
    my $token = encode_base64("$scfg->{login}:$scfg->{password}");
    $req->header(Authorization => "Basic $token");

    my $ua = LWP::UserAgent->new; # You might want some options here
    my $res = $ua->request($req);
    die $res->content if !$res->is_success;

    my $obj = eval { from_json($res->content); };
    die "JSON not valid. Content: " . $res->content if ($@);
    die "Nexenta API Error: $obj->{error}->{message}\n" if $obj->{error}->{message};
    return $obj->{result};
}


sub nexenta_get_zvol_size {
    my ($scfg, $zvol) = @_;

    return nexenta_request($scfg, 'get_child_prop', 'zvol', $zvol, 'size_bytes');
}

sub nexenta_get_zvol_props {
    my ($scfg, $zvol) = @_;

    my $props = nexenta_request($scfg, 'get_child_props', 'zvol', $zvol, '');
    return $props;
}

sub nexenta_list_lun_mapping_entries {
    my ($scfg, $zvol) = @_;

    return nexenta_request($scfg, 'list_lun_mapping_entries', 'scsidisk', "$scfg->{pool}/$zvol");
}

sub nexenta_add_lun_mapping_entry {
    my ($scfg, $zvol) = @_;

    nexenta_request($scfg, 'add_lun_mapping_entry', 'scsidisk', 
			   "$scfg->{pool}/$zvol", { target_group => "All" });
}

sub nexenta_delete_lu {
    my ($scfg, $zvol) = @_;

    nexenta_request($scfg, 'delete_lu', 'scsidisk', "$scfg->{pool}/$zvol");
}

sub nexenta_create_lu {
    my ($scfg, $zvol) = @_;

    nexenta_request($scfg, 'create_lu', 'scsidisk', "$scfg->{pool}/$zvol", {});
}

sub nexenta_import_lu {
    my ($scfg, $zvol) = @_;

    nexenta_request($scfg, 'import_lu', 'scsidisk', "$scfg->{pool}/$zvol");
}

sub nexenta_create_zvol {
    my ($scfg, $zvol, $size) = @_;

    nexenta_request($scfg, 'create', 'zvol', "$scfg->{pool}/$zvol", "${size}KB",
		    $scfg->{blocksize}, 1);
}

sub nexenta_delete_zvol {
    my ($scfg, $zvol) = @_;

    nexenta_request($scfg, 'destroy', 'zvol', "$scfg->{pool}/$zvol", '-r');
}

sub nexenta_list_zvol {
    my ($scfg) = @_;

    my $zvols = nexenta_request($scfg, 'get_names', 'zvol', '');
    return undef if !$zvols;

    my $list = {};
    foreach my $zvol (@$zvols) {
	my @values = split('/', $zvol);

	my $pool = $values[0];
	my $image = $values[1];
	my $owner;
	if ($image =~ m/^(vm-(\d+)-\S+)$/) {
	    $owner = $2;
	}

	my $props = nexenta_get_zvol_props($scfg, $zvol);

	$list->{$pool}->{$image} = {
	    name => $image,
	    size => $props->{size_bytes},
	    parent => $props->{origin},
	    format => 'raw',
	    vmid => $owner
	};
    }

    return $list;
}

# Configuration

sub type {
    return 'nexenta';
}

sub plugindata {
    return {
	content => [ {images => 1}, { images => 1 }],
    };
}

sub properties {
    return {
	login => {
	    description => "login",
	    type => 'string',
	},
	password => {
	    description => "password",
	    type => 'string',
	},
	blocksize => {
	    description => "block size",
	    type => 'string',
	},
	ssl => {
	    description => "ssl",
	    type => 'boolean',
	},
    };
}

sub options {
    return {
        nodes => { optional => 1 },
        disable => { optional => 1 },
	target => { fixed => 1 },
        portal => { fixed => 1 },
	login => { fixed => 1 },
	password => { fixed => 1 },
        pool => { fixed => 1 },
        blocksize => { fixed => 1 },
        ssl => { optional => 1 },
	content => { optional => 1 },
    };
}

# Storage implementation

sub parse_volname {
    my ($class, $volname) = @_;

    if ($volname =~ m/^(vm-(\d+)-\S+)$/) {
	return ('images', $1, $2);
    }

    die "unable to parse nexenta volume name '$volname'\n";
}

sub path {
    my ($class, $scfg, $volname) = @_;

    my ($vtype, $name, $vmid) = $class->parse_volname($volname);

    my $target = $scfg->{target};
    my $portal = $scfg->{portal};

    my $map = nexenta_list_lun_mapping_entries($scfg, $name);
    die "could not find lun number" if !$map;
    my $lun = @$map[0]->{lun};
    $lun =~ m/^(\d+)$/ or die "lun is not OK\n";
    $lun = $1;    
    my $path = "iscsi://$portal/$target/$lun";

    return ($path, $vmid, $vtype);
}

sub create_base {
    my ($class, $storeid, $scfg, $volname) = @_;

    die "not implemented";
}

sub clone_image {
    my ($class, $scfg, $storeid, $volname, $vmid) = @_;

    die "not implemented";
}

sub alloc_image {
    my ($class, $storeid, $scfg, $vmid, $fmt, $name, $size) = @_;

    die "unsupported format '$fmt'" if $fmt ne 'raw';

    die "illegal name '$name' - sould be 'vm-$vmid-*'\n"
	if $name && $name !~ m/^vm-$vmid-/;

    my $nexentapool = $scfg->{'pool'};

    if (!$name) {
	my $volumes = nexenta_list_zvol($scfg);
	die "unable de get zvol list" if !$volumes;

	for (my $i = 1; $i < 100; $i++) {
	    my $tn = "vm-$vmid-disk-$i";
	    if (!defined ($volumes->{$nexentapool}->{$tn})) {
		$name = $tn;
		last;
	    }
	}
    }

    die "unable to allocate an image name for VM $vmid in storage '$storeid'\n"
	if !$name;

    nexenta_create_zvol($scfg, $name, $size);
    nexenta_create_lu($scfg, $name);
    nexenta_add_lun_mapping_entry($scfg, $name);

    return $name;
}

sub free_image {
    my ($class, $storeid, $scfg, $volname) = @_;

    my ($vtype, $name, $vmid) = $class->parse_volname($volname);

    nexenta_delete_lu($scfg, $name);
    nexenta_delete_zvol($scfg, $name);

    return undef;
}

sub list_images {
    my ($class, $storeid, $scfg, $vmid, $vollist, $cache) = @_;

    $cache->{nexenta} = nexenta_list_zvol($scfg) if !$cache->{nexenta};
    my $nexentapool = $scfg->{pool};
    my $res = [];
    if (my $dat = $cache->{nexenta}->{$nexentapool}) {
	foreach my $image (keys %$dat) {

            my $volname = $dat->{$image}->{name};

            my $volid = "$storeid:$volname";

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

sub nexenta_parse_size {
    my ($text) = @_;

    return 0 if !$text;

    if ($text =~ m/^(\d+)([TGMK])?$/) {
	my ($size, $unit) = ($1, $2);
	return $size if !$unit;
	if ($unit eq 'K') {
	    $size *= 1024;
	} elsif ($unit eq 'M') {
	    $size *= 1024*1024;
	} elsif ($unit eq 'G') {
	    $size *= 1024*1024*1024;
	} elsif ($unit eq 'T') {
	    $size *= 1024*1024*1024*1024;
	}
	return $size;
    } else {
	return 0;
    }
}
sub status {
    my ($class, $storeid, $scfg, $cache) = @_;

    my $total = 0;
    my $free = 0;
    my $used = 0;
    my $active = 0;

    eval {
	my $map = nexenta_request($scfg, 'get_child_props', 'volume', $scfg->{pool}, '');
	$active = 1;
	$total = nexenta_parse_size($map->{size});
	$used = nexenta_parse_size($map->{used});
	$free = $total - $used;
    };
    warn $@ if $@;

    return ($total, $free, $used, $active);
}

sub activate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;
    return 1;
}

sub deactivate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;
    return 1;
}

sub activate_volume {
    my ($class, $storeid, $scfg, $volname, $exclusive, $cache) = @_;
    return 1;
}

sub deactivate_volume {
    my ($class, $storeid, $scfg, $volname, $exclusive, $cache) = @_;
    return 1;
}

sub volume_size_info {
    my ($class, $scfg, $storeid, $volname, $timeout) = @_;

    return nexenta_get_zvol_size($scfg, "$scfg->{pool}/$volname"),
}

sub volume_resize {
    my ($class, $scfg, $storeid, $volname, $size, $running) = @_;

    nexenta_request($scfg, 'set_child_prop', 'zvol', "$scfg->{pool}/$volname", 'volsize', ($size/1024) . 'KB');
}

sub volume_snapshot {
    my ($class, $scfg, $storeid, $volname, $snap, $running) = @_;

    nexenta_request($scfg, 'create_snapshot', 'zvol', "$scfg->{pool}/$volname", $snap, '');
}

sub volume_snapshot_rollback {
    my ($class, $scfg, $storeid, $volname, $snap) = @_;

    nexenta_delete_lu($scfg, $volname);

    nexenta_request($scfg, 'rollback', 'snapshot', "$scfg->{pool}/$volname\@$snap", '');
    
    nexenta_import_lu($scfg, $volname);
    
    nexenta_add_lun_mapping_entry($scfg, $volname);
}

sub volume_snapshot_delete {
    my ($class, $scfg, $storeid, $volname, $snap, $running) = @_;

    nexenta_request($scfg, 'destroy', 'snapshot', "$scfg->{pool}/$volname\@$snap", '');
}

sub volume_has_feature {
    my ($class, $scfg, $feature, $storeid, $volname, $snapname, $running) = @_;

    my $features = {
        snapshot => { current => 1, snap => 1},
        clone => { snap => 1},
    };

    my $snap = $snapname ? 'snap' : 'current';
    return 1 if $features->{$feature}->{$snap};

    return undef;
}

1;
