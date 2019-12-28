#!/bin/perl
#==============================================================================
# Script to identify unauthorized WiFi APs 
#
# Usage: $0 [options] 
#   Where options: 
#       -h          this help
#       -l 2        enable debug with level X 0-3 (nothing-high)
#       -v          be verbose
#		-i url		URL to JSON with authorized APs
#       -o url      URL to report rogue APs
#       -s file     Text file with dump of `sudo iw wlan0 scan`
#
# See documentation at the bottom
#
# Author: Eugene Taylashev, under the MIT License
#
#Copyright (c) 2019-2020 Eugene Taylashev
#
#Permission is hereby granted, free of charge, to any person obtaining
#a copy of this software and associated documentation files (the
#"Software"), to deal in the Software without restriction, including
#without limitation the rights to use, copy, modify, merge, publish,
#distribute, sublicense, and/or sell copies of the Software, and to
#permit persons to whom the Software is furnished to do so, subject to
#the following conditions:
#
#The above copyright notice and this permission notice shall be
#included in all copies or substantial portions of the Software.
#
#THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
#EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
#MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
#NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
#LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
#OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
#WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
#
#==============================================================================

use utf8;
use Getopt::Long;
use Data::Dumper;
use LWP::UserAgent;
use JSON;
#use URI::Encode qw(uri_encode uri_decode);

use strict;                 # Good practice
use warnings;               # Good practice

#==== Global vars ==========
my $gisVerbose = 0;     #-- be Verbose flag. See sub dlog
my $giLogLevel = 0;     #  Debug level: 0 - no debug errors only, 1 - important only, 2 - also sub in/out, 3 - everything
my $gisTest = 0;        #-- flag to run self-tests (no useful activity)

my $gsScanCmd = 'sudo iw wlan0 scan';
my ($gsInURL, $gsOutURL, $gsScanFile);
my %gaAuthorized; 		#-- hash for authorized APs BSS->SSID
my @gaUnauthorized;	#-- list of hashes for unauthorized APs

#-- Logging and tracking vars
my $gsLogFile;        #-- filename for logging/debugging
my $ghLogFile;        #-- file handler for logging/debugging
my @gaLogTime;          #-- array to store start time for subs
my $giLogIndent = 0;  #-- space indent for log formatting
$gaLogTime[0] = time(); 
my $giAPprocessed = 0;   #-- counter of processed APs

#-- Supporting vars
my $gsDirSeparator = '/';
my ($sec,$min,$hour,$day, $mon, $year) = (localtime)[0..5];     #-- get current date for log filename
my $curr_date = sprintf( "%04d%02d%02d", 1900+$year, 1+$mon, $day);
my $curr_time = sprintf( "%02d:%02d:%02d", $hour,$min,$sec);
my $help;


#--  command line options
my %args = ("help|h|?" => \$help,   #-- show help and exit
    "input|i=s" => \$gsInURL,       #-- input REST API URL or file with list of Authorized APs
    "output|o=s" => \$gsOutURL,     #-- reporting REST API URL or file with list of detected unauthorized APs
    "scan|s=s" => \$gsScanFile,     #-- file with WiFi scan results
    "log|l=i" => \$giLogLevel,    #-- set log/debug level
    "verbose|v"  => \$gisVerbose      #-- set flag to be verbose
);

#==== Constants for this script ==========
 use constant {
    DIR_LOGS    => 'logs'
};#use constant

#====== Sub prototypes ======
sub verifyAPs_file();
sub readAPfile($);
sub countSecs($);
sub myFtest($$);
sub myFopen($$$);
sub getFileName($);
sub getFileBase($);
sub startDebug();
sub stopDebug();
sub dlog($;$$$);
sub exitApp($);
sub usage();

#-- Exit by Ctrl-C 
$SIG{INT} = sub { stopDebug(); die "Interrupted by user\n"; };
$| = 1;  # autoflush

#-- Capture warnings into the log file with debug level 2
local $SIG{__WARN__} = sub {
    my $message = shift;
    dlog('warn:'.$message,2);
};

#==============================================================================
# Start of MAIN()
#==============================================================================
#-- parse command line options
GetOptions (%args) or usage();
usage() if $help;

#-- Create filename for logs
$gsLogFile = getFileBase($0).'-'.$curr_date.'.log';
#-- modify path if DIR_LOGS exists
$gsLogFile = DIR_LOGS . $gsDirSeparator . $gsLogFile if( -d DIR_LOGS );

startDebug();       #-- Start debuging

#-- Report settings
dlog((defined $gsInURL?'':'not ')."ok - Input URL/file with authorised APs=$gsInURL", 1, __LINE__);
dlog((defined $gsScanFile?'':'not ')."ok - WiFi scan results=$gsScanFile", 1, __LINE__);
dlog("ok - Log level=$giLogLevel", 1, __LINE__) if $giLogLevel > 0;
dlog("ok - Log file=$gsLogFile", 1, __LINE__) if $giLogLevel > 0;
dlog((myFtest('s',$gsScanFile)?'':'not ')."ok - the scan dump file is $gsScanFile", 1, __LINE__);

readAPfile($gsInURL) if defined $gsInURL;
verifyAPs_file();

#-- We are done
dlog(($giAPprocessed > 0?'':'not ')."ok - Processed $giAPprocessed APs in ".
    countSecs(time()-$gaLogTime[0]), 1);

dlog( "\nok - Done in ". countSecs(time()-$gaLogTime[0]), 1, __LINE__);
print "See logs in $gsLogFile\n" if $ghLogFile && $gisVerbose;
stopDebug(); #-- close the debug file
exit(0);
#==================================== End of MAIN =============================


#------------------------------------------------------------------------------
# Process the scan dump file
#------------------------------------------------------------------------------
sub verifyAPs_file(){
    my $sub_name = 'verifyAPs_file';  dlog("+++++ $sub_name: ", 2, __LINE__ );
    
    my $hFile;
    my $iRecs = 0;  #-- set element counter
#$gsScanCmd
    if( ! myFtest('s',$gsScanFile) ){
        derr( "not ok - the scan dump file $gsScanFile does not exists. ");
        dlog("----- sub $sub_name -not ok", 2, __LINE__ );
        return -1;
    } #if
    
    #-- open dump file
	myFopen( \$hFile, "<:encoding(utf8)", $gsScanFile );
    if( !$hFile ) {
        derr("not ok - Could not open the scan dump file $gsScanFile: $!" );
        dlog("----- sub $sub_name -not ok", 2, __LINE__ );
        return -1;
    } else {
        dlog( "ok - opened the scan dump file $gsScanFile for processing", 1, __LINE__);
    }#if + else

	my ($iLines, $iSkiped, $sBSS, $sSSID, $sLastSeen, $iKnown, $iNew, $sDetails) = (0,0,'','','',0,0,'');
	my $isBSS = 0;
	while(my $sLine = <$hFile>) {
		chomp $sLine;
		++$iLines;
		if( 	  $sLine =~ /^BSS\s+(\S+)\(/i ){
			my $sTmp = $1; 

			#-- close prev BSS
			if( $isBSS ){
				#-- verify if known
				if(  defined $gaAuthorized{$sBSS} ) {
					#-- authorised AP
					dlog( "ok - $sBSS -> $sSSID is authorised", 2, __LINE__ );
					++$iKnown;
				} else {
					#-- unauthorised AP
					dlog( "not ok - $sBSS -> $sSSID is unauthorised", 1, __LINE__ );
					my $aAP = {};  #-- anon hash
					$$aAP{'BSS'} = $sBSS; $$aAP{'SSID'} = $sSSID;
					$$aAP{'LastSeen'} = $sLastSeen;
					#$$aAP{'info'} = $sDetails;
					push @gaUnauthorized, $aAP;
					++$iNew;
				}#if + else
			}#if

			#-- start new BSS
			$sBSS = $sTmp; $isBSS = 1; $sSSID =''; $sDetails=''; $sLastSeen='';

		} elsif ( $sLine =~ /^\s+SSID: (.*)$/i && $isBSS ){
			$sSSID = $1;
		} elsif ( $sLine =~ /^\s+last seen:\s+(.*)$/i && $isBSS ){
			$sLastSeen = $1;
		}#if+elsif

		if( $isBSS ){
			$sDetails .= "\n" . $sLine;
		}#if
		

    }#while

    close( $hFile )   if $hFile;    #-- close the scan dump file
    dlog("processed $iLines lines, skiped $iSkiped lines", 2, __LINE__ );
    dlog("ok - Identified $iKnown known and $iNew new APs", 1, __LINE__ );
	$giAPprocessed = $iKnown + $iNew;
    dlog( Dumper( \@gaUnauthorized ), 4, __LINE__ );
    dlog( "----- ok - $sub_name", 2);
    return $iRecs;
}#sub verifyAPs_file()


#------------------------------------------------------------------------------
# Read list of authorized APs into an array
#------------------------------------------------------------------------------
sub readAPfile($){
    my ( $sJFile) = @_;
    my $sub_name = 'readAPfile'; 
    dlog("+++++ $sub_name: from the file $sJFile", 2, __LINE__ );
    my ($fh, $iLine, $sLine, $iBSS, $sBSS, $sSSID);
    
    #-- check that JSON file exists
	if( ! myFtest('s',$sJFile) ){
		derr( "File $sJFile does NOT exist" );
	    dlog("----- not ok - $sub_name", 2, __LINE__ );
		return -1;
	}#if 

    #-- open the JSON file for read
    open( $fh, "<:encoding(utf8)", $sJFile );
	if( !$fh ) {
		derr( "Could not open the $sJFile file: $!" );
	    dlog("----- not ok - $sub_name", 2, __LINE__ );
		return -1;
	}#if 
		
    #-- for all records
    $iLine = 0;  $iBSS = 0; #-- set counters to 0
    while($sLine = <$fh>){
        chomp $sLine; ++$iLine;
        next if $sLine =~ /^\s*#/;        #-- skip comments
        next if $sLine =~ /^\s*$/;        #-- skip empty lines
		if( $sLine =~ /^([0-9a-f:]+);(.*)$/i ){
			$sBSS = $1; $sSSID = $2; ++$iBSS;
			$gaAuthorized{$sBSS} = $sSSID if ! defined $gaAuthorized{$sBSS};
		}#if
        
    }#while

    close( $fh )   if $fh;    #-- close JSON file
    dlog( Dumper( \%gaAuthorized ), 4, __LINE__ );
    dlog(" processed $iLine records, inserted $iBSS APs", 2, __LINE__ );
    dlog("----- ok - $sub_name", 2, __LINE__ );
    return $iLine;
}#sub readAPfile($)


sub trim($){my ($s)=@_; $s=~ s/^\s*//; $s=~ s/\s*$//; return $s;}#-- Trim edge spaces
sub removeLastComma($){my($s)=@_;$s =~ s/,\s*$//; return $s;}  #-- remove trail comma symbols
sub q2($){my $s=shift; return "'".$s."'"; }
sub q2c($){my $s=shift; return "'".$s.'\','; }
sub qq2($){my $s=shift; return '"'.$s.'"'; }
sub qq2c($){my $s=shift; return '"'.$s.'",'; }
sub isList($){my $r=shift; return (ref($r) eq 'ARRAY');}
sub isHash($){my $r=shift; return (ref($r) eq 'HASH');}

#------------------------------------------------------------------------------
# Converts MAC-48 as string into long int
# Source: https://www.perlmonks.org/?node_id=440768
#------------------------------------------------------------------------------
sub mac_to_num($) {
  my $mac_hex = shift;

  $mac_hex =~ s/://g;
  $mac_hex =~ s/-//g;
  $mac_hex =~ s/\.//g;

  $mac_hex = substr(('0'x12).$mac_hex, -12);
  my @mac_bytes = unpack("A2"x6, $mac_hex);

  my $mac_num = 0;
  foreach (@mac_bytes) {
    $mac_num = $mac_num * (2**8) + hex($_);
  }

  return $mac_num;
}#sub mac_to_num($)


#------------------------------------------------------------------------------
# Converts long int into MAC-48 as string with :
# Source: https://www.perlmonks.org/?node_id=440768
#------------------------------------------------------------------------------
sub num_to_mac($) {
  my $mac_num = shift;

  my @mac_bytes;
  for (1..6) {
    unshift(@mac_bytes, sprintf("%02x", $mac_num % (2**8)));
    $mac_num = int($mac_num / (2**8));
  }

  return join(':', @mac_bytes);
}#sub num_to_mac($)


#------------------------------------------------------------------------------
# Converts a decimal IP to a dotted IP
# Source: http://ddiguru.com/blog/25-ip-address-conversions-in-perl
#------------------------------------------------------------------------------
sub dec2ip ($) {
    join '.', unpack 'C4', pack 'N', shift;
}#sub dec2ip
 
#------------------------------------------------------------------------------
# Converts a dotted IP to a decimal IP
# Source: http://ddiguru.com/blog/25-ip-address-conversions-in-perl
#------------------------------------------------------------------------------
sub ip2dec ($) {
    unpack N => pack CCCC => split /\./ => shift;
}#sub ip2dec


#------------------------------------------------------------------------------
# Private -X testing function to address long and UTF-16 names on Win32
# Input: $cmd - command line d/f/each
#        $obj - filename or handler
# Output: same as -X
# For Win32 requires: use Win32::LongPath;
# Updated on Jun 17, 2017 by Eugene Taylashev
#------------------------------------------------------------------------------
sub myFtest($$) {
    my ($cmd,$obj) = @_;
    if( $^O eq 'MSWin32' ){     #-- MS Windows approach
        return testL ($cmd, $obj);
    } else {
        return -d $obj if $cmd eq 'd';
        return -f $obj if $cmd eq 'f';
        return -s $obj if $cmd eq 's';
    } #if + else
    
}#sub myFtest


#------------------------------------------------------------------------------
# Private file opener to address long and UTF-16 names on Win32
# Input: for non-MS same as for open, 
#        for MS a reference: openL (\$FH, '>:encoding(UTF-8)', $file)
# Output: same as open
# For Win32 requires: use Win32::LongPath;
# Updated on Jun 20, 2019 by Eugene Taylashev
#------------------------------------------------------------------------------
sub myFopen($$$){
    my ($fh, $mode,@EXPR) = @_;
    return ($^O eq 'MSWin32'? openL($fh, $mode, @EXPR): open($$fh, $mode, @EXPR));
}#sub myFopen($$$)


#------------------------------------------------------------------------------
# Get file extension (suffix)
#------------------------------------------------------------------------------
sub getFileSuff($) {
    my ($f) = @_;
    return ( $f =~ /\.([^.]+)$/ )?$1:'';
#    my $ext = '';
#    $ext = $1
#        if( $f =~ /\.([^.]+)$/ );
#    return $ext;
}#sub getFileSuff


#------------------------------------------------------------------------------
# Get file name with extension (suffix) but without path 
# for MS Windows/Unix and ZIP#file formats
# Returns file name or original string
#------------------------------------------------------------------------------
sub getFileName($) {
    my ($f) = @_;
    $f =~ s/.*\\//; #-- remove MS Windows path
    $f =~ s/.*\///; #-- remove Unix path
    $f =~ s/.*#//;  #-- remove zip out of zip#file_name
    return $f;
}#sub getFileName


#------------------------------------------------------------------------------
# Get file name without last extension (suffix) and dir path
# Returns file name or original string
#------------------------------------------------------------------------------
sub getFileBase($) {
    my ($f) = @_; $f = getFileName($f); $f =~ s/\.[^.]+$//; #-- remove the last extension
    return $f;
}#sub getFileBase


#------------------------------------------------------------------------------
# Get dir path out of file name
# Returns dir path  or original string
#------------------------------------------------------------------------------
sub getFilePath($) {
    my ($f) = @_; $f =~ s/[^\/\\]+$//;  #-- remove everything after / or \
    return $f;
}#sub getFilePath


#------------------------------------------------------------------------------
#  Read entire file in one operation and return as string
#  ToDO: recognize Unicode or ASCII
#------------------------------------------------------------------------------
sub readEntireFile ($;$) {
    my ($sFileName, $sEncode) = @_;
    my $sRes = '';  my $fh;
    local $/ = undef;
    
    $sEncode = 'raw' if( !$sEncode);
    #-- try to open as raw
#'<:raw'; "<:utf8"; "<:encoding(UTF-16)"; "<:encoding(windows-1251)" "<:encoding(UCS-2le)"
    if( ! myFopen( \$fh, "<:$sEncode", $sFileName ) ) {
        dlog("Couldn't open file $sFileName: $!", 1, __LINE__);
        return undef;
    }#if
    
    #-- Read BOM - TBDef
                    
    binmode $fh;
    $sRes = <$fh>;
    close $fh;    
    
    #-- check that file is utf-8
#    return readEntireFile($sFileName, 'utf-8') if( is_utf8($sRes) and $sEncode ne 'utf-8' );
    return $sRes;
}#sub readEntireFile


#------------------------------------------------------------------------------
#  Convert number of seconds into string with hours, min and secs
#------------------------------------------------------------------------------
sub countSecs($) {
    my ($iSec) = @_;
    my $sRes = '';
    if( $iSec > 3600 ) {
        $sRes .= int($iSec/3600) . ' h ';
        $iSec = $iSec % 3600;
    }#if
    if( $iSec > 60 ) {
        $sRes .= int($iSec/60) . ' min ';
        $iSec = $iSec % 60;
    }#if
    $sRes .= $iSec . ' sec';
    return $sRes;
}#sub


#------------------------------------------------------------------------------
# Start logging/debugging by creating a log file
#------------------------------------------------------------------------------
sub startDebug() {
    return 0 if ( $giLogLevel <= 0 );           #-- debug is disabled
    return 0 if ( length($gsLogFile) < 3 ); #-- debug filename is not specified 
    return 0 if( $ghLogFile );              #-- file already opened
    #-- create or open for append the log file
    open( $ghLogFile, ">>:encoding(utf8)", $gsLogFile) 
            or exitApp( "Could not create/open the debug file $gsLogFile: $!" );
    print $ghLogFile "\n\n============================ $curr_date at $curr_time  =================================\n";
    return 1;
}#sub startDebug


#------------------------------------------------------------------------------
# Stop logging/debugging by closing the log file
#------------------------------------------------------------------------------
sub stopDebug(){
    close( $ghLogFile )   if $ghLogFile;    #-- close the debug file
}#sub stopDebug


#------------------------------------------------------------------------------
#  Output debug and verbose information based on debug level
#  Input: message to output,[optional]: debug level, default=1; code line; code file
#  Debug level: 0 - no debug errors only, 1 - important only, 2 - also sub in/out, 3 - everything
#------------------------------------------------------------------------------
sub dlog($;$$$) {
    my $message = shift;
    my $level = @_?shift:1;
    my ($ln,$fn) = @_;  #-- code line, code filename

    return undef if $giLogLevel < $level; #-- ignore everything where local level bigger than global level
    
    
    #-- check current indent
    $gaLogTime[++$giLogIndent] = time() if( $message =~ /\+\+\+\+\+/);
    $message = ('  ' x $giLogIndent) . $message;
    $message .=' in '. countSecs(time()-$gaLogTime[$giLogIndent--]) 
        if( $message =~ /\-\-\-\-\-/ && $giLogIndent>0);
    
    if( $gisVerbose && $level <= 1){
        my $s = trim($message);
        #-- encoding
        utf8::encode($s); # if utf8::is_utf8($s);
        print $s,"\n" ; # out message if beVerbose and level 1 or 0
    } #if gisVerbose
    
    #-- Add file name and line
    $message .= " [at line $ln" if (defined $ln);
    $message .= " in $fn" if (defined $fn);
    $message .= ']' if (defined $ln || defined $fn);
    
    if ($ghLogFile) {
        print $ghLogFile "$message\n" ; #decode_utf8()
    } else {
        print STDERR "$message\n" ;
    }#if
    
    #-- print errors to the screen
    print STDERR "$message\n"
        if ($ghLogFile and $level==0);
    return 1;
}#sub dlog


#------------------------------------------------------------------------------
#------------------------------------------------------------------------------
sub derr($;$$$) {
    my $message = shift;
    my $level = @_?shift:0;
    dlog($message,0,@_);
}#sub derr


#------------------------------------------------------------------------------
#  Abort application execution with a message
#------------------------------------------------------------------------------
sub exitApp( $ ) {
    my ($sMsg) = @_;
    #dlog( $sMsg, 0);
    die "Critical error: $sMsg. Aborting...\n";
}#sub exitApp

#------------------------------------------------------------------------------
#  Output information about the script
#------------------------------------------------------------------------------
sub usage() {
    my $sTmp = <<EOBU;

Script to identify unauthorized (rogue) WiFi Access Points (APs)
    
Usage: $0 [options]

    [options]:
    -h | --help : this help
    -v | --verbose : be verbose
    -l | --log=1 : Enable logging with level 1-3. 1-few, 3-everything
    -c | --config=file.ini : specify configuration file
    -i | --input=url : REST API url to obtain authorized APs
    -o | --output=url : REST API url to report unauthorized APs
    -s | --scan=file.txt : file with WiFi scan results
EOBU
    print $sTmp,"\n";
    exit(0);

}#sub


=pod

=head 1 Installation on Arch Linux

sudo pacman -S perl-lwp-protocol-https
sudo pacman -Ss perl-json
sudo pacman -S perl-uri


=head1 Updates
  Dec 28, 2019 - add ScanCommand, known APs
  Dec 27, 2019 - add read authorized APs, report unauthorized
  Dec 25, 2019 - initial draft

=cut