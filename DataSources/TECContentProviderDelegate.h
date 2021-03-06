//
//  TECContentProviderDelegate.h
//  DataSources
//
//  Created by Alexey Fayzullov on 1/28/16.
//  Copyright © 2016 Alexey Fayzullov. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@protocol TECContentProviderProtocol;
@protocol TECSectionModelProtocol;

typedef NS_ENUM(NSUInteger, TECContentProviderSectionChangeType) {
    TECContentProviderSectionChangeTypeInsert = 1, // To map to NSFetchedResultChangeType enum transparently
    TECContentProviderSectionChangeTypeDelete,
    TECContentProviderSectionChangeTypeUpdate
};

typedef NS_ENUM(NSUInteger, TECContentProviderItemChangeType) {
    TECContentProviderItemChangeTypeInsert = 1, // To map to NSFetchedResultChangeType enum transparently
    TECContentProviderItemChangeTypeDelete,
    TECContentProviderItemChangeTypeMove,
    TECContentProviderItemChangeTypeUpdate
};

@protocol TECContentProviderPresentationAdapterProtocol <NSObject>

@property (nonatomic, strong, readonly) UIScrollView *extendedView;

@optional

- (void)contentProviderDidReloadData:(id <TECContentProviderProtocol>)contentProvider;

- (void)contentProviderWillChangeContent:(id<TECContentProviderProtocol>)contentProvider;
- (void)contentProviderDidChangeSection:(id<TECSectionModelProtocol>)section
                                atIndex:(NSUInteger)index
                          forChangeType:(TECContentProviderSectionChangeType)changeType;
- (void)contentProviderDidChangeItem:(id)item
                         atIndexPath:(NSIndexPath *)indexPath
                       forChangeType:(TECContentProviderItemChangeType)changeType
                        newIndexPath:(NSIndexPath *)newIndexPath;
- (void)contentProviderDidChangeContent:(id<TECContentProviderProtocol>)contentProvider;

@end
