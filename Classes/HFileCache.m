//
//  HFileCache.m
//  HAccess
//
//  Created by zhangchutian on 15/11/10.
//  Copyright © 2015年 zhangchutian. All rights reserved.
//

#import "HFileCache.h"
#import <NSFileManager+ext.h>
#import <UIKit/UIKit.h>
#import <NSString+ext.h>

//#define HFileAccessTimeKey NSFileOwnerAccountID
//#define HFileExpireTimeKey NSFileGroupOwnerAccountID
#define HFileAccessTimeKey NSFileCreationDate
#define HFileExpireTimeKey NSFileModificationDate

@interface HFileCacheFileInfo : NSObject
@property (nonatomic) NSString *filePath;
@property (nonatomic) unsigned long lastAccess;
@property (nonatomic) long long size;
@end

@implementation HFileCacheFileInfo
@end

@interface HFileCache ()
@property (nonatomic, readwrite) NSString *cacheDir;
@end

@implementation HFileCache

+ (instancetype)shareCache
{
    static dispatch_once_t pred;
    static HFileCache *o = nil;
    dispatch_once(&pred, ^{ o = [[self alloc] init]; });
    return o;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        [self setup:@"com.hacess.HFileCache"];
    }
    return self;
}

- (instancetype)initWithDomain:(NSString *)domain
{
    self = [super init];
    if (self) {
        [self setup:domain];
    }
    return self;
}
- (void)setup:(NSString *)domain
{
    self.maxCacheSize = (50*1024*1024);
    self.queue = dispatch_queue_create([domain cStringUsingEncoding:NSUTF8StringEncoding], DISPATCH_QUEUE_CONCURRENT);
    self.cacheDir = [NSFileManager cachePath:domain];
    
    [[NSFileManager defaultManager] createDirectoryAtPath:self.cacheDir withIntermediateDirectories:YES attributes:nil error:NULL];
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(backgroundCleanDisk)
                                                 name:UIApplicationDidEnterBackgroundNotification
                                               object:nil];
}
- (instancetype)initWithCacheDir:(NSString *)cacheDir
{
    self = [super init];
    if (self) {
        self.maxCacheSize = (50*1024*1024);
        NSString *domain = [cacheDir lastPathComponent];
        self.queue = dispatch_queue_create([domain cStringUsingEncoding:NSUTF8StringEncoding], DISPATCH_QUEUE_CONCURRENT);
        self.cacheDir = cacheDir;
        [[NSFileManager defaultManager] createDirectoryAtPath:self.cacheDir withIntermediateDirectories:YES attributes:nil error:NULL];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(backgroundCleanDisk)
                                                     name:UIApplicationDidEnterBackgroundNotification
                                                   object:nil];
    }
    return self;
}
- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (NSString *)cachePathForKey:(NSString *)key
{
    if (!key) return nil;
    NSString *fileName = [key md5];
    return [self.cacheDir stringByAppendingPathComponent:fileName];
}
- (void)setExpire:(NSDate *)expire forFilePath:(NSString *)filePath
{
    if (!expire) return;
    dispatch_barrier_sync(self.queue, ^{
        [self _setExpire:expire forFilePath:filePath];
    });
}
- (void)_setExpire:(NSDate *)expire forFilePath:(NSString *)filePath
{
    NSError *error;
    [[NSFileManager defaultManager] setAttributes:@{HFileExpireTimeKey:expire} ofItemAtPath:filePath error:&error];
    NSAssert(!error, [error localizedDescription]);
}
- (void)setAccessDate:(NSDate *)accessDate forFilePath:(NSString *)filePath
{
    if (!accessDate) return;
    dispatch_barrier_sync(self.queue, ^{
        [self _setAccessDate:accessDate forFilePath:filePath];
    });
}
- (void)_setAccessDate:(NSDate *)accessDate forFilePath:(NSString *)filePath
{
    NSError *error;
    [[NSFileManager defaultManager] setAttributes:@{HFileAccessTimeKey:accessDate} ofItemAtPath:filePath error:&error];
    NSAssert(!error, [error localizedDescription]);
}
- (void)setData:(NSData *)data forKey:(NSString *)key
{
    //if there is no expire time, use FIFO
    [self setData:data forKey:key expire:nil];
}
- (void)setData:(NSData *)data forKey:(NSString *)key expire:(NSDate *)expire
{
    if (!data || !key) return;
    dispatch_barrier_async(self.queue, ^{
        NSString *filePath = [self cachePathForKey:key];
        [data writeToFile:filePath atomically:YES];
        //set expire time and access time
        if (expire) [self _setExpire:expire forFilePath:filePath];
        else [self _setExpire:[NSDate dateWithTimeIntervalSince1970:0] forFilePath:filePath];
        [self _setAccessDate:[NSDate date] forFilePath:filePath];
    });
}

- (void)moveIntoFileItem:(NSString *)itemPath forKey:(NSString *)key expire:(NSDate *)expire
{
    if (!itemPath || !key) return;
    dispatch_barrier_sync(self.queue, ^{
        NSString *filePath = [self cachePathForKey:key];
        [[NSFileManager defaultManager] moveItemAtPath:itemPath toPath:filePath error:nil];
        //set expire time and access time
        if (expire) [self _setExpire:expire forFilePath:filePath];
        else [self _setExpire:[NSDate dateWithTimeIntervalSince1970:0] forFilePath:filePath];
        [self _setAccessDate:[NSDate date] forFilePath:filePath];
    });
}

- (NSData *)dataForKey:(NSString *)key
{
    if (!key) return nil;
    __block NSData *data = nil;
    dispatch_sync(self.queue, ^{
        NSString *filePath = [self cachePathForKey:key];
        data = [NSData dataWithContentsOfFile:filePath];
        if (data) [self _setAccessDate:[NSDate date] forFilePath:filePath];
    });
    return data;
}
- (BOOL)cacheExsitForKey:(NSString *)key
{
    if (!key) return NO;
    __block BOOL res = NO;
    dispatch_sync(self.queue, ^{
        BOOL isDir;
        res = [[NSFileManager defaultManager] fileExistsAtPath:[self cachePathForKey:key] isDirectory:&isDir];
    });
    return res;
}

- (long long)getSize
{
    __block long long size = 0;
    dispatch_sync(self.queue, ^{
        size = [self _getSize];
    });
    return size;
}
- (long long)_getSize
{
    long long size = 0;
    NSDirectoryEnumerator *fileEnumerator = [[NSFileManager defaultManager] enumeratorAtPath:self.cacheDir];
    for (NSString *fileName in fileEnumerator) {
        NSString *filePath = [self.cacheDir stringByAppendingPathComponent:fileName];
        NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:filePath error:nil];
        size += [attrs fileSize];
    }
    return size;
}

- (void)backgroundCleanDisk {
    Class UIApplicationClass = NSClassFromString(@"UIApplication");
    if(!UIApplicationClass || ![UIApplicationClass respondsToSelector:@selector(sharedApplication)]) {
        return;
    }
    UIApplication *application = [UIApplication performSelector:@selector(sharedApplication)];
    __block UIBackgroundTaskIdentifier bgTask = [application beginBackgroundTaskWithExpirationHandler:^{
        [application endBackgroundTask:bgTask];
        bgTask = UIBackgroundTaskInvalid;
    }];
    [self clearExpire:^(id data){
        [application endBackgroundTask:bgTask];
        bgTask = UIBackgroundTaskInvalid;
    }];
}

- (void)removeFileForKey:(NSString *)key
{
    dispatch_barrier_sync(self.queue, ^{
        NSString *filePath = [self cachePathForKey:key];
        [[NSFileManager defaultManager] removeItemAtPath:filePath error:nil];
    });
}
- (void)handleClearNotification:(NSNotification *)notification
{
    
}
- (void)clearExpire:(simple_callback)finish
{
    dispatch_barrier_async(self.queue, ^{
        NSDate *now = [NSDate date];
        //1.clear expired item
        NSFileManager *fileManager = [NSFileManager defaultManager];
        NSArray *files = [fileManager contentsOfDirectoryAtPath:self.cacheDir error:nil];
        for (NSString *fileName in files)
        {
            NSString *filePath = [self.cacheDir stringByAppendingPathComponent:fileName];
            NSDictionary *attrs = [fileManager attributesOfItemAtPath:filePath error:nil];
            BOOL shouldDelete = NO;
            if (!attrs) shouldDelete = YES;
            else
            {
                NSDate *expire = attrs[HFileExpireTimeKey];
                
                //because I use NSFileModificationDate as HFileExpireTimeKey, but mostly when file created the time is the same
                NSDate *created = attrs[NSFileCreationDate];
                if ((long long)[created timeIntervalSince1970] == (long long)[expire timeIntervalSince1970])
                {
                    continue;
                }
                
                if (!expire) shouldDelete = YES;
                else if ([expire timeIntervalSince1970] <= 0) continue;
                else
                {
                    if ([expire timeIntervalSince1970] < [now timeIntervalSince1970])
                    {
                        shouldDelete = YES;
                    }
                }
            }
            if (shouldDelete)
            {
                [fileManager removeItemAtPath:filePath error:nil];
            }
        }
        //2.if no cache size just return
        if (self.maxCacheSize < 0)
        {
            if (finish) finish(self);
            return ;
        }
        //2.if over the max size, clear by FIFO strategy
        long long cacheSize = [self _getSize];
        if (cacheSize > self.maxCacheSize)
        {
            //sort by access time
            NSMutableArray *fileInfos = [NSMutableArray new];
            for (NSString *fileName in files)
            {
                NSString *filePath = [self.cacheDir stringByAppendingPathComponent:fileName];
                NSDictionary *attrs = [fileManager attributesOfItemAtPath:filePath error:nil];
                
                HFileCacheFileInfo *fileInfo = [HFileCacheFileInfo new];
                fileInfo.filePath = filePath;
                fileInfo.lastAccess = [(NSDate *)attrs[HFileAccessTimeKey] timeIntervalSince1970];
                fileInfo.size = [attrs fileSize];
                [fileInfos addObject:fileInfo];
            }
            [fileInfos sortUsingComparator:^NSComparisonResult(HFileCacheFileInfo *obj1, HFileCacheFileInfo *obj2) {
                if (obj1.lastAccess < obj2.lastAccess) return NSOrderedAscending;
                if (obj1.lastAccess > obj2.lastAccess) return NSOrderedDescending;
                return NSOrderedSame;
            }];
            //delete and check size again
            for (HFileCacheFileInfo *fileInfo in fileInfos)
            {
                [fileManager removeItemAtPath:fileInfo.filePath error:nil];
                cacheSize -= fileInfo.size;
                if (cacheSize < self.maxCacheSize) break;
            }
        }
        
        if (finish) finish(self);
    });
}


- (void)clearAll:(simple_callback)finish
{
    dispatch_barrier_async(self.queue, ^{
        [[NSFileManager defaultManager] removeItemAtPath:self.cacheDir error:nil];
        [[NSFileManager defaultManager] createDirectoryAtPath:self.cacheDir withIntermediateDirectories:YES attributes:nil error:NULL];
        if (finish) finish(self);
    });
}
@end