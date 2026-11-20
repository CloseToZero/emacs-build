// SPDX-FileCopyrightText: 2026 Chen Zhexuan
// SPDX-License-Identifier: MIT
// Small AppleEvent-aware emacsclient launcher, compiled for the advertised OS.
// osacompile's system droplet stub can require the builder's exact macOS patch
// release; compiling our own launcher avoids silently requiring macOS 14.8.
#import <AppKit/AppKit.h>

@interface EmacsClientDelegate : NSObject <NSApplicationDelegate>
@property(nonatomic, strong) NSMutableArray<NSString *> *pending;
@property(nonatomic, strong) NSTask *task;
- (void)openPending;
@end

@implementation EmacsClientDelegate
- (instancetype)init {
  self = [super init];
  if (self) self.pending = [NSMutableArray array];
  return self;
}

- (void)scheduleOpen {
  [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(openPending) object:nil];
  [self performSelector:@selector(openPending) withObject:nil afterDelay:0.1];
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
  [self scheduleOpen];
}

- (void)application:(NSApplication *)sender openFiles:(NSArray<NSString *> *)files {
  [self.pending addObjectsFromArray:files];
  [self scheduleOpen];
  [sender replyToOpenOrPrint:NSApplicationDelegateReplySuccess];
}

- (void)application:(NSApplication *)application openURLs:(NSArray<NSURL *> *)urls {
  for (NSURL *url in urls) [self.pending addObject:url.absoluteString];
  [self scheduleOpen];
}

- (void)reportError:(NSString *)message {
  NSAlert *alert = [[NSAlert alloc] init];
  alert.messageText = @"Emacs Client could not open Emacs";
  alert.informativeText = message;
  [alert runModal];
  [NSApp terminate:nil];
}

- (void)openPending {
  if (self.task) return;
  NSURL *parent = NSBundle.mainBundle.bundleURL.URLByDeletingLastPathComponent;
  NSURL *bin = [parent URLByAppendingPathComponent:@"Emacs.app/Contents/MacOS/bin" isDirectory:YES];
  NSURL *client = [bin URLByAppendingPathComponent:@"emacsclient"];
  if (![NSFileManager.defaultManager isExecutableFileAtPath:client.path]) {
    [self reportError:@"Keep Emacs Client.app beside Emacs.app."];
    return;
  }
  NSTask *task = [[NSTask alloc] init];
  task.executableURL = client;
  NSMutableArray<NSString *> *arguments = [NSMutableArray arrayWithArray:@[@"-c", @"-n", @"-a", @"", @"--"]];
  [arguments addObjectsFromArray:self.pending];
  [self.pending removeAllObjects];
  task.arguments = arguments;
  NSMutableDictionary *environment = [NSProcessInfo.processInfo.environment mutableCopy];
  environment[@"PATH"] = [bin.path stringByAppendingString:@":/usr/bin:/bin:/usr/sbin:/sbin"];
  task.environment = environment;
  __weak EmacsClientDelegate *weakSelf = self;
  task.terminationHandler = ^(NSTask *finished) {
    dispatch_async(dispatch_get_main_queue(), ^{
      EmacsClientDelegate *owner = weakSelf;
      if (!owner) return;
      owner.task = nil;
      if (finished.terminationStatus != 0) {
        [owner reportError:@"emacsclient failed. Check the Emacs server and your configuration."];
      } else if (owner.pending.count) {
        [owner openPending];
      } else {
        [NSApp terminate:nil];
      }
    });
  };
  self.task = task;
  NSError *error = nil;
  if (![task launchAndReturnError:&error]) {
    self.task = nil;
    [self reportError:error.localizedDescription];
  }
}
@end

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    NSApplication *application = NSApplication.sharedApplication;
    __attribute__((objc_precise_lifetime)) EmacsClientDelegate *delegate = [[EmacsClientDelegate alloc] init];
    application.delegate = delegate;
    [application setActivationPolicy:NSApplicationActivationPolicyAccessory];
    [application run];
  }
  return 0;
}
