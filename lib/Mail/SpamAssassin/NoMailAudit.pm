# <@LICENSE>
# ====================================================================
# The Apache Software License, Version 1.1
# 
# Copyright (c) 2000 The Apache Software Foundation.  All rights
# reserved.
# 
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
# 
# 1. Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
# 
# 2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in
#    the documentation and/or other materials provided with the
#    distribution.
# 
# 3. The end-user documentation included with the redistribution,
#    if any, must include the following acknowledgment:
#       "This product includes software developed by the
#        Apache Software Foundation (http://www.apache.org/)."
#    Alternately, this acknowledgment may appear in the software itself,
#    if and wherever such third-party acknowledgments normally appear.
# 
# 4. The names "Apache" and "Apache Software Foundation" must
#    not be used to endorse or promote products derived from this
#    software without prior written permission. For written
#    permission, please contact apache@apache.org.
# 
# 5. Products derived from this software may not be called "Apache",
#    nor may "Apache" appear in their name, without prior written
#    permission of the Apache Software Foundation.
# 
# THIS SOFTWARE IS PROVIDED ``AS IS'' AND ANY EXPRESSED OR IMPLIED
# WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
# OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
# DISCLAIMED.  IN NO EVENT SHALL THE APACHE SOFTWARE FOUNDATION OR
# ITS CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
# SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
# LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF
# USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
# ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
# OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT
# OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
# SUCH DAMAGE.
# ====================================================================
# 
# This software consists of voluntary contributions made by many
# individuals on behalf of the Apache Software Foundation.  For more
# information on the Apache Software Foundation, please see
# <http://www.apache.org/>.
# 
# Portions of this software are based upon public domain software
# originally written at the National Center for Supercomputing Applications,
# University of Illinois, Urbana-Champaign.
# </@LICENSE>

# Mail message object, used by SpamAssassin.  This was written to eliminate, as
# much as possible, SpamAssassin's dependency on Mail::Audit and the
# Mail::Internet, Net::SMTP, etc. module set it requires.
#
# This is more efficient (less modules, dependencies and unused code loaded),
# and fixes some bugs found in Mail::Audit, as well as working around some
# side-effects of features of Mail::Internet that we don't use.  It's also more
# lenient about the incoming message, in the spirit of the IETF dictum 'be
# liberal in what you accept'.
#
package Mail::SpamAssassin::NoMailAudit;

use strict;
use bytes;
use Fcntl qw(:DEFAULT :flock);

use Mail::SpamAssassin::Message;
use Mail::SpamAssassin::MIME;
use Mail::SpamAssassin::MIME::Parser;

@Mail::SpamAssassin::NoMailAudit::ISA = (
  'Mail::SpamAssassin::Message'
);

# ---------------------------------------------------------------------------

sub new {
  my $class = shift;
  my %opts = @_;

  my $self = $class->SUPER::new();

  $self->{is_spamassassin_wrapper_object} = 1;
  $self->{has_spamassassin_methods} = 1;
  $self->{headers_pristine} = '';
  $self->{headers} = { };
  $self->{header_order} = [ ];

  bless ($self, $class);

  # data may be filehandle (default stdin) or arrayref
  my $data = $opts{data} || \*STDIN;

  if (ref $data eq 'ARRAY') {
    $self->{textarray} = $data;
  } elsif (ref $data eq 'GLOB') {
    if (defined fileno $data) {
      $self->{textarray} = [ <$data> ];
    }
  }

  # Parse the message for MIME parts
  $self->{mime_parts} = Mail::SpamAssassin::MIME::Parser->parse(join("", @{$self->{textarray}}));

  # Parse the message to get header information
  $self->parse_headers();
  return $self;
}

# ---------------------------------------------------------------------------

sub create_new {
  my ($self, @args) = @_;
  return Mail::SpamAssassin::NoMailAudit->new(@args);
}

# ---------------------------------------------------------------------------

sub get_mail_object {
  my ($self) = @_;
  return $self;
}

# ---------------------------------------------------------------------------

sub parse_headers {
  my ($self) = @_;
  local ($_);

  $self->{headers_pristine} = '';
  $self->{headers} = { };
  $self->{header_order} = [ ];
  my ($prevhdr, $hdr, $val, $entry);

  while (defined ($_ = shift @{$self->{textarray}})) {
    # absolutely unmodified!
    $self->{headers_pristine} .= $_;

    # warn "parse_headers $_";
    if (/^\r*$/) { last; }

    $entry = $hdr = $val = undef;

    if (/^\s/) {
      if (defined $prevhdr) {
	$hdr = $prevhdr; $val = $_;
        $val =~ s/\r+\n/\n/gs;          # trim CRs, we don't want them
	$entry = $self->{headers}->{$hdr};
	$entry->{$entry->{count} - 1} .= $val;
	next;

      } else {
	$hdr = "X-Mail-Format-Warning";
	$val = "No previous line for continuation: $_";
	$entry = $self->_get_or_create_header_object ($hdr);
	$entry->{added} = 1;
      }

    } elsif (/^From /) {
      $self->{from_line} = $_;
      next;

    } elsif (/^([\x21-\x39\x3B-\x7E]+):\s*(.*)$/s) {
      # format of a header, as defined by RFC 2822 section 3.6.8;
      # 'Any character except controls, SP, and ":".'
      $hdr = $1; $val = $2;
      $val =~ s/\r+//gs;          # trim CRs, we don't want them
      $entry = $self->_get_or_create_header_object ($hdr);
      $entry->{original} = 1;

    } else {
      $hdr = "X-Mail-Format-Warning";
      $val = "Bad RFC2822 header formatting in $_";
      $entry = $self->_get_or_create_header_object ($hdr);
      $entry->{added} = 1;
    }

    $self->_add_header_to_entry ($entry, $hdr, $val);
    $prevhdr = $hdr;
  }
}

sub _add_header_to_entry {
  my ($self, $entry, $hdr, $line, $order) = @_;

  # Do a normal push if no specific order # is set.
  $order ||= @{$self->{header_order}};

  # ensure we have line endings
  if ($line !~ /\n$/s) { $line .= "\n"; }

  # Store this header
  $entry->{$entry->{count}} = $line;

  # Push the header and which count it is in header_order
  splice @{$self->{header_order}}, $order, 0, $hdr.":".$entry->{count};

  # Increase the count of this header type
  $entry->{count}++;
}

sub _get_or_create_header_object {
  my ($self, $hdr) = @_;

  if (!defined $self->{headers}->{$hdr}) {
    $self->{headers}->{$hdr} = {
              'count' => 0,
              'added' => 0,
              'original' => 0
    };
  }
  return $self->{headers}->{$hdr};
}

# ---------------------------------------------------------------------------

sub _get_header_list {
  my ($self, $hdr, $header_name_only) = @_;

  # OK, we want to do a case-insensitive match here on the header name
  # So, first I'm going to pick up an array of the actual capitalizations used:
  my $lchdr = lc $hdr;
  my @cap_hdrs = grep(lc($_) eq $lchdr, keys(%{$self->{headers}}));

  # If the request is just for the list of headers names that matched only ...
  if ( defined $header_name_only && $header_name_only ) {
    return @cap_hdrs;
  }
  else {
    # return the values in each of the headers
    return map($self->{headers}->{$_},@cap_hdrs);
  }
}

sub get_pristine_header {
  my ($self, $hdr) = @_;
  my(@ret) = $self->{headers_pristine} =~ /^(?:$hdr:[ ]+(.*\n(?:\s+\S.*\n)*))/mig;
  if (@ret) {
    return wantarray ? @ret : $ret[0];
  }
  else {
    return $self->get_header($hdr);
  }
}

sub get_header {
  my ($self, $hdr) = @_;

  # And now pick up all the entries into a list
  my @entries = $self->_get_header_list($hdr);

  if (!wantarray) {
      # If there is no header like that, return undef
      if (scalar(@entries) < 1 ) { return undef; }
      foreach my $entry (@entries) {
	  if($entry->{count} > 0) {
	    my $ret = $entry->{0};
            $ret =~ s/^\s+//;
            $ret =~ s/\n\s+/ /g;
	    return $ret;
	  }
      }
      return undef;

  } else {

      if(scalar(@entries) < 1) { return ( ); }

      my @ret = ();
      # loop through each entry and collect all the individual matching lines
      foreach my $entry (@entries)
      {
	  foreach my $i (0 .. ($entry->{count}-1)) {
		my $ret = $entry->{$i};
                $ret =~ s/^\s+//;
                $ret =~ s/\n\s+/ /g;
	  	push (@ret, $ret);
          }
      }

      return @ret;
  }
}

sub put_header {
  my ($self, $hdr, $text, $order) = @_;

  my $entry = $self->_get_or_create_header_object ($hdr);
  $self->_add_header_to_entry ($entry, $hdr, $text, $order);
  if (!$entry->{original}) { $entry->{added} = 1; }
}

sub get_all_headers {
  my ($self) = @_;

  my @lines = ();
  # warn "JMD".join (' ', caller);

  push(@lines, $self->{from_line}) if ( defined $self->{from_line} );
  foreach my $hdrcode (@{$self->{header_order}}) {
    $hdrcode =~ /^([^:]+):(\d+)$/ or next;

    my $hdr = $1;
    my $num = $2;
    my $entry = $self->{headers}->{$hdr};
    next unless defined($entry);

    my $text = $hdr.": ".$entry->{$num};
    if ($text !~ /\n$/s) { $text .= "\n"; }
    push (@lines, $text);
  }

  if (wantarray) {
    return @lines;
  } else {
    return join ('', @lines);
  }
}

sub replace_header {
  my ($self, $hdr, $text) = @_;

  # Figure out where the first case insensitive header of this name is stored.
  # We'll use this to add the new header with the same case and in the order.
  my($casehdr,$order) = ($hdr,undef);
  my $lchdr = lc "$hdr:0"; # just lc it once

  # Now find the header
  for ( my $count = 0; $count <= @{$self->{header_order}}; $count++ ) {
    next unless (lc $self->{header_order}->[$count] eq $lchdr);

    # Remember where in the order the header is, and the case of said header.
    $order = $count;
    ($casehdr = $self->{header_order}->[$count]) =~ s/:\d+$//;

    last;
  }

  # Remove all instances of this header
  $self->delete_header ($hdr);

  # Add the new header with correctly cased header and in the right place
  return $self->put_header($casehdr, $text, $order);
}

sub delete_header {
  my ($self, $hdr) = @_;

  # Delete all versions of the header, case insensitively
  foreach my $dhdr ( $self->_get_header_list($hdr,1) ) {
    @{$self->{header_order}} = grep( rindex($_,"$dhdr:",0) != 0, @{$self->{header_order}} );
    delete $self->{headers}->{$dhdr};
  }
}

sub get_body {
  my ($self) = @_;
  return $self->{textarray};
}

sub replace_body {
  my ($self, $aryref) = @_;
  $self->{textarray} = $aryref;
}

# ---------------------------------------------------------------------------
# bonus, not-provided-in-Mail::Audit methods.

sub get_pristine {
  my ($self) = @_;
  return join ('', $self->{headers_pristine}, @{ $self->{textarray} });
}

sub get_pristine_body {
  my ($self) = @_;
  return join ('', @{ $self->{textarray} });
}

sub as_string {
  my ($self) = @_;
  return join ('', $self->get_all_headers(), "\n",
                @{$self->get_body()});
}

sub replace_original_message {
  my ($self, $data) = @_;

  if (ref $data eq 'ARRAY') {
    $self->{textarray} = $data;
  } elsif (ref $data eq 'GLOB') {
    if (defined fileno $data) {
      $self->{textarray} = [ <$data> ];
    }
  }

  $self->parse_headers();
}

# ---------------------------------------------------------------------------
# Mail::Audit emulation methods.

sub get { shift->get_header(@_); }
sub header { shift->get_all_headers(@_); }

sub body {
  my ($self) = shift;
  my $replacement = shift;

  if (defined $replacement) {
    $self->replace_body ($replacement);
  } else {
    return $self->get_body();
  }
}

sub ignore {
  my ($self) = @_;
  exit (0) unless $self->{noexit};
}

sub print {
  my ($self, $fh) = @_;
  print $fh $self->as_string();
}

# ---------------------------------------------------------------------------

sub accept {
  my $self = shift;
  my $file = shift;

  # we don't support maildir or qmail here yet. use the real Mail::Audit
  # for those.

  # note that we cannot use fcntl() locking portably from perl. argh!
  # if this is an issue, we will have to enforce use of procmail for
  # local delivery to mboxes.

  {
    my $gotlock = $self->dotlock_lock ($file);
    my $nodotlocking = 0;

    if (!defined $gotlock) {
      # dot-locking not supported here (probably due to file permissions
      # on the /var/spool/mail dir).  just use flock().
      $nodotlocking = 1;
    }

    local $SIG{TERM} = sub { $self->dotlock_unlock (); die "killed"; };
    local $SIG{INT} = sub { $self->dotlock_unlock (); die "killed"; };

    if ($gotlock || $nodotlocking) {
      my $umask = umask 077;
      if (!open (MBOX, ">>$file")) {
	umask $umask;
        die "Couldn't open $file: $!";
      }
      umask $umask;

      flock(MBOX, LOCK_EX) or warn "failed to lock $file: $!";
      print MBOX $self->as_string()."\n";
      flock(MBOX, LOCK_UN) or warn "failed to unlock $file: $!";
      close MBOX;

      if (!$nodotlocking) {
        $self->dotlock_unlock ();
      }

      if (!$self->{noexit}) { exit 0; }
      return;

    } else {
      die "Could not lock $file: $!";
    }
  }
}

sub dotlock_lock {
  my ($self, $file) = @_;

  my $lockfile = $file.".lock";
  my $locktmp = $file.".lk.$$.".time();
  my $gotlock = 0;
  my $retrylimit = 30;

  my $umask = 0;
  if (!sysopen (LOCK, $locktmp, O_WRONLY | O_CREAT | O_EXCL, 0644)) {
    umask $umask;
    #die "lock $file failed: create $locktmp: $!";
    $self->{dotlock_not_supported} = 1;
    return;
  }
  umask $umask;

  print LOCK "$$\n";
  close LOCK or die "lock $file failed: write to $locktmp: $!";

  for (my $retries = 0; $retries < $retrylimit; $retries++) {
    if ($retries > 0) {
      my $sleeptime = 2*$retries;
      if ($sleeptime > 60) { $sleeptime = 60; }         # max 1 min
      sleep ($sleeptime);
    }

    if (!link ($locktmp, $lockfile)) { next; }

    # sanity: we should always be able to see this
    my @tmpstat = lstat ($locktmp);
    if (!defined $tmpstat[3]) { die "lstat $locktmp failed"; }

    # sanity: see if the link() succeeded
    my @lkstat = lstat ($lockfile);
    if (!defined $lkstat[3]) { next; }	# link() failed

    # sanity: if the lock succeeded, the dev/ino numbers will match
    if ($tmpstat[0] == $lkstat[0] && $tmpstat[1] == $lkstat[1]) {
      unlink $locktmp;
      $self->{dotlock_locked} = $lockfile;
      $gotlock = 1; last;
    }
  }

  return $gotlock;
}

sub dotlock_unlock {
  my ($self) = @_;

  if ($self->{dotlock_not_supported}) { return; }

  my $lockfile = $self->{dotlock_locked};
  if (!defined $lockfile) { die "no dotlock_locked"; }
  unlink $lockfile or warn "unlink $lockfile failed: $!";
}

# ---------------------------------------------------------------------------

sub reject {
  my $self = shift;
  $self->_proxy_to_mail_audit ('reject', @_);
}

sub resend {
  my $self = shift;
  $self->_proxy_to_mail_audit ('resend', @_);
}

# ---------------------------------------------------------------------------

sub _proxy_to_mail_audit {
  my $self = shift;
  my $method = shift;
  my $ret;

  my @textary = split (/^/m, $self->as_string());

  eval {
    require Mail::Audit;

    my %opts = ( 'data' => \@textary );
    if (exists $self->{noexit}) { $opts{noexit} = $self->{noexit}; }
    if (exists $self->{loglevel}) { $opts{loglevel} = $self->{loglevel}; }
    if (exists $self->{log}) { $opts{log} = $self->{log}; }

    my $audit = new Mail::Audit (%opts);

    if ($method eq 'accept') {
      $ret = $audit->accept (@_);
    } elsif ($method eq 'reject') {
      $ret = $audit->reject (@_);
    } elsif ($method eq 'resend') {
      $ret = $audit->resend (@_);
    }
  };

  if ($@) {
    warn "spamassassin: $method() failed, Mail::Audit ".
            "module could not be loaded: $@";
    return undef;
  }

  return $ret;
}

# ---------------------------------------------------------------------------

# does not need to be called it seems.  still, keep it here in case of
# emergency.
sub finish {
  my $self = shift;
  delete $self->{headers_pristine};
  delete $self->{textarray};
  foreach my $key (keys %{$self->{headers}}) {
    delete $self->{headers}->{$key};
  }
  delete $self->{headers};
  delete $self->{mail_object};
}

1;
