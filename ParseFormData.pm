#############################################################################
#
# Apache::ParseFormData
# Last Modification: Mon Jul 21 10:59:57 WEST 2003
#
# Copyright (c) 2003 Henrique Dias <hdias@aesbuc.pt>. All rights reserved.
# This module is free software; you can redistribute it and/or modify
# it under the same terms as Perl itself.
#
##############################################################################
package Apache::ParseFormData;

use strict;
use Apache::Const -compile => qw(M_POST M_GET :log);
use APR::Table;
use IO::File;
use POSIX qw(tmpnam);
require Exporter;
our @ISA = qw(Exporter Apache::RequestRec);
our %EXPORT_TAGS = ( 'all' => [ qw() ] );
our @EXPORT = qw();
our $VERSION = '0.02';
require 5;

use constant NELTS => 10;
use constant BUFFLENGTH => 1024;

sub new {
	my $proto = shift;
	my $class = ref($proto) || $proto;
	my $self  = shift;
	my %args = (
		temp_dir        => "/tmp",
		disable_uploads => 0,
		post_max        => 0,
		@_,
	);
	my $table = APR::Table::make($self->pool, NELTS);
	$self->pnotes('ap_req' => $table);
	bless ($self, $class);

	if($self->method_number == Apache::M_POST) {
		&content($self, \%args);
	} elsif($self->method_number == Apache::M_GET) {
		my $data = $self->args();
		&_parse_query($self, $data) if($data);
	}
	return($self);
}

sub DESTROY {  
	my $self = shift;
	for my $upload ($self->upload()) {
		my $path = $upload->[2];
		unlink($path) if(-e $path);
	}
}

sub parms { $_[0]->pnotes('ap_req') }

sub _parse_query {
	my $r = shift;
	my $query_string = shift;

	for(split(/&/, $query_string)) {
		my ($n, $v) = split(/=/);
		defined($v) or $v = "";
		&decode_chars($n);
		&decode_chars($v);
		$r->param($n => $v);
	}
	return();
}

sub decode_chars {
	$_[0] =~ tr/+/ /;
	$_[0] =~ s/%([\dA-Fa-f][\dA-Fa-f])/pack("C", hex($1))/egi;
}

sub upload { @{$_[0]->pnotes('upload')} }

sub content {
	my $r = shift;
	my $args = shift;

	my $buf = "";
	$r->setup_client_block;
	$r->should_client_block or return '';
	my $ct = $r->headers_in->get('content-type');
	if($ct =~ /^multipart\/form-data; boundary=(.+)$/) {
		my $boundary = $1;
		my $lenbdr = length("--$boundary");
		$r->get_client_block($buf, $lenbdr+2);
		$buf = substr($buf, $lenbdr);
		$buf =~ s/[\n\r]+//;
		my $iter = -1;
		my @data = ();
		&multipart_data($r, $args, \@data, $boundary, BUFFLENGTH, 1, $buf, $iter);
		my @uploads = ();
		for(@data) {
			if(exists($_->{'headers'}->{'content-disposition'})) {
				my @a = split(/ *; */, $_->{'headers'}->{'content-disposition'});
				if(shift(@a) eq "form-data") {
					if(scalar(@a) == 1) {
						my ($key) = ($a[0] =~ /name=\"([^\"]+)\"/);
						$r->param($key => $_->{'values'} || "");
					} else {
						my $fh = $_->{'values'}->[0];
						my $path = $_->{'values'}->[1];
						seek($fh, 0, 0);
						my %hash = (
							filename => "",
							type     => exists($_->{'headers'}->{'content-type'}) ? $_->{'headers'}->{'content-type'} : "",
							size     => ($fh->stat())[7],
						);
						my $param = "";
						for(@a) {
							my ($name, $value) = (/([^=]+)=\"([^\"]+)\"/);
							if($name eq "name") {
								push(@uploads, [$value, $fh, $path]);
								$param = $value;
							} else {
								$hash{$name} = $value;
							}
						}
						$r->param($param => \%hash);
					}
				}
			}
		}
		$r->pnotes('upload' => \@uploads);
		return();
	} else {
		my $len = $r->headers_in->get('content-length');
		$r->get_client_block($buf, $len);
		&_parse_query($r, $buf) if($buf);
	}
	return $buf;
}

sub extract_headers {
	my $raw = shift;
	my %hash = ();
	for(split(/\r?\n/, $raw)) {
		s/[\r\n]+$//;
		$_ or next;
		my ($h, $v) = split(/ *: */, $_, 2);
		$hash{lc($h)} = $v;
	}
	$_[0] = \%hash;
	return(exists($hash{'content-type'}));
}

sub output_data {
	my $dest = shift;
	my $data = shift;

	if(ref($dest->{values}) eq "ARRAY") {
		my $fh = $dest->{values}->[0];
		print $fh $data;
	} else { $dest->{values} .= $data; }
}

sub new_tmp_file {
	my $temp_dir = shift;
	my $data = shift;

	my $path = "";
	my $fh;
	my $i = 0;
	do {
		$i < 3 or last;
		my $name = tmpnam(); 
		$name = (split("/", $name))[-1];
		$path = join("/", $temp_dir, $name);
		$i++;
	} until($fh = IO::File->new($path, O_RDWR|O_CREAT|O_EXCL));
	defined($fh) or return("Couldn't create temporary file: $path");
	binmode($fh);
	$fh->autoflush(1);
	$data->{values} = [$fh, $path];
	return();
}

sub multipart_data {
	my $r = shift;
	my $args = shift;
	my $data = shift;
	my $boundary = shift;
	my $len = shift;
	my $h = shift;
	my $buff = shift;

	my ($part, $content) = ($buff, "");
	while($r->get_client_block($buff, $len)) {
		$part .= $buff;
		if($h) {
			if($part =~ /\r?\n\r?\n/) {
				my ($left, $right) = ($`, $');
				$left =~ s/[\r\n]+$//;
				$_[0]++;
				push(@{$data}, {values => "", headers => {}});
				if(&extract_headers($left, $data->[$_[0]]->{'headers'})) {
					if(my $error = &new_tmp_file($args->{'temp_dir'}, $data->[$_[0]])) { $r->log->warn($error), next; }
				}
				$part = $content = $right;
				$h = 0;
			} else { next; }
		}
		if($part =~ /\r?\n--$boundary\r?\n/) {
			my ($left, $right) = ($`, $');
			&output_data($data->[$_[0]], $left) if($left);
			&multipart_data($r, $args, $data, $boundary, $len, 1, $right, $_[0]);
			$part = "";
		}
		if($part) {
			$content = substr($part, 0, int($len/2));
			&output_data($data->[$_[0]], $content) if($content);
			$part = substr($part, int($len/2));
		}
	}
	if($h && $part =~ /\r?\n\r?\n/) {
		my ($left, $right) = ($`, $');
		$left =~ s/[\r\n]+$//;
		$_[0]++;
		push(@{$data}, {values => "", headers => {}});
		if(&extract_headers($left, $data->[$_[0]]->{'headers'})) {
			if(my $error = &new_tmp_file($args->{'temp_dir'}, $data->[$_[0]])) { $r->log->warn($error), next; }
		}
		$part = $right;
		$h = 0;
	}
	if($part =~ /\r?\n--$boundary\r?\n/) {
		my ($left, $right) = ($`, $');
		&output_data($data->[$_[0]], $left) if($left);
		&multipart_data($r, $args, $data, $boundary, $len, 1, $right, $_[0]);
		$part = "";
	}
	if($part =~ /\r?\n--$boundary--[\r\n]*/) {
		my $left = $`;
		&output_data($data->[$_[0]], $left) if($left);
	}
	return();
}

sub delete {
	my $self = shift;
	map { $self->parms->unset($_); } @_;
	return();
}

sub delete_all {
	my $self = shift;
	$self->parms->clear();
	return();
}

sub param {
	my $self = shift;

	if(scalar(@_) > 1) {
		my %hash = @_;
		while(my ($k, $v) = each(%hash)) {
			my @transfer = (ref($v) eq "HASH") ? %{$v} : (ref($v) eq "ARRAY") ? @{$v} : ($v);
			unless($self->parms->get($k)) {
				my $first = shift(@transfer);
				$self->parms->set($k => $first);
			}
			map { $self->parms->add($k, $_); } @transfer;
		}
		return();
	}
	if(scalar(@_) == 1) {
		my $k = shift;
		return($self->parms->get($k));
	}
	return(keys(%{$self->parms}));
}

1;
__END__

=head1 NAME

Apache::ParseFormData - Perl extension for dealing with client request data

=head1 SYNOPSIS

  use Apache::RequestRec ();
  use Apache::RequestUtil ();
  use Apache::RequestIO ();
  use Apache::Log;
  use Apache::Const -compile => qw(DECLINED OK);
  use Apache::ParseFormData;

  sub handler {
    my $r = shift;
    my $apr = Apache::ParseFormData->new($r);

    my $scalar = 'abc';
    $apr->param('scalar_test' => $scalar);
    my $s_test = $apr->param('scalar_test');
    print $s_test;

    my @array = ('a', 'b', 'c');
    $apr->param('array_test' => \@array);
    my @a_test = $apr->param('array_test');
    print $a_test[0];

    my %hash = {
      a => 1,
      b => 2,
      c => 3,
    };
    $apr->param('hash_test' => \%hash);
    my %h_test = $apr->param('hash_test');
    print $h_test{'a'};

    $apr->notes->clear();

    return Apache::OK;
  }

=head1 ABSTRACT

The Apache::ParseFormData module allows you to easily decode and parse    
form and query data, even multipart forms generated by "file upload".
This module only work with mod_perl 2.

=head1 DESCRIPTION

C<Apache::ParseFormData> extension parses a GET and POST requests, with
multipart form data input stream, and saves any files/parameters
encountered for subsequent use.

=head1 Apache::ParseFormData METHODS 


=head2 new

Create a new I<Apache::ParseFormData> object. The methods from I<Apache>
class are inherited. The optional arguments which can be passed to the 
method are the following:

=over 1

=item temp_dir

Directory where the upload files are stored.

=back

=head2 param

Like I<CGI.pm> you can add or modify the value of parameters within your
script.

  my $scalar = 'abc';
  $apr->param('scalar_test' => $scalar);
  my $s_test = $apr->param('scalar_test');
  print $s_test;

  my @array = ('a', 'b', 'c');
  $apr->param('array_test' => \@array);
  my @a_test = $apr->param('array_test');
  print $a_test[0];

  my %hash = {
    a => 1,
    b => 2,
    c => 3,
  };
  $apr->param('hash_test' => \%hash);
  my %h_test = $apr->param('hash_test');
  print $h_test{'a'};

You can create a parameter with multiple values by passing additional
arguments:

  $apr->param(
    'color'    => "red",
    'numbers'  => [0,1,2,3,4,5,6,7,8,9],
    'language' => "perl",
  );

Fetching the names of all the parameters passed to your script:

  foreach my $name (@names) {
    my $value = $apr->param($name);
    print "$name => $value\n";
  }

=head2 delete

To delete a parameter provide the name of the parameter:

  $apr->param("color");

You can delete multiple values:

  $apr->param("color", "nembers");

=head2 delete_all

This method clear all of the parameters

=head2 upload

You can access the name of an uploaded file with the param method, just
like the value of any other form element.

  my %file_hash = $apr->param('file');
  my $filename = $file_hash{'filename'};
  my $content_type = $file_hash{'type'};
  my $size = $file_hash{'size'};

  for my $upload ($apr->upload()) {
    my $form_name = $upload->[0];
    my $fh = $upload->[1];
    my $path = $upload->[2];

    while(<$fh>) {
      print $_;
    }

    my %file_hash = $apr->param($form_name);
    my $filename = $file_hash{'filename'};
    my $content_type = $file_hash{'type'};
    my $size = $file_hash{'size'};
    unlink($path);
  }

=head1 SEE ALSO

libapreq, Apache::Request

=head1 CREDITS

This interface is based on the libapreq by Doug MacEachern.

=head1 AUTHOR

Henrique Dias, E<lt>hdias@aesbuc.ptE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright 2003 by Henrique Dias
 
This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
