//
//  XXScriptListTableViewController.m
//  XXTouchApp
//
//  Created by Zheng on 8/29/16.
//  Copyright © 2016 Zheng. All rights reserved.
//

#import "XXLocalDataService.h"
#import "XXLocalNetService.h"
#import "XXQuickLookService.h"
#import "XXArchiveActivity.h"
#import "XXUnarchiveActivity.h"

#import "XXToolbar.h"
#import "XXSwipeableCell.h"
#import "XXInsetsLabel.h"

#import "XXNavigationViewController.h"
#import "XXScriptListTableViewController.h"
#import "XXCreateItemTableViewController.h"
#import "XXItemAttributesTableViewController.h"
#import "XXAboutTableViewController.h"
#import "XXTImagePickerController.h"

#import <AssetsLibrary/AssetsLibrary.h>

#import "UIViewController+MSLayoutSupport.h"
#import "NSFileManager+RealDestination.h"
#import "NSFileManager+Size.h"

#import "NSArray+FindString.h"

static NSString * const kXXScriptListCellReuseIdentifier = @"kXXScriptListCellReuseIdentifier";
static NSString * const kXXRewindSegueIdentifier = @"kXXRewindSegueIdentifier";

enum {
    kXXBrowserSearchTypeCurrent = 0,
    kXXBrowserSearchTypeRecursive
};

@interface XXScriptListTableViewController ()
<
UITableViewDelegate,
UITableViewDataSource,
UIGestureRecognizerDelegate,
XXToolbarDelegate,
UIDocumentMenuDelegate,
UIDocumentPickerDelegate,
XXTImagePickerControllerDelegate,
UIPopoverControllerDelegate
>

@property (weak, nonatomic) IBOutlet XXToolbar *topToolbar;

@property (nonatomic, assign, readonly) BOOL isRootDirectory;
@property (nonatomic, assign, readonly) BOOL hidesMainPath;
@property (nonatomic, strong) NSMutableArray <NSDictionary *> *rootItemsDictionaryArr;

@property (weak, nonatomic) IBOutlet UIButton *footerLabel;
@property (weak, nonatomic) IBOutlet UITableView *tableView;

@property (nonatomic, copy) NSString *relativePath;

@property (nonatomic, strong) UIBarButtonItem *aboutBtn;

@property (nonatomic, strong) UIPopoverController *currentPopoverController;
@property (nonatomic, strong) UIRefreshControl *refreshControl;
@end

@implementation XXScriptListTableViewController

- (UIStatusBarStyle)preferredStatusBarStyle {
    if (self.searchDisplayController.active) {
        return UIStatusBarStyleDefault;
    }
    return UIStatusBarStyleLightContent;
}

- (void)awakeFromNib {
    [super awakeFromNib];
    self.currentDirectory = [[XXTGSSI.dataService rootPath] mutableCopy];
    self.rootItemsDictionaryArr = [NSMutableArray new];
    if (!daemonInstalled() && self.isRootDirectory) {
        self.navigationItem.leftBarButtonItem = self.aboutBtn;
    }
}

- (void)viewDidLoad {
    [super viewDidLoad];
    
    UITableViewController *tableViewController = [[UITableViewController alloc] init];
    tableViewController.tableView = self.tableView;
    
    UIRefreshControl *refreshControl = [[UIRefreshControl alloc] init];
    [refreshControl addTarget:self action:@selector(launchSetup:) forControlEvents:UIControlEventValueChanged];
    [tableViewController setRefreshControl:refreshControl];
    [self.tableView.backgroundView insertSubview:refreshControl atIndex:0];
    self.refreshControl = refreshControl;
    
    self.tableView.delegate = self;
    self.tableView.dataSource = self;
    
    self.tableView.scrollIndicatorInsets =
    self.tableView.contentInset =
    UIEdgeInsetsMake(0, 0, self.tabBarController.tabBar.frame.size.height, 0);
    
    self.tableView.allowsSelection = YES;
    self.tableView.allowsMultipleSelection = NO;
    self.tableView.allowsSelectionDuringEditing = YES;
    self.tableView.allowsMultipleSelectionDuringEditing = YES;
    
    self.topToolbar.tapDelegate = self;
    if (self.type == XXScriptListTableViewControllerTypeBootscript) {
        self.navigationItem.rightBarButtonItem = nil;
        [self.topToolbar setItems:self.topToolbar.selectingBootscriptButtons animated:YES];
    } else {
        self.navigationItem.rightBarButtonItem = self.editButtonItem;
        [self.topToolbar setItems:self.topToolbar.defaultToolbarButtons animated:YES];
    }
    [self.footerLabel setTarget:self action:@selector(itemCountLabelTapped:) forControlEvents:UIControlEventTouchUpInside];
    
    if (daemonInstalled() &&
        [XXTGSSI.dataService selectedScript] == nil)
    {
        [self launchSetup:nil];
    }
    [self.tableView setContentOffset:CGPointMake(0, self.searchDisplayController.searchBar.frame.size.height)];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleNotification:) name:kXXGlobalNotificationList object:nil];
    [self reloadScriptListTableView];
    self.topToolbar.pasteButton.enabled = [XXTGSSI.dataService pasteboardArr].count != 0;
    if (self.isRootDirectory) {
        self.title = NSLocalizedString(@"My Scripts", nil);
    } else {
        self.title = [self.currentDirectory lastPathComponent];
    }
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    if ([self isEditing]) {
        [self setEditing:NO animated:YES];
    }
}

#pragma mark - Reload Control

- (void)setCurrentDirectory:(NSString *)currentDirectory {
    _currentDirectory = currentDirectory;
    NSString *homePath = [XXTGSSI.dataService rootPath];
    NSString *rootPath = [XXTGSSI.dataService mainPath];
    if ([currentDirectory isEqualToString:homePath]) {
        self.relativePath = @"~";
    } else if ([currentDirectory hasPrefix:[homePath stringByAppendingString:@"/"]]) {
        self.relativePath = [@"~" stringByAppendingString:[currentDirectory substringFromIndex:homePath.length]];
    } else if ([currentDirectory isEqualToString:rootPath]) {
        self.relativePath = @"/";
    } else if ([currentDirectory hasPrefix:[rootPath stringByAppendingString:@"/"]]) {
        self.relativePath = [@"/" stringByAppendingString:[currentDirectory substringFromIndex:(rootPath.length + 1)]];
    } else {
        self.relativePath = currentDirectory;
    }
}

- (void)launchSetup:(UIRefreshControl *)sender {
    if (!daemonInstalled())
    {
        [self reloadScriptListTableView];
        if ([sender isRefreshing]) {
            [sender endRefreshing];
        }
        return;
    }
    @weakify(self);
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
        @strongify(self);
        NSError *err = nil;
        BOOL result = (self.type == XXScriptListTableViewControllerTypeBootscript) ?
        [XXLocalNetService localGetStartUpConfWithError:&err] :
        [XXLocalNetService localGetSelectedScriptWithError:&err];
        dispatch_async_on_main_queue(^{
            if (!result) {
                if (self.isRootDirectory && !needsRespring()) {
                    SIAlertView *alertView = [[SIAlertView alloc] initWithTitle:NSLocalizedString(@"Sync Failure", nil)
                                                                     andMessage:NSLocalizedString(@"Failed to sync with daemon.\nTap to retry.", nil)];
                    [alertView addButtonWithTitle:NSLocalizedString(@"Cancel", nil)
                                             type:SIAlertViewButtonTypeCancel
                                          handler:^(SIAlertView *alert) {
                                              if ([sender isRefreshing]) {
                                                  [sender endRefreshing];
                                              }
                                          }];
                    [alertView addButtonWithTitle:NSLocalizedString(@"Retry", nil)
                                             type:SIAlertViewButtonTypeDestructive
                                          handler:^(SIAlertView *alert) {
                                              [self performSelector:@selector(launchSetup:) withObject:sender afterDelay:0.5];
                                          }];
                    [alertView show];
                    return;
                } else {
                    [self.navigationController.view makeToast:NSLocalizedString(@"Could not connect to the daemon.", nil)];
                }
            }
            [self reloadScriptListTableView];
            if ([sender isRefreshing]) {
                [sender endRefreshing];
            }
        });
    });
}

- (void)reloadScriptListTableView {
    [self reloadScriptListTableData];
    [self.tableView reloadData];
}

- (void)reloadScriptListTableData {
    NSMutableArray *pathArr = [[NSMutableArray alloc] initWithArray:[[NSFileManager defaultManager] listItemsInDirectoryAtPath:self.currentDirectory deep:NO cancelFlag:NULL]];
    
    // Item Counting
    NSString *freeSpace = [NSByteCountFormatter stringFromByteCount:[[UIDevice currentDevice] diskSpaceFree] countStyle:NSByteCountFormatterCountStyleFile];
    NSString *footerTitle = @"";
    if (pathArr.count == 0) {
        footerTitle = NSLocalizedString(@"No Item", nil);
    } else if (pathArr.count == 1) {
        footerTitle = NSLocalizedString(@"1 Item", nil);
    } else {
        footerTitle = [NSString stringWithFormat:NSLocalizedString(@"%d Items", nil), pathArr.count];
    }
    footerTitle = [footerTitle stringByAppendingString:[NSString stringWithFormat:NSLocalizedString(@", %@ free", nil), freeSpace]];
    [_footerLabel setTitle:footerTitle forState:UIControlStateNormal];
    
    // Items Fetching
    NSMutableArray *dirArr = [[NSMutableArray alloc] init];
    NSMutableArray *fileArr = [[NSMutableArray alloc] init];
    NSFileManager *fileManager = [[NSFileManager alloc] init];
    for (NSString *itemPath in pathArr) {
        NSError *err = nil;
        NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:itemPath error:&err];
        if (err == nil) {
            BOOL sortAtTop = NO;
            NSMutableDictionary *mutAttrs = [[NSMutableDictionary alloc] initWithDictionary:attrs];
            mutAttrs[kXXItemRealPathKey] = itemPath;
            mutAttrs[kXXItemPathKey] = itemPath;
            mutAttrs[kXXItemNameKey] = [itemPath lastPathComponent];
            NSString *fileType = mutAttrs[NSFileType];
            if ([fileType isEqualToString:NSFileTypeDirectory]) {
                sortAtTop = YES;
            } else if ([fileType isEqualToString:NSFileTypeSymbolicLink]) {
                NSError *err = nil;
                NSString *destPath = [fileManager realDestinationOfSymbolicLinkAtPath:itemPath error:&err];
                if (!err) {
                    NSDictionary *destAttrs = [[NSFileManager defaultManager] attributesOfItemAtPath:destPath error:&err];
                    if (!err) {
                        mutAttrs[kXXItemSymbolAttrsKey] = destAttrs;
                        mutAttrs[kXXItemRealPathKey] = destPath;
                        if ([destAttrs[NSFileType] isEqualToString:NSFileTypeDirectory]) {
                            sortAtTop = YES;
                        }
                    }
                }
            }
            sortAtTop ? [dirArr addObject:mutAttrs] : [fileArr addObject:mutAttrs];
        }
    }
    
    // Items Sorting
    if ([XXTGSSI.dataService sortMethod] == kXXScriptListSortByNameAsc) {
        [self.topToolbar.sortByButton setImage:[UIImage imageNamed:@"sort-alpha"]];
        [dirArr sortUsingComparator:^NSComparisonResult(NSDictionary *obj1, NSDictionary *obj2) {
            return [obj1[kXXItemNameKey] compare:obj2[kXXItemNameKey] options:NSCaseInsensitiveSearch];
        }];
        [fileArr sortUsingComparator:^NSComparisonResult(NSDictionary *obj1, NSDictionary *obj2) {
            return [obj1[kXXItemNameKey] compare:obj2[kXXItemNameKey] options:NSCaseInsensitiveSearch];
        }];
    } else if ([XXTGSSI.dataService sortMethod] == kXXScriptListSortByModificationDesc) {
        [self.topToolbar.sortByButton setImage:[UIImage imageNamed:@"sort-number"]];
        [dirArr sortUsingComparator:^NSComparisonResult(NSDictionary *obj1, NSDictionary *obj2) {
            return [obj2[NSFileModificationDate] compare:obj1[NSFileModificationDate]];
        }];
        [fileArr sortUsingComparator:^NSComparisonResult(NSDictionary *obj1, NSDictionary *obj2) {
            return [obj2[NSFileModificationDate] compare:obj1[NSFileModificationDate]];
        }];
    }
    
    // Items Combining
    NSMutableArray *attrArr = [[NSMutableArray alloc] init];
    
    [attrArr addObjectsFromArray:dirArr];
    [attrArr addObjectsFromArray:fileArr];
    
    self.rootItemsDictionaryArr = attrArr;
}

- (BOOL)hidesMainPath {
    if (!isJailbroken())
    {
        return NO;
    }
    return [[[XXTGSSI.dataService localUserConfig] objectForKey:kXXLocalConfigHidesMainPath] boolValue];
}

#pragma mark - Table view data source

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 2;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) {
        if (self.isRootDirectory && !self.hidesMainPath) {
            return 1;
        } else {
            return 0;
        }
    } else if (section == 1) {
        if (tableView == self.tableView) {
            return self.rootItemsDictionaryArr.count;
        }
    }
    
    return 0;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return 72;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 1) {
        return self.relativePath;
    }
    return nil;
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    if (section == 0) {
        return 0;
    }
    return 24.0;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    if (section == 1) {
        NSString *displayPath = [self.relativePath mutableCopy];
        if (displayPath.length == 0) {
            displayPath = @"/";
        }
        XXInsetsLabel *sectionNameLabel = [[XXInsetsLabel alloc] init];
        sectionNameLabel.text = displayPath;
        sectionNameLabel.textColor = [UIColor blackColor];
        sectionNameLabel.backgroundColor = [UIColor colorWithWhite:.96f alpha:.9f];
        sectionNameLabel.font = [UIFont italicSystemFontOfSize:14.f];
        sectionNameLabel.edgeInsets = UIEdgeInsetsMake(0, 12.f, 0, 12.f);
        sectionNameLabel.numberOfLines = 1;
        sectionNameLabel.lineBreakMode = NSLineBreakByTruncatingHead;
        [sectionNameLabel sizeToFit];
        return sectionNameLabel;
    } else {
        return nil;
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    XXSwipeableCell *cell = [tableView dequeueReusableCellWithIdentifier:kXXScriptListCellReuseIdentifier forIndexPath:indexPath];
    
    NSDictionary *attrs = nil;
    if (indexPath.section == 0 && indexPath.row == 0 && self.isRootDirectory && !self.hidesMainPath) {
        NSError *err = nil;
        NSString *rootPath = [XXTGSSI.dataService mainPath];
        if (rootPath) {
            NSDictionary *iAttrs = [[NSFileManager defaultManager] attributesOfItemAtPath:rootPath
                                                                                    error:&err];
            NSMutableDictionary *iMAttrs = [[NSMutableDictionary alloc] initWithDictionary:iAttrs];
            iMAttrs[kXXItemRealPathKey] = rootPath;
            iMAttrs[kXXItemPathKey] = rootPath;
            iMAttrs[kXXItemNameKey] = NSLocalizedString(@"Home Directory", nil);
            iMAttrs[kXXItemSpecialKey] = kXXItemSpecialValueHome;
            attrs = [iMAttrs copy];
        }
    } else {
        attrs = self.rootItemsDictionaryArr[(NSUInteger) indexPath.row];
    }
    
    cell.itemAttrs = attrs;
    cell.selectBootscript = (self.type == XXScriptListTableViewControllerTypeBootscript);
    
    if (cell.isSelectable) {
        NSString *highlightedItemPath = (cell.selectBootscript) ?
        [XXTGSSI.dataService startUpConfigScriptPath] :
        [XXTGSSI.dataService selectedScript];
        cell.checked = [attrs[kXXItemRealPathKey] isEqualToString:highlightedItemPath];
    } else if (cell.isDirectory) {
        cell.checked = (cell.selectBootscript) ?
        [XXTGSSI.dataService isSelectedStartUpScriptInPath:attrs[kXXItemRealPathKey]] :
        [XXTGSSI.dataService isSelectedScriptInPath:attrs[kXXItemRealPathKey]];
    }
    
    if (cell.selectBootscript) {
        cell.accessoryType = UITableViewCellAccessoryNone;
    } else {
        cell.accessoryType = cell.isSpecial ?
        UITableViewCellAccessoryDisclosureIndicator :
        UITableViewCellAccessoryDetailDisclosureButton;
    
        UILongPressGestureRecognizer *longPressGesture = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(cellLongPress:)];
        longPressGesture.delegate = self;
        [cell addGestureRecognizer:longPressGesture];
    
        NSMutableArray <MGSwipeButton *> *leftActionsArr = [[NSMutableArray alloc] init];
        NSMutableArray <MGSwipeButton *> *rightActionsArr = [[NSMutableArray alloc] init];
        if (cell.isSelectable && daemonInstalled()) {
            @weakify(self);
            [leftActionsArr addObject:[MGSwipeButton buttonWithTitle:nil
                                                                icon:[[UIImage imageNamed:@"action-play"] imageByTintColor:[UIColor whiteColor]]
                                                     backgroundColor:[STYLE_TINT_COLOR colorWithAlphaComponent:1.f]
                                                              insets:UIEdgeInsetsMake(0, 24, 0, 24)
                                                            callback:^BOOL(MGSwipeTableCell *sender) {
                                                                @strongify(self);
                                                                XXSwipeableCell *currentCell = (XXSwipeableCell *)sender;
                                                                self.navigationController.view.userInteractionEnabled = NO;
                                                                [self.navigationController.view makeToastActivity:CSToastPositionCenter];
                                                                @weakify(self);
                                                                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
                                                                    @strongify(self);
                                                                    NSError *err = nil;
                                                                    BOOL result = [XXLocalNetService localLaunchScript:currentCell.itemAttrs[kXXItemPathKey] error:&err];
                                                                    dispatch_async_on_main_queue(^{
                                                                        self.navigationController.view.userInteractionEnabled = YES;
                                                                        [self.navigationController.view hideToastActivity];
                                                                        if (!result) {
                                                                            if (err.code == 2) {
                                                                                SIAlertView *alertView = [[SIAlertView alloc] initWithTitle:[err localizedDescription] andMessage:[err localizedFailureReason]];
                                                                                [alertView addButtonWithTitle:NSLocalizedString(@"OK", nil) type:SIAlertViewButtonTypeCancel handler:^(SIAlertView *alertView) {
                                                                                    
                                                                                }];
                                                                                [alertView show];
                                                                            } else if (err.code >= 0 && err.code <= 10) {
                                                                                [self.navigationController.view makeToast:[err localizedDescription]];
                                                                            } else {
                                                                                [self.navigationController.view makeToast:NSLocalizedString(@"Could not connect to the daemon.", nil)];
                                                                            }
                                                                        }
                                                                    });
                                                                });
                                                                return YES;
                                                            }]];
        }
        if (cell.isEditable) {
            @weakify(self);
            [leftActionsArr addObject:[MGSwipeButton buttonWithTitle:nil icon:[[UIImage imageNamed:@"action-edit"] imageByTintColor:[UIColor whiteColor]]
                                                     backgroundColor:[STYLE_TINT_COLOR colorWithAlphaComponent:.8f]
                                                              insets:UIEdgeInsetsMake(0, 24, 0, 24)
                                                            callback:^BOOL(MGSwipeTableCell *sender) {
                                                                @strongify(self);
                                                                XXSwipeableCell *currentCell = (XXSwipeableCell *)sender;
                                                                BOOL result = [self editFileWithStandardEditor:currentCell.itemAttrs[kXXItemRealPathKey]
                                                                                                    anchorView:tableView
                                                                                                    anchorRect:[tableView rectForRowAtIndexPath:indexPath]];
                                                                if (!result) {
                                                                    [self.navigationController.view makeToast:NSLocalizedString(@"Unsupported file type", nil)];
                                                                }
                                                                return result;
                                                            }]];
        }
        if (!cell.isSpecial) {
            @weakify(self);
            [leftActionsArr addObject:[MGSwipeButton buttonWithTitle:nil
                                                                icon:[[UIImage imageNamed:@"action-info"] imageByTintColor:[UIColor whiteColor]]
                                                     backgroundColor:[STYLE_TINT_COLOR colorWithAlphaComponent:.6f]
                                                              insets:UIEdgeInsetsMake(0, 24, 0, 24)
                                                            callback:^BOOL(MGSwipeTableCell *sender) {
                                                                @strongify(self);
                                                                XXSwipeableCell *currentCell = (XXSwipeableCell *)sender;
                                                                UINavigationController *navController = [[UIStoryboard storyboardWithName:[XXItemAttributesTableViewController className] bundle:[NSBundle mainBundle]] instantiateViewControllerWithIdentifier:kXXItemAttributesTableViewControllerStoryboardID];
                                                                XXItemAttributesTableViewController *viewController = (XXItemAttributesTableViewController *)navController.topViewController;
                                                                viewController.currentPath = currentCell.itemAttrs[kXXItemPathKey];
                                                                [self.navigationController presentViewController:navController animated:YES completion:nil];
                                                                return YES;
                                                            }]];
        }
        if (!cell.isSpecial) {
            @weakify(self);
            [rightActionsArr addObject:[MGSwipeButton buttonWithTitle:nil
                                                                 icon:[[UIImage imageNamed:@"action-trash"] imageByTintColor:[UIColor whiteColor]]
                                                      backgroundColor:[UIColor colorWithRed:229.f/255.0f green:0.f/255.0f blue:15.f/255.0f alpha:1.f]
                                                               insets:UIEdgeInsetsMake(0, 24, 0, 24)
                                                             callback:^BOOL(MGSwipeTableCell *sender) {
                                                                 @strongify(self);
                                                                 XXSwipeableCell *currentCell = (XXSwipeableCell *)sender;
                                                                 NSIndexPath *currentIndexPath = [self.tableView indexPathForCell:currentCell];
                                                                 SIAlertView *alertView = [[SIAlertView alloc] initWithTitle:NSLocalizedString(@"Delete Confirm", nil)
                                                                                                                  andMessage:[NSString stringWithFormat:NSLocalizedString(@"Delete %@?\nThis operation cannot be revoked.", nil), currentCell.itemAttrs[kXXItemNameKey]]];
                                                                 [alertView addButtonWithTitle:NSLocalizedString(@"Cancel", nil) type:SIAlertViewButtonTypeCancel handler:^(SIAlertView *alert) {
                                                                     
                                                                 }];
                                                                 [alertView addButtonWithTitle:NSLocalizedString(@"Yes", nil) type:SIAlertViewButtonTypeDestructive handler:^(SIAlertView *alert) {
                                                                     self.navigationController.view.userInteractionEnabled = NO;
                                                                     [self.navigationController.view makeToastActivity:CSToastPositionCenter];
                                                                     dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
                                                                         NSError *err = nil;
                                                                         BOOL result = [[NSFileManager defaultManager] removeItemAtPath:currentCell.itemAttrs[kXXItemPathKey] error:&err]; // This may be time comsuming
                                                                         if (currentCell.checked) {
                                                                             if (self.type == XXScriptListTableViewControllerTypeBootscript) {
                                                                                 [XXTGSSI.dataService setStartUpConfigScriptPath:nil];
                                                                             } else {
                                                                                 [XXTGSSI.dataService setSelectedScript:nil];
                                                                             }
                                                                         }
                                                                         if (result)
                                                                         {
                                                                             [self.rootItemsDictionaryArr removeObjectAtIndex:currentIndexPath.row];
                                                                         }
                                                                         dispatch_async_on_main_queue(^{
                                                                             self.navigationController.view.userInteractionEnabled = YES;
                                                                             [self.navigationController.view hideToastActivity];
                                                                             if (result && err == nil) {
                                                                                 [self.tableView beginUpdates];
                                                                                 [self.tableView deleteRowAtIndexPath:currentIndexPath withRowAnimation:UITableViewRowAnimationFade];
                                                                                 [self.tableView endUpdates];
                                                                                 [self reloadScriptListTableData];
                                                                             } else {
                                                                                 [self.navigationController.view makeToast:[err localizedDescription]];
                                                                             }
                                                                         });
                                                                     });
                                                                 }];
                                                                 [alertView show];
                                                                 return YES;
                                                             }]];
        }
        cell.rightButtons = rightActionsArr;
        cell.leftButtons = leftActionsArr;
    }
    
    return cell;
}

#pragma mark - Long Press Gesture for Block

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    if (self.type == XXScriptListTableViewControllerTypeBootscript) {
        return NO;
    }
    return (!self.isEditing);
}

- (void)cellLongPress:(UIGestureRecognizer *)recognizer {
    if (!self.isEditing && recognizer.state == UIGestureRecognizerStateBegan) {
        CGPoint location = [recognizer locationInView:self.tableView];
        NSIndexPath *indexPath = [self.tableView indexPathForRowAtPoint:location];
        if (indexPath.section == 0 && indexPath.row == 0 && self.isRootDirectory && !self.hidesMainPath) {
            if (isJailbroken()) {
                XXSwipeableCell *cell = [self.tableView cellForRowAtIndexPath:indexPath];
                [cell becomeFirstResponder];
                UIMenuController *menuController = [UIMenuController sharedMenuController];
                UIMenuItem *hideItem = [[UIMenuItem alloc] initWithTitle:NSLocalizedString(@"Hide", nil) action:@selector(hideItemTapped:)];
                [menuController setMenuItems:[NSArray arrayWithObjects:hideItem, nil]];
                [menuController setTargetRect:[self.tableView rectForRowAtIndexPath:indexPath] inView:self.tableView];
                [menuController setMenuVisible:YES animated:YES];
            }
            return;
        }
        [self setEditing:YES animated:YES];
        [self.tableView selectRowAtIndexPath:indexPath animated:YES scrollPosition:UITableViewScrollPositionNone];
        self.topToolbar.pasteButton.enabled =
        self.topToolbar.shareButton.enabled =
        self.topToolbar.compressButton.enabled =
        self.topToolbar.trashButton.enabled = YES;
    }
}

- (BOOL)canPerformAction:(SEL)action withSender:(id)sender {
    if (action == @selector(hideItemTapped:)) {
        return YES;
    }
    return [super canPerformAction:action withSender:sender];
}

- (void)hideItemTapped:(id)sender {
    if (self.isRootDirectory && !self.hidesMainPath) {
        NSMutableDictionary *dict = [XXTGSSI.dataService localUserConfig];
        [dict setObject:@YES forKey:kXXLocalConfigHidesMainPath];
        [XXTGSSI.dataService setLocalUserConfig:dict];
        
        [self.tableView beginUpdates];
        [self.tableView deleteRow:0 inSection:0 withRowAnimation:UITableViewRowAnimationAutomatic];
        [self.tableView endUpdates];
        [self.navigationController.view makeToast:NSLocalizedString(@"\"Home Directory\" has been disabled, you can make it display again in \"More > User Defaults\".", nil)];
    }
}

#pragma mark - Table View Controller Editing Control

- (void)setEditing:(BOOL)editing animated:(BOOL)animated {
    [super setEditing:editing animated:animated];
    [self.tableView setEditing:editing animated:animated];
    if (self.type == XXScriptListTableViewControllerTypeBootscript) return;
    // Pasteboard Event - setEditing
    if (editing) {
        [self.topToolbar setItems:self.topToolbar.editingToolbarButtons animated:YES];
    } else {
        self.topToolbar.shareButton.enabled =
        self.topToolbar.compressButton.enabled =
        self.topToolbar.trashButton.enabled = NO;
        [self.topToolbar setItems:self.topToolbar.defaultToolbarButtons animated:YES];
        if ([XXTGSSI.dataService pasteboardArr].count == 0) {
            self.topToolbar.pasteButton.enabled = NO;
        }
    }
}

- (void)popToSelectViewController {
    [self.navigationController popToViewController:self.selectViewController animated:YES];
}

#pragma mark - Table View Delegate

- (void)tableView:(UITableView *)tableView didDeselectRowAtIndexPath:(NSIndexPath *)indexPath {
    if ([tableView indexPathsForSelectedRows].count == 0) {
        if ([XXTGSSI.dataService pasteboardArr].count == 0) {
            self.topToolbar.pasteButton.enabled = NO;
        }
        self.topToolbar.shareButton.enabled =
        self.topToolbar.compressButton.enabled =
        self.topToolbar.trashButton.enabled = NO;
    }
}

- (BOOL)shouldPerformSegueWithIdentifier:(NSString *)identifier sender:(id)sender {
    if (self.isEditing) return NO;
    if ([identifier isEqualToString:kXXRewindSegueIdentifier]) {
        XXSwipeableCell *currentCell = (XXSwipeableCell *)sender;
        if (currentCell.isDirectory || currentCell.isSpecial) return YES;
    }
    return NO;
}

- (void)prepareForSegue:(UIStoryboardSegue *)segue sender:(id)sender {
    XXSwipeableCell *currentCell = (XXSwipeableCell *)sender;
    if ([segue.identifier isEqualToString:kXXRewindSegueIdentifier]) {
        XXScriptListTableViewController *newController = (XXScriptListTableViewController *)segue.destinationViewController;
        newController.currentDirectory = currentCell.itemAttrs[kXXItemPathKey];
        if (self.type == XXScriptListTableViewControllerTypeBootscript) {
            newController.type = self.type;
            newController.selectViewController = self.selectViewController;
        }
    }
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (self.isEditing) {
        self.topToolbar.pasteButton.enabled =
        self.topToolbar.shareButton.enabled =
        self.topToolbar.compressButton.enabled =
        self.topToolbar.trashButton.enabled = YES;
        return;
    }
    
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    
    // It is OK if the last cell is not in display cuz the lastCell may be nil and nothing will happen if a message be sent to the nil
    XXSwipeableCell *currentCell = [tableView cellForRowAtIndexPath:indexPath];
    
    if (currentCell.isSelectable && isJailbroken()) {
        if (daemonInstalled()) {
            if (!currentCell.checked) {
                XXSwipeableCell *lastCell = nil;
                for (XXSwipeableCell *cell in tableView.visibleCells) {
                    if (cell.checked) {
                        lastCell = cell;
                    }
                }
                if (self.type == XXScriptListTableViewControllerTypeBootscript) {
                    SendConfigAction([XXLocalNetService localSetSelectedStartUpScript:currentCell.itemAttrs[kXXItemPathKey] error:&err], lastCell.checked = NO; currentCell.checked = YES;  [self popToSelectViewController];);
                } else {
                    SendConfigAction([XXLocalNetService localSetSelectedScript:currentCell.itemAttrs[kXXItemPathKey] error:&err], lastCell.checked = NO; currentCell.checked = YES;);
                }
            }
        } else {
            NSString *cydiaStr = extendDict()[@"CYDIA_URL"];
            if (cydiaStr) {
                NSURL *cydiaURL = [NSURL URLWithString:cydiaStr];
                if ([[UIApplication sharedApplication] canOpenURL:cydiaURL]) {
                    SIAlertView *alertView = [[SIAlertView alloc] initWithTitle:NSLocalizedString(@"Advanced Features", nil)
                                                                     andMessage:NSLocalizedString(@"To run XXTouch script, extra package(s) should be installed via Cydia.", nil)];
                    [alertView addButtonWithTitle:NSLocalizedString(@"Cancel", nil) type:SIAlertViewButtonTypeCancel handler:^(SIAlertView *alertView) {
                        
                    }];
                    [alertView addButtonWithTitle:NSLocalizedString(@"Open Cydia", nil) type:SIAlertViewButtonTypeDefault handler:^(SIAlertView *alertView) {
                        [[UIApplication sharedApplication] openURL:cydiaURL];
                    }];
                    [alertView show];
                } else {
                    [self.navigationController.view makeToast:NSLocalizedString(@"Failed to open Cydia", nil)];
                }
            }
        }
    } else {
        if (currentCell.isDirectory) {
            // Perform Segue
        } else {
            if (self.type == XXScriptListTableViewControllerTypeBootscript) {
                [self.navigationController.view makeToast:NSLocalizedString(@"You can only select executable script type: lua, xxt", nil)];
            } else {
                BOOL result = [self viewFileWithStandardViewer:currentCell.itemAttrs[kXXItemPathKey]
                                                    anchorView:tableView
                                                    anchorRect:[tableView rectForRowAtIndexPath:indexPath]];
                if (!result) {
                    [self.navigationController.view makeToast:NSLocalizedString(@"Unsupported file type", nil)];
                }
            }
        }
    }
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    if (self.type == XXScriptListTableViewControllerTypeBootscript) {
        return NO;
    }
    if (indexPath.section == 0 && indexPath.row == 0 && self.isRootDirectory && !self.hidesMainPath) {
        return NO;
    }
    return YES;
}

- (NSIndexPath *)tableView:(UITableView *)tableView willSelectRowAtIndexPath:(nonnull NSIndexPath *)indexPath {
    if (indexPath.section == 0 && indexPath.row == 0 && self.isEditing && self.isRootDirectory && !self.hidesMainPath) {
        return nil;
    }
    return indexPath;
}

- (BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)indexPath {
    return NO;
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath {
    return UITableViewCellEditingStyleNone;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    
}

START_IGNORE_PARTIAL
- (nullable NSArray<UITableViewRowAction *> *)tableView:(UITableView *)tableView editActionsForRowAtIndexPath:(NSIndexPath *)indexPath {
    // Replaced by MGSwipeTableCell
    return nil;
}
END_IGNORE_PARTIAL

- (void)tableView:(UITableView *)tableView accessoryButtonTappedForRowWithIndexPath:(NSIndexPath *)indexPath {
    XXSwipeableCell *cell = [tableView cellForRowAtIndexPath:indexPath];
    [cell showSwipe:MGSwipeDirectionLeftToRight animated:YES];
}

#pragma mark - Actions

- (void)itemCountLabelTapped:(id)sender {
    [[UIPasteboard generalPasteboard] setString:self.currentDirectory];
    [self.navigationController.view makeToast:NSLocalizedString(@"Absolute path copied to the clipboard", nil)];
}

- (void)presentNewDocumentViewController:(UIBarButtonItem *)sender {
    UINavigationController *navController = [[UIStoryboard storyboardWithName:[XXCreateItemTableViewController className] bundle:[NSBundle mainBundle]] instantiateViewControllerWithIdentifier:kXXCreateItemTableViewControllerStoryboardID];
    XXCreateItemTableViewController *viewController = (XXCreateItemTableViewController *)navController.topViewController;
    viewController.currentDirectory = self.currentDirectory;
    [self.navigationController presentViewController:navController animated:YES completion:nil];
}

- (void)presentDocumentMenuViewController:(UIBarButtonItem *)sender {
    UIDocumentMenuViewController *controller = [[UIDocumentMenuViewController alloc] initWithDocumentTypes:@[@"public.data"] inMode:UIDocumentPickerModeImport];
    controller.delegate = self;
    [controller addOptionWithTitle:NSLocalizedString(@"New Document", nil)
                             image:[UIImage imageNamed:@"menu-add"]
                             order:UIDocumentMenuOrderFirst
                           handler:^{
                               [self presentNewDocumentViewController:(UIBarButtonItem *)sender];
                           }];
    [controller addOptionWithTitle:NSLocalizedString(@"Photos Library", nil)
                             image:nil
                             order:UIDocumentMenuOrderLast
                           handler:^{
                               NSBundle *frameBundle = [NSBundle mainBundle];
                               XXTImagePickerController *cont = [[XXTImagePickerController alloc] initWithNibName:@"XXTImagePickerController" bundle:frameBundle];
                               cont.delegate = self;
                               cont.nResultType = XXT_PICKER_RESULT_ASSET;
                               cont.nMaxCount = XXT_NO_LIMIT_SELECT;
                               cont.nColumnCount = 4;
                               [self presentViewController:cont animated:YES completion:nil];
                           }];
    if ([[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad) {
        controller.modalPresentationStyle = UIModalPresentationPopover;
        START_IGNORE_PARTIAL
        if (XXT_SYSTEM_8) {
            controller.popoverPresentationController.permittedArrowDirections = UIPopoverArrowDirectionAny;
            controller.popoverPresentationController.barButtonItem = sender;
        } else {
            UIPopoverController *popover = [[UIPopoverController alloc] initWithContentViewController:controller];
            [popover presentPopoverFromBarButtonItem:sender
                            permittedArrowDirections:UIPopoverArrowDirectionAny
                                            animated:YES];
            self.currentPopoverController = popover;
            popover.delegate = self;
            popover.passthroughViews = nil;
            return;
        }
        END_IGNORE_PARTIAL
    }
    [self.navigationController presentViewController:controller animated:YES completion:nil];
}

- (void)toolbarButtonTapped:(UIBarButtonItem *)sender {
    if (sender == self.topToolbar.scanButton) {
        [((XXNavigationViewController *)self.navigationController) transitionToScanViewController];
    } else if (sender == self.topToolbar.addItemButton) {
        if (XXT_SYSTEM_8) {
            [self presentDocumentMenuViewController:sender];
        } else {
            [self presentNewDocumentViewController:sender];
        }
    } else if (sender == self.topToolbar.pasteButton) {
        // Start Alert View
        SIAlertView *alertView = [[SIAlertView alloc] initWithTitle:nil andMessage:nil];
        
        // Set Paste / Link Action
        NSString *pasteStr = nil;
        NSString *linkStr = nil;
        NSMutableArray *pasteArr = [XXTGSSI.dataService pasteboardArr];
        if (pasteArr.count != 0) {
            if (pasteArr.count == 1) {
                pasteStr = NSLocalizedString(@"Paste 1 item", nil);
                linkStr = NSLocalizedString(@"Create 1 link", nil);
            } else {
                pasteStr = [NSString stringWithFormat:NSLocalizedString(@"Paste %d items", nil), pasteArr.count];
                linkStr = [NSString stringWithFormat:NSLocalizedString(@"Create %d links", nil), pasteArr.count];
            }
            kXXPasteboardType pasteboardType = [XXTGSSI.dataService pasteboardType];
            @weakify(self);
            [alertView addButtonWithTitle:pasteStr type:SIAlertViewButtonTypeDefault handler:^(SIAlertView *alertView) {
                @strongify(self);
                NSString *currentPath = self.currentDirectory;
                self.navigationController.view.userInteractionEnabled = NO;
                [self.navigationController.view makeToastActivity:CSToastPositionCenter];
                if (pasteboardType == kXXPasteboardTypeCut) {
                    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
                        NSError *err = nil;
                        for (NSString *originPath in pasteArr) {
                            NSString *destPath = [currentPath stringByAppendingPathComponent:[originPath lastPathComponent]];
                            [[NSFileManager defaultManager] moveItemAtPath:originPath toPath:destPath error:&err]; // This may be time consuming
                        }
                        dispatch_async_on_main_queue(^{
                            self.navigationController.view.userInteractionEnabled = YES;
                            [self.navigationController.view hideToastActivity];
                            [pasteArr removeAllObjects];
                            self.topToolbar.pasteButton.enabled = NO;
                            [self reloadScriptListTableView];
                        });
                    });
                } else if (pasteboardType == kXXPasteboardTypeCopy) {
                    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
                        NSError *err = nil;
                        for (NSString *originPath in pasteArr) {
                            NSString *destPath = [currentPath stringByAppendingPathComponent:[originPath lastPathComponent]];
                            [[NSFileManager defaultManager] copyItemAtPath:originPath toPath:destPath error:&err]; // This may be time consuming
                        }
                        dispatch_async_on_main_queue(^{
                            self.navigationController.view.userInteractionEnabled = YES;
                            [self.navigationController.view hideToastActivity];
                            [self reloadScriptListTableView];
                        });
                    });
                }
            }];
            if (pasteboardType == kXXPasteboardTypeCopy) {
                @weakify(self);
                [alertView addButtonWithTitle:linkStr type:SIAlertViewButtonTypeDefault handler:^(SIAlertView *alertView) {
                    @strongify(self);
                    NSError *err = nil;
                    NSString *currentPath = self.currentDirectory;
                    NSFileManager *fileManager = [[NSFileManager alloc] init];
                    for (NSString *originPath in pasteArr) {
                        NSString *destPath = [currentPath stringByAppendingPathComponent:[originPath lastPathComponent]];
                        [fileManager createSymbolicLinkAtPath:destPath withDestinationPath:originPath error:&err];
                    }
                    [self reloadScriptListTableView];
                }];
            }
        }
        
        // Set Copy / Cut Action
        NSString *copyStr = nil;
        NSString *cutStr = nil;
        NSArray <NSIndexPath *> *selectedIndexes = [self.tableView indexPathsForSelectedRows];
        if (selectedIndexes.count != 0) {
            NSMutableArray <NSString *> *selectedPaths = [[NSMutableArray alloc] init];
            for (NSIndexPath *path in selectedIndexes) {
                [selectedPaths addObject:self.rootItemsDictionaryArr[path.row][kXXItemPathKey]];
            }
            if (selectedIndexes.count == 1) {
                copyStr = NSLocalizedString(@"Copy 1 item", nil);
                cutStr = NSLocalizedString(@"Cut 1 item", nil);
            } else {
                copyStr = [NSString stringWithFormat:NSLocalizedString(@"Copy %d items", nil), selectedIndexes.count];
                cutStr = [NSString stringWithFormat:NSLocalizedString(@"Cut %d items", nil), selectedIndexes.count];
            }
            if ([self isEditing]) {
                [alertView addButtonWithTitle:copyStr
                                         type:SIAlertViewButtonTypeDefault
                                      handler:^(SIAlertView *alertView) {
                    [XXTGSSI.dataService setPasteboardType:kXXPasteboardTypeCopy];
                    [XXTGSSI.dataService setPasteboardArr:selectedPaths];
                }];
                [alertView addButtonWithTitle:cutStr
                                         type:SIAlertViewButtonTypeDefault
                                      handler:^(SIAlertView *alertView) {
                    [XXTGSSI.dataService setPasteboardType:kXXPasteboardTypeCut];
                    [XXTGSSI.dataService setPasteboardArr:selectedPaths];
                }];
            }
        }
        
        [alertView addButtonWithTitle:NSLocalizedString(@"Cancel", nil) type:SIAlertViewButtonTypeCancel handler:^(SIAlertView *alertView) {
            
        }];
        
        // Show Alert
        [alertView show];
    } else if (sender == self.topToolbar.sortByButton) {
        if ([XXTGSSI.dataService sortMethod] == kXXScriptListSortByNameAsc) {
            [XXTGSSI.dataService setSortMethod:kXXScriptListSortByModificationDesc];
            [self.topToolbar.sortByButton setImage:[UIImage imageNamed:@"sort-number"]];
        } else if ([XXTGSSI.dataService sortMethod] == kXXScriptListSortByModificationDesc) {
            [XXTGSSI.dataService setSortMethod:kXXScriptListSortByNameAsc];
            [self.topToolbar.sortByButton setImage:[UIImage imageNamed:@"sort-alpha"]];
        }
        [self reloadScriptListTableView];
    } else if (sender == self.topToolbar.trashButton) {
        NSArray <NSIndexPath *> *selectedIndexPaths = [self.tableView indexPathsForSelectedRows];
        
        NSString *formatString = nil;
        if (selectedIndexPaths.count == 1) {
            formatString = [NSString stringWithFormat:NSLocalizedString(@"Delete 1 item?\nThis operation cannot be revoked.", nil)];
        } else {
            formatString = [NSString stringWithFormat:NSLocalizedString(@"Delete %d items?\nThis operation cannot be revoked.", nil), selectedIndexPaths.count];
        }
        SIAlertView *alertView = [[SIAlertView alloc] initWithTitle:NSLocalizedString(@"Delete Confirm", nil)
                                                         andMessage:formatString];
        @weakify(self);
        [alertView addButtonWithTitle:NSLocalizedString(@"Cancel", nil) type:SIAlertViewButtonTypeCancel handler:^(SIAlertView *alertView) {
            
        }];
        [alertView addButtonWithTitle:NSLocalizedString(@"Yes", nil) type:SIAlertViewButtonTypeDestructive handler:^(SIAlertView *alertView) {
            @strongify(self);
            BOOL result = YES;
            NSError *err = nil;
            NSMutableIndexSet *indexesToBeDeleted = [NSMutableIndexSet new];
            for (NSIndexPath *indexPath in selectedIndexPaths) {
                NSString *itemPath = self.rootItemsDictionaryArr[indexPath.row][kXXItemPathKey];
                if (self.type == XXScriptListTableViewControllerTypeBootscript) {
                    if ([itemPath isEqualToString:[XXTGSSI.dataService startUpConfigScriptPath]]) {
                        [XXTGSSI.dataService setStartUpConfigScriptPath:nil];
                    }
                } else {
                    if ([itemPath isEqualToString:[XXTGSSI.dataService selectedScript]]) {
                        [XXTGSSI.dataService setSelectedScript:nil];
                    }
                }
                result = [[NSFileManager defaultManager] removeItemAtPath:itemPath error:&err];
                if (err || !result) {
                    break;
                } else {
                    [indexesToBeDeleted addIndex:indexPath.row];
                }
            }
            [self.rootItemsDictionaryArr removeObjectsAtIndexes:[indexesToBeDeleted copy]];
            if (result) {
                [self.tableView beginUpdates];
                [self.tableView deleteRowsAtIndexPaths:selectedIndexPaths withRowAnimation:UITableViewRowAnimationAutomatic];
                [self.tableView endUpdates];
                [self reloadScriptListTableData];
            } else {
                [self.navigationController.view makeToast:[err localizedDescription]];
            }
        }];
        [alertView show];
    } else if (sender == self.topToolbar.shareButton) {
        NSArray <NSIndexPath *> *selectedIndexPaths = [self.tableView indexPathsForSelectedRows];
        NSMutableArray <NSURL *> *urlsArr = [[NSMutableArray alloc] init];
        for (NSIndexPath *indexPath in selectedIndexPaths) {
            NSDictionary *infoDict = self.rootItemsDictionaryArr[indexPath.row];
            if ([infoDict[NSFileType] isEqualToString:NSFileTypeDirectory]) {
                [urlsArr removeAllObjects];
                break;
            } else {
                [urlsArr addObject:[NSURL fileURLWithPath:infoDict[kXXItemPathKey]]];
            }
        }
        if (urlsArr.count != 0) {
            XXArchiveActivity *act = [[XXArchiveActivity alloc] init];
            UIActivityViewController *controller = [[UIActivityViewController alloc] initWithActivityItems:urlsArr applicationActivities:@[act]];
            if ([[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad) {
                controller.modalPresentationStyle = UIModalPresentationPopover;
                START_IGNORE_PARTIAL
                if (XXT_SYSTEM_8) {
                    controller.popoverPresentationController.permittedArrowDirections = UIPopoverArrowDirectionAny;
                    controller.popoverPresentationController.barButtonItem = sender;
                } else {
                    UIPopoverController *popover = [[UIPopoverController alloc] initWithContentViewController:controller];
                    [popover presentPopoverFromBarButtonItem:sender
                                    permittedArrowDirections:UIPopoverArrowDirectionAny
                                                    animated:YES];
                    self.currentPopoverController = popover;
                    popover.delegate = self;
                    popover.passthroughViews = nil;
                    return;
                }
                END_IGNORE_PARTIAL
            }
            [self.navigationController presentViewController:controller animated:YES completion:nil];
        } else {
            [self.navigationController.view makeToast:NSLocalizedString(@"You cannot share directory", nil)];
        }
    } else if (sender == self.topToolbar.compressButton) {
        NSArray <NSIndexPath *> *selectedIndexPaths = [self.tableView indexPathsForSelectedRows];
        NSMutableArray <NSURL *> *urlsArr = [[NSMutableArray alloc] init];
        for (NSIndexPath *indexPath in selectedIndexPaths) {
            NSString *itemPath = self.rootItemsDictionaryArr[indexPath.row][kXXItemPathKey];
            [urlsArr addObject:[NSURL fileURLWithPath:itemPath]];
        }
        if (urlsArr.count != 0) {
            XXArchiveActivity *act = [[XXArchiveActivity alloc] init];
            [act prepareWithActivityItems:urlsArr];
            [act performActivityWithController:self];
        }
    } else if (sender == self.topToolbar.purchaseButton) {
        XXPaymentActivity *act = [[XXPaymentActivity alloc] init];
        [act performActivityWithController:self];
    }
}

#pragma mark - Getters

- (BOOL)isRootDirectory {
    return (self != self.navigationController.topViewController && self.navigationController.topViewController != nil);
}

- (UIBarButtonItem *)aboutBtn {
    if (!_aboutBtn) {
        UIBarButtonItem *aboutBtn = [[UIBarButtonItem alloc] initWithTitle:NSLocalizedString(@"About", nil)
                                                                     style:UIBarButtonItemStylePlain
                                                                    target:self
                                                                    action:@selector(showAboutController:)];
        _aboutBtn = aboutBtn;
    }
    return _aboutBtn;
}

#pragma mark - Notification 0x1001ae344

- (void)handleNotification:(NSNotification *)aNotification {
    NSDictionary *userInfo = aNotification.userInfo;
    NSString *event = userInfo[kXXGlobalNotificationKeyEvent];
    if ([event isEqualToString:kXXGlobalNotificationKeyEventArchive] ||
        [event isEqualToString:kXXGlobalNotificationKeyEventUnarchive] ||
        [event isEqualToString:kXXGlobalNotificationKeyEventTransfer]
        ) {
        [self reloadScriptListTableView];
    }
}

#pragma mark - Non Jailbroken device

- (void)showAboutController:(UIBarButtonItem *)sender {
    XXAboutTableViewController *aboutController = (XXAboutTableViewController *)[[UIStoryboard storyboardWithName:@"Main" bundle:[NSBundle mainBundle]] instantiateViewControllerWithIdentifier:kXXAboutTableViewControllerStoryboardID];
    [self.navigationController pushViewController:aboutController animated:YES];
}

#pragma mark - Type Viewers

- (NSArray *)viewerActivities {
    if (daemonInstalled()) {
        return @[
                 [XXUIActivity class],
                 [XXWebActivity class],
                 [XXImageActivity class],
                 [XXMediaActivity class],
                 [XXUnarchiveActivity class],
                 ];
    } else if ([XXTGSSI.dataService purchasedProduct]) {
        return @[
                 [XXTerminalActivity class],
                 [XXUIActivity class],
                 [XXWebActivity class],
                 [XXImageActivity class],
                 [XXMediaActivity class],
                 [XXUnarchiveActivity class],
                 ];
    } else {
        return @[
                 [XXPaymentActivity class],
                 [XXWebActivity class],
                 [XXImageActivity class],
                 [XXMediaActivity class],
                 [XXUnarchiveActivity class],
                 ];
    }
}

#pragma mark - Type Editors

- (NSArray *)editorActivities {
    return @[
             [XXTextActivity class],
             ];
}

#pragma mark - Open In...

- (BOOL)viewFileWithStandardViewer:(NSString *)filePath
                        anchorView:(UIView *)anchorView
                        anchorRect:(CGRect)anchorRect
{
    NSString *fileExt = [[filePath pathExtension] lowercaseString];
    NSURL *fileURL = [NSURL fileURLWithPath:filePath];
    for (Class actClass in [self viewerActivities]) {
        if ([[actClass supportedExtensions] existsString:fileExt])
        {
            XXBaseActivity *act = [[actClass alloc] init];
            [act setFileURL:fileURL];
            [act performActivityWithController:self];
            return YES;
        }
    }
    { // Not supported
        NSMutableArray *acts = [[NSMutableArray alloc] init];
        for (Class actClass in [self viewerActivities]) {
            XXBaseActivity *act = [[actClass alloc] init];
            act.baseController = self;
            [acts addObject:act];
        }
        UIActivityViewController *controller = [[UIActivityViewController alloc] initWithActivityItems:@[fileURL] applicationActivities:acts];
        [controller setExcludedActivityTypes:@[ UIActivityTypeAirDrop ]];
        if ([[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad) {
            controller.modalPresentationStyle = UIModalPresentationPopover;
            START_IGNORE_PARTIAL
            if (XXT_SYSTEM_8) {
                controller.popoverPresentationController.permittedArrowDirections = UIPopoverArrowDirectionAny;
                controller.popoverPresentationController.sourceView = anchorView;
                controller.popoverPresentationController.sourceRect = anchorRect;
            } else {
                UIPopoverController *popover = [[UIPopoverController alloc] initWithContentViewController:controller];
                [popover presentPopoverFromRect:anchorRect
                                         inView:anchorView
                       permittedArrowDirections:UIPopoverArrowDirectionAny
                                       animated:YES];
                self.currentPopoverController = popover;
                popover.delegate = self;
                popover.passthroughViews = nil;
                return YES;
            }
            END_IGNORE_PARTIAL
        }
        [self.navigationController presentViewController:controller animated:YES completion:nil];
        return YES;
    }
    return NO;
}


- (BOOL)editFileWithStandardEditor:(NSString *)filePath
                        anchorView:(UIView *)anchorView
                        anchorRect:(CGRect)anchorRect
{
    NSString *fileExt = [[filePath pathExtension] lowercaseString];
    NSURL *fileURL = [NSURL fileURLWithPath:filePath isDirectory:NO];
    for (Class actClass in [self editorActivities]) {
        if ([[actClass supportedExtensions] existsString:fileExt])
        {
            XXBaseActivity *act = [[actClass alloc] init];
            [act setFileURL:fileURL];
            [act performActivityWithController:self];
            return YES;
        }
    }
    { // Not supported
        NSMutableArray *acts = [[NSMutableArray alloc] init];
        for (Class actClass in [self editorActivities]) {
            XXBaseActivity *act = [[actClass alloc] init];
            act.baseController = self;
            [acts addObject:act];
        }
        UIActivityViewController *controller = [[UIActivityViewController alloc] initWithActivityItems:@[fileURL] applicationActivities:acts];
        [controller setExcludedActivityTypes:@[ UIActivityTypeAirDrop ]];
        if ([[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad) {
            controller.modalPresentationStyle = UIModalPresentationPopover;
            START_IGNORE_PARTIAL
            if (XXT_SYSTEM_8) {
                controller.popoverPresentationController.permittedArrowDirections = UIPopoverArrowDirectionAny;
                controller.popoverPresentationController.sourceView = anchorView;
                controller.popoverPresentationController.sourceRect = anchorRect;
            } else {
                UIPopoverController *popover = [[UIPopoverController alloc] initWithContentViewController:controller];
                [popover presentPopoverFromRect:anchorRect
                                         inView:anchorView
                       permittedArrowDirections:UIPopoverArrowDirectionAny
                                       animated:YES];
                self.currentPopoverController = popover;
                popover.delegate = self;
                popover.passthroughViews = nil;
                return YES;
            }
            END_IGNORE_PARTIAL
        }
        [self.navigationController presentViewController:controller animated:YES completion:nil];
        return YES;
    }
    return NO;
}

#pragma mark - UIPopoverControllerDelegate

- (void)popoverControllerDidDismissPopover:(UIPopoverController *)popoverController {
    self.currentPopoverController = nil;
}

#pragma mark - UIDocumentMenuDelegate

- (void)documentMenuWasCancelled:(UIDocumentMenuViewController *)documentMenu {
    
}

- (void)documentMenu:(UIDocumentMenuViewController *)documentMenu didPickDocumentPicker:(UIDocumentPickerViewController *)documentPicker {
    documentPicker.delegate = self;
    [self.navigationController presentViewController:documentPicker animated:YES completion:nil];
}

#pragma mark - UIDocumentPickerDelegate

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentAtURL:(NSURL *)url {
    [[NSNotificationCenter defaultCenter] postNotification:[NSNotification notificationWithName:kXXGlobalNotificationLaunch object:url userInfo:@{kXXGlobalNotificationKeyEvent: kXXGlobalNotificationKeyEventInbox}]];
}

#pragma mark - XXTImagePickerControllerDelegate

- (void)didCancelImagePickerController:(XXTImagePickerController *)picker
{
    [picker dismissViewControllerAnimated:YES completion:nil];
}

- (void)didSelectPhotosFromImagePickerController:(XXTImagePickerController *)picker
                                            result:(NSArray *)aSelected
{
    [picker dismissViewControllerAnimated:YES completion:nil];
    self.navigationController.view.userInteractionEnabled = NO;
    [self.navigationController.view makeToastActivity:CSToastPositionCenter];
    @weakify(self);
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
        @strongify(self);
        NSError *error = nil;
        NSString *currentDirectory = self.currentDirectory;
        for (ALAsset *asset in aSelected) {
            ALAssetRepresentation *assetRepr = asset.defaultRepresentation;
            Byte *buffer = (Byte *)malloc((size_t)assetRepr.size);
            NSUInteger buffered = [assetRepr getBytes:buffer fromOffset:0 length:(NSUInteger)assetRepr.size error:&error];
            if (error) {
                continue;
            }
            NSData *data = [NSData dataWithBytesNoCopy:buffer length:buffered freeWhenDone:YES];
            [data writeToFile:[currentDirectory stringByAppendingPathComponent:assetRepr.filename] atomically:YES];
        }
        dispatch_async_on_main_queue(^{
            self.navigationController.view.userInteractionEnabled = YES;
            [self.navigationController.view hideToastActivity];
            [self.navigationController.view makeToast:[NSString stringWithFormat:NSLocalizedString(@"%lu image(s) imported.", nil), aSelected.count]];
            [self reloadScriptListTableView];
        });
    });
}

#pragma mark - Memory

- (void)dealloc {
    XXLog(@"");
}

@end
