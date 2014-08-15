/*
 *
 * Copyright 2008 Artifacts - Fine Software Development
 * http://www.artifacts.de
 * Author: Michael Markowski (m.markowski@artifacts.de)
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 *
 */

#import "AFCacheableItem.h"
#import "AFCache+PrivateAPI.h"
#import "DateParser.h"
#import "AFCache_Logging.h"
#include <sys/xattr.h>

@interface AFCacheableItem ()

@property NSMutableArray *completionBlocks;
@property NSMutableArray *failBlocks;
@property NSMutableArray *progressBlocks;

@property BOOL hasReturnedCachedItemBeforeRevalidation;

@end

@implementation AFCacheableItem

- (id) init {
	self = [super init];
	if (self != nil) {
		_data = nil;
        _canMapData = YES;
		_cacheStatus = kCacheStatusNew;
		_info = [[AFCacheableItemInfo alloc] init];
        _IMSRequest = nil;
        _URLInternallyRewritten = NO;

        _completionBlocks = [NSMutableArray array];
        _failBlocks = [NSMutableArray array];
        _progressBlocks = [NSMutableArray array];
	}
	return self;
}

- (AFCacheableItem*)initWithURL:(NSURL*)URL
                   lastModified:(NSDate*)lastModified
                     expireDate:(NSDate*)expireDate
                    contentType:(NSString*)contentType
{
    self = [self init];
    if (self) {
        _info = [[AFCacheableItemInfo alloc] init];
        _info.lastModified = lastModified;
        _info.expireDate = expireDate;
        _info.mimeType = contentType;
        _url = URL;
        _cacheStatus = kCacheStatusFresh;
        _validUntil = _info.expireDate;
        _cache = [AFCache sharedInstance];
    }
    return self;
}

- (AFCacheableItem*)initWithURL:(NSURL*)URL
                   lastModified:(NSDate*)lastModified
                     expireDate:(NSDate*)expireDate
{
    return [self initWithURL:URL lastModified:lastModified expireDate:expireDate contentType:nil];
}

- (void)addCompletionBlock:(AFCacheableItemBlock)completionBlock failBlock:(AFCacheableItemBlock)failBlock progressBlock:(AFCacheableItemBlock)progressBlock {
    @synchronized (self) {
        if (completionBlock) {
            [self.completionBlocks addObject:completionBlock];
        }
        if (failBlock) {
            [self.failBlocks addObject:failBlock];
        }
        if (progressBlock) {
            [self.progressBlocks addObject:progressBlock];
        }

    }
}

- (void)removeBlocks {
    @synchronized (self) {
        [self.completionBlocks removeAllObjects];
        [self.failBlocks removeAllObjects];
        [self.progressBlocks removeAllObjects];
    }
}

- (void)performBlocks:(NSArray*)blocks {
    @synchronized (self) {
        blocks = [blocks copy];
    }
    for (AFCacheableItemBlock block in blocks) {
        block(self);
    }
}

- (NSData*)data {
    if (!_data) {
        
		if (!self.cache.skipValidContentLengthCheck && ![self hasValidContentLength])
		{
			return nil;
		}
		
		NSString* filePath = [self.cache fullPathForCacheableItem:self];
		if (![[NSFileManager defaultManager] fileExistsAtPath:filePath])
		{
			return nil;
		}

        //TODO: check if this works (method marked as deprecated) see http://stackoverflow.com/questions/12623622/substitute-for-nsdata-deprecated-datawithcontentsofmappedfile
        _data = [NSData dataWithContentsOfMappedFile:filePath];
        
        if (!_data)
        {
            NSLog(@"Error: Could not map file %@", filePath);
        }
        _canMapData = (_data != nil);
    }
	
    return _data;
}

- (void)handleResponse:(NSURLResponse *)response
{
	self.info.mimeType = [response MIMEType];
	NSDate *now = [NSDate date];
	NSDate *newLastModifiedDate = nil;
	
    self.info.responseTimestamp = [now timeIntervalSinceReferenceDate];
	self.info.mimeType = [response MIMEType];
	
#if USE_ASSERTS
	NSAssert(self.info!=nil, @"AFCache internal inconsistency (connection:didReceiveResponse): Info must not be nil");
#endif
	// Get HTTP-Status code from response
	NSUInteger statusCode = 200;
	
	if ([response respondsToSelector:@selector(statusCode)]) {
		statusCode = (NSUInteger)[response performSelector:@selector(statusCode)];
	}
	self.info.statusCode = statusCode;
    
    // TODO this comment does not belong to following lines?
	// The resource has not been modified, so we call connectionDidFinishLoading and exit here.
	if (self.cacheStatus==kCacheStatusRevalidationPending) {
		switch (statusCode) {
			case 304:
				self.cacheStatus = kCacheStatusNotModified;
				self.validUntil = self.info.expireDate;
				return;
			case 200:
				self.cacheStatus = kCacheStatusModified;
				break;
		}
	} else {
		self.info.responseTimestamp = [now timeIntervalSinceReferenceDate];
        self.info.response = response;
	}
	
    
    if (200 == statusCode)
    {
        self.fileHandle = [self.cache createFileForItem:self];
    }
	
	// Calculate expiration time for newly fetched object to determine
	// until when we may cache it.
	if ([response isKindOfClass: [NSHTTPURLResponse class]]) {
		
		// get all headers from response
		NSDictionary *headers = [(NSHTTPURLResponse *) response allHeaderFields];
		
#ifdef AFCACHE_LOGGING_ENABLED
		// log headers
		NSLog(@"status code: %d", statusCode);
		for (NSString *key in[headers allKeys]) {
			NSString *logString = [NSString stringWithFormat: @"%@: %@", key, [headers objectForKey: key]];
			NSLog(@"Headers: %@", logString);
		}
#endif
		// get headers that are used for cache control
		NSString *ageHeader                     = [headers objectForKey: @"Age"];
		NSString *dateHeader                    = [headers objectForKey: @"Date"];
		NSString *modifiedHeader                = [headers objectForKey: @"Last-Modified"];
		NSString *expiresHeader                 = [headers objectForKey: @"Expires"];
		NSString *cacheControlHeader            = [headers objectForKey: @"Cache-Control"];
		NSString *pragmaHeader                  = [headers objectForKey: @"Pragma"];
		NSString *eTagHeader                    = [headers objectForKey: @"Etag"];
		NSString *contentLengthHeader           = [headers objectForKey: @"Content-Length"];
		self.info.headers                       = headers;
		self.info.contentLength = [contentLengthHeader integerValue];
		
		
		[self setDownloadStartedFileAttributes];
		
		
		// parse 'Age', 'Date', 'Last-Modified', 'Expires' headers and use
		// a date formatter capable of parsing the date string using
		// three different formats:
		// Excerpt from rfc2616: http://www.w3.org/Protocols/rfc2616/rfc2616-sec3.html#sec3.3
		// The first format is preferred as an Internet standard and represents a
		// fixed-length subset of that defined by RFC 1123 [8] (an update to RFC 822 [9]).
		// The second format is in common use, but is based on the obsolete RFC 850 [12] date
		// format and lacks a four-digit year. HTTP/1.1 clients and servers that parse the
		// date value MUST accept all three formats (for compatibility with HTTP/1.0),
		// though they MUST only generate the RFC 1123 format for representing HTTP-date
		// values in header fields. See section 19.3 for further information.
		
		self.info.age = (ageHeader) ? [ageHeader intValue] : 0;
		self.info.serverDate = (dateHeader) ? [DateParser gh_parseHTTP: dateHeader] : now;
		newLastModifiedDate = (modifiedHeader) ? [DateParser gh_parseHTTP: modifiedHeader] : now;
		
		// Store expire date from header or nil
		self.info.expireDate = (expiresHeader) ? [DateParser gh_parseHTTP: expiresHeader] : nil;
		
        
		// Update lastModifiedDate for cached object
		self.info.lastModified = newLastModifiedDate;
		
		// set validity to current last modified date. Might be overwritten later by
		// expireDate (from server) or new calculated expiration date (if max-age is set)
		// Only if validUntil is set, the resource is written into the cache
		self.validUntil = newLastModifiedDate;
		self.info.eTag = eTagHeader;
		
		// These values are fetched while parsing the headers and used later to
		// compute if the resource may be cached.
		BOOL pragmaNoCacheSet = NO;
		BOOL maxAgeIsZero = NO;
		BOOL maxAgeIsSet = NO;
		self.info.maxAge = nil;
		
		// parse "Pragma" header
		if (pragmaHeader) {
			// check if Pragma: no-cache is set (for compatibility with HTTP/1.0 clients
			NSRange range = [pragmaHeader rangeOfString: @"no-cache"];
			pragmaNoCacheSet = (range.location != NSNotFound);
		}
		
		// parse cache-control header, if given
		if (cacheControlHeader) {
			
			// check if max-age is set in header
			
			NSRange range = [cacheControlHeader rangeOfString: @"max-age="];
			maxAgeIsSet = (range.location != NSNotFound);
			if (maxAgeIsSet) {
				
				// max-age is set, parse seconds
				// The 'max-age' directive takes priority over 'Expires', so we overwrite validUntil,
				// no matter if it was already set by 'Expires'
				
				unsigned long start = range.location + range.length;
				unsigned long length =  [cacheControlHeader length] - (range.location + range.length);
				NSString *numStr = [cacheControlHeader substringWithRange: NSMakeRange(start, length)];
				self.info.maxAge = [NSNumber numberWithInt: [numStr intValue]];
				// create future expire date for max age by adding the given seconds to now
#if ((TARGET_OS_IPHONE == 0 && 1060 <= MAC_OS_X_VERSION_MAX_ALLOWED) || (TARGET_OS_IPHONE == 1 && 40000 <= __IPHONE_OS_VERSION_MAX_ALLOWED))
                self.validUntil = [now dateByAddingTimeInterval: [self.info.maxAge doubleValue]];
#else
				self.validUntil = [now addTimeInterval: [info.maxAge doubleValue]];
#endif
			}
			
			// check no-cache in "Cache-Control"
			// see http://www.ietf.org/rfc/rfc2616.txt - 14.9 Cache-Control, Page 107

			range = [cacheControlHeader rangeOfString: @"no-cache"];
			if (range.location != NSNotFound) pragmaNoCacheSet = YES;

			range = [cacheControlHeader rangeOfString: @"no-store"];
			if (range.location != NSNotFound) pragmaNoCacheSet = YES;
						
            
            // since AFCache can be classified as a private cache, we'll cache objects with the Cache-Control 'private' header too.
            // see 14.9.1 What is Cacheable
            // TODO: check other Cache-Control parameters
            /*
             cache-request-directive =
                "no-cache"                          ; Section 14.9.1
              | "no-store"                          ; Section 14.9.2
              | "max-age" "=" delta-seconds         ; Section 14.9.3, 14.9.4
              | "max-stale" [ "=" delta-seconds ]   ; Section 14.9.3
              | "min-fresh" "=" delta-seconds       ; Section 14.9.3
              | "no-transform"                      ; Section 14.9.5
              | "only-if-cached"                    ; Section 14.9.4
              | cache-extension                     ; Section 14.9.6
        
             cache-response-directive =
                "public"                               ; Section 14.9.1
              | "private" [ "=" <"> 1#field-name <"> ] ; Section 14.9.1
              | "no-cache" [ "=" <"> 1#field-name <"> ]; Section 14.9.1
              | "no-store"                             ; Section 14.9.2
              | "no-transform"                         ; Section 14.9.5
              | "must-revalidate"                      ; Section 14.9.4
              | "proxy-revalidate"                     ; Section 14.9.4
              | "max-age" "=" delta-seconds            ; Section 14.9.3
              | "s-maxage" "=" delta-seconds           ; Section 14.9.3
              | cache-extension                        ; Section 14.9.6            
            */            
		}
		
		// If expires is given, adjust validUntil date
		if (self.info.expireDate) self.validUntil = self.info.expireDate;
		
		// if either "Pragma: no-cache" is set in the header, or max-age=0 is set then
		// this resource must not be cached.
		BOOL mustNotCache = pragmaNoCacheSet || (maxAgeIsSet && maxAgeIsZero);
		if (mustNotCache) self.validUntil = nil;
	}
}

- (void)sendFailSignalToClientItems {
    if (self.isPackageArchive) {
        // TODO: Setting a status does not conform to method's name
        self.info.packageArchiveStatus = kAFCachePackageArchiveStatusLoadingFailed;
    }

    [self performBlocks:self.failBlocks];
}

- (void)sendSuccessSignalToClientItems {
    if (self.isPackageArchive) {
        // TODO: Setting a status does not conform to method's name
        if (self.info.packageArchiveStatus == kAFCachePackageArchiveStatusUnknown) {
            self.info.packageArchiveStatus = kAFCachePackageArchiveStatusLoaded;
        }
    }
    [self performBlocks:self.completionBlocks];
}

- (void)sendProgressSignalToClientItems {
    [self performBlocks:self.progressBlocks];
}
    
/*
 * calculate freshness of object according to algorithm in rfc2616
 * http://www.w3.org/Protocols/rfc2616/rfc2616-sec13.html
 *
 * age_value
 *      is the value of Age: header received by the cache with this response.
 * date_value
 *      is the value of the origin server's Date: header
 * request_time
 *      is the (local) time when the cache made the request that resulted in this cached response
 * response_time
 *      is the (local) time when the cache received the response
 * now
 *      is the current (local) time
 */

- (BOOL)isFresh {
#if USE_ASSERTS
	NSAssert(self.info!=nil, @"AFCache internal inconsistency detected while validating freshness. AFCacheableItem's info object must not be nil. This is a software bug.");
#endif
	
	NSTimeInterval apparent_age = fmax(0, self.info.responseTimestamp - [self.info.serverDate timeIntervalSinceReferenceDate]);
	NSTimeInterval corrected_received_age = fmax(apparent_age, self.info.age);
	NSTimeInterval response_delay = (self.info.responseTimestamp>0)?self.info.responseTimestamp - self.info.requestTimestamp:0;
	
#if USE_ASSERTS
  	NSAssert(response_delay >= 0, @"response_delay must never be negative!");
#else
// A zero (or negative) response delay indicates a transfer or connection error.
// This happened when the archiever started between request start and response.
    if (response_delay <= 0)
    {
        return NO;
    }
#endif
	
	NSTimeInterval corrected_initial_age = corrected_received_age + response_delay;
	NSTimeInterval resident_time = [NSDate timeIntervalSinceReferenceDate] - self.info.responseTimestamp;
	NSTimeInterval current_age = corrected_initial_age + resident_time;
	
	NSTimeInterval freshness_lifetime = 0;
	
	if (self.info.expireDate) {
		freshness_lifetime = [self.info.expireDate timeIntervalSinceReferenceDate] - [self.info.serverDate timeIntervalSinceReferenceDate];
	}
	
	// The max-age directive takes priority over Expires! Thanks, Serge ;)
	if (self.info.maxAge) {
		freshness_lifetime = [self.info.maxAge doubleValue];
	}
	
	// Note:
	// If none of Expires, Cache-Control: max-age, or Cache-Control: s- maxage (see section 14.9.3) appears in the response,
	// and the response does not include other restrictions on caching, the cache MAY compute a freshness lifetime using a heuristic.
	// The cache MUST attach Warning 113 to any response whose age is more than 24 hours if such warning has not already been added.
	
	BOOL fresh = (freshness_lifetime > current_age);
	AFLog(@"freshness_lifetime: %@", [NSDate dateWithTimeIntervalSinceReferenceDate: freshness_lifetime]);
	AFLog(@"current_age: %@", [NSDate dateWithTimeIntervalSinceReferenceDate: current_age]);
	
	return fresh;
}

- (void)setDownloadStartedFileAttributes {
    int fd = [self.fileHandle fileDescriptor];
    if (fd > 0) {
		uint64_t contentLength = self.info.contentLength;
        if (0 != fsetxattr(fd,
                           kAFCacheContentLengthFileAttribute,
                           &contentLength,
                           sizeof(uint64_t),
                           0, 0)) {
            AFLog(@"Could not set contentLength attribute on %@", self.info.filename);
        }
		
        unsigned int downloading = 1;
        if (0 != fsetxattr(fd,
                           kAFCacheDownloadingFileAttribute,
                           &downloading,
                           sizeof(downloading),
                           0, 0)) {
            AFLog(@"Could not set downloading attribute on %@", self.info.filename);
        }
		
    }
}

- (void)setDownloadFinishedFileAttributes
{
    int fd = [self.fileHandle fileDescriptor];
    if (fd > 0)
    {
		uint64_t contentLength = self.info.contentLength;
        if (0 != fsetxattr(fd,
                           kAFCacheContentLengthFileAttribute,
                           &contentLength,
                           sizeof(uint64_t),
                           0, 0))
        {
            AFLog(@"Could not set contentLength attribute on %@, errno = %ld", self.info.filename, (long)errno );
        }
		
        if (0 != fremovexattr(fd, kAFCacheDownloadingFileAttribute, 0))
        {
            AFLog(@"Could not remove downloading attribute on %@, errno = %ld", self.info.filename, (long)errno );
        }
    }
}

- (BOOL)hasDownloadFileAttribute
{
    unsigned int downloading = 0;
    NSString *filePath = [self.cache fullPathForCacheableItem:self];
    return sizeof(downloading) == getxattr([filePath fileSystemRepresentation], kAFCacheDownloadingFileAttribute, &downloading, sizeof(downloading), 0, 0);
}

- (BOOL)hasValidContentLength
{
	NSString* filePath = [self.cache fullPathForCacheableItem:self];
	if (![[NSFileManager defaultManager] fileExistsAtPath:filePath])
	{
		return NO;
	}
	
//    NSLog(@"has valid content length ? %@", self.url);
	NSError* err = nil;
	NSDictionary* attr = [[NSFileManager defaultManager] attributesOfItemAtPath:filePath error:&err];
	if (!attr)
	{
		AFLog(@"Error getting file attributes: %@", err);
		return NO;
    }
	
	uint64_t fileSize = [attr fileSize];
	if (self.info.contentLength == 0 || fileSize != self.info.contentLength)
	{
		uint64_t realContentLength = [self getContentLengthFromFile];
		
		if (realContentLength == 0 || realContentLength != fileSize)
		{
			return NO;
		}
	}
	
	return YES;
}

- (BOOL)isQueuedOrDownloading
{
    return [self.cache isQueuedOrDownloadingURL:self.url];
}


- (uint64_t)getContentLengthFromFile
{
    if ([self isQueuedOrDownloading])
    {
        return 0LL;
    }
	NSString *filePath = [self.cache fullPathForCacheableItem:self];
    
    uint64_t realContentLength = 0LL;
    ssize_t const size = getxattr([filePath fileSystemRepresentation],
								  kAFCacheContentLengthFileAttribute,
								  &realContentLength,
								  sizeof(realContentLength),
								  0, 0);
	if (sizeof(realContentLength) != size )
	{
        AFLog(@"Could not get content length attribute from file %@. This may be bad (errno = %ld",
              filePath, (long)errno );
        return 0LL;
    }
	
    return realContentLength;
}

- (NSString *)asString {
	if (!self.data) return nil;
	return [[NSString alloc] initWithData: self.data encoding: NSUTF8StringEncoding];
}

- (NSString*)description {
	NSMutableString *s = [NSMutableString stringWithString:@"URL: "];
	[s appendString:[self.url absoluteString]];
	[s appendString:@", "];
	[s appendFormat:@"tag: %d", self.tag];
	[s appendString:@", "];
	[s appendFormat:@"cacheStatus: %u", self.cacheStatus];
	[s appendString:@", "];
	[s appendFormat:@"body content size: %ld\n", (long)[self.data length]];
	[s appendString:[self.info description]];
	[s appendString:@"\n"];
	
	return s;
}

- (BOOL)isCachedOnDisk {
	return [self.cache.cachedItemInfos objectForKey: [self.url absoluteString]] != nil;
}

- (NSString*)guessContentType {
	NSString *extension = [self.url lastPathComponent];
	return [self.cache.suffixToMimeTypeMap valueForKey:extension];
}

- (NSString*)mimeType {
	if (!self.info.mimeType) {
		return [self guessContentType];
	}
	
	return self.info.mimeType;
}


#ifdef USE_TOUCHXML
- (CXMLDocument *)asXMLDocument {
	if (self.data == nil) return nil;
	NSError *err = nil;
	CXMLDocument *doc = [[[CXMLDocument alloc] initWithData: self.data options: 0 error: &err] autorelease];
	return (err) ? nil : doc;
}
#endif

- (BOOL)isComplete {
	//[[NSString alloc] initWithFormat:@"Item %@ has %lld of %lld data loaded, complete ? %d", self.info.filename, self.info.actualLength, self.info.contentLength,(self.currentContentLength >= self.info.contentLength)];
	//assumed complete if there is data and the actual data length is at least as big as the expected content length. (should be exactly the expected content length but sometimes there is no expected content lenght present; self.info.contentLength = 0)
    return [self isDataLoaded] && (self.info.actualLength >= self.info.contentLength);
}

- (BOOL)isDataLoaded
{
	return self.info.actualLength >0;// data != nil;
}

-(uint64_t)currentContentLength{
	return self.info.actualLength;
}

-(void)setCurrentContentLength:(uint64_t)contentLength
{
	self.info.actualLength = contentLength;
}

- (BOOL)isDownloading {
    return [self.cache isDownloadingURL: self.url];
}
@end
