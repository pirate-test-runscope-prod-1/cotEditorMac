/*
 ==============================================================================
 CEAppearancePaneController
 
 CotEditor
 http://coteditor.com
 
 Created on 2014-04-18 by 1024jp
 encoding="UTF-8"
 ------------------------------------------------------------------------------
 
 © 2004-2007 nakamuxu
 © 2014-2015 1024jp
 
 This program is free software; you can redistribute it and/or modify it under
 the terms of the GNU General Public License as published by the Free Software
 Foundation; either version 2 of the License, or (at your option) any later
 version.
 
 This program is distributed in the hope that it will be useful, but WITHOUT
 ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
 FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
 
 You should have received a copy of the GNU General Public License along with
 this program; if not, write to the Free Software Foundation, Inc., 59 Temple
 Place - Suite 330, Boston, MA  02111-1307, USA.
 
 ==============================================================================
 */

@import AudioToolbox;
#import "CEAppearancePaneController.h"
#import "CEThemeViewController.h"
#import "CEThemeManager.h"
#import "constants.h"


@interface CEAppearancePaneController () <NSTableViewDelegate, NSTableViewDataSource, CEThemeViewControllerDelegate>

@property (nonatomic, nullable, weak) IBOutlet NSTextField *fontField;
@property (nonatomic, nullable, weak) IBOutlet NSTableView *themeTableView;
@property (nonatomic, nullable, weak) IBOutlet NSBox *box;

@property (nonatomic, nullable) CEThemeViewController *themeViewController;
@property (nonatomic, nullable) NSArray *themeNames;
@property (nonatomic, getter=isBundled) BOOL bundled;

@end




#pragma mark -

@implementation CEAppearancePaneController

#pragma mark Superclass Methods

// ------------------------------------------------------
/// clean up
- (void)dealloc
// ------------------------------------------------------
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}


// ------------------------------------------------------
/// setup UI
- (void)loadView
// ------------------------------------------------------
{
    [super loadView];
    
    [self setFontFamilyNameAndSize];
    
    [self setupThemeList];
    
    // デフォルトテーマを選択
    NSArray *themeNames = [[self themeNames] copy];
    NSInteger row = [themeNames indexOfObject:[[NSUserDefaults standardUserDefaults] stringForKey:CEDefaultThemeKey]];
    [[self themeTableView] selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
    [[self themeTableView] setAllowsEmptySelection:NO];
    
    // テーマのラインナップが変更されたらテーブルビューを更新
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(setupThemeList)
                                                 name:CEThemeListDidUpdateNotification
                                               object:nil];
}



#pragma mark Protocol

//=======================================================
// NSMenuValidation Protocol
//=======================================================

// ------------------------------------------------------
/// メニュー項目の有効化／無効化を制御
- (BOOL)validateMenuItem:(nonnull NSMenuItem *)menuItem
// ------------------------------------------------------
{
    BOOL isCustomized;
    BOOL isBundled = [[CEThemeManager sharedManager] isBundledTheme:[self selectedTheme] cutomized:&isCustomized];
    
    if ([menuItem action] == @selector(exportTheme:)) {
        [menuItem setTitle:[NSString stringWithFormat:NSLocalizedString(@"Export “%@”…", nil), [self selectedTheme]]];
        return (!isBundled || isCustomized);
        
    } else if ([menuItem action] == @selector(duplicateTheme:)) {
        [menuItem setTitle:[NSString stringWithFormat:NSLocalizedString(@"Duplicate “%@”", nil), [self selectedTheme]]];
    } else if ([menuItem action] == @selector(restoreTheme:)) {
        [menuItem setTitle:[NSString stringWithFormat:NSLocalizedString(@"Restore “%@”", nil), [self selectedTheme]]];
        [menuItem setHidden:!isBundled];
        return isCustomized;
    }
    
    return YES;
}



#pragma mark Data Source

//=======================================================
// NSTableDataSource Protocol  < themeTableView
//=======================================================

// ------------------------------------------------------
/// テーブルの行数を返す
- (NSInteger)numberOfRowsInTableView:(nonnull NSTableView *)aTableView
// ------------------------------------------------------
{
    return [[self themeNames] count];
}


// ------------------------------------------------------
/// テーブルのセルの内容を返す
- (nullable id)tableView:(nonnull NSTableView *)aTableView objectValueForTableColumn:(nullable NSTableColumn *)aTableColumn row:(NSInteger)rowIndex
// ------------------------------------------------------
{
    return [self themeNames][rowIndex];
}



#pragma mark Delegate

//=======================================================
// CEThemeViewControllerDelegate
//=======================================================

// ------------------------------------------------------
/// テーマが編集された
- (void)didUpdateTheme:(NSMutableDictionary *)theme
// ------------------------------------------------------
{
    // save
    [[CEThemeManager sharedManager] saveTheme:theme name:[self selectedTheme] completionHandler:nil];
}


//=======================================================
// NSTableViewDelegate  < themeTableView
//=======================================================

// ------------------------------------------------------
/// テーブルの選択が変更された
- (void)tableViewSelectionDidChange:(nonnull NSNotification *)notification
// ------------------------------------------------------
{
    if ([notification object] == [self themeTableView]) {
        BOOL isBundled;
        NSMutableDictionary *themeDict = [[CEThemeManager sharedManager] archivedTheme:[self selectedTheme] isBundled:&isBundled];
        
        // デフォルトテーマ設定の更新（初回の選択変更はまだ設定が反映されていない時点で呼び出されるので保存しない）
        if ([self themeViewController]) {
            NSString *oldThemeName = [[NSUserDefaults standardUserDefaults] stringForKey:CEDefaultThemeKey];
            
            [[NSUserDefaults standardUserDefaults] setObject:[self selectedTheme] forKey:CEDefaultThemeKey];
            
            // 現在開いているウインドウのテーマも変更
            [[NSNotificationCenter defaultCenter] postNotificationName:CEThemeDidUpdateNotification
                                                                object:self
                                                              userInfo:@{CEOldNameKey: oldThemeName,
                                                                         CENewNameKey: [self selectedTheme]}];
        }
        
        [self setThemeViewController:[[CEThemeViewController alloc] init]];
        [[self themeViewController] setDelegate:self];
        [[self themeViewController] setRepresentedObject:themeDict];
        [[self themeViewController] setBundled:isBundled];
        [[self box] setContentView:[[self themeViewController] view]];
        
        [self setBundled:isBundled];
    }
}


// ------------------------------------------------------
/// テーブルセルが編集可能かを設定する
- (void)tableView:(nonnull NSTableView *)tableView didAddRowView:(nonnull NSTableRowView *)rowView forRow:(NSInteger)row
// ------------------------------------------------------
{
    NSTableCellView *view = [tableView viewAtColumn:0 row:row makeIfNecessary:NO];
    NSString *themeName = [self themeNames][row];
    BOOL editable = ![[CEThemeManager sharedManager] isBundledTheme:themeName cutomized:nil];
    
    [[view textField] setEditable:editable];
}


// ------------------------------------------------------
/// テーマ名が編集された
- (BOOL)control:(nonnull NSControl *)control textShouldEndEditing:(nonnull NSText *)fieldEditor
// ------------------------------------------------------
{
    NSString *oldName = [self selectedTheme];
    NSString *newName = [fieldEditor string];
    NSError *error = nil;
    
    // 空の場合は終わる（自動的に元の名前がセットされる）
    if ([newName isEqualToString:@""]) {
        return YES;
    }
    
    BOOL success = [[CEThemeManager sharedManager] renameTheme:oldName toName:newName error:&error];
    
    if (error) {
        // revert name
        [fieldEditor setString:oldName];
        // show alert
        NSAlert *alert = [NSAlert alertWithError:error];
        [alert beginSheetModalForWindow:[[self view] window] modalDelegate:nil didEndSelector:NULL contextInfo:NULL];
    }
    
    return success;
}



#pragma mark Action Messages

// ------------------------------------------------------
/// show font panel
- (IBAction)showFonts:(nullable id)sender
//-------------------------------------------------------
{
    NSFont *font = [NSFont fontWithName:[[NSUserDefaults standardUserDefaults] stringForKey:CEDefaultFontNameKey]
                                   size:(CGFloat)[[NSUserDefaults standardUserDefaults] doubleForKey:CEDefaultFontSizeKey]];
    
    [[[self view] window] makeFirstResponder:self];
    [[NSFontManager sharedFontManager] setSelectedFont:font isMultiple:NO];
    [[NSFontManager sharedFontManager] orderFrontFontPanel:sender];
}


// ------------------------------------------------------
/// font in font panel did update
- (void)changeFont:(nullable id)sender
// ------------------------------------------------------
{
    NSFontManager *fontManager = (NSFontManager *)sender;
    NSFont *newFont = [fontManager convertFont:[NSFont systemFontOfSize:0]];
    
    [[NSUserDefaults standardUserDefaults] setObject:[newFont fontName] forKey:CEDefaultFontNameKey];
    [[NSUserDefaults standardUserDefaults] setDouble:[newFont pointSize] forKey:CEDefaultFontSizeKey];
    [self setFontFamilyNameAndSize];
}


//------------------------------------------------------
/// テーマを追加
- (IBAction)addTheme:(nullable id)sender
//------------------------------------------------------
{
    __weak typeof(self) weakSelf = self;
    [[CEThemeManager sharedManager] createUntitledThemeWithCompletionHandler:^(NSString *themeName, NSError *error) {
        typeof(weakSelf) strongSelf = weakSelf;
        
        NSArray *themeNames = [[CEThemeManager sharedManager] themeNames];
        NSInteger row = [themeNames indexOfObject:themeName];
        [[strongSelf themeTableView] selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
    }];
}


//------------------------------------------------------
/// 選択しているテーマを削除
- (IBAction)deleteTheme:(nullable id)sender
//------------------------------------------------------
{
    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:[NSString stringWithFormat:NSLocalizedString(@"Delete the theme “%@”?", nil),
                           [self selectedTheme]]];
    [alert setInformativeText:NSLocalizedString(@"Deleted theme cannot be restored.", nil)];
    [alert addButtonWithTitle:NSLocalizedString(@"Cancel", nil)];
    [alert addButtonWithTitle:NSLocalizedString(@"Delete", nil)];
    
    [alert beginSheetModalForWindow:[[self view] window]
                      modalDelegate:self
                     didEndSelector:@selector(deleteThemeAlertDidEnd:returnCode:contextInfo:) contextInfo:NULL];
}


//------------------------------------------------------
/// 選択しているテーマを複製
- (IBAction)duplicateTheme:(nullable id)sender
//------------------------------------------------------
{
    [[CEThemeManager sharedManager] duplicateTheme:[self selectedTheme] error:nil];
}


//------------------------------------------------------
/// 選択しているテーマを書き出し
- (IBAction)exportTheme:(nullable id)sender
//------------------------------------------------------
{
    NSString *selectedThemeName = [self selectedTheme];
    
    NSSavePanel *savePanel = [NSSavePanel savePanel];
    [savePanel setCanCreateDirectories:YES];
    [savePanel setCanSelectHiddenExtension:YES];
    [savePanel setNameFieldLabel:NSLocalizedString(@"Export As:", nil)];
    [savePanel setNameFieldStringValue:selectedThemeName];
    [savePanel setAllowedFileTypes:@[CEThemeExtension]];
    
    [savePanel beginSheetModalForWindow:[[self view] window] completionHandler:^(NSInteger result) {
        if (result == NSFileHandlingPanelCancelButton) { return; }
        
        [[CEThemeManager sharedManager] exportTheme:selectedThemeName toURL:[savePanel URL] error:nil];
    }];
}


//------------------------------------------------------
/// テーマを読み込み
- (IBAction)importTheme:(nullable id)sender
//------------------------------------------------------
{
    NSOpenPanel *openPanel = [NSOpenPanel openPanel];
    [openPanel setPrompt:NSLocalizedString(@"Import", nil)];
    [openPanel setResolvesAliases:YES];
    [openPanel setAllowsMultipleSelection:NO];
    [openPanel setCanChooseDirectories:NO];
    [openPanel setAllowedFileTypes:@[CEThemeExtension]];
    
    [openPanel beginSheetModalForWindow:[[self view] window] completionHandler:^(NSInteger result) {
        if (result == NSFileHandlingPanelCancelButton) { return; }
        
        NSURL *URL = [openPanel URL];
        NSError *error = nil;
        
        // インポートを試みる
        [[CEThemeManager sharedManager] importTheme:URL replace:NO error:&error];
        
        if (error) {
            NSAlert *alert = [NSAlert alertWithError:error];
            
            [openPanel orderOut:nil];
            [[openPanel sheetParent] makeKeyAndOrderFront:nil];
            
            // 同名のファイルがある場合は上書きするかを訊く
            if ([error code] == CEThemeFileDuplicationError) {
                [alert beginSheetModalForWindow:[[self view] window]
                                  modalDelegate:self
                                 didEndSelector:@selector(importDuplicateThemeAlertDidEnd:returnCode:contextInfo:)
                                    contextInfo:(__bridge_retained void *)(URL)];
            } else {
                [alert beginSheetModalForWindow:[[self view] window]
                                  modalDelegate:nil
                                 didEndSelector:NULL
                                    contextInfo:NULL];
            }
        }
    }];
}


// ------------------------------------------------------
/// カスタマイズされたバンドル版テーマをオリジナルに戻す
- (IBAction)restoreTheme:(nullable id)sender
// ------------------------------------------------------
{
    [[CEThemeManager sharedManager] restoreTheme:[self selectedTheme] completionHandler:^(NSError *error) {
        if (!error) {
            // 辞書をセットし直す
            NSMutableDictionary *bundledTheme = [[CEThemeManager sharedManager] archivedTheme:[self selectedTheme] isBundled:nil];
            
            [[self themeViewController] setRepresentedObject:bundledTheme];
        }
    }];
}



#pragma mark Private Methods

//------------------------------------------------------
/// display font name and size in the font field
- (void)setFontFamilyNameAndSize
//------------------------------------------------------
{
    NSString *name = [[NSUserDefaults standardUserDefaults] stringForKey:CEDefaultFontNameKey];
    CGFloat size = (CGFloat)[[NSUserDefaults standardUserDefaults] doubleForKey:CEDefaultFontSizeKey];
    NSFont *font = [NSFont fontWithName:name size:size];
    NSString *localizedName = [font displayName];
    
    [[self fontField] setStringValue:[NSString stringWithFormat:@"%@ %g", localizedName, size]];
}


//------------------------------------------------------
/// 現在選択されているテーマ名を返す
- (nonnull NSString *)selectedTheme
//------------------------------------------------------
{
    return [self themeNames][[[self themeTableView] selectedRow]];
}


// ------------------------------------------------------
/// テーマ削除確認シートが閉じる直前
- (void)deleteThemeAlertDidEnd:(NSAlert *)alert returnCode:(NSInteger)returnCode contextInfo:(void *)contextInfo
// ------------------------------------------------------
{
    if (returnCode != NSAlertSecondButtonReturn) {  // != Delete
        return;
    }
    
    NSError *error = nil;
    if ([[CEThemeManager sharedManager] removeTheme:[self selectedTheme] error:&error]) {
        AudioServicesPlaySystemSound(CESystemSoundID_MoveToTrash);
    }
    
    if (error) {
        // 削除できなければ、その旨をユーザに通知
        [[alert window] orderOut:self];
        [[[self view] window] makeKeyAndOrderFront:self];
        NSAlert *errorAlert = [NSAlert alertWithError:error];
        NSBeep();
        [errorAlert beginSheetModalForWindow:[[self view] window] modalDelegate:self didEndSelector:NULL contextInfo:NULL];
    }
}


// ------------------------------------------------------
/// テーマ読み込みでの重複するテーマの上書き確認シートが閉じる直前
- (void)importDuplicateThemeAlertDidEnd:(NSAlert *)alert returnCode:(NSInteger)returnCode contextInfo:(void *)contextInfo
// ------------------------------------------------------
{
    if (returnCode != NSAlertSecondButtonReturn) {  // Cancel
        return;
    }
    
    NSURL *URL = CFBridgingRelease(contextInfo);
    NSError *error = nil;
    [[CEThemeManager sharedManager] importTheme:URL replace:YES error:&error];
    
    if (error) {
        NSAlert *alert = [NSAlert alertWithError:error];
        [alert beginSheetModalForWindow:[[self view] window] modalDelegate:nil didEndSelector:NULL contextInfo:NULL];
    }
}


// ------------------------------------------------------
/// テーマのリストを更新
- (void)setupThemeList
// ------------------------------------------------------
{
    [self setThemeNames:[[CEThemeManager sharedManager] themeNames]];
    [[self themeTableView] reloadData];
}

@end
