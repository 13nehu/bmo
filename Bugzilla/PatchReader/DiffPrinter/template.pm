package Bugzilla::PatchReader::DiffPrinter::template;

use 5.10.1;
use strict;
use warnings;

sub new {
  my $class = shift;
  $class = ref($class) || $class;
  my $this = {};
  bless $this, $class;

  $this->{TEMPLATE_PROCESSOR} = $_[0];
  $this->{HEADER_TEMPLATE} = $_[1];
  $this->{FILE_TEMPLATE} = $_[2];
  $this->{FOOTER_TEMPLATE} = $_[3];
  $this->{ARGS} = $_[4] || {};

  $this->{ARGS}{file_count} = 0;
  return $this;
}

sub start_patch {
  my $this = shift;
  $this->{TEMPLATE_PROCESSOR}->process($this->{HEADER_TEMPLATE}, $this->{ARGS})
      || ::ThrowTemplateError($this->{TEMPLATE_PROCESSOR}->error());
}

sub end_patch {
  my $this = shift;
  $this->{TEMPLATE_PROCESSOR}->process($this->{FOOTER_TEMPLATE}, $this->{ARGS})
      || ::ThrowTemplateError($this->{TEMPLATE_PROCESSOR}->error());
}

sub start_file {
  my $this = shift;
  $this->{ARGS}{file_count}++;
  $this->{ARGS}{file} = shift;
  $this->{ARGS}{file}{plus_lines} = 0;
  $this->{ARGS}{file}{minus_lines} = 0;
  @{$this->{ARGS}{sections}} = ();
}

sub end_file {
  my $this = shift;
  my $file = $this->{ARGS}{file};
  $this->{TEMPLATE_PROCESSOR}->process($this->{FILE_TEMPLATE}, $this->{ARGS})
      || ::ThrowTemplateError($this->{TEMPLATE_PROCESSOR}->error());
  @{$this->{ARGS}{sections}} = ();
  delete $this->{ARGS}{file};
}

sub next_section {
  my $this = shift;
  my ($section) = @_;

  $this->{ARGS}{file}{plus_lines} += $section->{plus_lines};
  $this->{ARGS}{file}{minus_lines} += $section->{minus_lines};

  # Get groups of lines and print them
  my $last_line_char = '';
  my $context_lines = [];
  my $plus_lines = [];
  my $minus_lines = [];
  foreach my $line (@{$section->{lines}}) {
    $line =~ s/\r?\n?$//;
    if ($line =~ /^ /) {
      if ($last_line_char ne ' ') {
        push @{$section->{groups}}, {context => $context_lines,
                                     plus => $plus_lines,
                                     minus => $minus_lines};
        $context_lines = [];
        $plus_lines = [];
        $minus_lines = [];
      }
      $last_line_char = ' ';
      push @{$context_lines}, substr($line, 1);
    } elsif ($line =~ /^\+/) {
      if ($last_line_char eq ' ' || $last_line_char eq '-' && @{$plus_lines}) {
        push @{$section->{groups}}, {context => $context_lines,
                                     plus => $plus_lines,
                                     minus => $minus_lines};
        $context_lines = [];
        $plus_lines = [];
        $minus_lines = [];
        $last_line_char = '';
      }
      $last_line_char = '+';
      push @{$plus_lines}, substr($line, 1);
    } elsif ($line =~ /^-/) {
      if ($last_line_char eq '+' && @{$minus_lines}) {
        push @{$section->{groups}}, {context => $context_lines,
                                     plus => $plus_lines,
                                     minus => $minus_lines};
        $context_lines = [];
        $plus_lines = [];
        $minus_lines = [];
        $last_line_char = '';
      }
      $last_line_char = '-';
      push @{$minus_lines}, substr($line, 1);
    }
  }

  push @{$section->{groups}}, {context => $context_lines,
                               plus => $plus_lines,
                               minus => $minus_lines};
  push @{$this->{ARGS}{sections}}, $section;
}

1;

=head1 B<Methods in need of POD>

=over

=item new

=item start_patch

=item end_patch

=item start_file

=item end_file

=item next_section

=back
