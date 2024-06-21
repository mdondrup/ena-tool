#!/usr/bin/env perl

use strict;
use warnings;
use Getopt::Long;
use LWP::UserAgent;
use HTTP::Request::Common qw(POST);
use MIME::Base64;
use Pod::Usage;
use POSIX qw(strftime);
use XML::Simple qw (:strict);


my $today = strftime "%Y-%m-%d", localtime;

use File::Temp qw(tempfile tempdir); 

# Usage message
sub usage {
    pod2usage(
        -verbose => 1,
        -exitval => 1,
    );
}

# Command-line options

###### Supported actions:
## From ENA error message
## Expected elements 'ADD MODIFY CANCEL SUPPRESS* KILL HOLD RELEASE PROTECT* ROLLBACK VALIDATE RECEIPT'
## *: not supported by ENA API
######

my %allowed_actions = qw(ADD 1 MODIFY 1 CANCEL 1 SUPPRESS 0 KILL 1 HOLD 1 RELEASE 1 PROTECT 0 ROLLBACK 1 VALIDATE 1 RECEIPT 1);

my ($action, $what, $alias, $description, $children, $parent, $title, $verbose, $date, $center,
    $username, $password, $receipt, $locusTag, $accession, $keep, $production);
GetOptions(    
	   'alias=s'       => \$alias,
	   'description=s' => \$description,
	   'title=s' => \$title,
	   'username=s'    => \$username,
	   'password=s'    => \$password,
	   'locustagprefix=s' => \$locusTag, ## only works on productions
	   'center=s' => \$center,
	   'releasedate=s' => \$date,
	   'children=s' => \$children,
	   'receipt=s' => \$receipt, # save the receipt to file
	   'accession=s' => \$accession,
	   'keeptemp' => \$keep, # keep temporary xml control files
	   'production' => \$production, # really do it on the production system, otherwise
	   'verbose' => \$verbose, # if not verbose, the only thing STDOUT is the accession of the project if success
	   'help|?'        => \&usage,
) or usage();

$action = uc $ARGV[0] or usage();
usage() unless $allowed_actions{$action};
$what = $ARGV[1];
$center |= 'EBP Norway';
$date |= $today;

# Check required options
unless ($action && $username && $password) {
  warn "action, username and password required\n";
  usage();
}
if  ( $what && $what !~ /^umbrella|project$/ ) {
  warn "<what> must be one of 'umbrella' or 'project'\n";
  usage();
}


# URL for ENA submission
my $url = 'https://wwwdev.ebi.ac.uk/ena/submit/drop-box/submit/';
### Add the production URL
$url = 'https://www.ebi.ac.uk/ena/submit/drop-box/submit/' if $production;

my $encoded_credentials = encode_base64("$username:$password", '');

# Prepare HTTP user agent
my $ua = LWP::UserAgent->new;
$ua->timeout(10);
my ($submit_file, $project_file);

if ($action eq 'ADD') {
  ### we should check if the project exists already... This can only be done based on alias
  $submit_file = makesubmit($action, $date);
  $project_file = makeproject($what, $title, $description, $alias, $center, $locusTag);
    

} elsif ($action eq 'MODIFY') {
 
   $submit_file = makesubmit($action, $date);
  $project_file = make_modify_project($what, $title, $description, $alias, $center,  $children, $accession, $locusTag);
  
} else {
  $submit_file = makesubmit($action, $date, $accession);
  #$project_file = make_modify_project($what, $title, $description, $alias, $center, $parent, $children, $accession);


}


my $req = POST $url,
  Content_Type => 'form-data',			     
  Content => [
	      Application => 'testing',
	      SUBMISSION => ["$submit_file"],
	      PROJECT => ["$project_file"],
	     ],
  Authorization => "Basic $encoded_credentials"
  ;
			    

print $req->as_string if $verbose;

my $response = $ua->request($req);

# Check the response
if ($response->is_success) {
  print "XML Response from ENA: \n" . $response->decoded_content . "\n" if $verbose;
  if ($receipt) {
    open RECEIPT, ">$receipt" or die "Cannot open receipt file $receipt, $!\n";
    print RECEIPT $response->decoded_content . "\n";
    close RECEIPT;
  }
} else {
    warn "Error communicating with ENA: " . $response->status_line . "\n" . "\n";
  }

my $ref = XMLin($response->decoded_content, KeyAttr => {  }, ForceArray => [  'ACTIONS' ]);


use Data::Dumper;
 
#print Dumper($ref);

if ($ref->{success} eq 'true') {
  
  print ($ref->{PROJECT}->{accession},"\n"); 
  print STDERR join("\n", @{$ref->{MESSAGES}->{INFO}});
  exit 0;
} else {
  die ($ref->{MESSAGES}->{ERROR}."\n");
}



################################################## Subroutines ####################################################

sub makesubmit {
  my ($action, $date, $target) = @_;
  my $dir = tempdir( CLEANUP => !$keep );
  my ($fh, $filename) = tempfile('ENA-SubmissionXXXXXXXXXX', DIR => $dir, SUFFIX => '.tmp' );
  $action = uc $action;
  my $hold = qq( <ACTION>
         <HOLD HoldUntilDate="$date"/>
      </ACTION>
);

   $target = ($target) ? qq( target="$target") : '';
  
  if ($action eq 'ADD') {
    $action = "<ADD/>"
  } elsif ($action eq "MODIFY") {
    $action = "<MODIFY/>"
  } elsif ($action eq 'HOLD') {
  $action = qq ( <$action$target  HoldUntilDate="$date"/> );
  $hold='';
  
  } else {
   
   
    $action = qq ( <$action$target/> ); #this is generic, could be dangerous
  }
  my $xml = <<"END_XML";
 <SUBMISSION>
   <ACTIONS>
      <ACTION>
          $action
      </ACTION>
    $hold  
   </ACTIONS>
</SUBMISSION>

END_XML
  
  print $fh $xml;
  close ($fh);
  print "Submission file $filename \n" if $verbose;
  return $filename;
}

sub makeproject {
  my ($what, $title, $description, $alias, $center, $locusTag) = @_;
  my $dir = tempdir( CLEANUP => !$keep );
  $locusTag |= '';
  my ($fh, $filename) = tempfile('ENA-ProjectXXXXXXXXXX', DIR => $dir, SUFFIX => '.tmp' );
  $locusTag = "<LOCUS_TAG_PREFIX>$locusTag</LOCUS_TAG_PREFIX>" if $locusTag;
  my $subm_xml = <<"END_XML";
<SUBMISSION_PROJECT>
   <SEQUENCING_PROJECT>
$locusTag
    </SEQUENCING_PROJECT>
 </SUBMISSION_PROJECT>
END_XML

  
  my $type = ($what eq 'umbrella') ? '<UMBRELLA_PROJECT/>' : ($what eq 'project') ? $subm_xml : usage();
  my $xml = <<"END_XML";
<PROJECT_SET>
    <PROJECT center_name="$center" alias="$alias">
        <TITLE>$title</TITLE>
        <DESCRIPTION>$description</DESCRIPTION>
         $type
    </PROJECT>
</PROJECT_SET>
END_XML


    
  print $fh $xml;
  close ($fh);
  print " Project file: $filename \n" if $verbose;

  return $filename;
}

sub make_modify_project {
  my ($what, $title, $description, $alias, $center, $parent, $children, $accession, $locusTag) = @_;
  my $dir = tempdir( CLEANUP => !$keep );
  my ($fh, $filename) = tempfile('ENA-ModifyXXXXXXXXXX', DIR => $dir, SUFFIX => '.tmp' );

  my $children_xml = "";
  my $xml = "";
$accession = ($accession) ?  qq( accession="$accession" ) : '';

my @children = split ',', $children;

if (scalar @children) {

$children_xml =
  join ("\n" ,
	(map { 
my $ret = <<"END_XML";  
  <RELATED_PROJECT>
    <CHILD_PROJECT accession="$_"/>
    </RELATED_PROJECT>
END_XML
$ret }
	 @children)
       );
}
if ($what eq 'umbrella' ) {
  
$xml = <<"END_XML";
  <PROJECT_SET xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
    <PROJECT $accession center_name="$center" alias="$alias">
        <TITLE>$title</TITLE>
        <DESCRIPTION>$description</DESCRIPTION>
        <UMBRELLA_PROJECT/>
        <RELATED_PROJECTS>
          $children_xml
        </RELATED_PROJECTS>
    </PROJECT>
</PROJECT_SET>
END_XML

} elsif ($what eq 'project') {
   $locusTag = "<LOCUS_TAG_PREFIX>$locusTag</LOCUS_TAG_PREFIX>" if $locusTag;
   $xml = <<"END_XML";
<PROJECT_SET>
    <PROJECT $accession center_name="$center" alias="$alias">
        <TITLE>$title</TITLE>
        <DESCRIPTION>$description</DESCRIPTION>
<SUBMISSION_PROJECT>
   <SEQUENCING_PROJECT>
$locusTag
    </SEQUENCING_PROJECT>
 </SUBMISSION_PROJECT>


    </PROJECT>
</PROJECT_SET>


END_XML
   
 } else {
   die "Don't know what to do with this type";
 }
  
 
 print $fh $xml;
  close ($fh);
  print " Project file: $filename \n" if $verbose;

  return $filename;

}

__END__

=head1 NAME

ena.pl - Create and manage projects in the European Nucleotide Archive (ENA)

=head1 SYNOPSIS

ena.pl [ACTION] [umbrella|project] [OPTIONS]

=head1 DESCRIPTION

This script is used to create, modify, and manage projects in the European Nucleotide Archive (ENA). It supports various actions such as ADD, MODIFY, CANCEL, SUPPRESS, KILL, HOLD, RELEASE, ROLLBACK, VALIDATE, and RECEIPT.

=head1 ACTIONS

The following actions are supported (case independent):

=over 4

=item B<ADD>

Add a new project.

=item B<MODIFY>

Modify an existing project.

=item B<CANCEL>

Cancel a project.

=item B<KILL>

Kill a project.

=item B<HOLD>

Hold a project until a specified date.

=item B<RELEASE>

Release a project.

=item B<ROLLBACK>

Rollback a project.

=item B<VALIDATE>

TODO: Validate a project. Not supported yet.

=item B<RECEIPT>

Receive a receipt of the project submission.

=back

=head1 OPTIONS

=over 4

=item B<--alias> I<ALIAS>

Specify the alias for the project.

=item B<--description> I<DESCRIPTION>

Provide a description for the project.

=item B<--title> I<TITLE>

Specify the title of the project.

=item B<--username> I<USERNAME>

Provide the username for authentication.

=item B<--password> I<PASSWORD>

Provide the password for authentication.

=item B<--locustagprefix> I<LOCUSTAGPREFIX>

Specify the locus tag prefix (only supported on production system).

=item B<--center> I<CENTER>

Specify the center name. Defaults to 'EBP Norway'.

=item B<--releasedate> I<RELEASEDATE>

Specify the release date for the project. (Format YYYY-MM-DD) Default: TODAY

=item B<--children> I<CHILDREN>

Specify the children projects, separated by commas.

=item B<--receipt> I<RECEIPT>

Save the receipt to a file.

=item B<--accession> I<ACCESSION>

Specify the accession for the project.

=item B<--keeptemp>

Keep temporary XML control files.

=item B<--production>

Run the script on the production system. By default the test system is used

=item B<--verbose>

Enable verbose output. IF not verbose, only the acession of an successfuly created project will be printed to STDOUT.

=item B<--help>

Print this help message.

=back

=head1 DETAILS

This script provides simplyfied commandline client to the ENA Project API.

 It allows to create umbrella projects and allows to 
link submission projects to an umbrella. Note, that there is no client-side sanity checking. All error checking is done on the ENA side. It is not possible to turn a submission project into an umbrella project and vice-versa. Some changes may not be reversible, e.g.child projects cannot be unlinked from an umbrella without contacting support and published projects cannot be unpublished.

Unless verbose is activated, the script will only print the accession of a successfully created project to STDOUT. INFO and ERROR messages are printed on STDERR.

The script exits with code 0 if the operation was succesful, 1 otherwise. 

Projects can be identified by either their alias or accession. When creating a new project, a unique alias must be provided.


=head1 EXAMPLES

=over 4

=item B<Add a new project>

  ena.pl ADD project --alias "project_alias" --description "Project description" --title "Project Title" \
  --username "your_username" --password "your_password"

=item B<Modify an existing project>

  ena.pl MODIFY project --alias "project_alias" --description "Updated description" --title "Updated Title"\
   --username "your_username" --password "your_password" --accession "accession_number"

=item B<Add projects to an umbrella project>

   ena.pl MODIFY umbrella --accession "umbrella_project_accession" --description "Umbrella Project Description" \
   --title "Umbrella Project Title" --username "your_username" --password "your_password" \
   --children "child_project_accession_1,child_project_accession_2"


=back

=head1 TODO

=over 4

=item B<There is no option to retrieve project data yet.>

=item B<Include some internal validation>

=item B<Include sample and run submission?>

=back

=head1 AUTHOR

Michael Dondrup (michael.dondrup < at > uib.no)

=head1 COPYRIGHT AND LICENSE


BSD 2-Clause License

Copyright (c) 2024, Michael Dondrup

All rights reserved.

Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

=over 4

=item 1. Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.

=item 2. Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.

=back

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

=cut

