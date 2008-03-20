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
#import "CoverStoryScroller.h"
#import "CoverStoryDocumentTypes.h"
#import "CoverStoryPreferenceKeys.h"
#import "GTMScriptRunner.h"
#import "GTMNSFileManager+Path.h"
#import "GTMNSEnumerator+Filter.h"

@interface CoverStoryDocument (PrivateMethods)
- (void)openFolderInThread:(NSString*)path;
- (void)openFileInThread:(NSString*)path;
- (BOOL)processCoverageForFolder:(NSString *)path;
- (BOOL)processCoverageForFiles:(NSArray *)filenames
                       inFolder:(NSString *)folderPath;
- (void)updateScrollBar:(CoverStoryCoverageFileData*)data;
- (BOOL)addFileData:(CoverStoryCoverageFileData *)fileData;
@end

static NSString *const kPrefsToWatch[] = { 
  kCoverStoryHideSystemSourcesKey,
  kCoverStoryMissedLineColorKey,
  kCoverStoryUnexecutableLineColorKey,
  kCoverStoryNonFeasibleLineColorKey,
  kCoverStoryExecutedLineColorKey
};

@implementation CoverStoryDocument
- (NSString*)valuesKey:(NSString*)key {
  return [NSString stringWithFormat:@"values.%@", key];
}

- (id)init {
  self = [super init];
  if (self) {
    dataSet_ = [[CoverStoryCoverageSet alloc] init];
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
  [super dealloc];
}


- (void)awakeFromNib {
  // We want no cell spacing to make it look normal
  [codeTableView_ setIntercellSpacing:NSMakeSize(0.0f, 0.0f)];
  
  // Create up our scroller, it will be owned by the tableview.
  CoverStoryScroller *scroller = [[[CoverStoryScroller alloc] init] autorelease];
  NSScrollView *scrollView = [codeTableView_ enclosingScrollView];
  [scrollView setVerticalScroller:scroller]; 
  
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
  
  if (openingInThread_) {
    [spinner_ startAnimation:self];
  }
}

- (NSString *)windowNibName {
  return @"CoverStoryDocument";
}
  
- (BOOL)addFileData:(CoverStoryCoverageFileData *)fileData {
  [self willChangeValueForKey:@"dataSet_"];
  BOOL isGood = [dataSet_ addFileData:fileData];
  [self didChangeValueForKey:@"dataSet_"];
  return isGood;
}

- (BOOL)readFromFileWrapper:(NSFileWrapper *)fileWrapper
                     ofType:(NSString *)typeName
                      error:(NSError **)outError {
  
  BOOL isGood = NO;
  
  // the wrapper doesn't have the full path, but it's already set on us, so
  // use that instead.
  NSString *path = [self fileName];
  if ([fileWrapper isDirectory]) {
    [NSThread detachNewThreadSelector:@selector(openFolderInThread:)
                             toTarget:self
                           withObject:path];
    isGood = YES;
  } else if ([typeName isEqualToString:@kGCOVTypeName]) {
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (data) {
      // load it and add it to out set
      CoverStoryCoverageFileData *fileData =
      [CoverStoryCoverageFileData coverageFileDataFromData:data];
      if (fileData) {
        isGood = [self addFileData:fileData];
      }
    }
  } else {
    // the wrapper doesn't have the full path, but it's already set on us, so use
    // that instead.
    [NSThread detachNewThreadSelector:@selector(openFileInThread:)
                             toTarget:self
                           withObject:path];
    isGood = YES;
  }
  
  return isGood;
}

- (void)openSource:(NSString*)path {
  [[NSWorkspace sharedWorkspace] openFile:path];
}

- (BOOL)isDocumentEdited {
  return NO;
}

- (void)openFolderInThread:(NSString*)path {
  NSAutoreleasePool *pool = [NSAutoreleasePool new];
  openingInThread_ = YES;

  [self processCoverageForFolder:path];
  openingInThread_ = NO;
  [spinner_ performSelectorOnMainThread:@selector(stopAnimation:)
                             withObject:self waitUntilDone:NO];
  // Clean up NSTask Zombies.
  [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1]];
  [pool release];
}

- (void)openFileInThread:(NSString*)path {
  NSAutoreleasePool *pool = [NSAutoreleasePool new];
  openingInThread_ = YES;
  NSString *folderPath = [path stringByDeletingLastPathComponent];
  NSString *filename = [path lastPathComponent];
  [self processCoverageForFiles:[NSArray arrayWithObject:filename]
                       inFolder:folderPath];
  
  openingInThread_ = NO;
  [spinner_ performSelectorOnMainThread:@selector(stopAnimation:)
                             withObject:self waitUntilDone:NO];
  
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
  
  // we want to back process them by chunks w/in a given directory.  so sort
  // and then break them off into chunks.
  allFilePaths = [allFilePaths sortedArrayUsingSelector:@selector(compare:)];
  if ([allFilePaths count] > 0) {
    
    // see our collecting w/ the first item
    NSString *filename = [allFilePaths objectAtIndex:0];
    NSString *currentFolder = [filename stringByDeletingLastPathComponent];
    NSMutableArray *currentFileList =
    [NSMutableArray arrayWithObject:[filename lastPathComponent]];
    
    // now spin the loop
    for (int x = 1 ; x < [allFilePaths count] ; ++x) {
      NSString *filename = [allFilePaths objectAtIndex:x];
      // see if it has the same parent folder
      if ([[filename stringByDeletingLastPathComponent] isEqualTo:currentFolder]) {
        // add it
        NSAssert([currentFileList count] > 0, @"file list should NOT be empty");
        [currentFileList addObject:[filename lastPathComponent]];
      } else {
        // process what's in the list
        if (![self processCoverageForFiles:currentFileList
                                  inFolder:currentFolder]) {
          // TODO: better error handling
          NSLog(@"from folder '%@' failed to process files: %@",
                currentFolder, currentFileList);
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
      // TODO: better error handling
      NSLog(@"from folder '%@' failed to process files: %@",
            currentFolder, currentFileList);
    }
  }
  return YES;
}

- (BOOL)processCoverageForFiles:(NSArray *)filenames
                       inFolder:(NSString *)folderPath {
  
  if (([filenames count] == 0) || ([folderPath length] == 0)) {
    return NO;
  }
  
  NSString *tempDir = NSTemporaryDirectory();
  tempDir = [tempDir stringByAppendingPathComponent:[folderPath lastPathComponent]];
  
  // make sure all the filenames are just leaves
  for (int x = 0 ; x < [filenames count] ; ++x) {
    NSString *filename = [filenames objectAtIndex:x];
    NSRange range = [filename rangeOfString:@"/"];
    if (range.location != NSNotFound) {
      // TODO - report this out better
      NSLog(@"filename '%@' had a slash", filename);
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
  for (int x = 0 ; x < [filenames count] ; ++x) {
    NSString *filename = [filenames objectAtIndex:x];
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
        // TODO - provide a real way to get this to the users
        NSLog(@"gcov failed from folder '%@' failed to process files: %@",
              folderPath, filenames);
        NSLog(@">>> stdout: %@", stdOut);
        NSLog(@">>> stderr: %@", stdErr);
      } 
      
      // swince we batch process, we might have gotten some data even w/ an error
      // so we check anyways for data
      
      // collect the gcov files
      NSArray *resultPaths = [fm gtm_filePathsWithExtension:@"gcov"
                                                inDirectory:tempDir];
      for (int x = 0 ; x < [resultPaths count] ; ++x) {
        NSString *fullPath = [resultPaths objectAtIndex:x];
        NSData *data = [NSData dataWithContentsOfFile:fullPath];
        if (data) {
          // load it and add it to out set
          CoverStoryCoverageFileData *fileData =
          [CoverStoryCoverageFileData coverageFileDataFromData:data];
          if (fileData) {
            [self performSelectorOnMainThread:@selector(addFileData:)
                                   withObject:fileData
                                waitUntilDone:NO];
            result = YES;
          } else {
            NSLog(@"failed to pull data from gcov file (%@), usually means source isn't a currently handled encoding",
                  [fullPath lastPathComponent]);
          }
        } else {
          // TODO: report this out
          NSLog(@"failed to load data from gcov file: %@", fullPath);
        }
      }
    } else {
      // TODO: report this out
      NSLog(@"failed to write out the file lists (%@)", fileListPath);
    }
    
    // nuke our temp dir tree
    if (![fm removeFileAtPath:tempDir handler:nil]) {
      // TODO - provide a real way to get this to the users
      NSLog(@"failed to remove our tempdir (%@)", tempDir);
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
    [self updateScrollBar:data];
  } else if ([object isEqualTo:[NSUserDefaultsController sharedUserDefaultsController]]) {
    if ([keyPath isEqualToString:[self valuesKey:kCoverStoryHideSystemSourcesKey]]) {
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

- (void)updateScrollBar:(CoverStoryCoverageFileData*)data {
  NSScrollView *scrollView = [codeTableView_ enclosingScrollView];
  CoverStoryScroller *scroller = (CoverStoryScroller*)[scrollView verticalScroller]; 
  if (!data) {
    [scroller setEnabled:NO];
    [scroller setCoverageData:nil];
  } else {
    NSArray *lines = [data lines];
    int firstMissedLine = -1;
    int count = 0;
    NSEnumerator *dataEnum = [lines objectEnumerator];
    CoverStoryCoverageLineData* dataPoint;
    while ((dataPoint = [dataEnum nextObject]) && (firstMissedLine == -1)) {
      int hitCount = [dataPoint hitCount];
      if (hitCount == 0) {
        firstMissedLine = count;
      }
      ++count;
    }
    SInt32 totalLines = [data numberTotalLines];
    
    [scroller setCoverageData:[data lines]];
    [scroller setEnabled:YES];
    // Scroll to the first missed line if we have one.
    if (firstMissedLine != -1) {
      float value = (float)firstMissedLine / (float)totalLines;
      float middleOffset = (NSHeight([scrollView documentVisibleRect]) * 0.5);
      float contentHeight = NSHeight([[scrollView documentView] bounds]);
      value = value * contentHeight - middleOffset;
      [[scrollView documentView] scrollPoint:NSMakePoint(0, value)];
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


@end
