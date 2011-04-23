# -*- Mode: perl; indent-tabs-mode: nil -*-
#
# The contents of this file are subject to the Mozilla Public
# License Version 1.1 (the "License"); you may not use this file
# except in compliance with the License. You may obtain a copy of
# the License at http://www.mozilla.org/MPL/
#
# Software distributed under the License is distributed on an "AS
# IS" basis, WITHOUT WARRANTY OF ANY KIND, either express or
# implied. See the License for the specific language governing
# rights and limitations under the License.
#
# The Original Code is the BMO Bugzilla Extension.
#
# The Initial Developer of the Original Code is Gervase Markham.
# Portions created by the Initial Developer are Copyright (C) 2010 the
# Initial Developer. All Rights Reserved.
#
# Contributor(s):
#   Gervase Markham <gerv@gerv.net>
#   David Lawrence <dkl@mozilla.com>
#   Byron Jones <glob@mozilla.com>

package Bugzilla::Extension::BMO;
use strict;
use base qw(Bugzilla::Extension);

use Bugzilla::Extension::BMO::Data qw($cf_visible_in_products
                                      %group_to_cc_map
                                      $blocking_trusted_setters
                                      $blocking_trusted_requesters
                                      $status_trusted_wanters
                                      %always_fileable_group
                                      %product_sec_groups);

use Bugzilla::Field;
use Bugzilla::Constants;
use Bugzilla::Status;
use Bugzilla::User;
use Bugzilla::User::Setting;
use Bugzilla::Util qw(html_quote trick_taint trim datetime_from);
use Scalar::Util qw(blessed);
use Bugzilla::Error;
use Date::Parse;
use DateTime;
use Bugzilla::Extension::BMO::FakeBug;

our $VERSION = '0.1';

#
# Monkey-patched methods
#

BEGIN {
    *Bugzilla::Bug::last_closed_date = \&_last_closed_date;
}

sub template_before_process {
    my ($self, $args) = @_;
    my $file = $args->{'file'};
    my $vars = $args->{'vars'};
    
    $vars->{'cf_hidden_in_product'} = \&cf_hidden_in_product;
    
    if ($file =~ /^list\/list/) {
        # Purpose: enable correct sorting of list table
        # Matched to changes in list/table.html.tmpl
        my %db_order_column_name_map = (
            'map_components.name' => 'component',
            'map_products.name' => 'product',
            'map_reporter.login_name' => 'reporter',
            'map_assigned_to.login_name' => 'assigned_to',
            'delta_ts' => 'opendate',
            'creation_ts' => 'changeddate',
        );

        my @orderstrings = split(/,\s*/, $vars->{'order'});
        
        # contains field names of the columns being used to sort the table.
        my @order_columns;
        foreach my $o (@orderstrings) {
            $o =~ s/bugs.//;
            $o = $db_order_column_name_map{$o} if 
                               grep($_ eq $o, keys(%db_order_column_name_map));
            next if (grep($_ eq $o, @order_columns));
            push(@order_columns, $o);
        }

        $vars->{'order_columns'} = \@order_columns;
        
        # fields that have a custom sortkey. (So they are correctly sorted 
        # when using js)
        my @sortkey_fields = qw(bug_status resolution bug_severity priority
                                rep_platform op_sys);

        my %columns_sortkey;
        foreach my $field (@sortkey_fields) {
            $columns_sortkey{$field} = _get_field_values_sort_key($field);
        }
        $columns_sortkey{'target_milestone'} = _get_field_values_sort_key('milestones');

        $vars->{'columns_sortkey'} = \%columns_sortkey;
    }
    elsif ($file =~ /^bug\/create\/create[\.-]/) {
        if (!$vars->{'cloned_bug_id'}) {
            # Allow status whiteboard values to be bookmarked
            $vars->{'status_whiteboard'} = 
                               Bugzilla->cgi->param('status_whiteboard') || "";
        }
       
        # Purpose: for pretty product chooser
        $vars->{'format'} = Bugzilla->cgi->param('format');

        # Data needed for "this is a security bug" checkbox
        $vars->{'sec_groups'} = \%product_sec_groups;
    }


    if ($file =~ /^list\/list/ || $file =~ /^bug\/create\/create[\.-]/) {
        # hack to allow the bug entry templates to use check_can_change_field 
        # to see if various field values should be available to the current user.
        $vars->{'default'} = Bugzilla::Extension::BMO::FakeBug->new($vars->{'default'} || {});
    }
}

sub page_before_template {
    my ($self, $args) = @_;
    my $page = $args->{'page_id'};
    my $vars = $args->{'vars'};

    if ($page eq 'user_activity.html') {
        _user_activity($vars);

    } elsif ($page eq 'upgrade-3.6.html') {
        $vars->{'bzr_history'} = sub { 
            return `cd /data/www/bugzilla.mozilla.org; /usr/bin/bzr log -n0 -rlast:10..`;
        };
    }
}

sub _get_field_values_sort_key {
    my ($field) = @_;
    my $dbh = Bugzilla->dbh;
    my $fields = $dbh->selectall_arrayref(
         "SELECT value, sortkey FROM $field
        ORDER BY sortkey, value");

    my %field_values;
    foreach my $field (@$fields) {
        my ($value, $sortkey) = @$field;
        $field_values{$value} = $sortkey;
    }
    return \%field_values;
}

sub cf_hidden_in_product {
    my ($field_name, $product_name, $component_name) = @_;

    # If used in buglist.cgi, we pass in one_product which is a Bugzilla::Product
    # elsewhere, we just pass the name of the product.
    $product_name = blessed($product_name) ? $product_name->name
                                           : $product_name;
   
    # Also in buglist.cgi, we pass in a list of components instead 
    # of a single compoent name everywhere else.
    my $component_list = ref $component_name ? $component_name 
                                             : [ $component_name ];
   
    foreach my $field_re (keys %$cf_visible_in_products) {
        if ($field_name =~ $field_re) {
            # If no product given, for example more than one product
            # in buglist.cgi, then hide field by default
            return 1 if !$product_name;

            my $products = $cf_visible_in_products->{$field_re};
            foreach my $product (keys %$products) {
                my $components = $products->{$product};

                my $found_component = 0;    
                if (@$components) {
                    foreach my $component (@$components) {
                        if (grep($_ eq $component, @$component_list)) {
                            $found_component = 1;
                            last;
                        }
                    }
                }
        
                # If product matches and at at least one component matches
                # from component_list (if a matching component was required), 
                # we allow the field to be seen
                if ($product eq $product_name && (!@$components || $found_component)) {
                    return 0;
                }
            }

            return 1;
        }
    }
    
    return 0;
}

# Purpose: CC certain email addresses on bugmail when a bug is added or 
# removed from a particular group.
sub bugmail_recipients {
    my ($self, $args) = @_;
    my $bug = $args->{'bug'};
    my $recipients = $args->{'recipients'};
    my $diffs = $args->{'diffs'};
    
    if (@$diffs) {
        # Changed bug
        foreach my $ref (@$diffs) {
            my ($who, $whoname, $what, $when, 
                $old, $new, $attachid, $fieldname) = (@$ref);
            
            if ($fieldname eq "bug_group") {
                _cc_if_special_group($old, $recipients);
                _cc_if_special_group($new, $recipients);
            }
        }
    }
    else {
        # New bug
        foreach my $group (@{ $bug->groups_in }) {
            _cc_if_special_group($group->{'name'}, $recipients);
        }
    }
}    

sub _cc_if_special_group {
    my ($group, $recipients) = @_;
    
    return if !$group;
    
    if ($group_to_cc_map{$group}) {
        my $id = login_to_id($group_to_cc_map{$group});
        $recipients->{$id}->{+REL_CC} = $Bugzilla::BugMail::BIT_DIRECT;
    }
}

sub _check_trusted {
    my ($field, $trusted, $priv_results) = @_;
    
    my $needed_group = $trusted->{'_default'} || "";
    foreach my $dfield (keys %$trusted) {
        if ($field =~ $dfield) {
            $needed_group = $trusted->{$dfield};
        }
    }
    if ($needed_group && !Bugzilla->user->in_group($needed_group)) {
        push (@$priv_results, PRIVILEGES_REQUIRED_EMPOWERED);
    }              
}

sub bug_check_can_change_field {
    my ($self, $args) = @_;
    my $bug = $args->{'bug'};
    my $field = $args->{'field'};
    my $new_value = $args->{'new_value'};
    my $old_value = $args->{'old_value'};
    my $priv_results = $args->{'priv_results'};
    my $user = Bugzilla->user;

    # Purpose: Only users in the appropriate drivers group can change the 
    # cf_blocking_* fields or cf_tracking_* fields
    if ($field =~ /^cf_(?:blocking|tracking)_/) {
        unless ($new_value eq '---' ||
                $new_value eq '?' || 
                ($new_value eq '1' && $old_value eq '0')) 
        {
            _check_trusted($field, $blocking_trusted_setters, $priv_results);
        }
        
        if ($new_value eq '?') {
            _check_trusted($field, $blocking_trusted_requesters, $priv_results);
        }
    }

    if ($field =~ /^cf_status_/) {
        # Only drivers can set wanted.
        if ($new_value eq 'wanted') {
            _check_trusted($field, $status_trusted_wanters, $priv_results);
        }
        
        # Require 'canconfirm' to change anything else
        if (!$user->in_group('canconfirm', $bug->{'product_id'})) {
            push (@$priv_results, PRIVILEGES_REQUIRED_EMPOWERED);
        }
    }

    # The EXPIRED resolution should only be settable by gerv.
    if ($field eq 'resolution' && $new_value eq 'EXPIRED') {
        if ($user->login ne 'gerv@mozilla.org') {
            push (@$priv_results, PRIVILEGES_REQUIRED_EMPOWERED);
        }
    }

    # Canconfirm is really "cantriage"; users with canconfirm can also mark 
    # bugs as DUPLICATE, WORKSFORME, and INCOMPLETE.
    if ($user->in_group('canconfirm', $bug->{'product_id'})) {
        if ($field eq 'bug_status'
            && is_open_state($old_value)
            && !is_open_state($new_value))
        {
            push (@$priv_results, PRIVILEGES_REQUIRED_NONE);
        }
        elsif ($field eq 'resolution' && 
               ($new_value eq 'DUPLICATE' ||
                $new_value eq 'WORKSFORME' ||
                $new_value eq 'INCOMPLETE'))
        {
            push (@$priv_results, PRIVILEGES_REQUIRED_NONE);
        }
    }

    # Bug 649625 - Disallow reopening of bugs which have been resolved for > 1 year
    if ($field eq 'bug_status') {
        if (is_open_state($new_value) && !is_open_state($old_value)) {
            my $days_ago = DateTime->now(time_zone => Bugzilla->local_timezone);
            $days_ago->subtract(days => 365);
            my $last_closed = datetime_from($bug->last_closed_date);
            if ($last_closed lt $days_ago) {
                push (@$priv_results, PRIVILEGES_REQUIRED_EMPOWERED);
            }
        }
    }

    push @$priv_results, PRIVILEGES_REQUIRED_NONE unless @$priv_results;
}

# Purpose: link up various Mozilla-specific strings.
sub _link_uuid {
    my $args = shift;    
    my $match = html_quote($args->{matches}->[0]);
    
    return qq{<a href="https://crash-stats.mozilla.com/report/index/$match">bp-$match</a>};
}

sub _link_cve {
    my $args = shift;
    my $match = html_quote($args->{matches}->[0]);
    
    return qq{<a href="http://cve.mitre.org/cgi-bin/cvename.cgi?name=$match">$match</a>};
}

sub _link_svn {
    my $args = shift;
    my $match = html_quote($args->{matches}->[0]);
    
    return qq{<a href="http://viewvc.svn.mozilla.org/vc?view=rev&amp;revision=$match">r$match</a>};
}

sub _link_hg {
    my $args = shift;
    my $text = html_quote($args->{matches}->[0]);
    my $repo = html_quote($args->{matches}->[1]);
    my $id   = html_quote($args->{matches}->[2]);
    
    return qq{<a href="https://hg.mozilla.org/$repo/rev/$id">$text</a>};
}

sub bug_format_comment {
    my ($self, $args) = @_;
    my $regexes = $args->{'regexes'};
  
    push (@$regexes, {
        match => qr/\b(?:UUID\s+|bp\-)([a-f0-9]{8}\-[a-f0-9]{4}\-[a-f0-9]{4}\-
                                       [a-f0-9]{4}\-[a-f0-9]{12})\b/x,
        replace => \&_link_uuid
    });

    push (@$regexes, {
        match => qr/\b((?:CVE|CAN)-\d{4}-\d{4})\b/,
        replace => \&_link_cve
    });

    push (@$regexes, {
        match => qr/\br(\d{4,})\b/,
        replace => \&_link_svn
    });

    # Note: for grouping in this regexp, always use non-capturing parentheses.
    my $hgrepos = join('|', qw!(?:releases/)?comm-[\w.]+ 
                               (?:releases/)?mozilla-[\w.]+
                               (?:releases/)?mobile-[\w.]+
                               tracemonkey
                               tamarin-[\w.]+
                               camino!);

    push (@$regexes, {
        match => qr/\b(($hgrepos)\s+changeset:?\s+(?:\d+:)?([0-9a-fA-F]{12}))\b/,
        replace => \&_link_hg
    });
}

# Purpose: make it always possible to file bugs in certain groups.
sub bug_check_groups {
    my ($self, $args) = @_;
    my $group_names = $args->{'group_names'};
    my $add_groups = $args->{'add_groups'};
    
    foreach my $name (@$group_names) {
        if ($always_fileable_group{$name}) {
            my $group = new Bugzilla::Group({ name => $name }) or next;
            $add_groups->{$group->id} = $group;
        }
    }
}

# Purpose: generically handle generating pretty blocking/status "flags" from
# custom field names.
sub quicksearch_map {
    my ($self, $args) = @_;
    my $map = $args->{'map'};
    
    foreach my $name (keys %$map) {
        if ($name =~ /^cf_(blocking|tracking|status)_([a-z]+)?(\d+)?$/) {
            my $type = $1;
            my $product = $2;
            my $version = $3;

            if ($version) {
                $version = join('.', split(//, $version));
            }

            my $pretty_name = $type;
            if ($product) {              
                $pretty_name .= "-" . $product;
            }
            if ($version) {
                $pretty_name .= $version;
            }

            $map->{$pretty_name} = $name;
        }
    }
}

# Restrict content types attachable by non-privileged people
my @mimetype_whitelist = ('^image\/', 'application\/pdf');

sub object_end_of_create_validators {
    my ($self, $args) = @_;
    my $class = $args->{'class'};
    
    if ($class->isa('Bugzilla::Attachment')) {
        my $params = $args->{'params'};
        my $bug = $params->{'bug'};
        if (!Bugzilla->user->in_group('editbugs', $bug->product_id)) {
            my $mimetype = $params->{'mimetype'};
            if (!grep { $mimetype =~ /$_/ } @mimetype_whitelist ) {
                # Need to neuter MIME type to something non-executable
                if ($mimetype =~ /^text\//) {
                    $params->{'mimetype'} = "text/plain";
                }
                else {
                    $params->{'mimetype'} = "application/octet-stream";
                }
            }
        }
    }
}

# Add product chooser setting (although it was added long ago, so add_setting
# will just return every time).
sub install_before_final_checks {
    my ($self, $args) = @_;
    
    add_setting('product_chooser', 
                ['pretty_product_chooser', 'full_product_chooser'],
                'pretty_product_chooser');
}

# Migrate old is_active stuff to new patch (is in core in 4.2), The old column
# name was 'is_active', the new one is 'isactive' (no underscore).
sub install_update_db {
    my $dbh = Bugzilla->dbh;
    
    if ($dbh->bz_column_info('milestones', 'is_active')) {
        $dbh->do("UPDATE milestones SET isactive = 0 WHERE is_active = 0;");
        $dbh->bz_drop_column('milestones', 'is_active');
        $dbh->bz_drop_column('milestones', 'is_searchable');
    }
}

# User activity report
sub _user_activity {
    my ($vars) = @_;
    my $dbh = Bugzilla->dbh;
    my $input = Bugzilla->input_params;

    my @who = ();
    my $from = trim($input->{'from'});
    my $to = trim($input->{'to'});

    if ($input->{'action'} eq 'run') {
        if ($input->{'who'} eq '') {
            ThrowUserError('user_activity_missing_username');
        }
        $input->{'who'} =~ s/[\s;]+/,/g;
        Bugzilla::User::match_field({ 'who' => {'type' => 'multi'} });

        ThrowUserError('user_activity_missing_from_date') unless $from;
        my $from_time = str2time($from)
            or ThrowUserError('user_activity_invalid_date', { date => $from });
        my $from_dt = DateTime->from_epoch(epoch => $from_time)
                              ->set_time_zone('local')
                              ->truncate(to => 'day');
        $from = $from_dt->ymd();

        ThrowUserError('user_activity_missing_to_date') unless $to;
        my $to_time = str2time($to)
            or ThrowUserError('user_activity_invalid_date', { date => $to });
        my $to_dt = DateTime->from_epoch(epoch => $to_time)
                            ->set_time_zone('local')
                            ->truncate(to => 'day');
        $to = $to_dt->ymd();
        # add one day to include all activity that happened on the 'to' date
        $to_dt->add(days => 1);

        my ($activity_joins, $activity_where) = ('', '');
        my ($attachments_joins, $attachments_where) = ('', '');
        if (Bugzilla->params->{"insidergroup"}
            && !Bugzilla->user->in_group(Bugzilla->params->{'insidergroup'}))
        {
            $activity_joins = "LEFT JOIN attachments
                       ON attachments.attach_id = bugs_activity.attach_id";
            $activity_where = "AND COALESCE(attachments.isprivate, 0) = 0";
            $attachments_where = $activity_where;
        }

        my @who_bits;
        foreach my $who (
            ref $input->{'who'} 
            ? @{$input->{'who'}} 
            : $input->{'who'}
        ) {
            push @who, $who;
            push @who_bits, '?';
        }
        my $who_bits = join(',', @who_bits);

        if (!@who) {
            my $template = Bugzilla->template;
            my $cgi = Bugzilla->cgi;
            my $vars = {};
            $vars->{'script'}        = $cgi->url(-relative => 1);
            $vars->{'fields'}        = {};
            $vars->{'matches'}       = [];
            $vars->{'matchsuccess'}  = 0;
            $vars->{'matchmultiple'} = 1;
            print $cgi->header();
            $template->process("global/confirm-user-match.html.tmpl", $vars)
              || ThrowTemplateError($template->error());
            exit;
        }

        my @params;
        push @params, @who;
        push @params, ($from_dt->ymd(), $to_dt->ymd());
        push @params, @who;
        push @params, ($from_dt->ymd(), $to_dt->ymd());

        my $query = "
        SELECT 
                   fielddefs.name,
                   bugs_activity.bug_id,
                   bugs_activity.attach_id,
                   ".$dbh->sql_date_format('bugs_activity.bug_when', '%Y.%m.%d %H:%i:%s').",
                   bugs_activity.removed,
                   bugs_activity.added,
                   profiles.login_name,
                   bugs_activity.comment_id,
                   bugs_activity.bug_when
              FROM bugs_activity
                   $activity_joins
         LEFT JOIN fielddefs
                ON bugs_activity.fieldid = fielddefs.id
        INNER JOIN profiles
                ON profiles.userid = bugs_activity.who
             WHERE profiles.login_name IN ($who_bits)
                   AND bugs_activity.bug_when > ? AND bugs_activity.bug_when < ?
                   $activity_where

        UNION ALL

        SELECT 
                   'attachments.filename' AS name,
                   attachments.bug_id,
                   attachments.attach_id,
                   ".$dbh->sql_date_format('attachments.creation_ts', '%Y.%m.%d %H:%i:%s').",
                   '' AS removed,
                   attachments.description AS added,
                   profiles.login_name,
                   NULL AS comment_id,
                   attachments.creation_ts AS bug_when
              FROM attachments
        INNER JOIN profiles
                ON profiles.userid = attachments.submitter_id
             WHERE profiles.login_name IN ($who_bits)
                   AND attachments.creation_ts > ? AND attachments.creation_ts < ?
                   $attachments_where

          ORDER BY bug_when ";

        my $list = $dbh->selectall_arrayref($query, undef, @params);

        my @operations;
        my $operation = {};
        my $changes = [];
        my $incomplete_data = 0;

        foreach my $entry (@$list) {
            my ($fieldname, $bugid, $attachid, $when, $removed, $added, $who,
                $comment_id) = @$entry;
            my %change;
            my $activity_visible = 1;

            next unless Bugzilla->user->can_see_bug($bugid);

            # check if the user should see this field's activity
            if ($fieldname eq 'remaining_time'
                || $fieldname eq 'estimated_time'
                || $fieldname eq 'work_time'
                || $fieldname eq 'deadline')
            {
                $activity_visible = Bugzilla->user->is_timetracker;
            }
            elsif ($fieldname eq 'longdescs.isprivate'
                    && !Bugzilla->user->is_insider 
                    && $added) 
            { 
                $activity_visible = 0;
            } 
            else {
                $activity_visible = 1;
            }

            if ($activity_visible) {
                # Check for the results of an old Bugzilla data corruption bug
                if (($added eq '?' && $removed eq '?')
                    || ($added =~ /^\? / || $removed =~ /^\? /)) {
                    $incomplete_data = 1;
                }

                # An operation, done by 'who' at time 'when', has a number of
                # 'changes' associated with it.
                # If this is the start of a new operation, store the data from the
                # previous one, and set up the new one.
                if ($operation->{'who'}
                    && ($who ne $operation->{'who'}
                        || $when ne $operation->{'when'}))
                {
                    $operation->{'changes'} = $changes;
                    push (@operations, $operation);
                    $operation = {};
                    $changes = [];
                }

                $operation->{'bug'} = $bugid;
                $operation->{'who'} = $who;
                $operation->{'when'} = $when;

                $change{'fieldname'} = $fieldname;
                $change{'attachid'} = $attachid;
                $change{'removed'} = $removed;
                $change{'added'} = $added;
                
                if ($comment_id) {
                    $change{'comment'} = Bugzilla::Comment->new($comment_id);
                }

                push (@$changes, \%change);
            }
        }

        if ($operation->{'who'}) {
            $operation->{'changes'} = $changes;
            push (@operations, $operation);
        }

        $vars->{'incomplete_data'} = $incomplete_data;
        $vars->{'operations'} = \@operations;

    } else {

        if ($from eq '') {
            my ($yy, $mm) = (localtime)[5, 4];
            $from = sprintf("%4d-%02d-01", $yy + 1900, $mm + 1);
        }
        if ($to eq '') {
            my ($yy, $mm, $dd) = (localtime)[5, 4, 3];
            $to = sprintf("%4d-%02d-%02d", $yy + 1900, $mm + 1, $dd);
        }
    }

    $vars->{'action'} = $input->{'action'};
    $vars->{'who'} = join(',', @who);
    $vars->{'from'} = $from;
    $vars->{'to'} = $to;
}

sub object_before_create {
    my ($self, $args) = @_;
    my $class = $args->{'class'};

    # Block the creation of custom fields via the web UI
    if ($class->isa('Bugzilla::Field') 
        && Bugzilla->usage_mode == USAGE_MODE_BROWSER) 
    {
        ThrowUserError("bmo_new_cf_prohibited");
    }
}

sub _last_closed_date {
    my ($self) = @_;
    my $dbh = Bugzilla->dbh;

    return $self->{'last_closed_date'} if defined $self->{'last_closed_date'};

    my $closed_statuses = "'" . join("','", map { $_->name } closed_bug_statuses()) . "'";
    my $status_field_id = get_field_id('bug_status');

    $self->{'last_closed_date'} = $dbh->selectrow_array("
        SELECT bugs_activity.bug_when
          FROM bugs_activity
         WHERE bugs_activity.fieldid = ?
               AND bugs_activity.added IN ($closed_statuses)
               AND bugs_activity.bug_id = ?
      ORDER BY bugs_activity.bug_when DESC " . $dbh->sql_limit(1),
        undef, $status_field_id, $self->id
    );

    return $self->{'last_closed_date'};
}

__PACKAGE__->NAME;
