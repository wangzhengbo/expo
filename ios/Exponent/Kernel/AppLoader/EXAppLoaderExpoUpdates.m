// Copyright 2020-present 650 Industries. All rights reserved.

#import "EXAppFetcher.h"
#import "EXClientReleaseType.h"
#import "EXEnvironment.h"
#import "EXErrorRecoveryManager.h"
#import "EXFileDownloader.h"
#import "EXKernel.h"
#import "EXKernelLinkingManager.h"
#import "EXSession.h"
#import "EXAppLoaderExpoUpdates.h"
#import "EXVersions.h"

#import <EXUpdates/EXUpdatesAppLoaderTask.h>
#import <EXUpdates/EXUpdatesConfig.h>
#import <EXUpdates/EXUpdatesDatabase.h>
#import <EXUpdates/EXUpdatesFileDownloader.h>
#import <EXUpdates/EXUpdatesSelectionPolicyNewest.h>
#import <EXUpdates/EXUpdatesUtils.h>
#import <React/RCTUtils.h>
#import <sys/utsname.h>

NS_ASSUME_NONNULL_BEGIN

@interface EXAppLoaderExpoUpdates ()

@property (nonatomic, strong, nullable) NSURL *manifestUrl;
@property (nonatomic, strong, nullable) NSURL *httpManifestUrl;

@property (nonatomic, strong, nullable) NSDictionary *confirmedManifest;
@property (nonatomic, strong, nullable) NSDictionary *optimisticManifest;
@property (nonatomic, strong, nullable) NSData *bundle;

@property (nonatomic, strong, nullable) NSError *error;

@property (nonatomic, assign) BOOL shouldUseCacheOnly;

@property (nonatomic, strong) dispatch_queue_t appLoaderQueue;

@end

@implementation EXAppLoaderExpoUpdates

@synthesize manifestUrl = _manifestUrl;
@synthesize bundle = _bundle;

- (instancetype)initWithManifestUrl:(NSURL *)url
{
  if (self = [super init]) {
    _manifestUrl = url;
    _httpManifestUrl = [EXAppLoaderExpoUpdates _httpUrlFromManifestUrl:_manifestUrl];
    _appLoaderQueue = dispatch_queue_create("host.exp.exponent.LoaderQueue", DISPATCH_QUEUE_SERIAL);
  }
  return self;
}

#pragma mark - getters and lifecycle

- (void)_reset
{
  _confirmedManifest = nil;
  _optimisticManifest = nil;
  _error = nil;
  _shouldUseCacheOnly = NO;
}

- (EXAppLoaderStatus)status
{
  if (_error) {
    return kEXAppLoaderStatusError;
  } else if (_bundle) {
    return kEXAppLoaderStatusHasManifestAndBundle;
  } else if (_optimisticManifest) {
    return kEXAppLoaderStatusHasManifest;
  }
  return kEXAppLoaderStatusNew;
}

- (nullable NSDictionary *)manifest
{
  if (_confirmedManifest) {
    return _confirmedManifest;
  }
  if (_optimisticManifest) {
    return _optimisticManifest;
  }
  return nil;
}

- (nullable NSData *)bundle
{
  if (_bundle) {
    return _bundle;
  }
  return nil;
}

- (void)forceBundleReload
{
  if (self.status == kEXAppLoaderStatusNew) {
    @throw [NSException exceptionWithName:NSInternalInconsistencyException
                                   reason:@"Tried to load a bundle from an AppLoader with no manifest."
                                 userInfo:@{}];
  }
  NSAssert([self supportsBundleReload], @"Tried to force a bundle reload on a non-development bundle");
  [self _loadDevelopmentJavaScriptResource];
}

- (BOOL)supportsBundleReload
{
  if (_optimisticManifest) {
    return [EXAppFetcher areDevToolsEnabledWithManifest:_optimisticManifest];
  }
  return NO;
}

#pragma mark - public

- (void)request
{
  [self _reset];
  if (_manifestUrl) {
    [self _beginRequest];
  }
}

- (void)requestFromCache
{
  [self _reset];
  _shouldUseCacheOnly = YES;
  if (_manifestUrl) {
    [self _beginRequest];
  }
}

#pragma mark - EXUpdatesAppLoaderTaskDelegate

- (void)appLoaderTask:(EXUpdatesAppLoaderTask *)appLoaderTask didStartLoadingUpdate:(EXUpdatesUpdate *)update
{
  _optimisticManifest = update.rawManifest;
  if (self.delegate) {
    [self.delegate appLoader:self didLoadOptimisticManifest:update.rawManifest];
  }
}

- (void)appLoaderTask:(EXUpdatesAppLoaderTask *)appLoaderTask didFinishWithLauncher:(id<EXUpdatesAppLauncher>)launcher
{
  NSAssert(![EXAppFetcher areDevToolsEnabledWithManifest:launcher.launchedUpdate.rawManifest], @"Should not finish loading a development mode manifest and bundle with AppLoaderTask");
  _confirmedManifest = launcher.launchedUpdate.rawManifest;
  _bundle = [NSData dataWithContentsOfURL:launcher.launchAssetUrl];
  if (self.delegate) {
    [self.delegate appLoader:self didFinishLoadingManifest:_confirmedManifest bundle:_bundle];
  }
}

- (void)appLoaderTask:(EXUpdatesAppLoaderTask *)appLoaderTask didFinishWithError:(NSError *)error
{
  _error = error;
  if (self.delegate) {
    [self.delegate appLoader:self didFailWithError:error];
  }
}

- (void)appLoaderTask:(EXUpdatesAppLoaderTask *)appLoaderTask didFireEventWithType:(NSString *)type body:(NSDictionary *)body
{
  // TODO: add delegate method for this
}

#pragma mark - EXUpdatesAppLoaderTaskAborterDelegate

- (BOOL)appLoaderTask:(EXUpdatesAppLoaderTask *)appLoaderTask shouldLoadCachedUpdate:(EXUpdatesUpdate *)update
{
  if ([EXAppFetcher areDevToolsEnabledWithManifest:update.rawManifest]) {
    dispatch_async(_appLoaderQueue, ^{
      [self _startDevelopmentModeLoad];
    });
    return NO;
  }
  // if previous run of this app failed due to a loading error, we want to make sure to check for remote updates
  if ([[EXKernel sharedInstance].serviceRegistry.errorRecoveryManager experienceIdIsRecoveringFromError:[EXAppFetcher experienceIdWithManifest:update.rawManifest]]) {
    if (_shouldUseCacheOnly) {
      _shouldUseCacheOnly = NO;
      dispatch_async(_appLoaderQueue, ^{
        [self _startLoaderTask];
      });
      return NO;
    }
  }
  return YES;
}

- (BOOL)appLoaderTask:(EXUpdatesAppLoaderTask *)appLoaderTask shouldLoadRemoteUpdate:(EXUpdatesUpdate *)update
{
  if ([EXAppFetcher areDevToolsEnabledWithManifest:update.rawManifest]) {
    _optimisticManifest = update.rawManifest;
    _confirmedManifest = _optimisticManifest;
    if (self.delegate) {
      [self.delegate appLoader:self didLoadOptimisticManifest:update.rawManifest];
    }
    return NO;
  } else {
    return YES;
  }
}

#pragma mark - internal

+ (NSURL *)_httpUrlFromManifestUrl:(NSURL *)url
{
  NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:YES];
  // if scheme is exps or https, use https. Else default to http
  if (components.scheme && ([components.scheme isEqualToString:@"exps"] || [components.scheme isEqualToString:@"https"])){
    components.scheme = @"https";
  } else {
    components.scheme = @"http";
  }
  NSMutableString *path = [((components.path) ? components.path : @"") mutableCopy];
  path = [[EXKernelLinkingManager stringByRemovingDeepLink:path] mutableCopy];
  components.path = path;
  return [components URL];
}

- (void)_beginRequest
{
  // if we're in dev mode, don't try loading cached manifest
  if ([_httpManifestUrl.host isEqualToString:@"localhost"]) {
    // we can't pre-detect if this person is using a developer tool, but using localhost is a pretty solid indicator.
    [self _startDevelopmentModeLoad];
  } else {
    [self _startLoaderTask];
  }
}

- (void)_startLoaderTask
{
  EXUpdatesConfig *config = [EXUpdatesConfig configWithDictionary:@{
    @"EXUpdatesURL": [[self class] _httpUrlFromManifestUrl:_manifestUrl].absoluteString,
    @"EXUpdatesSDKVersion": [self _sdkVersions],
    @"EXUpdatesScopeKey": _manifestUrl.absoluteString,
    @"EXUpdatesHasEmbeddedUpdate": @(NO),
    @"EXUpdatesEnabled": @(YES),
    @"EXUpdatesLaunchWaitMs": _shouldUseCacheOnly ? @(0) : @(10000),
    @"EXUpdatesCheckOnLaunch": _shouldUseCacheOnly ? @"NEVER" : @"ALWAYS",
    @"EXUpdatesRequestHeaders": [self _requestHeaders]
  }];

  NSError *fsError;
  NSURL *updatesDirectory = [EXUpdatesUtils initializeUpdatesDirectoryWithError:&fsError];
  __block NSError *dbError;
  EXUpdatesDatabase *database = [[EXUpdatesDatabase alloc] init];
  dispatch_sync(database.databaseQueue, ^{
    [database openDatabaseInDirectory:updatesDirectory withError:&dbError];
  });

  EXUpdatesSelectionPolicyNewest *selectionPolicy = [[EXUpdatesSelectionPolicyNewest alloc] initWithRuntimeVersions:[EXVersions sharedInstance].versions[@"sdkVersions"] ?: @[[EXVersions sharedInstance].temporarySdkVersion]];

  EXUpdatesAppLoaderTask *loaderTask = [[EXUpdatesAppLoaderTask alloc] initWithConfig:config
                                                                             database:database
                                                                            directory:updatesDirectory
                                                                      selectionPolicy:selectionPolicy
                                                                        delegateQueue:_appLoaderQueue];
  loaderTask.delegate = self;
  loaderTask.aborterDelegate = self;
  [loaderTask start];
}

- (void)_startDevelopmentModeLoad
{
  NSURL *httpManifestUrl = [[self class] _httpUrlFromManifestUrl:_manifestUrl];

  EXUpdatesConfig *config = [EXUpdatesConfig configWithDictionary:@{
    @"EXUpdatesURL": httpManifestUrl.absoluteString,
    @"EXUpdatesSDKVersion": [self _sdkVersions],
    @"EXUpdatesScopeKey": _manifestUrl.absoluteString,
    @"EXUpdatesRequestHeaders": [self _requestHeaders]
  }];

  EXUpdatesFileDownloader *fileDownloader = [[EXUpdatesFileDownloader alloc] initWithUpdatesConfig:config];
  // TODO: database and cache directory
  [fileDownloader downloadManifestFromURL:httpManifestUrl withDatabase:[[EXUpdatesDatabase alloc] init] cacheDirectory:[EXUpdatesUtils initializeUpdatesDirectoryWithError:nil] successBlock:^(EXUpdatesUpdate * _Nonnull update) {
    self.optimisticManifest = update.rawManifest;
    self.confirmedManifest = self.optimisticManifest;
    if (self.delegate) {
      [self.delegate appLoader:self didLoadOptimisticManifest:self.optimisticManifest];
    }
  } errorBlock:^(NSError * _Nonnull error, NSURLResponse * _Nonnull response) {
    self.error = error;
    if (self.delegate) {
      [self.delegate appLoader:self didFailWithError:error];
    }
  }];
}

- (void)_loadDevelopmentJavaScriptResource
{
  EXAppFetcher *appFetcher = [[EXAppFetcher alloc] initWithAppLoader:self];
  [appFetcher fetchJSBundleWithManifest:self.confirmedManifest cacheBehavior:EXCachedResourceNoCache timeoutInterval:kEXJSBundleTimeout progress:^(EXLoadingProgress *progress) {
    if (self.delegate) {
      [self.delegate appLoader:self didLoadBundleWithProgress:progress];
    }
  } success:^(NSData *bundle) {
    self.bundle = bundle;
    if (self.delegate) {
      [self.delegate appLoader:self didFinishLoadingManifest:self.confirmedManifest bundle:self.bundle];
    }
  } error:^(NSError *error) {
    self.error = error;
    if (self.delegate) {
      [self.delegate appLoader:self didFailWithError:error];
    }
  }];
}

- (NSDictionary *)_requestHeaders
{
  NSDictionary *requestHeaders = @{
      @"Exponent-SDK-Version": [self _sdkVersions],
      @"Exponent-Accept-Signature": @"true",
      @"Exponent-Platform": @"ios",
      @"Exponent-Version": [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"],
      @"Expo-Client-Environment": [self _clientEnvironment],
      @"Expo-Updates-Environment": [self _clientEnvironment],
      @"User-Agent": [self _userAgentString],
      @"Expo-Client-Release-Type": [EXClientReleaseType clientReleaseType]
  };

  NSString *sessionSecret = [[EXSession sharedInstance] sessionSecret];
  if (sessionSecret) {
    NSMutableDictionary *requestHeadersMutable = [requestHeaders mutableCopy];
    requestHeadersMutable[@"Expo-Session"] = sessionSecret;
    requestHeaders = requestHeadersMutable;
  }

  return requestHeaders;
}

- (NSString *)_userAgentString
{
  struct utsname systemInfo;
  uname(&systemInfo);
  NSString *deviceModel = [NSString stringWithCString:systemInfo.machine encoding:NSUTF8StringEncoding];
  return [NSString stringWithFormat:@"Exponent/%@ (%@; %@ %@; Scale/%.2f; %@)",
          [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"],
          deviceModel,
          [UIDevice currentDevice].systemName,
          [UIDevice currentDevice].systemVersion,
          [UIScreen mainScreen].scale,
          [NSLocale autoupdatingCurrentLocale].localeIdentifier];
}

- (NSString *)_clientEnvironment
{
  if ([EXEnvironment sharedEnvironment].isDetached) {
    return @"STANDALONE";
  } else {
    return @"EXPO_DEVICE";
#if TARGET_IPHONE_SIMULATOR
    return @"EXPO_SIMULATOR";
#endif
  }
}

- (NSString *)_sdkVersions
{
  NSArray *versionsAvailable = [EXVersions sharedInstance].versions[@"sdkVersions"];
  if (versionsAvailable) {
    return [versionsAvailable componentsJoinedByString:@","];
  } else {
    return [EXVersions sharedInstance].temporarySdkVersion;
  }
}

@end

NS_ASSUME_NONNULL_END
