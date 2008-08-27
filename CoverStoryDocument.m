//
//  CoverStoryDocument.m
//  CoverStory
//
//  Created by dmaclach on 12/20/06.
//  Copyright 2006-2007 Google Inc.
//  Licensed under the Apache License, Version 2.0 (the "License"); you may not
//  use this file except in compliance with the License.  You may obtain a copy
//  of the License at
// 
//  http://www.apache.org/licenses/LICENSE-2.0
// 
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
//  WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.  See the
//  License for the specific language governing permissions and limitations under
//  the License.
//

#import "CoverStoryDocument.h"
#import "CoverStoryCoverageData.h"
#import "CoverStoryDocumentTypes.h"
#import "CoverStoryPreferenceKeys.h"
#import "GTMScriptRunner.h"
#import "GTMNSFileManager+Path.h"
#import "GTMNSEnumerator+Filter.h"

@interface NSTableView (CoverStoryTableView)
- (void)cs_setSortKeyOfColumn:(NSString *)columnName
                           to:(NSString *)sortKeyName;
- (void)cs_setValueTransformerOfColumn:(NSString *)columnName
                                    to:(NSString *)transformerName;
- (void)cs_setHeaderOfColumn:(NSString*)columnName
                          to:(NSString*)name;
@end

typedef enum {
  kCSMessageTypeError,
  kCSMessageTypeWarning,
  kCSMessageTypeInfo
} CSMessageType;

@interface CoverStoryDocument (PrivateMethods)
- (void)openFolderInThread:(NSString*)path;
- (void)openFileInThread:(NSString*)path;
- (void)setOpenThreadState:(BOOL)threadRunning;
- (BOOL)processCoverageForFolder:(NSString *)path;
- (BOOL)processCoverageForFiles:(NSArray *)filenames
                       inFolder:(NSString *)folderPath;
- (BOOL)addFileData:(CoverStoryCoverageFileData *)fileData;
- (void)configureCoverageVsComplexityColumns;
- (void)addMessageFromThread:(NSString *)message 
                        path:(NSString*)path 
                 messageType:(CSMessageType)msgType;
- (void)addMessageFromThread:(NSString *)message
                 messageType:(CSMessageType)msgType;
- (void)addMessage:(NSDictionary *)msgInfo;
- (BOOL)isClosed;
@end

static NSString *const kPrefsToWatch[] = { 
  kCoverStoryHideSystemSourcesKey,
  kCoverStorySystemSourcesPatternsKey,
  kCoverStoryHideUnittestSourcesKey,
  kCoverStoryUnittestSourcesPatternsKey,
  kCoverStoryShowComplexityKey,
  kCoverStoryRemoveCommonSourcePrefix,
  kCoverStoryMissedLineColorKey,
  kCoverStoryUnexecutableLineColorKey,
  kCoverStoryNonFeasibleLineColorKey,
  kCoverStoryExecutedLineColorKey
};

@implementation CoverStoryDocument

+ (void)registerDefaults {
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  NSDictionary *documentDefaults =
    [NSDictionary dictionaryWithObjectsAndKeys:
     [NSNumber numberWithInt:kCoverStoryFilterStringTypeWildcardPattern],
     kCoverStoryFilterStringTypeKey,
     [NSNumber numberWithBool:NO], // defaults to coverage
     kCoverStoryShowComplexityKey,
     [NSNumber numberWithBool:YES],
     kCoverStoryRemoveCommonSourcePrefix,
     nil];
  
  [defaults registerDefaults:documentDefaults];
}

- (NSString*)valuesKey:(NSString*)key {
  return [NSString stringWithFormat:@"values.%@", key];
}

- (id)init {
  if ((self = [super init])) {
    
    dataSet_ = [[CoverStoryCoverageSet alloc] init];

    NSString *path;
    NSFileWrapper *wrapper;
    NSBundle *mainBundle = [NSBundle mainBundle];

    path        = [mainBundle pathForResource:@"error" ofType:@"png"];
    wrapper     = [[[NSFileWrapper alloc] initWithPath:path] autorelease];
    errorIcon_  = [[NSTextAttachment alloc] initWithFileWrapper:wrapper];

    path         = [mainBundle pathForResource:@"warning" ofType:@"png"];
    wrapper      = [[[NSFileWrapper alloc] initWithPath:path] autorelease];
    warningIcon_ = [[NSTextAttachment alloc] initWithFileWrapper:wrapper];
    
    path         = [mainBundle pathForResource:@"info" ofType:@"png"];
    wrapper      = [[[NSFileWrapper alloc] initWithPath:path] autorelease];
    infoIcon_    = [[NSTextAttachment alloc] initWithFileWrapper:wrapper];
  }
  return self;
}

- (void)dealloc {
  NSUserDefaultsController *defaults = [NSUserDefaultsController sharedUserDefaultsController];
  for (size_t i = 0; i < sizeof(kPrefsToWatch) / sizeof(NSString*); ++i) {
    [defaults removeObserver:self 
                  forKeyPath:[self valuesKey:kPrefsToWatch[i]]];
  }  
  [dataSet_ release];
  [filterString_ release];
  [currentAnimation_ release];
  [commonPathPrefix_ release];
  [super dealloc];
}


- (void)awakeFromNib {
  // expand the search field to start out (odds are we've already started to
  // load something, but the annimation is done by a selector invoke on the main
  // thread so it will happen after we've been called.)
  NSRect searchFieldFrame = [searchField_ frame];
  annimationWidth_ = searchFieldFrame.origin.x - [spinner_ frame].origin.x;
  searchFieldFrame.origin.x -= annimationWidth_;
  searchFieldFrame.size.width += annimationWidth_;
  [searchField_ setFrame:searchFieldFrame];
  
  [sourceFilesController_ addObserver:self 
                           forKeyPath:@"selectedObjects" 
                              options:NSKeyValueObservingOptionNew
                              context:nil];

  NSUserDefaultsController *defaults = [NSUserDefaultsController sharedUserDefaultsController];
  for (size_t i = 0; i < sizeof(kPrefsToWatch) / sizeof(NSString*); ++i) {
    [defaults addObserver:self 
               forKeyPath:[self valuesKey:kPrefsToWatch[i]]
                  options:NSKeyValueObservingOptionNew
                  context:nil];
  }
  
  [self observeValueForKeyPath:@"selectedObjects"
                      ofObject:sourceFilesController_
                        change:nil
                       context:nil];
  
  NSSortDescriptor *ascending = [[[NSSortDescriptor alloc] initWithKey:@"coverage"
                                                             ascending:YES] autorelease];
  [sourceFilesController_ setSortDescriptors:[NSArray arrayWithObject:ascending]];
  [self configureCoverageVsComplexityColumns];
}

- (NSString *)windowNibName {
  return @"CoverStoryDocument";
}
  
// Called as a performSelectorOnMainThread, so must check to make sure
// we haven't been closed.
- (BOOL)addFileData:(CoverStoryCoverageFileData *)fileData {
  if ([self isClosed]) return NO;
  ++numFileDatas_;
  [fileData setUserData:self]; // store us in there for the value transformer
  [self willChangeValueForKey:@"dataSet_"];
  BOOL isGood = [dataSet_ addFileData:fileData messageReceiver:self];
  [self didChangeValueForKey:@"dataSet_"];
  return isGood;
}

- (BOOL)readFromFileWrapper:(NSFileWrapper *)fileWrapper
                     ofType:(NSString *)typeName
                      error:(NSError **)outError {
  BOOL isGood = NO;
  numFileDatas_ = 0;

  // the wrapper doesn't have the full path, but it's already set on us, so
  // use that instead.
  NSString *path = [self fileName];
  if ([fileWrapper isDirectory]) {
    NSString *message =
      [NSString stringWithFormat:@"Scanning for coverage data in '%@'",
       path];
    [self addMessageFromThread:message messageType:kCSMessageTypeInfo];
    [NSThread detachNewThreadSelector:@selector(openFolderInThread:)
                             toTarget:self
                           withObject:path];
    isGood = YES;
  } else if ([typeName isEqualToString:@kGCOVTypeName]) {
    NSString *message =
      [NSString stringWithFormat:@"Reading gcov data '%@'",
       path];
    [self addMessageFromThread:message messageType:kCSMessageTypeInfo];
    // load it and add it to our set
    CoverStoryCoverageFileData *fileData =
      [CoverStoryCoverageFileData coverageFileDataFromPath:path
                                           messageReceiver:self];
    if (fileData) {
      isGood = [self addFileData:fileData];
    } else {
      [self addMessageFromThread:@"Failed to load gcov data"
                            path:path
                     messageType:kCSMessageTypeError];
    }
  } else {
    NSString *message =
      [NSString stringWithFormat:@"Processing coverage data in '%@'",
       path];
    [self addMessageFromThread:message messageType:kCSMessageTypeInfo];
    [NSThread detachNewThreadSelector:@selector(openFileInThread:)
                             toTarget:self
                           withObject:path];
    isGood = YES;
  }
  return isGood;
}

- (void)openSelectedSource {
  BOOL didOpen = NO;
  NSArray *fileSelection = [sourceFilesController_ selectedObjects];      
  CoverStoryCoverageFileData *fileData = [fileSelection objectAtIndex:0];
  NSString *path = [fileData sourcePath];
  NSIndexSet *selectedRows = [codeTableView_ selectedRowIndexes];
  if ([selectedRows count]) {
    NSString *scriptPath = [[NSBundle mainBundle] pathForResource:@"openscript"
                                                           ofType:@"scpt"
                                                      inDirectory:@"Scripts"];
    if (scriptPath) {
      GTMScriptRunner *runner = [GTMScriptRunner runnerWithInterpreter:@"/usr/bin/osascript"];
      [runner runScript:scriptPath
               withArgs:[NSArray arrayWithObjects:
                         path,
                         [NSString stringWithFormat:@"%d", [selectedRows firstIndex] + 1],
                         [NSString stringWithFormat:@"%d", [selectedRows lastIndex] + 1],
                         nil]];
    }                         
  }
  if (!didOpen) {
    [[NSWorkspace sharedWorkspace] openFile:path];
  }
}

- (BOOL)isDocumentEdited {
  return NO;
}

- (void)openFolderInThread:(NSString*)path {
  NSAutoreleasePool *pool = [NSAutoreleasePool new];
  [self setOpenThreadState:YES];
  @try {
    [self processCoverageForFolder:path];
  }
  @catch (NSException *e) {
    NSString *msg =
      [NSString stringWithFormat:@"Internal error while processing directory (%@ - %@).",
                                 [e name], [e reason]];
    [self addMessageFromThread:msg path:path messageType:kCSMessageTypeError];
  }
  [self performSelectorOnMainThread:@selector(finishedLoadingFileDatas:)
                         withObject:@"ignored"
                      waitUntilDone:NO];
  [self setOpenThreadState:NO];
  
  // Clean up NSTask Zombies.
  [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1]];
  [pool release];
}

- (void)openFileInThread:(NSString*)path {
  NSAutoreleasePool *pool = [NSAutoreleasePool new];
  [self setOpenThreadState:YES];
  NSString *folderPath = [path stringByDeletingLastPathComponent];
  NSString *filename = [path lastPathComponent];
  @try {
    [self processCoverageForFiles:[NSArray arrayWithObject:filename]
                         inFolder:folderPath];
  }
  @catch (NSException *e) {
    NSString *msg =
    [NSString stringWithFormat:@"Internal error while processing file (%@ - %@).",
     [e name], [e reason]];
    [self addMessageFromThread:msg path:path messageType:kCSMessageTypeError];
  }
  [self performSelectorOnMainThread:@selector(finishedLoadingFileDatas:)
                         withObject:@"ignored"
                      waitUntilDone:NO];
  [self setOpenThreadState:NO];
  
  // Clean up NSTask Zombies.
  [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1]];
  [pool release];
}

- (BOOL)processCoverageForFolder:(NSString *)path {
  // cycle through the directory...
  NSFileManager *fm = [NSFileManager defaultManager];
  NSDirectoryEnumerator *enumerator = [fm enumeratorAtPath:path];
  // ...filter to .gcda files...
  NSEnumerator *enumerator2 =
    [enumerator gtm_filteredEnumeratorByMakingEachObjectPerformSelector:@selector(hasSuffix:)
                                                             withObject:@".gcda"];
  // ...turn them all into full paths...
  NSEnumerator *enumerator3 =
    [enumerator2 gtm_enumeratorByTarget:path
                  performOnEachSelector:@selector(stringByAppendingPathComponent:)];
  // .. and collect them all.
  NSArray *allFilePaths = [enumerator3 allObjects];
  int pathCount = [allFilePaths count];
  if (pathCount == 0) {
    [self addMessageFromThread:@"Found no gcda files to process."
                   messageType:kCSMessageTypeWarning];
  } else if (pathCount == 1) {
    [self addMessageFromThread:@"Found 1 gcda file to process."
                   messageType:kCSMessageTypeInfo];
  } else {
    NSString *message =
      [NSString stringWithFormat:@"Found %u gcda files to process.", pathCount];
    [self addMessageFromThread:message
                   messageType:kCSMessageTypeInfo];
  }
  
  // we want to back process them by chunks w/in a given directory.  so sort
  // and then break them off into chunks.
  allFilePaths = [allFilePaths sortedArrayUsingSelector:@selector(compare:)];
  NSEnumerator *pathEnum = [allFilePaths objectEnumerator];
  NSString *filename;
  if ((filename = [pathEnum nextObject])) {
    // seed our collecting w/ the first item
    NSString *currentFolder = [filename stringByDeletingLastPathComponent];
    NSMutableArray *currentFileList =
      [NSMutableArray arrayWithObject:[filename lastPathComponent]];
    
    // now spin the loop
    while ((filename = [pathEnum nextObject])) {
      // see if it has the same parent folder
      if ([[filename stringByDeletingLastPathComponent] isEqualTo:currentFolder]) {
        // add it
        NSAssert([currentFileList count] > 0, @"file list should NOT be empty");
        [currentFileList addObject:[filename lastPathComponent]];
      } else {
        // process what's in the list
        if (![self processCoverageForFiles:currentFileList
                                  inFolder:currentFolder]) {
          NSString *message =
            [NSString stringWithFormat:@"failed to process files: %@",
             currentFileList];
          [self addMessageFromThread:message path:currentFolder
                         messageType:kCSMessageTypeError];
        }
        // restart the collecting w/ this filename
        currentFolder = [filename stringByDeletingLastPathComponent];
        [currentFileList removeAllObjects];
        [currentFileList addObject:[filename lastPathComponent]];
      }
    }
    // process whatever what we were collecting when we hit the end
    if (![self processCoverageForFiles:currentFileList
                              inFolder:currentFolder]) {
      NSString *message =
        [NSString stringWithFormat:@"failed to process files: %@", 
         currentFileList];
      [self addMessageFromThread:message
                            path:currentFolder
                     messageType:kCSMessageTypeError];
    }
  }
  return YES;
}

- (NSString *)tempDirName {
  // go w/ temp dir if anything goes wrong
  NSString *result = NSTemporaryDirectory();
  // throw a guid on it so if we're scanning >1 place at a time, each gets
  // it's own sandbox.
  CFUUIDRef uuidRef = CFUUIDCreate(NULL);
  if (uuidRef) {
    CFStringRef uuidStr = CFUUIDCreateString(NULL, uuidRef);
    if (uuidStr) {
      result = [result stringByAppendingPathComponent:(NSString*)uuidStr];
      CFRelease(uuidStr);
    } else {
      NSLog(@"failed to convert our CFUUIDRef into a CFString");
    }
    CFRelease(uuidRef);
  } else {
    NSLog(@"failed to generate a CFUUIDRef");
  }
  return result;
}

- (BOOL)processCoverageForFiles:(NSArray *)filenames
                       inFolder:(NSString *)folderPath {
  
  if (([filenames count] == 0) || ([folderPath length] == 0)) {
    return NO;
  }
  
  NSString *tempDir = [self tempDirName];
  NSEnumerator *fileNamesEnum = [filenames objectEnumerator];
  NSString *filename;
  // make sure all the filenames are just leaves
  while ((filename = [fileNamesEnum nextObject])) {
    NSRange range = [filename rangeOfString:@"/"];
    if (range.location != NSNotFound) {
      [self addMessageFromThread:@"skipped because filename had a slash"
                            path:[folderPath stringByAppendingPathComponent:filename]
                     messageType:kCSMessageTypeError];
      return NO;
    }
  }
  
  // make sure it ends in a slash
  if (![folderPath hasSuffix:@"/"]) {
    folderPath = [folderPath stringByAppendingString:@"/"];
  }
  
  // we write all the full file paths into a file w/ null chars after each
  // so we can feed it into xargs -0
  NSMutableData *fileList = [NSMutableData data];
  NSData *folderPathUTF8 = [folderPath dataUsingEncoding:NSUTF8StringEncoding];
  if (!folderPathUTF8 || !fileList) return NO;
  char nullByte = 0;
  fileNamesEnum = [filenames objectEnumerator];
  while ((filename = [fileNamesEnum nextObject])) {
    NSData *filenameUTF8 = [filename dataUsingEncoding:NSUTF8StringEncoding];
    if (!filenameUTF8) return NO;
    [fileList appendData:folderPathUTF8];
    [fileList appendData:filenameUTF8];
    [fileList appendBytes:&nullByte length:1];
  }
  
  BOOL result = NO;
  GTMScriptRunner *runner = [GTMScriptRunner runnerWithBash];
  if (!runner) return NO;
  
  // make a scratch directory
  NSFileManager *fm = [NSFileManager defaultManager];
  if ([fm gtm_createFullPathToDirectory:tempDir attributes:nil]) {
    
    // now write out our file
    NSString *fileListPath = [tempDir stringByAppendingPathComponent:@"filelists.txt"];
    if (fileListPath && [fileList writeToFile:fileListPath atomically:YES]) {
      // run gcov (it writes to current directory, so we cd into our dir first)
      // we use xargs to batch up the files into as few of runs of gcov as
      // possible.  (we could use -P [num_cpus] to do things in parallell)
      NSString *script =
      [NSString stringWithFormat:@"cd \"%@\" && /usr/bin/xargs -0 /usr/bin/gcov -l -o \"%@\" < \"%@\"",
       tempDir, folderPath, fileListPath];
      
      NSString *stdErr = nil;
      NSString *stdOut = [runner run:script standardError:&stdErr];
      if (([stdOut length] == 0) || ([stdErr length] > 0)) {
        // we don't actually care about stdout since it's just the files
        // that did work.
        NSEnumerator *enumerator = [[stdErr componentsSeparatedByString:@"\n"] objectEnumerator];
        NSString *message;
        while ((message = [enumerator nextObject])) {
          NSRange range = [message rangeOfString:@":"];
          NSString *path = nil;
          if (range.length != 0) {
            path = [message substringToIndex:range.location];
            message = [message substringFromIndex:NSMaxRange(range)];
          }
          [self addMessageFromThread:message
                                path:path
                         messageType:kCSMessageTypeError];
        }
      } 
      
      // since we batch process, we might have gotten some data even w/ an error
      // so we check anyways for data
      
      // collect the gcov files
      NSArray *resultPaths = [fm gtm_filePathsWithExtension:@"gcov"
                                                inDirectory:tempDir];
      NSEnumerator *resultPathsEnum = [resultPaths objectEnumerator];
      NSString *fullPath;
      while ((fullPath = [resultPathsEnum nextObject])) {
        // load it and add it to out set
        CoverStoryCoverageFileData *fileData =
          [CoverStoryCoverageFileData coverageFileDataFromPath:fullPath
                                               messageReceiver:self];
        if (fileData) {
          [self performSelectorOnMainThread:@selector(addFileData:)
                                 withObject:fileData
                              waitUntilDone:NO];
          result = YES;
        }
      }
    } else {
      
      [self addMessageFromThread:@"failed to write out the file lists"
                            path:fileListPath
                     messageType:kCSMessageTypeError];
    }
    
    // nuke our temp dir tree
    if (![fm removeFileAtPath:tempDir handler:nil]) {
      [self addMessageFromThread:@"failed to remove our tempdir"
                            path:tempDir
                     messageType:kCSMessageTypeError];
    }
  }
  
  return result;
}

- (void)observeValueForKeyPath:(NSString *)keyPath 
                      ofObject:(id)object 
                        change:(NSDictionary *)change 
                       context:(void *)context {
  if ([object isEqualTo:sourceFilesController_] &&
      [keyPath isEqualToString:@"selectedObjects"]) {
    NSArray *selectedObjects = [object selectedObjects];
    CoverStoryCoverageFileData *data = nil;
    if ([selectedObjects count]) {
      data = (CoverStoryCoverageFileData*)[selectedObjects objectAtIndex:0];
    }
    // Update our scroll bar
    [codeTableView_ setCoverageData:[data lines]];
    
    // Jump to first missing code block
    [self tableView:codeTableView_ handleSelectionKey:NSDownArrowFunctionKey];
  } else if ([object isEqualTo:[NSUserDefaultsController sharedUserDefaultsController]]) {
    if ([keyPath isEqualToString:[self valuesKey:kCoverStoryHideSystemSourcesKey]] ||
        [keyPath isEqualToString:[self valuesKey:kCoverStoryHideUnittestSourcesKey]]) {
      [sourceFilesController_ rearrangeObjects];
    } else if ([keyPath isEqualToString:[self valuesKey:kCoverStorySystemSourcesPatternsKey]]) {
      NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
      if ([defaults boolForKey:kCoverStoryHideSystemSourcesKey]) {
        // if we're hiding them then update because the pattern changed
        [sourceFilesController_ rearrangeObjects];
      }
    } else if ([keyPath isEqualToString:[self valuesKey:kCoverStoryUnittestSourcesPatternsKey]]) {
      NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
      if ([defaults boolForKey:kCoverStoryHideUnittestSourcesKey]) {
        // if we're hiding them then update because the pattern changed
        [sourceFilesController_ rearrangeObjects];
      }
    } else if ([keyPath isEqualToString:[self valuesKey:kCoverStoryShowComplexityKey]]) {
      [self configureCoverageVsComplexityColumns];
      [sourceFilesTableView_ reloadData];
      [codeTableView_ reloadData];
    } else if ([keyPath isEqualToString:[self valuesKey:kCoverStoryRemoveCommonSourcePrefix]]) {
      // we to recalc the common prefix, so trigger a rearrange
      [sourceFilesController_ rearrangeObjects];
    } else {
      NSString *const kColorsToWatch[] = { 
        kCoverStoryMissedLineColorKey,
        kCoverStoryUnexecutableLineColorKey,
        kCoverStoryNonFeasibleLineColorKey,
        kCoverStoryExecutedLineColorKey
      };
      for (size_t i = 0; i < sizeof(kColorsToWatch) / sizeof(NSString*); ++i) {
        if ([keyPath isEqualToString:[self valuesKey:kColorsToWatch[i]]]) {
          [codeTableView_ reloadData];
        }
      }
    }
  }
}

- (NSString *)filterString {
  return filterString_;
}

- (void)setFilterString:(NSString *)string {
  if (filterString_ != string) {
    [filterString_ release];
    filterString_ = [string copy];
    [sourceFilesController_ rearrangeObjects];
  }
}

- (void)setFilterStringType:(CoverStoryFilterStringType)type {
  [[NSUserDefaults standardUserDefaults] setInteger:type 
                                             forKey:kCoverStoryFilterStringTypeKey];
  [sourceFilesController_ rearrangeObjects];
}

- (IBAction)setUseWildcardPattern:(id)sender {
  [self setFilterStringType:kCoverStoryFilterStringTypeWildcardPattern];
}

- (IBAction)setUseRegularExpression:(id)sender {
  [self setFilterStringType:kCoverStoryFilterStringTypeRegularExpression];
}

- (BOOL)validateMenuItem:(NSMenuItem *)menuItem {
  typedef struct {
    CoverStoryFilterStringType type;
    SEL selector;
  } FilterSelectorMap;
  FilterSelectorMap map[] = {
    { kCoverStoryFilterStringTypeWildcardPattern, @selector(setUseWildcardPattern:) },
    { kCoverStoryFilterStringTypeRegularExpression, @selector(setUseRegularExpression:) },
  };
  
  CoverStoryFilterStringType type;
  type = [[NSUserDefaults standardUserDefaults] integerForKey:kCoverStoryFilterStringTypeKey];
  BOOL isGood = NO;
  SEL action = [menuItem action];
  for (size_t i = 0; i <= sizeof(map) / sizeof(FilterSelectorMap); ++i) {
    if (action == map[i].selector) {
      isGood = YES;
      [menuItem setState:map[i].type == type ? NSOnState : NSOffState];
      break;
    }
  }
  if (!isGood) {
    isGood = [super validateMenuItem:menuItem];
  }
  return isGood;
}

// On enter we just want to open the selected lines of source
- (void)tableViewHandleEnter:(NSTableView *)tableView {
  NSAssert(tableView == codeTableView_, @"Unexpected tableView");
  [self openSelectedSource];
}

// On up or down key we want to select the next block of code that has
// zero coverage.
- (void)tableView:(NSTableView *)tableView handleSelectionKey:(unichar)keyCode {
  NSAssert(tableView == codeTableView_, @"Unexpected key");
  NSAssert(keyCode == NSUpArrowFunctionKey || keyCode == NSDownArrowFunctionKey,
           @"Unexpected key");
  
  // If no source, bail
  NSArray *selection = [sourceFilesController_ selectedObjects];
  if (![selection count]) return;
  
  // Start with the current selection
  CoverStoryCoverageFileData *fileData = [selection objectAtIndex:0];
  NSArray *lines = [fileData lines];
  NSIndexSet *currentSel = [tableView selectedRowIndexes];
  
  // Choose direction based on key and set offset and stopping conditions
  // as well as start.
  int offset = -1;
  int stoppingCond = 0;
  NSRange range = NSMakeRange(0, 0);
  
  if (keyCode == NSDownArrowFunctionKey) {
    offset = 1;
    stoppingCond = [lines count] - 1;
  }
  int startLine = 0;
  if ([currentSel count]) {
    int first = [currentSel firstIndex];
    int last = [currentSel lastIndex];
    range = NSMakeRange(first, last - first);
    startLine = offset == 1 ? last : first;
  }
  
  // From start, look for first line in our given direction that has
  // zero hits
  int i;
  for(i = startLine + offset; i != stoppingCond && i >= 0; i += offset) {
    CoverStoryCoverageLineData *lineData = [lines objectAtIndex:i];
    if ([lineData hitCount] == 0) {
      break;
    }
  }
  
  // Check to see if we hit end of page (or beginning depending which way
  // we went
  if (i != stoppingCond) {
    // Now select "forward" everything that is zero
    int j;
    for (j = i; j != stoppingCond; j+= offset) {
      CoverStoryCoverageLineData *lineData = [lines objectAtIndex:j];
      if ([lineData hitCount] != 0) {
        break;
      }
    }
    
    // Now if we started in a block, select "backwards"
    int k;
    stoppingCond = offset == 1 ? 0 : [lines count] - 1;
    offset *= -1;
    for (k = i; k != stoppingCond; k+= offset) {
      CoverStoryCoverageLineData *lineData = [lines objectAtIndex:k];
      if ([lineData hitCount] != 0) {
        k -= offset;
        break;
      }
    }
    
    // Update our selection
    range = k > j ? NSMakeRange(j + 1, k - j) : NSMakeRange(k, j - k);
    
    [tableView selectRowIndexes:[NSIndexSet indexSetWithIndexesInRange:range]
           byExtendingSelection:NO];
  }
  [tableView scrollRowToVisible:NSMaxRange(range)];
  [tableView scrollRowToVisible:range.location];
}


- (void)setSortKeyOfTableView:(NSTableView *)tableView 
                       column:(NSString *)columnName
                           to:(NSString *)sortKeyName {
  NSTableColumn *column = [tableView tableColumnWithIdentifier:columnName];
  NSSortDescriptor *oldDesc = [column sortDescriptorPrototype];
  NSSortDescriptor *descriptor = [[[NSSortDescriptor alloc] initWithKey:sortKeyName 
                                                              ascending:[oldDesc ascending]]  autorelease];
  [column setSortDescriptorPrototype:descriptor];
}

- (void)reloadData:(id)sender {
  if (openingInThread_) {
    // starting a reload keeps pushing to the existing data, so block it until
    // we're done.
    [self addMessageFromThread:@"Still loading data, can't start a reload." 
                   messageType:kCSMessageTypeWarning];
    return;
  }
  [self willChangeValueForKey:@"dataSet_"];
  [dataSet_ release];
  dataSet_ = [[CoverStoryCoverageSet alloc] init];
  [self didChangeValueForKey:@"dataSet_"];

  // clear the message view before we start
  // add the message, color, and scroll
  [messageView_ setString:@""];

  NSError *error = nil;
  if (![self readFromURL:[NSURL fileURLWithPath:[self fileName]]
                  ofType:[self fileType]
                   error:&error]) {
    [self addMessageFromThread:@"couldn't reload file" 
                          path:[self fileName]
                   messageType:kCSMessageTypeError];
  }
}

- (IBAction)toggleMessageDrawer:(id)sender {
  [drawer_ toggle:self];
}

- (void)setCommonPathPrefix:(NSString *)newPrefix {
  [commonPathPrefix_ autorelease];
  // we cheat, and if the pref is set, we just make sure we return no prefix
  if ([[NSUserDefaults standardUserDefaults] boolForKey:kCoverStoryRemoveCommonSourcePrefix]) {
    commonPathPrefix_ = [newPrefix copy];
  } else {
    commonPathPrefix_ = nil;
  }
}

- (NSString *)commonPathPrefix {
  return commonPathPrefix_;
}

- (void)configureCoverageVsComplexityColumns {
  NSString *const hitCountTransformerNames[] = { 
    @"CoverageLineDataToHitCountTransformer",
    @"CoverageLineDataToComplexityTransformer"
  };
  NSString *const coverageTransformerNames[] = {
    @"CoverageFileDataToCoveragePercentageTransformer",
    @"CoverageFileDataToComplexityTransformer"
  };
  
  NSString *const coverageSortKeyNames[] = {
    @"coverage",
    @"maxComplexity"
  };
  
  NSString *const coverageTitles[] = {
    @"%",
    @"Max"
  };
  
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  int displayIndex = [defaults boolForKey:kCoverStoryShowComplexityKey] ? 1 : 0;
  
  [codeTableView_ cs_setValueTransformerOfColumn:@"hitCount"
                                              to:hitCountTransformerNames[displayIndex]];
  [sourceFilesTableView_ cs_setValueTransformerOfColumn:@"coverage"
                                                     to:coverageTransformerNames[displayIndex]];
  [sourceFilesTableView_ cs_setSortKeyOfColumn:@"coverage"
                                            to:coverageSortKeyNames[displayIndex]];
  [sourceFilesTableView_ cs_setHeaderOfColumn:@"coverage"
                                           to:coverageTitles[displayIndex]];
}

// Moves our searchfield to display our spinner and starts it spinning.
// Called as a performSelectorOnMainThread, so must check to make sure
// we haven't been closed.
- (void)displayAndAnimateSpinner:(NSNumber*)start {
  if ([self isClosed]) return;
  if (spinner_) {
    // force any running animation to end
    if (currentAnimation_) {
      [currentAnimation_ stopAnimation];
      [currentAnimation_ release];
      currentAnimation_ = nil;
    }
    BOOL starting = [start boolValue];
    NSString *effect;
    NSRect rect = [searchField_ frame];
    if (starting) {
      rect.origin.x += annimationWidth_;
      rect.size.width -= annimationWidth_;
      effect = NSViewAnimationFadeInEffect;
    } else {
      rect.origin.x -= annimationWidth_;
      rect.size.width += annimationWidth_;
      effect = NSViewAnimationFadeOutEffect;
    }
    NSValue *endFrameRectValue = [NSValue valueWithRect:rect];
    NSDictionary *searchAnimation = [NSDictionary dictionaryWithObjectsAndKeys:
                                     searchField_, NSViewAnimationTargetKey,
                                     endFrameRectValue, NSViewAnimationEndFrameKey,
                                     nil];
    NSDictionary *spinnerAnimation = [NSDictionary dictionaryWithObjectsAndKeys:
                                      spinner_, NSViewAnimationTargetKey,
                                      effect, NSViewAnimationEffectKey,
                                      nil];
    
    NSArray *animations;
    if (starting) {
      animations = [NSArray arrayWithObjects:
                    searchAnimation, 
                    spinnerAnimation, 
                    nil];
    } else {
      animations = [NSArray arrayWithObjects:
                    spinnerAnimation,
                    searchAnimation,
                    nil];
    }               
    currentAnimation_ =
      [[NSViewAnimation alloc] initWithViewAnimations:animations];
    [currentAnimation_ setDelegate:self];
    [currentAnimation_ startAnimation];
    if (starting) {
      [spinner_ startAnimation:self];
    } else {
      
      [spinner_ stopAnimation:self];
    }
  } 
}

- (void)animationDidEnd:(NSAnimation *)animation {
  if (animation == currentAnimation_) {
    // clear out our reference
    [currentAnimation_ release];
    currentAnimation_ = nil;
  }
}

- (void)finishedLoadingFileDatas:(id)ignored {
  if (numFileDatas_ == 0) {
    [self addMessageFromThread:@"No coverage data read."
                   messageType:kCSMessageTypeWarning];
  } else {
    if (numFileDatas_ == 1) {
      [self addMessageFromThread:@"Loaded one file of coverage data."
                     messageType:kCSMessageTypeInfo];
    } else {
      NSString *message =
        [NSString stringWithFormat:@"Successfully loaded %u coverage fragments.",
         numFileDatas_];
      [self addMessageFromThread:message
                     messageType:kCSMessageTypeInfo];
    }
    NSInteger totalLines = 0;
    NSInteger codeLines = 0;
    NSInteger hitLines = 0;
    NSInteger nonfeasible = 0;
    NSString *coverage = nil;
    [dataSet_ coverageTotalLines:&totalLines
                       codeLines:&codeLines
                    hitCodeLines:&hitLines
                nonFeasibleLines:&nonfeasible
                  coverageString:&coverage
                        coverage:NULL];
    NSString *summary = nil;
    if (nonfeasible > 0) {
      summary = [NSString stringWithFormat:
                 @"Full dataset executed %@%% of %d lines (%d executed, "
                 @"%d executable, %d non-feasible, %d total lines).",
                 coverage, codeLines, hitLines, codeLines, nonfeasible,
                 totalLines];
    } else {
      summary = [NSString stringWithFormat:
                 @"Full dataset executed %@%% of %d lines (%d executed, "
                 @"%d executable, %d total lines).",
                 coverage, codeLines, hitLines, codeLines, totalLines];
    }
    [self addMessageFromThread:summary
                   messageType:kCSMessageTypeInfo];
    [self addMessageFromThread:@"There is a tooltip on the total above the file"
                               @" list that shows numbers for the currently"
                               @" displayed set."
                   messageType:kCSMessageTypeInfo];
  }
}

- (void)setOpenThreadState:(BOOL)threadRunning {
  openingInThread_ = threadRunning;
  [self performSelectorOnMainThread:@selector(displayAndAnimateSpinner:) 
                         withObject:[NSNumber numberWithBool:openingInThread_]
                      waitUntilDone:NO];
}

- (void)addMessageFromThread:(NSString *)message
                 messageType:(CSMessageType)msgType {
  NSDictionary *messageInfo =
    [NSDictionary dictionaryWithObjectsAndKeys:
     message, @"message",
     [NSNumber numberWithInt:msgType], @"msgType",
     nil];
  [self performSelectorOnMainThread:@selector(addMessage:)
                         withObject:messageInfo
                      waitUntilDone:NO];
}

- (void)addMessageFromThread:(NSString *)message
                        path:(NSString*)path
                 messageType:(CSMessageType)msgType {
  NSString *pathMessage = [NSString stringWithFormat:@"%@:%@", path, message];
  [self addMessageFromThread:pathMessage messageType:msgType];
}

- (void)coverageErrorForPath:(NSString*)path message:(NSString *)format, ... {
  // we use the data objects on other threads, so bounce to the main thread

  va_list list;
  va_start(list, format);
  NSString *message = [[NSString alloc] initWithFormat:format arguments:list];
  va_end(list);
  [self addMessageFromThread:message path:path messageType:kCSMessageTypeError];
}

- (void)close {
  // No need to synchronize this because it should only ever be called from
  // main thread
  documentClosed_ = YES;
  [super close];
}

- (BOOL)isClosed {
  // No need to synchronize this because it should only ever be called from main
  // thread.
  return documentClosed_;
}

// Called as a performSelectorOnMainThread, so must check to make sure
// we haven't been closed.
- (void)addMessage:(NSDictionary *)msgInfo {
  if ([self isClosed]) return;

  NSString *message = [msgInfo objectForKey:@"message"];
  CSMessageType msgType = [[msgInfo objectForKey:@"msgType"] intValue];
  if (message) {
    // for non-info make sure the drawer is open
    if (msgType != kCSMessageTypeInfo) {
      [drawer_ open];
    }
    
    // make sure it ends in a newline
    if (![message hasSuffix:@"\n"]) {
      message = [message stringByAppendingString:@"\n"];
    }
    
    // add the message, color, and scroll
    size_t length = [[messageView_ string] length];
    NSRange appendRange = NSMakeRange(length, 0);
    NSTextAttachment *icon = nil;
    NSColor *textColor = nil;
    switch (msgType) {
      case kCSMessageTypeError:
        icon = errorIcon_;
        textColor = [NSColor redColor];
        break;
      case kCSMessageTypeWarning:
        icon = warningIcon_;
        textColor = [NSColor orangeColor];
        break;
      case kCSMessageTypeInfo:
        icon = infoIcon_;
        textColor = [NSColor blackColor];
        break;
    }
    NSMutableAttributedString *attrIconAndMessage
      = [[[NSAttributedString attributedStringWithAttachment:icon] mutableCopy] autorelease];
    NSAttributedString *attrMessage = [[[NSAttributedString alloc] initWithString:message] autorelease];
    [attrIconAndMessage appendAttributedString:attrMessage];
    
    NSMutableParagraphStyle *paraStyle = [[[NSParagraphStyle defaultParagraphStyle] mutableCopy] autorelease];
    [paraStyle setFirstLineHeadIndent:0];
    [paraStyle setHeadIndent:12];
    NSDictionary *attrs = [NSDictionary dictionaryWithObjectsAndKeys:
                           textColor, NSForegroundColorAttributeName,
                           paraStyle, NSParagraphStyleAttributeName,
                           nil];
    
    [attrIconAndMessage addAttributes:attrs range:NSMakeRange(0, [attrMessage length])];
    NSTextStorage *storage = [messageView_ textStorage];
    [storage replaceCharactersInRange:appendRange withAttributedString:attrIconAndMessage];
    if (msgType != kCSMessageTypeInfo) {  // only scroll to the warnings/errors
      NSRange visibleRange = NSMakeRange(appendRange.location, [attrIconAndMessage length]);
      [messageView_ scrollRangeToVisible:visibleRange];
    }
    [messageView_ display];
  }
}

@end

@implementation NSTableView (CoverStoryTableView)
- (void)cs_setValueTransformerOfColumn:(NSString *)columnName
                                    to:(NSString *)transformerName {
  NSTableColumn *column = [self tableColumnWithIdentifier:columnName];
  NSAssert1(column, @"No %@ column?", columnName);
  NSDictionary *bindingInfo = [column infoForBinding:NSValueBinding];
  NSAssert1(bindingInfo, @"No binding Info for column %@", columnName);
  [column unbind:NSValueBinding];
  NSMutableDictionary *bindingOptions = [[[bindingInfo objectForKey:NSOptionsKey] mutableCopy] autorelease];
  [bindingOptions setObject:transformerName 
                     forKey:NSValueTransformerNameBindingOption];
  [bindingOptions setObject:[NSValueTransformer valueTransformerForName:transformerName]
                     forKey:NSValueTransformerBindingOption];
  [column bind:NSValueBinding 
      toObject:[bindingInfo objectForKey:NSObservedObjectKey]
   withKeyPath:[bindingInfo objectForKey:NSObservedKeyPathKey] 
       options:bindingOptions];
}

- (void)cs_setSortKeyOfColumn:(NSString *)columnName
                           to:(NSString *)sortKeyName {
  NSTableColumn *column = [self tableColumnWithIdentifier:columnName];
  NSAssert1(column, @"No %@ column?", columnName);
  NSSortDescriptor *oldDesc = [column sortDescriptorPrototype];
  BOOL ascending = oldDesc ? [oldDesc ascending] : YES;
  NSSortDescriptor *descriptor = [[[NSSortDescriptor alloc] initWithKey:sortKeyName 
                                                              ascending:ascending]  autorelease];
  [column setSortDescriptorPrototype:descriptor];
}

- (void)cs_setHeaderOfColumn:(NSString*)columnName
                          to:(NSString*)name {
  NSTableColumn *column = [self tableColumnWithIdentifier:columnName];
  NSAssert1(column, @"No %@ column?", columnName);
  [[column headerCell] setTitle:name];
}
@end

@implementation CoverStoryArrayController
- (void)updateCommonPathPrefix {
  if (!owningDocument_) return;
  
  NSString *newPrefix = nil;
  
  // now figure out a new prefix
  NSArray *arranged = [self arrangedObjects];
  if ([arranged count] == 0) {
    // empty string
    newPrefix = @"";
  } else {
    // process the list to find the common prefix
    
    // start w/ the first path, and now loop throught them all, but give up
    // the moment he only common prefix is "/"
    NSArray *sourcePathes = [arranged valueForKey:@"sourcePath"];
    NSEnumerator *enumerator = [sourcePathes objectEnumerator];
    newPrefix = [enumerator nextObject];
    NSString *basePath;
    while (([newPrefix length] > 1) &&
           (basePath = [enumerator nextObject])) {
      newPrefix = [newPrefix commonPrefixWithString:basePath
                                            options:NSLiteralSearch];
    }
    // if you have two files of:
    //   /Foo/bar/spam.m
    //   /Foo/baz/wee.m
    // we end up here w/ "/Foo/ba" as the common prefix, but we don't want
    // to do that, so we make sure we end in a slash
    if (![newPrefix hasSuffix:@"/"]) {
      NSRange lastSlash = [newPrefix rangeOfString:@"/"
                                           options:NSBackwardsSearch];
      if (lastSlash.location == NSNotFound) {
        newPrefix = @"";
      } else {
        newPrefix = [newPrefix substringToIndex:NSMaxRange(lastSlash)];
      }
    }
    // if we just have the leading "/", use no prefix
    if ([newPrefix length] <= 1) {
      newPrefix = @"";
    }
  }
  // send it back to the document
  [owningDocument_ setCommonPathPrefix:newPrefix];
}

- (void)rearrangeObjects {
  // this fires when the filtering changes
  [super rearrangeObjects];
  [self updateCommonPathPrefix];
}
- (void)setContent:(id)content {
  // this fires as results are added during a load
  [super setContent:content];
  [self updateCommonPathPrefix];
}
@end
