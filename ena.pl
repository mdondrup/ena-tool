#!/usr/bin/env perl

use strict;
use warnings;
use Getopt::Long;
use LWP::UserAgent;
use HTTP::Request::Common qw(POST GET);
use MIME::Base64;
use Pod::Usage;
use POSIX qw(strftime);
use XML::Simple qw (:strict);
use utf8;


my $today = strftime "%Y-%m-%d", localtime;
my $timestamp = strftime "-- (updated: %Y-%m-%d %T %Z)", localtime; # Generate a timestamp to append to description for modifications


my $maxRetries = 10; ## max number of server retries in case of errors
my $serverTimeout = 5; ## 10s to respond
my $waitBetweenRetries = 5; ## 2s to wait betweeen retries

 # Prepare HTTP user agent
my $ua = LWP::UserAgent->new;
$ua->timeout($serverTimeout);
#$ua->agent("");


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
## Expected elements 'ADD MODIFY CANCEL SUPPRESS* KILL* HOLD RELEASE PROTECT* ROLLBACK VALIDATE RECEIPT'
## *: not supported by ENA API
######

my %allowed_actions = qw(SHOW 1 ADD 1 MODIFY 1 CANCEL 1 SUPPRESS 0 KILL 0 HOLD 1 RELEASE 1 PROTECT 0 ROLLBACK 1 VALIDATE 1 RECEIPT 1);

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
$center ||= 'EBP Norway';
$date ||= $today;

# Check required options
unless ($action && $username && $password) {
  warn "action, username and password required\n";
  usage();
}
if  ( $what && $what !~ /^umbrella|project|object$/ ) {
  warn "<what> must be one of 'umbrella', 'project', or 'object'\n";
  usage();
}


# URL for ENA submission
my $URL_PREFIX = 'https://wwwdev.ebi.ac.uk/ena/submit/drop-box/';
### Add the production URL
$URL_PREFIX = 'https://www.ebi.ac.uk/ena/submit/drop-box/' if $production;

my $url = $URL_PREFIX;

my $encoded_credentials = encode_base64("$username:$password", '');

#$ua->credentials( 'wwwdev.ebi.ac.uk:443', 'PAUSE', $username, $password);
my ($submit_file, $project_file);

if ($action eq 'SHOW') {
### "https://wwwdev.ebi.ac.uk/ena/submit/drop-box/projects/PRJEB704?format=xml
  usage() unless $accession;
  $url .= 'projects/'.($accession).'?format=xml'
} else {

  $url .= 'submit';

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
}

my $request = ($action eq 'SHOW') ?
  GET $url, Authorization => "Basic $encoded_credentials"
  :
  POST $url,
  Content_Type => 'form-data',			     
  Content => [
	      Application => 'testing',
	      SUBMISSION => ["$submit_file"],
	      PROJECT => ["$project_file"],
	     ],
  Authorization => "Basic $encoded_credentials"
  ;
			    

print $request->as_string if $verbose;

my $response;



$response = retry_request($request, $maxRetries);


# Check the response
if ($response->is_success) {
  print "XML Response from ENA: \n" . $response->decoded_content . "\n" if $verbose;
  if ($receipt) {
    open RECEIPT, ">$receipt" or die "Cannot open receipt file $receipt, $!\n";
    print RECEIPT $response->decoded_content . "\n";
    close RECEIPT;
  }
} else {
  die "Error communicating with ENA: " . $response->status_line . "\n" .$response->decoded_content. "\n";
 
  }

my $ref = XMLin($response->decoded_content, KeyAttr => {  }, ForceArray => [  'ERROR', 'INFO' ]);

#use Data::Dumper;
 
#print Dumper($ref);

if ($ref->{PROJECT}->{accession} || $action eq 'SHOW' || $ref->{success} && $ref->{success} eq 'true' ) {
  if($action eq 'SHOW') {
    print $response->decoded_content,"\n";
  } else {
    print ($ref->{PROJECT}->{accession},"\n");
  }
  if (ref $ref->{MESSAGES}->{INFO} eq 'ARRAY') {
    print STDERR join("\n", @{$ref->{MESSAGES}->{INFO}});

  } else {
     print STDERR $ref->{MESSAGES}->{INFO} if $ref->{MESSAGES}->{INFO};
  }
} else {
  die join "\n", @{$ref->{MESSAGES}->{ERROR}} if ref $ref->{MESSAGES}->{ERROR} ;
}



################################################## Subroutines ####################################################

### Server time-out issues.... on dev at least

sub retry_request {
  my ($req, $retries) = @_;
  my $response;
  die "request empty" unless $req;
  print ($req->as_string,"\n") if $verbose;
  while (!$response || !$response->is_success) {
    $response = $ua->request($req);
    if ($response->status_line =~/Operation timed out/) {
      warn "Server connection timed out, waiting $waitBetweenRetries secs ...";
      sleep $waitBetweenRetries;
    }
    $retries--;
    last if $retries <= 0 || $response->status_line =~ /404|500 Internal Server Error/ || $response->is_success  ;
  }
  #undef ua;
  sleep $serverTimeout+1;
  return $response;
}

sub getObjectDataByAccession {
  my ($accession, $urll) = @_;
  die "missing accession" unless $accession;

  $urll .= 'projects/'.($accession).'?format=xml';
  my $request = GET $urll, Authorization => "Basic $encoded_credentials";
  
  my $response = retry_request($request, $maxRetries);

  die "Error retrieving project data for $accession: ". $response->status_line ."\n" unless $response->is_success;

  my $ref = XMLin($response->decoded_content, KeyAttr => {  }, ForceArray => [ ]);

  #use Data::Dumper;

  #print Dumper $ref;
  
  return (
	  title => $ref->{PROJECT}->{TITLE},
	  accession => $ref->{PROJECT}->{accession},
	  alias => $ref->{PROJECT}->{alias},
	  description => $ref->{PROJECT}->{DESCRIPTION},
	  locustag => ((ref  $ref->{PROJECT}->{SUBMISSION_PROJECT}) ? $ref->{PROJECT}->{SUBMISSION_PROJECT}->{SEQUENCING_PROJECT}->{LOCUS_TAG_PREFIX} : undef)
	  
	 );


}


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




###################################### ENA API BEHAVIOR ######################################
## The ENA API has the following dumb behavior:
## - The TITLE and DESCRIPTION elements have to be present to validate
## - If Title or Description element are present and empty, the content is DELETED
## - IF Title and Description elements are present and unchanged, no change is applied because md5 is unchanged
## - The change test ignores child projects that should be added to the umbrella

## To preserve data integrity, we have to do the following:
## - Retrieve the original values for Title and Description from the project if no values were provided by the user.
## - To allow for an update to happen, we have to change something. We therefore will therefore append an update timestamp to the
## - end of the Description field automatically if the description argument is not set.  

sub changeDescription {
  my $des = shift;
  $des =~ s/ \-\- \(updated: .+\)$//g; # remove trailling timestamp
  return $des.' '.$timestamp;
}


sub make_modify_project {
  my ($what, $title, $description, $alias, $center,  $children, $accession, $locusTag) = @_;
  my $dir = tempdir( CLEANUP => !$keep );
  my ($fh, $filename) = tempfile('ENA-ModifyXXXXXXXXXX', DIR => $dir, SUFFIX => '.tmp' );

  my $children_xml = "";
  my $xml = "";

  my %data = getObjectDataByAccession($accession, $URL_PREFIX);
  $accession ||= $data{accession};
  $title ||= $data{title};
  $alias ||= $data{alias};
  $description ||= changeDescription($data{description});
  $locusTag ||= $data{locustag};
  
  
$accession = ($accession) ?  qq( accession="$accession" ) : '';

  
my @children = split ',', $children if defined $children;

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
  
  $xml = qq (
  <PROJECT_SET xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
    <PROJECT $accession center_name="$center" alias="$alias">
 ) .
   (($title) ? "<TITLE>$title</TITLE>" : '<TITLE/>') ## This will DELETE the Title if empty!
   .
   (($description) ? "<DESCRIPTION>$description</DESCRIPTION>" : '<DESCRIPTION/>' ) ## Same with DESCRIPTION!
   .
   "<UMBRELLA_PROJECT/>\n"
   .
   ((@children) ? qq (<RELATED_PROJECTS>
          $children_xml
        </RELATED_PROJECTS> 
 ) : ' ')
   . qq (
    </PROJECT>
</PROJECT_SET>
)



   
} elsif ($what eq 'project') {
  $locusTag = "<LOCUS_TAG_PREFIX>$locusTag</LOCUS_TAG_PREFIX>" if $locusTag;
  
$xml = qq (
  <PROJECT_SET xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
    <PROJECT $accession center_name="$center" alias="$alias">
 ) .
   (($title) ? "<TITLE>$title</TITLE>" : '<TITLE/>') ## This will DELETE the Title if empty!
   .
   (($description) ? "<DESCRIPTION>$description</DESCRIPTION>" : '<DESCRIPTION/>' ) ## Same with DESCRIPTION!
   .
  
qq(
<SUBMISSION_PROJECT>
   <SEQUENCING_PROJECT>
$locusTag
    </SEQUENCING_PROJECT>
 </SUBMISSION_PROJECT>
    </PROJECT>
</PROJECT_SET>
)

   
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

This script is used to create, modify, and manage projects in the European Nucleotide Archive (ENA). It also supports various actions such as ADD, MODIFY, CANCEL, SUPPRESS, KILL, HOLD, RELEASE, ROLLBACK, VALIDATE, and RECEIPT on any object.

=head1 ACTIONS

The following actions are supported (case independent):

=over 4

=item B<SHOW>

Show the XML code for a project. Note: Related projects cannot be retrieved from the API.

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

Release a project or any object.

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

This script provides simplyfied commandline client to the ENA Project and object API.

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

=item B<Release any ENA object with an accession>

   ena.pl RELEASE object --accession ERZXXXXXXX  --username user --pass "pass" -prod --verbose --releasedate 2024-12-01


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

