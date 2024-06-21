use inc::Module::Install;

name 'ena';
version '0.01';
abstract 'Create and manage projects in the European Nucleotide Archive (ENA)';
author 'Michael Dondrup <michael.dondrup@uib.no>';
license 'bsd';

requires 'Getopt::Long';
requires 'LWP::UserAgent';
requires 'HTTP::Request::Common';
requires 'MIME::Base64';
requires 'Pod::Usage';
requires 'POSIX';
requires 'XML::Simple';
requires 'File::Temp';
requires 'Data::Dumper';

WriteAll;
