//
//  CDEvents.m
//  CDEvents
//
//  Created by Aron Cedercrantz on 03/04/10.
//  Copyright 2010 __MyCompanyName__. All rights reserved.
//

#import "CDEvents.h"

#import "CDEventsDelegate.h"

#pragma mark CDEvents custom exceptions
NSString *const CDEventsEventStreamCreationFailureException = @"CDEventsEventStreamCreationFailureException";


#pragma mark -
#pragma mark Private API
// Private API
@interface CDEvents ()

// The FSEvents callback function
static void CDEventsCallback(
	ConstFSEventStreamRef streamRef,
	void *callbackCtxInfo,
	size_t numEvents,
	void *eventPaths,
	const FSEventStreamEventFlags eventFlags[],
	const FSEventStreamEventId eventIds[]);

// Creates and initiates the event stream.
- (void)createEventStream;
// Disposes of the event stream.
- (void)disposeEventStream;

@end


#pragma mark -
#pragma mark Implementation
@implementation CDEvents

#pragma mark Properties
@synthesize delegate						= _delegate;
@synthesize notificationLatency				= _notificationLatency;
@synthesize sinceEventIdentifier			= _sinceEventIdentifier;
@synthesize ignoreEventsFromSubDirectories	= _ignoreEventsFromSubDirectories;
@synthesize lastEvent						= _lastEvent;
@synthesize watchedURLs						= _watchedURLs;
@synthesize excludedURLs					= _excludedURLs;


#pragma mark Event identifier class methods
+ (CDEventIdentifier)currentEventIdentifier
{
	return (NSUInteger)FSEventsGetCurrentEventId();
}


#pragma mark Init/dealloc/finalize methods
- (void)dealloc
{
	[self disposeEventStream];
	
	_delegate = nil;
	
	[_lastEvent release];
	[_watchedURLs release];
	[_excludedURLs release];
	
	[super dealloc];
}

- (void)finalize
{
	[self disposeEventStream];
	
	_delegate = nil;
	
	[super finalize];
}

- (id)initWithURLs:(NSArray *)URLs delegate:(id<CDEventsDelegate>)delegate
{
	return [self initWithURLs:URLs
					 delegate:delegate
					onRunLoop:[NSRunLoop currentRunLoop]];
}

- (id)initWithURLs:(NSArray *)URLs
			delegate:(id<CDEventsDelegate>)delegate
		   onRunLoop:(NSRunLoop *)runLoop
{
	return [self initWithURLs:URLs
					 delegate:delegate
					onRunLoop:runLoop
		 sinceEventIdentifier:[CDEvents currentEventIdentifier]
		 notificationLantency:CD_EVENTS_DEFAULT_NOTIFICATION_LATENCY
	  ignoreEventsFromSubDirs:CD_EVENTS_DEFAULT_IGNORE_EVENT_FROM_SUB_DIRS
				  excludeURLs:nil];
}

- (id)initWithURLs:(NSArray *)URLs
		  delegate:(id<CDEventsDelegate>)delegate
		   onRunLoop:(NSRunLoop *)runLoop
sinceEventIdentifier:(CDEventIdentifier)sinceEventIdentifier
notificationLantency:(CFTimeInterval)notificationLatency
ignoreEventsFromSubDirs:(BOOL)ignoreEventsFromSubDirs
		 excludeURLs:(NSArray *)exludeURLs
{
	if (delegate == nil || URLs == nil || [URLs count] == 0) {
		[NSException raise:NSInvalidArgumentException
					format:@"Invalid arguments passed to CDEvents init-method."];
	}
	
	if ((self = [super init])) {
		_watchedURLs = [URLs copy];
		[self setExcludedURLs:exludeURLs];
		[self setDelegate:delegate];
		
		_sinceEventIdentifier = sinceEventIdentifier;
		
		_notificationLatency = notificationLatency;
		_ignoreEventsFromSubDirectories = ignoreEventsFromSubDirs;
		
		_lastEvent = nil;
		
		[self createEventStream];
		
		FSEventStreamScheduleWithRunLoop(_eventStream,
										 [runLoop getCFRunLoop],
										 kCFRunLoopDefaultMode);
		if (!FSEventStreamStart(_eventStream)) {
			return nil;
		}
	}
	
	return self;
}


#pragma mark NSCopying method
- (id)copyWithZone:(NSZone *)zone
{
	CDEvents *copy = [[CDEvents alloc] init];
	
	copy->_delegate = _delegate;
	copy->_notificationLatency = [self notificationLatency];
	copy->_ignoreEventsFromSubDirectories = [self ignoreEventsFromSubDirectories];
	copy->_lastEvent = [[self lastEvent] retain];
	copy->_sinceEventIdentifier = _sinceEventIdentifier;
	copy->_watchedURLs = [[self watchedURLs] copyWithZone:zone];
	copy->_excludedURLs = [[self excludedURLs] copyWithZone:zone];
	
	return copy;
}


#pragma mark Misc methods


#pragma mark Private API:
- (void)createEventStream
{
	FSEventStreamContext callbackCtx;
	
	callbackCtx.version			= 0;
	callbackCtx.info			= (void *)self;
	callbackCtx.retain			= NULL;
	callbackCtx.release			= NULL;
	callbackCtx.copyDescription	= NULL;
	
	_eventStream = FSEventStreamCreate(kCFAllocatorDefault,
									   &CDEventsCallback,
									   &callbackCtx,
									   (CFArrayRef)[self watchedURLs],
									   (FSEventStreamEventId)[self sinceEventIdentifier],
									   [self notificationLatency],
									   kCDEventsEventStreamFlags);
}

- (void)disposeEventStream
{
	if (!(_eventStream)) {
		return;
	}
	
	FSEventStreamStop(_eventStream);
	FSEventStreamInvalidate(_eventStream);
	FSEventStreamRelease(_eventStream);
	_eventStream = NULL;
}

static void CDEventsCallback(
	ConstFSEventStreamRef streamRef,
	void *callbackCtxInfo,
	size_t numEvents,
	void *eventPaths,
	const FSEventStreamEventFlags eventFlags[],
	const FSEventStreamEventId eventIds[])
{
	CDEvents *watcher = (CDEvents *)callbackCtxInfo;
	NSArray *excludedURLs = [watcher excludedURLs];
	NSArray *eventPathsArray = (NSArray *)eventPaths;
	BOOL shouldIgnore;
	
	for (NSUInteger i = 0; i < numEvents; ++i) {
		shouldIgnore = NO;
		
		NSString *eventPath = [eventPathsArray objectAtIndex:i];
		
		if ([excludedURLs containsObject:[NSURL URLWithString:eventPath]]) {
			shouldIgnore = YES;
		} else if (excludedURLs != nil && [watcher ignoreEventsFromSubDirectories]) {
			for (NSURL *URL in excludedURLs) {
				if ([eventPath hasPrefix:[URL path]]) {
					shouldIgnore = YES;
					break;
				}
			}
		}
		
		if (!shouldIgnore) {
			NSURL *eventURL = [NSURL URLWithString:eventPath];
			
			CDEvent *event = [[CDEvent alloc] initWithIdentifier:eventIds[i]
												   date:[NSDate date]
													URL:eventURL
												  flags:eventFlags[i]];
			
			if ([(id)[watcher delegate] conformsToProtocol:@protocol(CDEventsDelegate)]) {
				[[watcher delegate] URLWatcher:watcher eventOccurred:event];
			}
			
			// Last event?
			if (i == (numEvents - 1)) {
				[watcher setLastEvent:event];
			}
			
			[event release];
		}
	}
	
	
}

@end
