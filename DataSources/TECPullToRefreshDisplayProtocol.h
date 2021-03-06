//
//  TECPullToRefreshPresentationAdapterProtocol.h
//  DataSources
//
//  Created by Alexey Fayzullov on 3/14/16.
//  Copyright © 2016 Alexey Fayzullov. All rights reserved.
//

#import <UIKit/UIKit.h>

@class TECPullToRefreshState;

@protocol TECPullToRefreshDisplayProtocol <NSObject>

- (void)setupWithContainerView:(UIView *)containerView;
- (void)didChangeState:(TECPullToRefreshState *)state;

@optional
- (void)didChangeScrollProgress:(CGFloat)progress;

@end
