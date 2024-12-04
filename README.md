# ena-tool
A simple command-line tool to create and manage ENA projects and object.

A Perl script that allows to create submission projects and umbrella projects in ENA.
Also: can send any status change request to the XML api.

## Installation

Don't need to install anything, but just in case.

    perl Makefile.PL
    make install

  ### Dependencies  
  
- Perl >5.20
- 'Getopt::Long';
- 'LWP::UserAgent';
- 'HTTP::Request::Common';
- 'MIME::Base64';
- 'Pod::Usage';
- 'POSIX';
- 'XML::Simple';
- 'File::Temp';
  
    

## Documentation 

See https://github.com/mdondrup/ena-tool/blob/main/README.pod

Inline POD documentation, run: 

    perldoc ena.pl

Run the the script without options for usage.    
    

