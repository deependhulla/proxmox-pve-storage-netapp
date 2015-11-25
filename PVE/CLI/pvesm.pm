package PVE::CLI::pvesm;

use strict;
use warnings;

use Fcntl ':flock';
use File::Path;

use PVE::SafeSyslog;
use PVE::Cluster;
use PVE::INotify;
use PVE::RPCEnvironment;
use PVE::Storage;
use PVE::API2::Storage::Config;
use PVE::API2::Storage::Content;
use PVE::API2::Storage::Status;
use PVE::API2::Storage::Scan;
use PVE::JSONSchema qw(get_standard_option);

use PVE::CLIHandler;

use base qw(PVE::CLIHandler);

my $nodename = PVE::INotify::nodename();

__PACKAGE__->register_method ({
    name => 'path',
    path => 'path',
    method => 'GET',
    description => "Get filesystem path for specified volume",
    parameters => {
    	additionalProperties => 0,
	properties => {
	    volume => {
		description => "Volume identifier",
		type => 'string', format => 'pve-volume-id',
		completion => \&PVE::Storage::complete_volume,
	    },
	},
    },
    returns => { type => 'null' },

    code => sub {
	my ($param) = @_;

	my $cfg = PVE::Storage::config();

	my $path = PVE::Storage::path ($cfg, $param->{volume});

	print "$path\n";

	return undef;

    }});

my $print_content = sub {
    my ($list) = @_;

    my $maxlenname = 0;
    foreach my $info (@$list) {

	my $volid = $info->{volid};
	my $sidlen =  length ($volid);
	$maxlenname = $sidlen if $sidlen > $maxlenname;
    }

    foreach my $info (@$list) {
	next if !$info->{vmid};
	my $volid = $info->{volid};

	printf "%-${maxlenname}s %5s %10d %d\n", $volid,
	$info->{format}, $info->{size}, $info->{vmid};
    }

    foreach my $info (sort { $a->{format} cmp $b->{format} } @$list) {
	next if $info->{vmid};
	my $volid = $info->{volid};

	printf "%-${maxlenname}s %5s %10d\n", $volid,
	$info->{format}, $info->{size};
    }
};

my $print_status = sub {
    my $res = shift;

    my $maxlen = 0;
    foreach my $res (@$res) {
	my $storeid = $res->{storage};
	$maxlen = length ($storeid) if length ($storeid) > $maxlen;
    }
    $maxlen+=1;

    foreach my $res (sort { $a->{storage} cmp $b->{storage} } @$res) {
	my $storeid = $res->{storage};

	my $sum = $res->{used} + $res->{avail};
	my $per = $sum ? (0.5 + ($res->{used}*100)/$sum) : 100;

	printf "%-${maxlen}s %5s %1d %15d %15d %15d %.2f%%\n", $storeid,
	$res->{type}, $res->{active},
	$res->{total}/1024, $res->{used}/1024, $res->{avail}/1024, $per;
    }
};

our $cmddef = {
    add => [ "PVE::API2::Storage::Config", 'create', ['type', 'storage'] ],
    set => [ "PVE::API2::Storage::Config", 'update', ['storage'] ],
    remove => [ "PVE::API2::Storage::Config", 'delete', ['storage'] ],
    status => [ "PVE::API2::Storage::Status", 'index', [],
		{ node => $nodename }, $print_status ],
    list => [ "PVE::API2::Storage::Content", 'index', ['storage'],
	      { node => $nodename }, $print_content ],
    alloc => [ "PVE::API2::Storage::Content", 'create', ['storage', 'vmid', 'filename', 'size'],
	       { node => $nodename }, sub {
		   my $volid = shift;
		   print "sucessfuly created '$volid'\n";
	       }],
    free => [ "PVE::API2::Storage::Content", 'delete', ['volume'],
	      { node => $nodename } ],
    nfsscan => [ "PVE::API2::Storage::Scan", 'nfsscan', ['server'],
		 { node => $nodename }, sub  {
		     my $res = shift;

		     my $maxlen = 0;
		     foreach my $rec (@$res) {
			 my $len = length ($rec->{path});
			 $maxlen = $len if $len > $maxlen;
		     }
		     foreach my $rec (@$res) {
			 printf "%-${maxlen}s %s\n", $rec->{path}, $rec->{options};
		     }
		 }],
    glusterfsscan => [ "PVE::API2::Storage::Scan", 'glusterfsscan', ['server'],
		 { node => $nodename }, sub  {
		     my $res = shift;

		     foreach my $rec (@$res) {
			 printf "%s\n", $rec->{volname};
		     }
		 }],
    iscsiscan => [ "PVE::API2::Storage::Scan", 'iscsiscan', ['server'],
		   { node => $nodename }, sub  {
		       my $res = shift;

		       my $maxlen = 0;
		       foreach my $rec (@$res) {
			   my $len = length ($rec->{target});
			   $maxlen = $len if $len > $maxlen;
		       }
		       foreach my $rec (@$res) {
			   printf "%-${maxlen}s %s\n", $rec->{target}, $rec->{portal};
		       }
		   }],
    lvmscan => [ "PVE::API2::Storage::Scan", 'lvmscan', [],
		 { node => $nodename }, sub  {
		     my $res = shift;
		     foreach my $rec (@$res) {
			 printf "$rec->{vg}\n";
		     }
		 }],
    zfsscan => [ "PVE::API2::Storage::Scan", 'zfsscan', [],
		 { node => $nodename }, sub  {
		     my $res = shift;

		     foreach my $rec (@$res) {
			 printf "$rec->{pool}\n";
		     }
		 }],
    path => [ __PACKAGE__, 'path', ['volume']],
};

1;

__END__

=head1 NAME

pvesm - PVE Storage Manager

=head1 SYNOPSIS

=include synopsis

=head1 DESCRIPTION

=head2 Storage pools

Each storage pool is uniquely identified by its <STORAGE_ID>.

=head3 Storage content

A storage can support several content types, for example virtual disk
images, cdrom iso images, openvz templates or openvz root directories
(C<images>, C<iso>, C<vztmpl>, C<rootdir>).

=head2 Volumes

A volume is identified by the <STORAGE_ID>, followed by a storage type
dependent volume name, separated by colon. A valid <VOLUME_ID> looks like:

 local:230/example-image.raw

 local:iso/debian-501-amd64-netinst.iso

 local:vztmpl/debian-5.0-joomla_1.5.9-1_i386.tar.gz

 iscsi-storage:0.0.2.scsi-14f504e46494c4500494b5042546d2d646744372d31616d61

To get the filesystem path for a <VOLUME_ID> use:

 pvesm path <VOLUME_ID>


=head1 EXAMPLES

 # scan iscsi host for available targets
 pvesm iscsiscan -portal <HOST[:PORT]>

 # scan nfs server for available exports
 pvesm nfsscan <HOST>

 # add storage pools
 pvesm add <TYPE> <STORAGE_ID> <OPTIONS>
 pvesm add dir <STORAGE_ID> --path <PATH>
 pvesm add nfs <STORAGE_ID> --path <PATH> --server <SERVER> --export <EXPORT>
 pvesm add lvm <STORAGE_ID> --vgname <VGNAME>
 pvesm add iscsi <STORAGE_ID> --portal <HOST[:PORT]> --target <TARGET>

 # disable storage pools
 pvesm set <STORAGE_ID> --disable 1

 # enable storage pools
 pvesm set <STORAGE_ID> --disable 0

 # change/set storage options
 pvesm set <STORAGE_ID> <OPTIONS>
 pvesm set <STORAGE_ID> --shared 1
 pvesm set local --format qcow2
 pvesm set <STORAGE_ID> --content iso

 # remove storage pools - does not delete any data
 pvesm remove <STORAGE_ID>

 # alloc volumes
 pvesm alloc <STORAGE_ID> <VMID> <name> <size> [--format <raw|qcow2>]

 # alloc 4G volume in local storage - use auto generated name
 pvesm alloc local <VMID> '' 4G

 # free volumes (warning: destroy/deletes all volume data)
 pvesm free <VOLUME_ID>

 # list storage status
 pvesm status

 # list storage contents
 pvesm list <STORAGE_ID> [--vmid <VMID>]

 # list volumes allocated by VMID
 pvesm list <STORAGE_ID> --vmid <VMID>

 # list iso images
 pvesm list <STORAGE_ID> --iso

 # list openvz templates
 pvesm list <STORAGE_ID> --vztmpl

 # show filesystem path for a volume
 pvesm path <VOLUME_ID>

=include pve_copyright
