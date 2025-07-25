#import "FileLogger.h"
#define LOG_LEVEL_DEF ddLogLevel
#import <CocoaLumberjack/CocoaLumberjack.h>
#import <MessageUI/MessageUI.h>
#import "FileLoggerFormatter.h"
#import <SSZipArchive/SSZipArchive.h>

enum LogLevel {
    LOG_LEVEL_DEBUG,
    LOG_LEVEL_INFO,
    LOG_LEVEL_WARNING,
    LOG_LEVEL_ERROR
};

// Log.h
@interface CustomLogFileManager : DDLogFileManagerDefault
@property (nonatomic, copy) NSString *fileName;

- (instancetype)initWithLogsDirectory:(NSString *)logsDirectory fileName:(NSString *)name;

@end

@implementation CustomLogFileManager

#pragma mark - Lifecycle method

- (instancetype)initWithLogsDirectory:(NSString *)logsDirectory
                             fileName:(NSString *)name
{
    self = [super initWithLogsDirectory:logsDirectory];
    if (self) {
        self.fileName = name;
    }
    return self;
}

#pragma mark - Override methods

- (NSString *)newLogFileName
{
     NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    [formatter setDateFormat:@"yyyy-MM-dd_HH-mm-ss"];
    NSString *timestamp = [formatter stringFromDate:[NSDate date]];

    if (self.fileName && [self.fileName length]) {
        return [NSString stringWithFormat:@"%@.log", self.fileName];
    }
    NSString *appName = self.fileName;
    if (!appName || appName.length == 0) {
        appName = [[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleDisplayName"];
    }
    if (!appName || appName.length == 0) {
        appName = [[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleName"];
    }
    return [NSString stringWithFormat:@"%@_%@.log", appName, timestamp];
}

- (BOOL)isLogFile:(NSString *)fileName
{
    NSString *appName = self.fileName;
    if (!appName || appName.length == 0) {
        appName = [[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleDisplayName"];
    }
    if (!appName || appName.length == 0) {
        appName = [[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleName"];
    }
    return [fileName hasPrefix: appName];
}

@end

static const DDLogLevel ddLogLevel = DDLogLevelDebug;

@interface FileLogger () <MFMailComposeViewControllerDelegate>
@property (nonatomic, strong) DDFileLogger* fileLogger;

@end

@implementation FileLogger

RCT_EXPORT_MODULE()

- (dispatch_queue_t)methodQueue {
    return dispatch_get_main_queue();
}

RCT_EXPORT_METHOD(configure:(NSDictionary*)options resolver:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject) {
    NSNumber* dailyRolling = options[@"dailyRolling"];
    NSNumber* maximumFileSize = options[@"maximumFileSize"];
    NSNumber* maximumNumberOfFiles = options[@"maximumNumberOfFiles"];
    NSString* logsDirectory = options[@"logsDirectory"];
    NSString* logPrefix = options[@"logPrefix"];
    if (self.fileLogger) {
        [DDLog removeLogger:self.fileLogger];
    }
    
    id<DDLogFileManager> fileManager = [[CustomLogFileManager alloc] initWithLogsDirectory:logsDirectory fileName:logPrefix];
    fileManager.maximumNumberOfLogFiles = [maximumNumberOfFiles unsignedIntegerValue];
    fileManager.logFilesDiskQuota = 0;
    
    DDFileLogger* fileLogger = [[DDFileLogger alloc] initWithLogFileManager:fileManager];
    fileLogger.logFormatter = [[FileLoggerFormatter alloc] init];
    fileLogger.rollingFrequency = [dailyRolling boolValue] ? 24 * 60 * 60 : 0;
    fileLogger.maximumFileSize = [maximumFileSize unsignedIntegerValue];

    [DDLog addLogger:fileLogger];
    self.fileLogger = fileLogger;
    
    resolve(nil);
}

RCT_EXPORT_METHOD(write:(NSNumber* _Nonnull)level str:(NSString*)str) {
    switch (level.integerValue) {
        case LOG_LEVEL_DEBUG:
            DDLogDebug(@"%@", str);
            break;
        case LOG_LEVEL_INFO:
            DDLogInfo(@"%@", str);
            break;
        case LOG_LEVEL_WARNING:
            DDLogWarn(@"%@", str);
            break;
        case LOG_LEVEL_ERROR:
            DDLogError(@"%@", str);
            break;
    }
}

RCT_EXPORT_METHOD(getLogFilePaths:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject) {
    resolve(self.fileLogger.logFileManager.sortedLogFilePaths);
}

RCT_EXPORT_METHOD(deleteLogFiles:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject) {
    [self.fileLogger rollLogFileWithCompletionBlock:^{
        for (DDLogFileInfo* logFileInfo in [self.fileLogger.logFileManager unsortedLogFileInfos]) {
            if (logFileInfo.isArchived) {
                [[NSFileManager defaultManager] removeItemAtPath:logFileInfo.filePath error:nil];
            }
        }
        resolve(nil);
    }];
}

RCT_EXPORT_METHOD(sendLogFilesByEmail:(NSDictionary*)options resolver:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject) {
    NSArray<NSString*>* to = options[@"to"];
    NSString* subject = options[@"subject"];
    NSString* body = options[@"body"];
    NSNumber* compressFiles = options[@"compressFiles"];

    if (![MFMailComposeViewController canSendMail]) {
        reject(@"CannotSendMail", @"Cannot send emails on this device", nil);
        return;
    }
    
    MFMailComposeViewController* composeViewController = [[MFMailComposeViewController alloc] init];
    composeViewController.mailComposeDelegate = self;
    if (to) {
        [composeViewController setToRecipients:to];
    }
    if (subject) {
        [composeViewController setSubject:subject];
    }
    if (body) {
        [composeViewController setMessageBody:body isHTML:NO];
    }
    
    NSArray<NSString*>* logFiles = self.fileLogger.logFileManager.sortedLogFilePaths;
    
    if ([compressFiles boolValue]) {
        // Create a temporary directory for the zip file
        NSString* tempDir = NSTemporaryDirectory();
        NSString* zipPath = [tempDir stringByAppendingPathComponent:@"logs.zip"];
        
        // Create zip file containing all log files
        [SSZipArchive createZipFileAtPath:zipPath withFilesAtPaths:logFiles];
        
        // Add the zip file as attachment
        NSData* zipData = [NSData dataWithContentsOfFile:zipPath];
        [composeViewController addAttachmentData:zipData mimeType:@"application/zip" fileName:@"logs.zip"];
        
        // Clean up the temporary zip file
        [[NSFileManager defaultManager] removeItemAtPath:zipPath error:nil];
    } else {
        // Add each log file as a separate attachment
        for (NSString* logFile in logFiles) {
            NSData* data = [NSData dataWithContentsOfFile:logFile];
            [composeViewController addAttachmentData:data mimeType:@"text/plain" fileName:[logFile lastPathComponent]];
        }
    }
    
    UIViewController* presentingViewController = UIApplication.sharedApplication.delegate.window.rootViewController;
    while (presentingViewController.presentedViewController) {
        presentingViewController = presentingViewController.presentedViewController;
    }
    [presentingViewController presentViewController:composeViewController animated:YES completion:nil];
    
    resolve(nil);
}

- (void)mailComposeController:(MFMailComposeViewController*)controller didFinishWithResult:(MFMailComposeResult)result error:(NSError*)error {
    [controller dismissViewControllerAnimated:YES completion:nil];
}
- (void)dealloc
{
    if (self.fileLogger) {
        [DDLog removeLogger:self.fileLogger];
    }
}
// Don't compile this code when we build for the old architecture.
#ifdef RCT_NEW_ARCH_ENABLED
- (std::shared_ptr<facebook::react::TurboModule>)getTurboModule:
    (const facebook::react::ObjCTurboModule::InitParams &)params
{
    return std::make_shared<facebook::react::NativeFileLoggerSpecJSI>(params);
}

// Signature only used by the new architecture.
- (void)configure:(JS::NativeFileLogger::NativeConfigureOptions &)options resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject {
    NSMutableDictionary * optionsDict = [NSMutableDictionary dictionary];

    [optionsDict setValue:@(options.dailyRolling()) forKey:@"dailyRolling"];
    [optionsDict setValue:@(options.maximumFileSize()) forKey:@"maximumFileSize"];
    [optionsDict setValue:@(options.maximumNumberOfFiles()) forKey:@"maximumNumberOfFiles"];
    NSString* logsDirectory = options.logsDirectory();
    if (logsDirectory) {
        [optionsDict setValue:logsDirectory forKey:@"logsDirectory"];
    }
    NSString* logPrefix = options.logPrefix();
    if (logPrefix) {
        [optionsDict setValue:logPrefix forKey:@"logPrefix"];
    }

    [self configure:optionsDict resolver:resolve rejecter:reject];
}

// Signature only used by the new architecture.
- (void)sendLogFilesByEmail:(JS::NativeFileLogger::SendByEmailOptions &)options resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject {
    NSMutableDictionary * optionsDict = [NSMutableDictionary dictionary];
    
    [optionsDict setValue:options.subject() forKey:@"subject"];
    [optionsDict setValue:options.body() forKey:@"body"];
    [optionsDict setValue:convertToNSArray(options.to()) forKey:@"to"];
    [optionsDict setValue:@(options.compressFiles()) forKey:@"compressFiles"];

    [self sendLogFilesByEmail:optionsDict resolver:resolve rejecter:reject];
}

// Signature only used by the new architecture.
- (void)write:(double)level msg:(NSString *)msg {
    NSNumber* _Nonnull logLevel = [NSNumber numberWithInt:level];
    [self write:logLevel str:msg];
}

NSArray<NSString *> *convertToNSArray(std::optional<FB::LazyVector<NSString *, id>> optional) {
    if (optional.has_value()) {
        FB::LazyVector<NSString *, id> value = optional.value();
        NSMutableArray<NSString *> *result = [[NSMutableArray alloc] initWithCapacity:value.size()];
        for (const auto &string : value) {
            [result addObject:string];
        }
        return result;
    } else {
        return [[NSArray alloc] init];
    }
}
#endif


@end

