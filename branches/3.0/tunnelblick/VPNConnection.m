/*
 * Copyright (c) 2004, 2005, 2006, 2007, 2008, 2009 Angelo Laub
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License version 2
 *  as published by the Free Software Foundation.
 *
 *  This program is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *  GNU General Public License for more details.
 *
 *  You should have received a copy of the GNU General Public License
 *  along with this program (see the file COPYING included with this
 *  distribution); if not, write to the Free Software Foundation, Inc.,
 *  59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
 */

#import "VPNConnection.h"
#import <Security/Security.h>
#import <CoreServices/CoreServices.h>
#import <Foundation/NSDebug.h>
#import <signal.h>
#import "KeyChain.h"
#import "NetSocket.h"
#import "NetSocket+Text.h"
#import "NSApplication+LoginItem.h"
#import "helper.h"
#import "MenuController.h"
#import "TBUserDefaults.h"
#include <sys/param.h>
#include <sys/mount.h>

extern TBUserDefaults  * gTbDefaults;

@interface VPNConnection()          // PRIVATE METHODS

-(BOOL)             configNotProtected:         (NSString *)        configFile;
-(void)             connectToManagementSocket;
-(BOOL)             copyFile:                   (NSString *)        source
                      toFile:                   (NSString *)        target
                   usingAuth:                   (AuthorizationRef)  authRef;
-(BOOL)             makeSureFolderExistsAtPath: (NSString *)        folderPath
                                     usingAuth:  (AuthorizationRef) authRef;
-(NSString *)       getConfigToUse:             (NSString *)        cfgPath
                             orAlt:             (NSString *)        altCfgPath;
-(unsigned int)     getFreePort;
-(void)             killProcess;                                                // Kills the OpenVPN process associated with this connection, if any
-(BOOL)             isSampleConfigurationAtPath:(NSString *)        cfgPath;
-(BOOL)             onRemoteVolume:             (NSString *)        cfgPath;
-(void)             processLine:                (NSString *)        line;
-(BOOL)             protectConfigurationFile:   (NSString *)        configFile
                                   usingAuth:   (AuthorizationRef)  authRef;
-(BOOL)             setConfigurationFileAtPath: (NSString *)        configFilePath
                                       toOwner: (int)               owner
                                      andGroup: (int)               group
                               withPermissions: (NSString *)        permissions
                                     usingAuth: (AuthorizationRef) authRef;
-(void)             setConnectedSinceDate:      (NSDate *)          value;
-(void)             setManagementSocket:        (NetSocket *)       socket;
@end

@implementation VPNConnection

-(id) initWithConfig:(NSString *)inConfig inDirectory: (NSString *) inDir isInDeploy: (BOOL) inDeploy
{	
    if (self = [super init]) {
        configFilename = [inConfig copy];
        configDirPath = [inDir copy];
        configDirIsDeploy = inDeploy;
        portNumber = 0;
		pid = 0;
		connectedSinceDate = [[NSDate alloc] init];
		[self addToLog:[[NSApp delegate] openVPNLogHeader] atDate: nil];
        lastState = @"EXITING";
        NSArray  * pipePathComponents = [[inDir stringByAppendingPathComponent: inConfig] pathComponents];
        NSArray  * pipePathComponentsAfter1st = [pipePathComponents subarrayWithRange: NSMakeRange(1, [pipePathComponents count]-1)];
        NSString * pipePath = [NSString stringWithFormat: @"/tmp/tunnelblick-%@.logpipe",
                               [pipePathComponentsAfter1st componentsJoinedByString: @"-"]];
		myAuthAgent = [[AuthAgent alloc] initWithConfigName:[self configName]];
        myPipeBuffer = [[NSMutableString alloc] initWithCapacity: 10000];
        myPipe = [[NamedPipe alloc] initPipeReadingFromPath: pipePath
                                              sendingDataTo: @selector(appendDataToLog:)
                                                  whichIsIn: self];
        if ( ! myPipe ) {
            NSLog(@"Unable to create pipe %@ for up/down scripts to write to OpenVPN Log", pipePath);
        }
        
    }
    return self;
}

-(NSString *) description
{
	return [NSString stringWithFormat:@"VPN Connection %@", configFilename];
}

-(void) setConfigFilename:(NSString *)inName 
{
    if (inName!=configFilename) {
	[configFilename release];
	configFilename = [inName retain];
    }
}

-(void)setPort:(unsigned int)inPort 
{
	portNumber = inPort;
}

-(unsigned int)port 
{
    return portNumber;
}

- (void) setManagementSocket: (NetSocket*) socket
{
    [socket retain];
    [managementSocket autorelease];
    managementSocket = socket;
    [managementSocket setDelegate: self];    
}

- (void) dealloc
{
    [self disconnect:self];
    [logStorage release];
    [managementSocket close];
    [managementSocket setDelegate: nil];
    [managementSocket release]; 
    [lastState release];
    [configFilename release];
    [configDirPath release];
    [connectedSinceDate release];
    [myAuthAgent release];
    [myPipe release];
    [myPipeBuffer release];
    [super dealloc];
}


- (IBAction) connect: (id) sender
{
    if (  ! [gTbDefaults boolForKey:@"skipWarningAboutSimultaneousConnections"]  ) {
        // Count the total number of connections and what their "Set nameserver" status was at the time of connection
        int numConnections = 1;
        int numConnectionsWithSetNameserver = 0;
        if (  useDNSStatus(self)  ) {
            numConnectionsWithSetNameserver = 1;
        }
        VPNConnection * connection;
        NSEnumerator* e = [[[NSApp delegate] myVPNConnectionDictionary] objectEnumerator];
        while (connection = [e nextObject]) {
            if (  ! [[connection state] isEqualToString:@"EXITING"]  ) {
                numConnections++;
                if (  [connection usedSetNameserver]  ) {
                    numConnectionsWithSetNameserver++;
                }
            }
        }
        
        if (  numConnections != 1  ) {
            int button = TBRunAlertPanelExtended(NSLocalizedString(@"Do you wish to connect?", @"Window title"),
                                                 [NSString stringWithFormat:NSLocalizedString(@"Multiple simultaneous connections would be created (%d with 'Set nameserver', %d without 'Set nameserver').", @"Window text"), numConnectionsWithSetNameserver, (numConnections-numConnectionsWithSetNameserver) ],
                                                 NSLocalizedString(@"Connect", @"Button"),  // Default button
                                                 NSLocalizedString(@"Cancel", @"Button"),   // Alternate button
                                                 nil,
                                                 @"skipWarningAboutSimultaneousConnections",
                                                 NSLocalizedString(@"Do not warn about this again", @"Checkbox name"),
                                                 nil);
            if (  button == NSAlertAlternateReturn  ) {
                return;
            }
        }
    }
    
	NSString *cfgPath = [configDirPath stringByAppendingPathComponent: [self configFilename]];
    NSString *altPath = [NSString stringWithFormat:@"/Library/Application Support/Tunnelblick/Users/%@/%@", NSUserName(), [self configFilename]];

    if ( ! (cfgPath = [self getConfigToUse:cfgPath orAlt:altPath]) ) {
        return;
    }
    
    authenticationFailed = NO;
    
	NSString* path = [[NSBundle mainBundle] pathForResource: @"openvpnstart" 
													 ofType: nil];
    [managementSocket close];
    [managementSocket setDelegate: nil];
    [managementSocket release];
    managementSocket = nil;
    
    [self setPort:[self getFreePort]];
	NSTask* task = [[[NSTask alloc] init] autorelease];
	[task setLaunchPath: path]; 
		
	NSString *portString = [NSString stringWithFormat:@"%d",portNumber];
	NSArray *arguments;
		
	NSString *useDNS = @"0";
	if(useDNSStatus(self)) {
        NSString * useDownRootPluginKey = [[[self configFilename] stringByDeletingPathExtension] stringByAppendingString: @"-useDownRootPlugin"];
        if (  [gTbDefaults boolForKey: useDownRootPluginKey]  ) {
            useDNS = @"2";
        } else {
            useDNS = @"1";
        }
        usedSetNameserver = TRUE;
	} else {
        usedSetNameserver = FALSE;
    }

    NSString *altCfgLoc = @"0";
    if ( [cfgPath isEqualToString:altPath] ) {
        altCfgLoc = @"1";
    } else if (  configDirIsDeploy  ) {
        altCfgLoc = @"2";
    }
    
    NSString * noMonitorKey = [[[self configFilename] stringByDeletingPathExtension] stringByAppendingString: @"-notMonitoringConnection"];
    NSString * noMonitor = @"0";
    if (  [useDNS isEqualToString: @"0"] || [gTbDefaults boolForKey: noMonitorKey]  ) {
        noMonitor = @"1";
    }
    
    // for OpenVPN v. 2.1_rc9 or higher, clear skipScrSec so we use "--script-security 2"
    
    NSDictionary * vers = getOpenVPNVersion();
    int intMajor =  [[vers objectForKey:@"major"]  intValue];
    int intMinor =  [[vers objectForKey:@"minor"]  intValue];
    int intSuffix = [[vers objectForKey:@"suffix"] intValue];
    
	NSString *skipScrSec =@"1";
    if ( intMajor == 2 ) {
        if ( intMinor == 1 ) {
            if (  [[vers objectForKey:@"preSuffix"] isEqualToString:@"_rc"] ) {
                if ( intSuffix > 8 ) {
                    skipScrSec = @"0";
                }
            } else {
                skipScrSec = @"0";
            }
        } else if ( intMinor > 1 ) {
            skipScrSec = @"0";
        }
    } else if ( intMajor > 2 ) {
        skipScrSec = @"0";
    }
    
    NSPipe * errPipe = [[NSPipe alloc] init];
    [task setStandardError: errPipe];
    NSPipe * stdPipe = [[NSPipe alloc] init];
    [task setStandardOutput: stdPipe];
    
    arguments = [NSArray arrayWithObjects:@"start", [self configFilename], portString, useDNS, skipScrSec, altCfgLoc, noMonitor, nil];
    
    NSString * logText = [NSString stringWithFormat:@"*Tunnelblick: Attempting connection with %@%@; Set nameserver = %@%@",
                          configFilename,
                          (  [altCfgLoc isEqualToString:@"1"]
                           ? @" using shadow copy"
                           : (  [altCfgLoc isEqualToString:@"2"]
                              ? @" from Deploy"
                              : @""  )  ),
                          useDNS,
                          (  [noMonitor isEqualToString:@"1"]
                           ? @"; not monitoring connection"
                           : @"; monitoring connection" )
                          ];
    [self addToLog: logText atDate: nil];

    NSMutableArray * escapedArguments = [NSMutableArray arrayWithCapacity:40];
    int i;
    for (i=0; i<[arguments count]; i++) {
        [escapedArguments addObject: [[[arguments objectAtIndex: i] componentsSeparatedByString: @" "] componentsJoinedByString: @"\\ "]];
    }
    
    [self addToLog: [NSString stringWithFormat: @"*Tunnelblick: %@ %@",
                     [[path componentsSeparatedByString: @" "] componentsJoinedByString: @"\\ "],
                     [escapedArguments componentsJoinedByString: @" "]]
            atDate: nil];
    
	[task setArguments:arguments];
	[task setCurrentDirectoryPath: configDirPath];
	[task launch];
	[task waitUntilExit];
    
    // Standard output has command line that openvpnstart used to start OpenVPN; copy it to the log
    NSFileHandle * file = [stdPipe fileHandleForReading];
    NSData * data = [file readDataToEndOfFile];
    [file closeFile];
    [stdPipe release];
    NSString * openvpnstartOutput = [[[NSString alloc] initWithData: data encoding: NSUTF8StringEncoding] autorelease];
    openvpnstartOutput = [openvpnstartOutput stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    [self addToLog: [NSString stringWithFormat:@"*Tunnelblick: %@", openvpnstartOutput] atDate: nil];

    int status = [task terminationStatus];
    if (  status != 0  ) {
        if (  status == 240  ) {
            openvpnstartOutput = @"Internal Tunnelblick error: openvpnstart syntax error";
        } else {
            file = [errPipe fileHandleForReading];
            data = [file readDataToEndOfFile];
            [file closeFile];
            openvpnstartOutput = [[[NSString alloc] initWithData: data encoding: NSUTF8StringEncoding] autorelease];
            openvpnstartOutput = [openvpnstartOutput stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        }
        
        [self addToLog: [NSString stringWithFormat:NSLocalizedString(@"*Tunnelblick: openvpnstart status #%d: %@", @"OpenVPN Log message"), status, openvpnstartOutput]
                atDate: nil];
    }
    
    [errPipe release];
    
	[self setState: @"SLEEP"];
    
	//sleep(1);
	[self connectToManagementSocket];
	// Wait some time for the demon to start up before connecting to the management interface:
	//[NSTimer scheduledTimerWithTimeInterval: 3.0 target: self selector: @selector(connectToManagementSocket) userInfo: nil repeats: NO];
}


- (NSDate *)connectedSinceDate {
    return [[connectedSinceDate retain] autorelease];
}

- (void)setConnectedSinceDate:(NSDate *)value {
    if (connectedSinceDate != value) {
        [connectedSinceDate release];
        connectedSinceDate = [value copy];
    }
}

- (BOOL) usedSetNameserver {
    return usedSetNameserver;
}


- (IBAction) toggle: (id) sender
{
	if (![self isDisconnected]) {
		[self disconnect: sender];
	} else {
		[self connect: sender];
	}
}


- (NSString*) configFilename
{
    return [[configFilename retain] autorelease];
}

- (NSString*) configName
{
    return [[[[self configFilename] stringByDeletingPathExtension] retain] autorelease];
}

- (void) connectToManagementSocket
{
    [self setManagementSocket: [NetSocket netsocketConnectedToHost: @"127.0.0.1" port: portNumber]];   
}

- (IBAction) disconnect: (id)sender 
{
    pid_t savedPid = 0;
	if(pid > 0) {
        savedPid = pid;
		[self killProcess];
	} else {
		if([managementSocket isConnected]) {
			[managementSocket writeString: @"signal SIGTERM\r\n" encoding: NSASCIIStringEncoding];
		}
        sleep(5);       // Wait five seconds for OpenVPN to disappear
	}
    
    [self emptyPipe];
    
    [[NSApp delegate] removeConnection:self];
    [self setState:@"EXITING"];
    
    if (  savedPid != 0  ) {
        [NSApp waitUntilNoProcessWithID: savedPid];     // Wait until OpenVPN process is completely gone
    }
    
    if (  ! [managementSocket peekData]  ) {
        [managementSocket close]; [managementSocket setDelegate: nil];
        [managementSocket release]; managementSocket = nil;
    }
}



// Kills the OpenVPN process associated with this connection, if any
-(void)killProcess 
{
	NSParameterAssert(pid > 0);
	NSString* path = [[NSBundle mainBundle] pathForResource: @"openvpnstart" 
													 ofType: nil];
	NSTask* task = [[[NSTask alloc] init] autorelease];
	[task setLaunchPath: path]; 
	NSString *pidString = [NSString stringWithFormat:@"%d", pid];
	NSArray *arguments = [NSArray arrayWithObjects:@"kill", pidString, nil];
	[task setArguments:arguments];
	[task setCurrentDirectoryPath: configDirPath];
    pid = 0;
	[task launch];
	[task waitUntilExit];
    
}

- (void) netsocketConnected: (NetSocket*) socket
{
    
    NSParameterAssert(socket == managementSocket);
    
    if (NSDebugEnabled) NSLog(@"Tunnelblick connected to management interface on port %d.", [managementSocket remotePort]);
    
    NS_DURING {
		[managementSocket writeString: @"pid\r\n" encoding: NSASCIIStringEncoding];
        [managementSocket writeString: @"state on\r\n" encoding: NSASCIIStringEncoding];    
        [managementSocket writeString: @"log on all\r\n" encoding: NSASCIIStringEncoding];
        [managementSocket writeString: @"hold release\r\n" encoding: NSASCIIStringEncoding];
    } NS_HANDLER {
        NSLog(@"Exception caught while writing to socket: %@\n", localException);
    }
    NS_ENDHANDLER
    
}

-(void)setPIDFromLine:(NSString *)line 
{
	if([line rangeOfString: @"SUCCESS: pid="].length) {
		@try {
			NSArray* parameters = [line componentsSeparatedByString: @"="];
			NSString *pidString = [parameters lastObject];
			pid = atoi([pidString UTF8String]);			
		} @catch(NSException *exception) {
			pid = 0;
		}
	}
}


- (void) processLine: (NSString*) line
{
    if (NSDebugEnabled) NSLog(@">openvpn: '%@'", line);
    
    if (![line hasPrefix: @">"]) {
        // Output in response to command to OpenVPN. Could be the PID command, or additional log output from LOG ON ALL
		[self setPIDFromLine:line];
		@try {
			NSArray* parameters = [line componentsSeparatedByString: @","];
            NSCalendarDate* date = nil;
            if ( [[parameters objectAtIndex: 0] intValue] != 0) {
                date = [NSCalendarDate dateWithTimeIntervalSince1970: [[parameters objectAtIndex: 0] intValue]];
            }
            NSString* logLine = [parameters lastObject];
			[self addToLog:logLine atDate:date];
		} @catch (NSException *exception) {
			
		}
		return;
	}
    // "Real time" output from OpenVPN.
    NSRange separatorRange = [line rangeOfString: @":"];
    if (separatorRange.length) {
        NSRange commandRange = NSMakeRange(1, separatorRange.location-1);
        NSString* command = [line substringWithRange: commandRange];
        NSString* parameterString = [line substringFromIndex: separatorRange.location+1];
        //NSLog(@"Found command '%@' with parameters: %@", command, parameterString);
        
        if ([command isEqualToString: @"STATE"]) {
            NSArray* parameters = [parameterString componentsSeparatedByString: @","];
            NSString* state = [parameters objectAtIndex: 1];
            if (NSDebugEnabled) NSLog(@"State is '%@'", state);
            [self setState: state];

            if([state isEqualToString: @"RECONNECTING"]) {
                [managementSocket writeString: @"hold release\r\n" encoding: NSASCIIStringEncoding];
            
            } else if ([state isEqualToString: @"CONNECTED"]) {
                NSDate *now = [[NSDate alloc] init];
                [[NSApp delegate] addConnection:self];
                [self setConnectedSinceDate:now];
                [now release];
            
            } else if ([state isEqualToString: @"EXITING"]) {
                [managementSocket close]; [managementSocket setDelegate: nil];
                [managementSocket release]; managementSocket = nil;
            }
            
        } else if ([command isEqualToString: @"PASSWORD"]) {
            if ([line rangeOfString: @"Failed"].length) {
                if (NSDebugEnabled) NSLog(@"Passphrase or user/auth verification failed");
                authenticationFailed = YES;
            } else {
                // Password request from server. If it comes immediately after a failure, inform user and ask what to do
                if (  authenticationFailed  ) {
                    authenticationFailed = NO;
                    id buttonWithDifferentCredentials = nil;
                    if (  [myAuthAgent authMode]  ) {               // Handle "auto-login" --  we were never asked for credentials, so authMode was never set
                        if ([myAuthAgent keychainHasCredentials]) { //                         so credentials in Keychain (if any) were never used, so we needn't delete them to rery
                            buttonWithDifferentCredentials = NSLocalizedString(@"Try again with different credentials", @"Button");
                        }
                    }
                    int alertVal = TBRunAlertPanel([NSString stringWithFormat:@"%@: %@", [self configName], NSLocalizedString(@"Authentication failed", @"Window title")],
                                                   NSLocalizedString(@"The credentials (passphrase or username/password) were not accepted by the remote VPN server.", @"Window text"),
                                                   NSLocalizedString(@"Try again", @"Button"),  // Default
                                                   buttonWithDifferentCredentials,              // Alternate
                                                   NSLocalizedString(@"Cancel", @"Button"));    // Other
                    if (alertVal == NSAlertAlternateReturn) {
                        [myAuthAgent deleteCredentialsFromKeychain];
                    }
                    if (  (alertVal != NSAlertDefaultReturn) && (alertVal != NSAlertAlternateReturn)  ) {	// If cancel or error then disconnect
                        [self disconnect:nil];
                        return;
                    }
                }

                // Find out whether the server wants a private key or user/auth:
                NSRange pwrange_need = [parameterString rangeOfString: @"Need \'"];
                NSRange pwrange_password = [parameterString rangeOfString: @"\' password"];
                if (pwrange_need.length && pwrange_password.length) {
                    if (NSDebugEnabled) NSLog(@"Server wants user private key.");
                    [myAuthAgent setAuthMode:@"privateKey"];
                    [myAuthAgent performAuthentication];
                    NSString *myPassphrase = [myAuthAgent passphrase];
					NSRange tokenNameRange = NSMakeRange(pwrange_need.length, pwrange_password.location - 6 );
					NSString* tokenName = [parameterString substringWithRange: tokenNameRange];
					if (NSDebugEnabled) NSLog(@"tokenName is  '%@'", tokenName);
                    if(myPassphrase){
                        [managementSocket writeString: [NSString stringWithFormat: @"password \"%@\" \"%@\"\r\n", tokenName, escaped(myPassphrase)] encoding:NSISOLatin1StringEncoding]; 
                    } else {
                        [self disconnect:self];
                    }

                } else if ([line rangeOfString: @"Auth"].length) {
                    if (NSDebugEnabled) NSLog(@"Server wants user auth/pass.");
                    [myAuthAgent setAuthMode:@"password"];
                    [myAuthAgent performAuthentication];
                    NSString *myPassword = [myAuthAgent password];
                    NSString *myUsername = [myAuthAgent username];
                    if(myUsername && myPassword){
                        [managementSocket writeString:[NSString stringWithFormat:@"username \"Auth\" \"%@\"\r\n", escaped(myUsername)] encoding:NSISOLatin1StringEncoding];
                        [managementSocket writeString:[NSString stringWithFormat:@"password \"Auth\" \"%@\"\r\n", escaped(myPassword)] encoding:NSISOLatin1StringEncoding];
                    } else {
                        [self disconnect:self];
                    }
                
                } else {
                    NSLog(@"Unrecognized PASSWORD command from OpenVPN management interface has been ignored:\n%@", line);
                }
            }

        } else if ([command isEqualToString:@"LOG"]) {
            NSArray* parameters = [parameterString componentsSeparatedByString: @","];
            NSCalendarDate* date = nil;
            if ( [[parameters objectAtIndex: 0] intValue] != 0) {
                date = [NSCalendarDate dateWithTimeIntervalSince1970: [[parameters objectAtIndex: 0] intValue]];
            }
            NSString* logLine = [parameters lastObject];
            [self addToLog:logLine atDate:date];
            
        } else if ([command isEqualToString:@"NEED-OK"]) {
            // NEED-OK: MSG:Please insert TOKEN
            if ([line rangeOfString: @"Need 'token-insertion-request' confirmation"].length) {
                if (NSDebugEnabled) NSLog(@"Server wants token.");
                NSRange tokenNameRange = [parameterString rangeOfString: @"MSG:"];
                NSString* tokenName = [parameterString substringFromIndex: tokenNameRange.location+4];
                int needButtonReturn = TBRunAlertPanel([NSString stringWithFormat:@"%@: %@",
                                                        [self configName],
                                                        NSLocalizedString(@"Please insert token", @"Window title")],
                                                       [NSString stringWithFormat:NSLocalizedString(@"Please insert token \"%@\", then click \"OK\"", @"Window text"), tokenName],
                                                       nil,
                                                       NSLocalizedString(@"Cancel", @"Button"),
                                                       nil);
                if (needButtonReturn == NSAlertDefaultReturn) {
                    if (NSDebugEnabled) NSLog(@"Write need ok.");
                    [managementSocket writeString:[NSString stringWithFormat:@"needok 'token-insertion-request' ok\r\n"] encoding:NSASCIIStringEncoding];
                } else {
                    if (NSDebugEnabled) NSLog(@"Write need cancel.");
                    [managementSocket writeString:[NSString stringWithFormat:@"needok 'token-insertion-request' cancel\r\n"] encoding:NSASCIIStringEncoding];
                }
            }
        }
    }
}


// Adds a message to the OpenVPN Log with a specified date/time. If date/time is nil, current date/time is used
-(void)addToLog:(NSString *)text atDate:(NSCalendarDate *)date {
    if ( ! date ) {
        date = [NSCalendarDate date];
    }
    NSString *dateText = [NSString stringWithFormat:@"%@ %@\n",[date descriptionWithCalendarFormat:@"%Y-%m-%d %H:%M:%S"],text];
    [[self logStorage] appendAttributedString: [[[NSAttributedString alloc] initWithString: dateText] autorelease]];
}

- (void) netsocket: (NetSocket*) socket dataAvailable: (unsigned) inAmount
{
    NSParameterAssert(socket == managementSocket);
    NSString* line;
    
    while (line = [socket readLine]) {
        // Can we get blocked here?
        //NSLog(@">>> %@", line);
        if ([line length]) {
            [self performSelectorOnMainThread: @selector(processLine:) 
                                   withObject: line 
                                waitUntilDone: NO];
        }
    }
}

- (void) netsocketDisconnected: (NetSocket*) inSocket
{
    if (inSocket==managementSocket) {
        [self setManagementSocket: nil];
    }
    if (NSDebugEnabled) NSLog(@"Socket disconnected");
	//[self performSelectorOnMainThread:@selector(disconnect:) withObject:nil waitUntilDone:NO];
    [self disconnect:self];
}

- (NSString*) state
{
    return lastState;
}

- (void) setDelegate: (id) newDelegate
{
    delegate = newDelegate;
}

-(BOOL) isConnected
{
    return [[self state] isEqualToString:@"CONNECTED"];
}
-(BOOL) isDisconnected 
{
    return [[self state] isEqualToString:@"EXITING"];
}

- (void) setState: (NSString*) newState
	// Be sure to call this in main thread only
{
    [newState retain];
    [lastState release];
    lastState = newState;
    [[NSApp delegate] performSelectorOnMainThread:@selector(setState:) withObject:newState waitUntilDone:NO];
//    [self performSelectorOnMainThread:@selector(updateUI) withObject:nil waitUntilDone:NO];
    
    [delegate performSelector: @selector(connectionStateDidChange:) withObject: self];    
}

- (NSTextStorage*) logStorage 
/*" Returns all collected log messages for the reciever. "*/
{
    if (!logStorage) {
        logStorage = [[NSTextStorage alloc] init];
    }
    return logStorage;
}

- (unsigned int) getFreePort
{
	unsigned int resultPort = 1336; // start port	
	int fd = socket(AF_INET, SOCK_STREAM, 0);
	int result = 0;
	
	do {		
		struct sockaddr_in address;
		int len = sizeof(struct sockaddr_in);
		resultPort++;
		
		address.sin_len = len;
		address.sin_family = AF_INET;
		address.sin_port = htons(resultPort);
		address.sin_addr.s_addr = htonl(0x7f000001); // 127.0.0.1, localhost
		
		memset(address.sin_zero,0,sizeof(address.sin_zero));
		
		result = bind(fd, (struct sockaddr *)&address,sizeof(address));
		
	} while (result!=0);
	
	close(fd);
	
	return resultPort;
}

- (BOOL)validateMenuItem:(NSMenuItem *)anItem 
{
    SEL action = [anItem action];
	
    if (action == @selector(toggle:)) 
    {
        VPNConnection *connection = [anItem target];
        
        // setting menu item's state:
        int state = NSMixedState;
        
        if ([connection isConnected]) 
        {
            state = NSOnState;
        } 
        else if ([connection isDisconnected]) 
        {
            state = NSOffState;
        }
        
        [anItem setState:state];
        
        // setting menu command title depending on current status:
        NSString *commandString; 
        if ([[connection state] isEqualToString:@"CONNECTED"]) commandString = NSLocalizedString(@"Disconnect", @"Button");
        else commandString = NSLocalizedString(@"Connect", @"Button");
        
        NSString *itemTitle = [NSString stringWithFormat:@"%@ '%@'", commandString, [connection configName]];
        [anItem setTitle:itemTitle]; 
	}
	return YES;
}

-(BOOL)configNotProtected:(NSString *)configFile 
{
	NSFileManager *fileManager = [NSFileManager defaultManager];
	NSDictionary *fileAttributes = [fileManager fileAttributesAtPath:configFile traverseLink:YES];
	unsigned long perms = [fileAttributes filePosixPermissions];
	NSString *octalString = [NSString stringWithFormat:@"%o",perms];
	NSNumber *fileOwner = [fileAttributes fileOwnerAccountID];
	
	if ( (![octalString isEqualToString:@"644"])  || (![fileOwner isEqualToNumber:[NSNumber numberWithInt:0]])) {
		// NSLog(@"Configuration file %@ has permissions: 0%@, is owned by %@ and needs repair",configFile,octalString,fileOwner);
		return YES;
	}
	return NO;
}

// Given paths to the regular config in ~/Library/Application Support/Tunnelblick/Configurations or /Resources/Deploy, and an alternate config in /Library/Application Support/Tunnelblick/Users/<username>/
// Returns the path to use, or nil if can't use either one
-(NSString *) getConfigToUse:(NSString *)cfgPath orAlt:(NSString *)altCfgPath
{
    if (  ! [self configNotProtected:cfgPath]  ) {                             // If config doesn't need repair
        if (  ! [gTbDefaults boolForKey:@"useShadowConfigurationFiles"]  ) {   // And not using shadow configuration files
            if (  [self isSampleConfigurationAtPath: cfgPath]  ) {             // And it isn't the sample configuration file
                return nil;
            }
            return cfgPath;                                                   // Then use it
        }
    }
    
    // Repair the configuration file or use the alternate
    AuthorizationRef authRef;
    if (    ! ( [self onRemoteVolume:cfgPath]
             || [gTbDefaults boolForKey:@"useShadowConfigurationFiles"] )    ) {
        // Config is on non-remote volume and we are not supposed to use a shadow configuration file
        if (  [self isSampleConfigurationAtPath: cfgPath]  ) {             // Make sure it isn't the sample configuration file
            return nil;
        }
		NSLog( [NSString stringWithFormat: @"Configuration file %@ needs ownership/permissions repair", cfgPath]);
        authRef = [NSApplication getAuthorizationRef: NSLocalizedString(@"Tunnelblick needs to repair ownership/permissions of the configuration file to secure it.", @"Window text")]; // Try to repair regular config
        if ( authRef == nil ) {
            NSLog(@"Repair authorization cancelled by user");
            AuthorizationFree(authRef, kAuthorizationFlagDefaults);	
            return nil;
        }
        if( ! [self protectConfigurationFile:cfgPath usingAuth:authRef] ) {
            AuthorizationFree(authRef, kAuthorizationFlagDefaults);
            return nil;
        }
        AuthorizationFree(authRef, kAuthorizationFlagDefaults);                         // Repair worked, so return the regular conf
        return cfgPath;
    } else {
        // Config is on remote volume or we should use a shadow configuration file
        NSFileManager * fMgr = [NSFileManager defaultManager];                          // See if alt config exists
        if ( [fMgr fileExistsAtPath:altCfgPath] ) {
            // Alt config exists
            if (  [self isSampleConfigurationAtPath: altCfgPath]  ) {                   // And it isn't the sample configuration file
                return nil;
            }
            if ( [fMgr contentsEqualAtPath:cfgPath andPath:altCfgPath] ) {              // See if files are the same
                // Alt config exists and is the same as regular config
                if ( [self configNotProtected:altCfgPath] ) {                            // Check ownership/permissions
                    // Alt config needs repair
                    NSLog(@"The shadow copy of configuration file %@ needs ownership/permissions repair", cfgPath);
                    authRef = [NSApplication getAuthorizationRef: NSLocalizedString(@"Tunnelblick needs to repair ownership/permissions of the shadow copy of the configuration file to secure it.", @"Window text")]; // Repair if necessary
                    if ( authRef == nil ) {
                        NSLog(@"Repair authorization cancelled by user");
                        AuthorizationFree(authRef, kAuthorizationFlagDefaults);
                        return nil;
                    }
                    if(  ! [self protectConfigurationFile:altCfgPath usingAuth:authRef]  ) {
                        AuthorizationFree(authRef, kAuthorizationFlagDefaults);
                        return nil;                                                     // Couldn't repair alt file
                    }
                    AuthorizationFree(authRef, kAuthorizationFlagDefaults);
                }
                return altCfgPath;                                                      // Return the alt config
            } else {
                // Alt config exists but is different
                NSLog(@"The shadow copy of configuration file %@ needs to be updated from the original", cfgPath);
                authRef = [NSApplication getAuthorizationRef: NSLocalizedString(@"Tunnelblick needs to update the shadow copy of the configuration file from the original.", @"Window text")];// Overwrite it with the standard one and set ownership & permissions
                if ( authRef == nil ) {
                    NSLog(@"Authorization for update of shadow copy cancelled by user");
                    AuthorizationFree(authRef, kAuthorizationFlagDefaults);	
                    return nil;
                }
                if ( [self copyFile:cfgPath toFile:altCfgPath usingAuth:authRef] ) {
                    AuthorizationFree(authRef, kAuthorizationFlagDefaults);
                    return altCfgPath;                                                  // And return the alt config
                } else {
                    AuthorizationFree(authRef, kAuthorizationFlagDefaults);             // Couldn't overwrite alt file with regular one
                    return nil;
                }
            }
        } else {
            // Alt config doesn't exist. We must create it (and maybe the folders that contain it)
            if (  [self isSampleConfigurationAtPath: cfgPath]  ) {             // But only if it isn't the sample configuration file
                return nil;
            }
            NSLog(@"Creating shadow copy of configuration file %@", cfgPath);
            
            // Folder creation code below needs alt config to be in /Library/Application Support/Tunnelblick/Users/<username>/xxx.conf
            NSString * altCfgFolderPath  = [altCfgPath stringByDeletingLastPathComponent]; // Strip off xxx.conf to get path to folder that holds it
            if (  ! [[altCfgFolderPath stringByDeletingLastPathComponent] isEqualToString:@"/Library/Application Support/Tunnelblick/Users"]  ) {
                NSLog(@"Internal Tunnelblick error: altCfgPath\n%@\nmust be in\n/Library/Application Support/Tunnelblick/Users/<username>", altCfgFolderPath);
                return nil;
            }
            if (  ! [gTbDefaults boolForKey:@"useShadowConfigurationFiles"]  ) {
                // Get user's permission to proceed
                NSString * longMsg = NSLocalizedString(@"Configuration file %@ is on a remote volume. Tunnelblick requires configuration files to be on a local volume for security reasons\n\nDo you want Tunnelblick to create and use a local copy of the configuration file in %@?\n\n(You will need an administrator name and password.)\n", @"Window text");
                int alertVal = TBRunAlertPanel([NSString stringWithFormat:@"%@: %@",
                                                                          [self configName],
                                                                          NSLocalizedString(@"Create local copy of configuration file?", @"Window title")],
                                               [NSString stringWithFormat:longMsg, cfgPath,
                                                [[fMgr componentsToDisplayForPath: altCfgFolderPath] componentsJoinedByString: @"/"]],
                                               NSLocalizedString(@"Create copy", @"Button"),
                                               nil,
                                               NSLocalizedString(@"Cancel", @"Button"));
                if (  alertVal == NSAlertOtherReturn  ) {                                       // Cancel
                    return nil;
                }
            }

            authRef = [NSApplication getAuthorizationRef: NSLocalizedString(@"Tunnelblick needs to create a shadow copy of the configuration file.", @"Window text")]; // Create folders if they don't exist:
            if ( authRef == nil ) {
                NSLog(@"Authorization to create a shadow copy of the configuration file cancelled by user.");
                AuthorizationFree(authRef, kAuthorizationFlagDefaults);	
                return nil;
            }
            if ( ! [self makeSureFolderExistsAtPath:@"/Library" usingAuth:authRef] ) {
                AuthorizationFree(authRef, kAuthorizationFlagDefaults);
                return nil;
            }
            if ( ! [self makeSureFolderExistsAtPath:@"/Library/Application Support" usingAuth:authRef] ) {
                AuthorizationFree(authRef, kAuthorizationFlagDefaults);
                return nil;
            }
            if ( ! [self makeSureFolderExistsAtPath:@"/Library/Application Support/Tunnelblick" usingAuth:authRef] ) {
                AuthorizationFree(authRef, kAuthorizationFlagDefaults);
                return nil;
            }
            if ( ! [self makeSureFolderExistsAtPath:@"/Library/Application Support/Tunnelblick/Users" usingAuth:authRef] ) {
                AuthorizationFree(authRef, kAuthorizationFlagDefaults);
                return nil;
            }
            if ( ! [self makeSureFolderExistsAtPath:altCfgFolderPath usingAuth:authRef] ) {  //       /Library/.../<username>
                AuthorizationFree(authRef, kAuthorizationFlagDefaults);
                return nil;
            }
            if ( [self copyFile:cfgPath toFile:altCfgPath usingAuth:authRef] ) {                // Copy the config to the alt config
                AuthorizationFree(authRef, kAuthorizationFlagDefaults);
                return altCfgPath;                                                              // Return the alt config
            }
            AuthorizationFree(authRef, kAuthorizationFlagDefaults);                             // Couldn't make alt file
            return nil;
        }
    }
}

// Returns TRUE if a file is on a remote volume or statfs on it fails, FALSE otherwise
-(BOOL) onRemoteVolume:(NSString *)cfgPath
{
    const char * fileName = [cfgPath UTF8String];
    struct statfs stats_buf;
    int status;

    if (  0 == (status = statfs(fileName, &stats_buf))  ) {
        if (  (stats_buf.f_flags & MNT_LOCAL) == MNT_LOCAL  ) {
            return FALSE;
        }
    } else {
        NSLog(@"statfs returned error %d; treating %@ as if it were on a remote volume", status, cfgPath);
    }
    return TRUE;   // Network volume or error accessing the file's data.
}

// Copies a config file and sets ownership and permissions
// Returns TRUE if succeeded, FALSE if failed, having already output an error message to the console log
-(BOOL) copyFile:(NSString *)source toFile: (NSString *) target usingAuth: (AuthorizationRef) authRef
{
    NSFileManager * fMgr;
	int i;
	int maxtries = 5;
    
	// Copy the file
    NSString *helper = @"/bin/cp";
	NSArray *arguments = [NSArray arrayWithObjects:@"-f", @"-p", source, target, nil];
	
	for (i=0; i <= maxtries; i++) {
        [NSApplication executeAuthorized:helper withArguments:arguments withAuthorizationRef:authRef];
        fMgr = [NSFileManager defaultManager];
        if ( [fMgr contentsEqualAtPath:source andPath:target] ) {
            break;
        }
        sleep(1);
    }
    if ( ! [fMgr contentsEqualAtPath:source andPath:target] ) {
        NSLog(@"Tunnelblick could not copy the config file %@ to the alternate local location %@ in %d attempts.", source, target, maxtries);
    TBRunAlertPanel([NSString stringWithFormat:@"%@: %@",
                                               [self configName],
                                               NSLocalizedString(@"Not connecting", @"Window title")],
                    NSLocalizedString(@"Tunnelblick could not copy the configuration file to the alternate local location. See the Console Log for details.", @"Window text"),
                    nil,
                    nil,
                    nil);
        return FALSE;
    }

    // Make sure the file is unlocked (if not, can't change ownership)
    NSDictionary * curAttributes;
    NSDictionary * newAttributes = [NSDictionary dictionaryWithObject:[NSNumber numberWithInt:0] forKey:NSFileImmutable];
    
	for (i=0; i <= maxtries; i++) {
        curAttributes = [fMgr fileAttributesAtPath:target traverseLink:YES];
        if (  ! [curAttributes fileIsImmutable]  ) {
            break;
        }
        [fMgr changeFileAttributes:newAttributes atPath:target];
        sleep(1);
    }
    if (  [curAttributes fileIsImmutable]  ) {
         NSLog(@"Unlocking alternate configuration file %@ failed in %d attempts", target, maxtries);
    }
    
    // Set the file's ownership and permissions
    if (  [self configNotProtected:target]  ) {
        NSLog(@"Shadow copy of configuration file %@ needs ownership/permissions repair", source);
        if (  ! [self protectConfigurationFile:target usingAuth:authRef]  ) {
            return FALSE;
        }
    }
    return TRUE;
}

// If the specified folder doesn't exist, uses root to create it so it is owned by root:wheel and has permissions 0755.
// If the folder exists, ownership doesn't matter (as long as we can read/execute it).
// Returns TRUE if the folder already existed or was created successfully, returns FALSE otherwise, having already output an error message to the console log.
-(BOOL) makeSureFolderExistsAtPath:(NSString *)folderPath usingAuth: (AuthorizationRef) authRef
{
	NSFileManager * fMgr = [NSFileManager defaultManager];
    BOOL isDir;

    if (  [fMgr fileExistsAtPath:folderPath isDirectory:&isDir] && isDir  ) {
        return TRUE;
    }
    
    NSString *helper = @"/bin/mkdir";
	NSArray *arguments = [NSArray arrayWithObjects:folderPath, nil];
    OSStatus status;
	int i = 0;
	int maxtries = 5;
    
	for (i=0; i <= maxtries; i++) {
		status = [NSApplication executeAuthorized:helper withArguments:arguments withAuthorizationRef:authRef];
		sleep(1);   // This is needed or the test in the next line fails for some reason!
		if (  [fMgr fileExistsAtPath:folderPath isDirectory:&isDir] && isDir  ) {
			break;
		}
	}

    if (    ! (  [fMgr fileExistsAtPath:folderPath isDirectory:&isDir] && isDir  )    ) {
        NSLog(@"Tunnelblick could not create folder %@ for the alternate configuration in %d attempts. OSStatus %ld.", folderPath, maxtries, status);
        TBRunAlertPanel([NSString stringWithFormat:@"%@: %@",
                                                    [self configName],
                                                    NSLocalizedString(@"Not connecting", @"Window title")],
                        NSLocalizedString(@"Tunnelblick could not create a folder for the alternate local configuration. See the Console Log for details.", @"Window text"),
                        nil,
                        nil,
                        nil);
        return FALSE;
    }
    return TRUE;
}

// Attempts to set ownership/permissions on a config file to root:wheel/0644
// Returns TRUE if succeeded, FALSE if failed, having already output an error message to the console log
-(BOOL)protectConfigurationFile:(NSString *) configFilePath usingAuth: (AuthorizationRef) authRef
{
    return [self setConfigurationFileAtPath: configFilePath
                                    toOwner: 0
                                   andGroup: 0
                            withPermissions: @"644"
                                  usingAuth: authRef];
}

// Sets ownership/permissions on a config file to the current user:group/0644 without using authorization
// Returns TRUE if succeeded, FALSE if failed, having already output an error message to the console log
-(BOOL)unprotectConfigurationFile:(NSString *) configFilePath
{
    // Do it by replacing the root-owned file with a user-owned copy (keep root-owned file as a backup)
    NSString * configBackupPath = [configFilePath stringByAppendingPathExtension:@"previous"];
    NSString * configTempPath   = [configFilePath stringByAppendingPathExtension:@"temp"];
    
    NSFileManager * fMgr = [NSFileManager defaultManager];
    
    // Although the documentation for copyPath:toPath:handler: says that the file's ownership and permissions are copied, the ownership
    // of a file owned by root is NOT copied. Instead, the owner is the currently logged-in user:group, which is *exactly* what we want!
    [fMgr removeFileAtPath: configTempPath handler: nil];
    if (  ! [fMgr copyPath: configFilePath toPath: configTempPath handler: nil]  ) {
        NSLog(@"Unable to copy %@ to %@", configFilePath, configTempPath);
        return FALSE;
    }
    
    [fMgr removeFileAtPath: configBackupPath handler: nil];
    if (  ! [fMgr movePath: configFilePath toPath: configBackupPath handler: nil]  ) {
        NSLog(@"Unable to rename %@ to %@", configFilePath, configBackupPath);
        return FALSE;
    }
    
    if (  ! [fMgr movePath: configTempPath toPath: configFilePath handler: nil]  ) {
        NSLog(@"Unable to rename %@ to %@", configTempPath, configFilePath);
        return FALSE;
    }

    return TRUE;
}

// Sets ownership and permissions for a configuration file using an authorization
-(BOOL)setConfigurationFileAtPath: (NSString *) configFilePath toOwner: (int) owner andGroup: (int) group withPermissions: (NSString *) permissions usingAuth: (AuthorizationRef) authRef
{
    NSFileManager * fileManager = [NSFileManager defaultManager];
    BOOL failed = FALSE;

    // Warn user if the file is locked
    NSDictionary * curAttributes = [fileManager fileAttributesAtPath:configFilePath traverseLink:YES];
    if (  [curAttributes fileIsImmutable]  ) {
        NSLog(@"Configuration file needs ownership and/or permissions change but is locked: %@", configFilePath);
    } else {

        // Try to set permissions
        OSStatus status;
        int i = 0;
        int maxtries = 5;
        NSDictionary * fileAttributes;
        unsigned long perms;
        NSString * octalString;
        int fileOwner;
        
        NSString * helper = @"/bin/chmod";
        NSArray * arguments = [NSArray arrayWithObjects: permissions, configFilePath, nil];
        for (i=0; i <= maxtries; i++) {
            if (  i != 0  ) {
                sleep(1);
                status = [NSApplication executeAuthorized:helper withArguments:arguments withAuthorizationRef:authRef];
            }
            fileAttributes = [fileManager fileAttributesAtPath:configFilePath traverseLink:YES];
            perms = [fileAttributes filePosixPermissions];
            octalString = [NSString stringWithFormat:@"%lo",perms];
            if (  [octalString isEqualToString: permissions]  ) {
                break;
            }
        }
        if (  ! [octalString isEqualToString: permissions]  ) {
            NSLog(@"Unable to change permissions of configuration file %@ from 0%@ to 0%@ in %d attempts; OSStatus = @ld", configFilePath, octalString, permissions, maxtries, status);
            failed = TRUE;
        } else {
            
            // Try to set ownership
            helper = @"/usr/sbin/chown";
            arguments = [NSArray arrayWithObjects: [NSString stringWithFormat: @"%d:%d", owner, group], configFilePath, nil];
            
            for (i=0; i <= maxtries; i++) {
                if (  i != 0  ) {
                    sleep(1);
                    status = [NSApplication executeAuthorized:helper withArguments:arguments withAuthorizationRef:authRef];
                }
                fileAttributes = [fileManager fileAttributesAtPath:configFilePath traverseLink:YES];
                fileOwner = [[fileAttributes fileOwnerAccountID] intValue];
                if (  fileOwner == owner  ) {
                    break;
                }
            }
            if (  fileOwner != owner  ) {
                NSLog(@"Unable to change ownership of configuration file %@ from %d to %d in %d attempts. OSStatus = @ld", configFilePath, fileOwner, owner, maxtries, status);
                failed = TRUE;
            }
        }
    }
        
    if (  failed  ) {
        NSLog(@"Could not change ownership and/or permissions of configuration file %@", configFilePath);
        TBRunAlertPanel([NSString stringWithFormat:@"%@: %@",
                                                   [self configName],
                                                   NSLocalizedString(@"Not connecting", @"Window title")],
                        NSLocalizedString(@"Tunnelblick could not change ownership and permissions of the configuration file to secure it. See the Console Log for details.", @"Window text"),
                        nil,
                        nil,
                        nil);
        return NO;
    }

    NSLog(@"Changed ownership and permissions of configuration file %@ to %d:%d and %@", configFilePath, owner, group, permissions);
    return YES;
}

-(BOOL) isSampleConfigurationAtPath: (NSString *) cfgPath
{
    NSString * samplePath = [[NSBundle mainBundle] pathForResource: @"openvpn" ofType: @"conf"];
    NSFileManager  * fMgr = [NSFileManager defaultManager];
    
    if (  ! [fMgr contentsEqualAtPath: cfgPath andPath: samplePath]  ) {
        return FALSE;
    }
    
    int button = TBRunAlertPanel(NSLocalizedString(@"You cannot connect using the sample configuration", @"Window title"),
                                 NSLocalizedString(@"You have tried to connect using a configuration file that is the same as the sample configuration file installed by Tunnelblick. The configuration file must be modified to connect to a VPN. You may also need other files, such as certificate or key files, to connect to the VPN.\n\nConsult your network administrator or your VPN service provider to obtain configuration and other files or the information you need to modify the sample file.\n\nOpenVPN documentation is available at\n\n     http://openvpn.net/index.php/open-source/documentation.html\n", @"Window text"),
                                 NSLocalizedString(@"Cancel", @"Button"),                           // Default button
                                 NSLocalizedString(@"Go to the OpenVPN documentation on the web", @"Button"), // Alternate button
                                 nil);                                                              // No Other button
	
    if( button == NSAlertAlternateReturn ) {
		[[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"http://openvpn.net/index.php/open-source/documentation.html"]];
	}
    
    return TRUE;
}

-(void) destroyPipe
{
    [self emptyPipe];
    [myPipe destroyPipe];
}

-(void) emptyPipe
{
    if (  [myPipeBuffer length] != 0  ) {
        [self appendDataToLog: [@"\003\n" dataUsingEncoding: NSUTF8StringEncoding]];
    }
}
         
/* Invoked when data is available from myPipe, which accepts data and sends it to the OpenVPN Log via this routine
 
 The pipe is created in /tmp by the "initWithConfig:inDirectory:isInDeploy: method (above)
 The name of the pipe is formed in part by replacing slash characters in the configuration file's path with dashes:
 If the configuration file's path is
                      "/Users/joe/Application Support/Tunnelblick/Configurations/test.conf"
 then the pipe is named
      "/tmp/tunnelblick-Users-joe-Application Support-Tunnelblick-Configurations-test.conf.logpipe"
 
Data sent to the pipe should a message consisting of
       ETX LF timestamp SP star SP program SP message ETX LF

 Where ETX       is the ASCII ETX character (use "\003" in the "echo -e" command)
       LF        is the ASCII LF character ("\n")
       timestamp is in the form "YYYY-MM-DD HH:MM:SS", as generated by bash shell "$(date '+%Y-%m-%d %T')"
       SP        is a single space character
       star      is the asterisk character "*"
       program   is the name of the program generating the message
       message   is the message that is to be displayed in the log. It may include any sequence of characters except ETX LF

 This format will make piped log output consistent with the way that Tunnelblick displays other messages in the log

 The first ETX LF forces any partial message that wasn't terminated to be output. If there is no partial message, then
 nothing will be output and the first ETX LF are ignored.
 
 Example:
 echo -e "\003\n$(date '+%Y-%m-%d %T') * XYZ-Script This-is-the-actual-message.\003"
 will append a line like the following to the log. Note that the echo command appends a LF after the second ETX.

       2010-01-15 10:05:02 * XYZ-Script This is the actual message

 Also, see leasewatch for shell code that outputs multi-line messages to the log window when the network configuration changes.
*/

-(void) appendDataToLog: (NSData *) data
{
    if (  [data length] != 0  ) {
        // Append the data to the buffer
        NSString * s = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        [myPipeBuffer appendString: s];
        [s release];
    }
    
    NSString * endOfMsgMarker = @"\003\n";
    
    NSRange eomRange = [myPipeBuffer rangeOfString: endOfMsgMarker];
    if (  eomRange.location != NSNotFound  ) {
        
        while (  [myPipeBuffer length] != 0  ) {
            
            // Get message up to, but not including, the ETX-LF
            NSMutableString * msg = [[NSMutableString alloc] initWithString: [myPipeBuffer substringWithRange: NSMakeRange(0, eomRange.location)]];
            
            // Remove LFs at the end of the message (for example, if have: msg  LF  ETX  LF, removes the first LF
            // We do this to make indentation easy, and we add a final LF to the end of the message when it goes in the log
            while (  [msg hasSuffix: @"\n"]  ) {
                [msg deleteCharactersInRange:NSMakeRange([msg length]-1, 1)];
            }
            
            if (  [msg length] != 0  ) {
                // Indent all lines after the first. Since msg doesn't have the terminating \n, we can just replace all \n characters
                [msg replaceOccurrencesOfString: @"\n"
                                     withString: @"\n                                          " options: 0 range: NSMakeRange(0, [msg length])];
                
                [msg appendString: @"\n"];
                
                // Add the message to the log
                NSAttributedString * msgAS = [[NSAttributedString alloc] initWithString: msg];
                [[self logStorage] appendAttributedString: msgAS];
                [msgAS release];
            }
            
            [msg release];
            
            // Remove the entry from the buffer
            [myPipeBuffer deleteCharactersInRange: NSMakeRange(0, eomRange.location + [endOfMsgMarker length])  ];
            
            eomRange = [myPipeBuffer rangeOfString: endOfMsgMarker];
            if (  eomRange.location == NSNotFound  ) {
                break;
            }
        }
    }
}

@end