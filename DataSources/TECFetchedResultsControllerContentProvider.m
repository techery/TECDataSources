//
//  TECFetchedResultsControllerContentProvider.m
//  DataSources
//
//  Created by Petro Korienev on 2/13/16.
//  Copyright © 2016 Alexey Fayzullov. All rights reserved.
//

#import "TECFetchedResultsControllerContentProvider.h"
#import "TECCoreDataSectionModel.h"
#import "TECContentProviderDelegate.h"
#import <libkern/OSAtomic.h>


typedef NS_ENUM(NSUInteger, TECChangesetKind) {
    TECChangesetKindSection = 1,
    TECChangesetKindRow,
};

NSString * const kTECChangesetKindKey = @"kind";
NSString * const kTECChangesetSectionKey = @"section";
NSString * const kTECChangesetIndexKey = @"index";
NSString * const kTECChangesetObjectKey = @"object";
NSString * const kTECChangesetIndexPathKey = @"indexPath";
NSString * const kTECChangesetChangeTypeKey = @"type";
NSString * const kTECChangesetNewIndexPathKey = @"newIndexPath";

@interface TECFetchedResultsControllerContentProvider () <NSFetchedResultsControllerDelegate>

@property (nonatomic, strong) id <TECFetchedResultsControllerContentProviderGetter> itemsGetter;
@property (nonatomic, strong) id <TECFetchedResultsControllerContentProviderMutator> itemsMutator;
@property (nonatomic, strong) NSFetchedResultsController *fetchedResultsController;
@property (nonatomic, strong) NSArray<TECCoreDataSectionModel *> *sectionModelArray;
@property (nonatomic, strong) NSMutableArray<NSMutableDictionary *> *changeSetArray;

@end

@implementation TECFetchedResultsControllerContentProvider

- (instancetype)initWithItemsGetter:(id<TECFetchedResultsControllerContentProviderGetter>)getter
                       itemsMutator:(id<TECFetchedResultsControllerContentProviderMutator>)mutator
                       fetchRequest:(NSFetchRequest *)fetchRequest
                 sectionNameKeyPath:(NSString *)sectionNameKeyPath {
    self = [self init];
    if (self) {
        self.itemsGetter = getter;
        self.itemsMutator = mutator;
        self.fetchedResultsController = [self.itemsGetter fetchedResultsControllerForFetchRequest:fetchRequest sectionNameKeyPath:sectionNameKeyPath];
        self.fetchedResultsController.delegate = self;
        [self.fetchedResultsController performFetch:nil];
        [self snapshotSectionModelArray];
        [self resetChangeSetArray];
    }
    return self;
}

- (void)snapshotSectionModelArray {
    NSMutableArray *array = [NSMutableArray arrayWithCapacity:self.fetchedResultsController.sections.count];
    for(id<NSFetchedResultsSectionInfo> sectionInfo in self.fetchedResultsController.sections) {
        [array addObject:[[TECCoreDataSectionModel alloc] initWithFetchedResultsSectionInfo:sectionInfo]];
    }
    self.sectionModelArray = [NSArray arrayWithArray:array];
}

- (void)resetChangeSetArray {
    self.changeSetArray = [NSMutableArray new];
}

- (void)flushChangeSetArrayToAdapter {
    BOOL adapterListensToSectionUpdates = [self.presentationAdapter respondsToSelector:@selector(contentProviderDidChangeSection:atIndex:forChangeType:)];
    BOOL adapterListensToRowUpdates = [self.presentationAdapter respondsToSelector:@selector(contentProviderDidChangeItem:atIndexPath:forChangeType:newIndexPath:)];
    for (NSDictionary *changeset in self.changeSetArray) {
        if (adapterListensToSectionUpdates && [changeset[kTECChangesetKindKey] unsignedIntegerValue] == TECChangesetKindSection) {
            [self.presentationAdapter contentProviderDidChangeSection:[[TECCoreDataSectionModel alloc] initWithFetchedResultsSectionInfo:changeset[kTECChangesetSectionKey]]
                                                              atIndex:[changeset[kTECChangesetIndexKey] unsignedIntegerValue]
                                                        forChangeType:[changeset[kTECChangesetChangeTypeKey] unsignedIntegerValue]];
        }
        if (adapterListensToRowUpdates && [changeset[kTECChangesetKindKey] unsignedIntegerValue] == TECChangesetKindRow) {
            [self.presentationAdapter contentProviderDidChangeItem:changeset[kTECChangesetObjectKey]
                                                       atIndexPath:changeset[kTECChangesetIndexPathKey]
                                                     forChangeType:[changeset[kTECChangesetChangeTypeKey] unsignedIntegerValue]
                                                      newIndexPath:changeset[kTECChangesetNewIndexPathKey]];
        }
    }
    [self resetChangeSetArray];
}

- (void)workChangeSetArrayAround {
    // 1.
    // UITableView raises an exception if a row is both updated and moved.
    // So we should be able to handle change sequences like: (
    //     ...
    //     "upd row {4, 0}",
    //     "mov row {4, 0} -> {1, 0}",
    //     ...
    // )
    [self workUpdateThenMoveAround];
    // 2.
    // UITableView can't handle the cases when a section is deleted right afterwards it was inserted and raises an exception.
    // So we should be able to handle cases like: (
    //     "ins sect 1",
    //     "ins sect 2",
    //     "del sect 1",
    //     "del sect 2",
    //     "upd row {1, 0}",
    //     "mov row {1, 0} -> {1, 0}",
    //     "upd row {2, 0}",
    //     "mov row {2, 0} -> {2, 0}",
    // )
    // NSFetchResultsController produces such changes when section name changes but it's relative index stays the same, e.g.:
    // you have grouping by the first letter, and you have two rows: "DI" and "MK", and you rename them to "I" and "K" respectively
    [self workConsecutiveSectionInsertDeleteAround];
    // 3.
    // Note: sometimes section changes occur after row changes, e.g.: (
    //     "del row {0, 0}",
    //     "del sect 0",
    // )
    [self workSectionBeforeRowChangeSetsAround];
    // 4.
    // When reordering by some integer ordinal key CoreData fires series of chain moves
    // Consider following content:
    // [{"name":"Alexey Fayzullov", "ordinal":0},{"name":"Anastasiya Gorban", "ordinal":1,},{"name":"Petro Korienev", "ordinal":2}]
    // Imagine we'are moving row "Alexey Fayzullov" below row "Petro Korienev". The following ordinal changes happen:
    // "Anastasiya Gorban" -> 0, "Petro Korienev" -> 1, "Alexey Fayzullov" -> 2
    // NSFetchedResultsController fires 3 consecutive moves:
    //     "mov row {0, 0} -> {0, 2}",
    //     "mov row {0, 2} -> {0, 1}",
    //     "mov row {0, 1} -> {0, 0}",
    // Instead of 1 move
    //     "mov row {0, 0} -> {0, 2}",
    // Or delete/insert
    //     "del row {0, 0}",
    //     "ins row {0, 2}",
    [self workManualMovesAround];
}

- (void)workUpdateThenMoveAround {
    NSMutableArray *moves = [NSMutableArray new];
    for (NSMutableDictionary *changeset in self.changeSetArray) {
        if ([changeset[kTECChangesetKindKey] unsignedIntegerValue] == TECChangesetKindRow) {
            if ([changeset[kTECChangesetChangeTypeKey] unsignedIntegerValue] == NSFetchedResultsChangeMove) {
                [moves addObject:changeset[kTECChangesetIndexPathKey]];
            }
        }
    };
    NSPredicate *filterOddUpdatesPredicate =
    [NSPredicate predicateWithFormat:@"NOT ((%K = %@) AND (%K IN %@))", kTECChangesetChangeTypeKey, @(TECContentProviderItemChangeTypeUpdate), kTECChangesetIndexPathKey, moves];
    [self.changeSetArray filterUsingPredicate:filterOddUpdatesPredicate];
}

- (void)workConsecutiveSectionInsertDeleteAround {
    
}

- (void)workSectionBeforeRowChangeSetsAround {
    [self.changeSetArray sortUsingDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:kTECChangesetKindKey ascending:YES]]];
}

- (void)workManualMovesAround {
    
}

- (void)setCurrentRequest:(NSFetchRequest *)currentRequest {
    self.fetchedResultsController.delegate = nil;
    self.fetchedResultsController.fetchRequest.predicate = currentRequest.predicate;
    self.fetchedResultsController.fetchRequest.sortDescriptors = currentRequest.sortDescriptors;
    self.fetchedResultsController.fetchRequest.propertiesToFetch = currentRequest.propertiesToFetch;
    self.fetchedResultsController.fetchRequest.propertiesToGroupBy = currentRequest.propertiesToGroupBy;
    self.fetchedResultsController.fetchRequest.fetchBatchSize = currentRequest.fetchBatchSize;
    self.fetchedResultsController.fetchRequest.fetchLimit = currentRequest.fetchLimit;
    self.fetchedResultsController.fetchRequest.fetchOffset = currentRequest.fetchOffset;
    [self.fetchedResultsController performFetch:nil];
    self.fetchedResultsController.delegate = self;
    if ([self.presentationAdapter respondsToSelector:@selector(contentProviderDidReloadData:)]) {
        [self.presentationAdapter contentProviderDidReloadData:self];
    }
}

- (NSFetchRequest *)getCopyOfCurrentRequest {
    return [self.fetchedResultsController.fetchRequest copy];
}

#pragma mark - NSFastEnumeration implementation

- (NSUInteger)countByEnumeratingWithState:(NSFastEnumerationState *)state objects:(__unsafe_unretained id  _Nonnull *)buffer count:(NSUInteger)len {
    return [self.sectionModelArray countByEnumeratingWithState:state objects:buffer count:len];
}

- (NSUInteger)count {
    return self.sectionModelArray.count;
}

- (NSEnumerator *)sectionEnumerator {
    return [self.sectionModelArray objectEnumerator];
}

- (NSEnumerator *)reverseSectionEnumerator {
    return [self.sectionModelArray reverseObjectEnumerator];
}

- (NSInteger)numberOfSections {
    return [self.fetchedResultsController.sections count];
}

- (NSInteger)numberOfItemsInSection:(NSInteger)section {
    return [self.fetchedResultsController.sections[section] numberOfObjects];
}

- (void)deleteSectionAtIndex:(NSUInteger)index {
    [self.itemsMutator deleteObjects:self.fetchedResultsController.sections[index].objects
               withEntityDescription:self.fetchedResultsController.fetchRequest.entity];
}

- (void)insertSection:(id<TECSectionModelProtocol>)section atIndex:(NSUInteger)index {
    NSAssert(NO, @"%s CoreData content provider asked for ineligible mutation", __PRETTY_FUNCTION__);
}

- (void)updateItemAtIndexPath:(NSIndexPath *)indexPath {
    [self.fetchedResultsController.managedObjectContext refreshObject:[self.fetchedResultsController objectAtIndexPath:indexPath] mergeChanges:YES];
}

- (void)updateItemAtIndexPath:(NSIndexPath *)indexPath withItem:(id)item {
    NSAssert(NO, @"%s CoreData content provider asked for ineligible mutation", __PRETTY_FUNCTION__);
}

- (void)moveItemAtIndexPath:(NSIndexPath *)indexPath toIndexPath:(NSIndexPath *)newIndexPath {
    NSAssert(self.moveBlock, @"%s CoreData content provider asked for ineligible mutation", __PRETTY_FUNCTION__);
    if (self.moveBlock) {
        self.moveBlock(self.fetchedResultsController, indexPath, newIndexPath);
    }
}

- (void)insertItem:(id)item atIndexPath:(NSIndexPath *)indexPath {
    NSAssert(NO, @"%s CoreData content provider asked for ineligible mutation", __PRETTY_FUNCTION__);
}

- (void)deleteItemAtIndexPath:(NSIndexPath *)indexPath {
    [self.itemsMutator deleteObject:[self.fetchedResultsController objectAtIndexPath:indexPath]];
}

- (id)itemAtIndexPath:(NSIndexPath *)indexPath {
    return [self.fetchedResultsController objectAtIndexPath:indexPath];
}

- (id)objectForKeyedSubscript:(NSIndexPath *)key {
    return [self itemAtIndexPath:key];
}

- (void)setObject:(id)object forKeyedSubscript:(NSIndexPath *)key {
    NSAssert(NO, @"%s CoreData content provider asked for ineligible mutation", __PRETTY_FUNCTION__);
}

- (id)objectAtIndexedSubscript:(NSUInteger)idx {
    return [self sectionAtIndex:idx];
}

- (void)setObject:(id)object atIndexedSubscript:(NSUInteger)idx {
    NSAssert(NO, @"%s CoreData content provider asked for ineligible mutation", __PRETTY_FUNCTION__);
}

- (id<TECSectionModelProtocol>)sectionAtIndex:(NSInteger)idx {
    return [[TECCoreDataSectionModel alloc] initWithFetchedResultsSectionInfo:self.fetchedResultsController.sections[idx]];
}

- (void)reloadDataSourceWithCompletion:(TECContentProviderCompletionBlock)completion {
    self.fetchedResultsController.delegate = nil;
    [self.fetchedResultsController performFetch:nil];
    self.fetchedResultsController.delegate = self;
    if (completion) {
        completion();
    }
    if ([self.presentationAdapter respondsToSelector:@selector(contentProviderDidReloadData:)]) {
        [self.presentationAdapter contentProviderDidReloadData:self];
    }
}

- (void)performBatchUpdatesWithBlock:(TECContentProviderBatchUpdatesBlock)block {
    if (block) {
        block(self);
    }
}

- (void)enumerateObjectsUsingBlock:(void (^)(id, NSUInteger, BOOL *))block {
    [self enumerateObjectsUsingBlock:block options:0];
}

- (void)enumerateObjectsUsingBlock:(void (^)(id, NSUInteger, BOOL *))block options:(NSEnumerationOptions)options {
    __block volatile int32_t idx = 0;
    __block BOOL stop = NO;
    BOOL isEnumerationConcurrent = options & NSEnumerationConcurrent;
    BOOL isEnumerationReverse = options & NSEnumerationReverse;
    NSAssert(!isEnumerationConcurrent, @"%s NSEnumerationConcurrent: doing this with CoreData is the best way to shoot own leg", __PRETTY_FUNCTION__);
    NSEnumerator *enumerator = isEnumerationReverse ? [self reverseSectionEnumerator] : [self sectionEnumerator];
    for (id object in enumerator) {
        void(^innerBlock)() = ^() {
            block(object, idx, &stop);
            OSAtomicIncrement32(&idx);
        };
        if (isEnumerationConcurrent) {
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), innerBlock);
        }
        else {
            innerBlock();
        }
        if (stop) {
            return;
        }
    }
}

#pragma mark - NSFetchedResutsControllerDelegate implementation

- (void)controllerWillChangeContent:(NSFetchedResultsController *)controller {
    if ([self.presentationAdapter respondsToSelector:@selector(contentProviderWillChangeContent:)]) {
        [self.presentationAdapter contentProviderWillChangeContent:self];
    }
}

- (void)controller:(NSFetchedResultsController *)controller
  didChangeSection:(id<NSFetchedResultsSectionInfo>)sectionInfo
           atIndex:(NSUInteger)sectionIndex
     forChangeType:(NSFetchedResultsChangeType)type {
    NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithCapacity:4];
    dict[kTECChangesetKindKey] = @(TECChangesetKindSection);
    dict[kTECChangesetSectionKey] = sectionInfo;
    dict[kTECChangesetChangeTypeKey] = @(type);
    dict[kTECChangesetIndexKey] = @(sectionIndex);
    [self.changeSetArray addObject:dict];
}

- (void)controller:(NSFetchedResultsController *)controller
   didChangeObject:(id)anObject
       atIndexPath:(NSIndexPath *)indexPath
     forChangeType:(NSFetchedResultsChangeType)type
      newIndexPath:(NSIndexPath *)newIndexPath {
    NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithCapacity:5];
    dict[kTECChangesetKindKey] = @(TECChangesetKindRow);
    dict[kTECChangesetObjectKey] = anObject;
    dict[kTECChangesetChangeTypeKey] = @(type);
    if (indexPath) {
        dict[kTECChangesetIndexPathKey] = indexPath;
    }
    if (newIndexPath) {
        dict[kTECChangesetNewIndexPathKey] = newIndexPath;
    }
    [self.changeSetArray addObject:dict];
}

- (void)controllerDidChangeContent:(NSFetchedResultsController *)controller {
    [self snapshotSectionModelArray];
    [self workChangeSetArrayAround];
    [self flushChangeSetArrayToAdapter];
    if ([self.presentationAdapter respondsToSelector:@selector(contentProviderDidChangeContent:)]) {
        [self.presentationAdapter contentProviderDidChangeContent:self];
    }
}

@end
