/*
 
 EditorTextView.swift
 
 CotEditor
 https://coteditor.com
 
 Created by nakamuxu on 2005-03-30.
 
 ------------------------------------------------------------------------------
 
 © 2004-2007 nakamuxu
 © 2014-2016 1024jp
 
 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at
 
 http://www.apache.org/licenses/LICENSE-2.0
 
 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.
 
 */

import Cocoa

extension Notification.Name {
    
    static let TextViewDidBecomeFirstResponder = Notification.Name("TextViewDidBecomeFirstResponder")
}


private let kTextContainerInset = NSSize(width: 0.0, height: 4.0)

private let AutoBalancedClosingBracketAttributeName = "autoBalancedClosingBracket"



// MARK:

final class EditorTextView: NSTextView, Themable {
    
    // MARK: Public Properties
    
    var showsPageGuide = false
    var isAutomaticTabExpansionEnabled = false
    
    var lineHighlightRect: NSRect?
    
    var inlineCommentDelimiter: String?
    var blockCommentDelimiters: BlockDelimiters?
    
    var firstSyntaxCompletionCharacterSet: CharacterSet?
    var needsRecompletion = false
    
    // for Scaling extension
    var initialMagnificationScale: CGFloat = 0
    var deferredMagnification: CGFloat = 0
    
    
    // MARK: Private Properties
    
    private let matchingOpeningBracketsSet = CharacterSet(charactersIn: "[{(\"")
    private let matchingClosingBracketsSet = CharacterSet(charactersIn: "]})")  // ignore "
    
    private var balancesBrackets = false
    private var isAutomaticIndentEnabled = false
    private var isSmartIndentEnabled = false
    
    private var lineHighLightColor: NSColor?
    
    private weak var completionTimer: Timer?
    private var particalCompletionWord: String?
    
    private let observedDefaultKeys: [DefaultKey] = [
        .autoExpandTab,
        .autoIndent,
        .enableSmartIndent,
        .smartInsertAndDelete,
        .balancesBrackets,
        .checkSpellingAsType,
        .pageGuideColumn,
        .enableSmartQuotes,
        .enableSmartDashes,
        .tabWidth,
        .hangingIndentWidth,
        .enablesHangingIndent,
        .autoLinkDetection,
        .fontName,
        .fontSize,
        .shouldAntialias,
        .lineHeight,
        ]
    
    
    
    // MARK:
    // MARK: Lifecycle
    
    required init?(coder: NSCoder) {
        
        let defaults = UserDefaults.standard
        
        self.isAutomaticTabExpansionEnabled = defaults.bool(forKey: DefaultKey.autoExpandTab)
        self.isAutomaticIndentEnabled = defaults.bool(forKey: DefaultKey.autoIndent)
        self.isSmartIndentEnabled = defaults.bool(forKey: DefaultKey.enableSmartIndent)
        self.balancesBrackets = defaults.bool(forKey: DefaultKey.balancesBrackets)
        
        // set paragraph style values
        self.lineHeight = defaults.cgFloat(forKey: DefaultKey.lineHeight)
        self.tabWidth = defaults.integer(forKey: DefaultKey.tabWidth)
        
        self.theme = ThemeManager.shared.theme(name: defaults.string(forKey: DefaultKey.theme)!)
        // -> will be applied first in `viewDidMoveToWindow()`
        
        super.init(coder: coder)
        
        // setup layoutManager and textContainer
        let layoutManager = LayoutManager()
        layoutManager.usesScreenFonts = true
        layoutManager.allowsNonContiguousLayout = true
        self.textContainer!.replaceLayoutManager(layoutManager)
        
        // set layout values
        self.minSize = self.frame.size
        self.maxSize = NSSize.infinite
        self.isHorizontallyResizable = true
        self.isVerticallyResizable = true
        self.textContainerInset = kTextContainerInset
        
        // set NSTextView behaviors
        self.allowsDocumentBackgroundColorChange = false
        self.allowsUndo = true
        self.isRichText = false
        self.importsGraphics = false
        self.usesFindPanel = true
        self.acceptsGlyphInfo = true
        self.linkTextAttributes = [NSCursorAttributeName: NSCursor.pointingHand(),
                                   NSUnderlineStyleAttributeName: NSUnderlineStyle.styleSingle.rawValue]
        
        // setup behaviors
        self.smartInsertDeleteEnabled = defaults.bool(forKey: DefaultKey.smartInsertAndDelete)
        self.isContinuousSpellCheckingEnabled = defaults.bool(forKey: DefaultKey.smartInsertAndDelete)
        self.isAutomaticQuoteSubstitutionEnabled = defaults.bool(forKey: DefaultKey.enableSmartQuotes)
        self.isAutomaticDashSubstitutionEnabled = defaults.bool(forKey: DefaultKey.enableSmartDashes)
        self.isAutomaticDashSubstitutionEnabled = defaults.bool(forKey: DefaultKey.autoLinkDetection)
        
        // set font
        let font: NSFont? = {
            let fontName = defaults.string(forKey: DefaultKey.fontName)!
            let fontSize = defaults.cgFloat(forKey: DefaultKey.fontSize)
            return NSFont(name: fontName, size: fontSize) ?? NSFont.userFont(ofSize: fontSize)
        }()
        super.font = font
        layoutManager.textFont = font
        layoutManager.usesAntialias = defaults.bool(forKey: DefaultKey.shouldAntialias)
        
        self.invalidateDefaultParagraphStyle()
        
        // observe change of defaults
        for key in self.observedDefaultKeys {
            UserDefaults.standard.addObserver(self, forKeyPath: key, options: .new, context: nil)
        }
    }
    
    
    deinit {
        for key in self.observedDefaultKeys {
            UserDefaults.standard.removeObserver(self, forKeyPath: key)
        }
        NotificationCenter.default.removeObserver(self)
        
        self.completionTimer?.invalidate()
    }
    
    
    
    // MARK: Text View Methods
    
    /// post notification about becoming the first responder
    override func becomeFirstResponder() -> Bool {
        
        NotificationCenter.default.post(name: .TextViewDidBecomeFirstResponder, object: self)
        
        return super.becomeFirstResponder()
    }
    
    
    
    /// textView was attached to a window
    override func viewDidMoveToWindow() {
        
        super.viewDidMoveToWindow()
        
        guard let window = self.window else { return }  // do nothing if view was removed from the window
        
        // apply theme to window
        self.applyTheme()
        
        // apply window opacity
        self.didWindowOpacityChange(nil)
        
        // observe window opacity flag
        NotificationCenter.default.addObserver(self, selector: #selector(didWindowOpacityChange),
                                               name: .WindowDidChangeOpacity,
                                               object: window)
    }
    
    
    /// key is pressed
    override func keyDown(with event: NSEvent) {
        
        // perform snippet insertion if not in the middle of Japanese input
        if !self.hasMarkedText(),
            let snippet = SnippetKeyBindingManager.shared.snippet(keyEquivalent: event.charactersIgnoringModifiers,
                                                                  modifierMask: event.modifierFlags)
        {
            if self.shouldChangeText(in: self.rangeForUserTextChange, replacementString: snippet) {
                self.replaceCharacters(in: self.rangeForUserTextChange, with: snippet)
                self.didChangeText()
                self.undoManager?.setActionName(NSLocalizedString("Insert Custom Text", comment: "action name"))
                self.centerSelectionInVisibleArea(self)
            }
            return
        }
        
        super.keyDown(with: event)
    }
    
    
    /// on inputting text (NSTextInputClient Protocol)
    override func insertText(_ string: AnyObject, replacementRange: NSRange) {
        
        // do not use this method for programmatical insertion.
        
        // cast NSAttributedString to String in order to make sure input string is plain-text
        guard let plainString: String = {
            if let attrString = string as? NSAttributedString {
                return attrString.string
            }
            if let string = string as? String {
                return string
            }
            return nil
            }() else {
                return super.insertText(string, replacementRange: replacementRange)
        }
        
        // swap '¥' with '\' if needed
        if UserDefaults.standard.bool(forKey: DefaultKey.swapYenAndBackSlash), plainString.characters.count == 1 {
            if plainString == "\\" {
                return super.insertText("¥", replacementRange: replacementRange)
            } else if plainString == "¥" {
                return super.insertText("\\", replacementRange: replacementRange)
            }
        }
        
        // balance brackets and quotes
        if self.balancesBrackets && replacementRange.length == 0,
            plainString.unicodeScalars.count == 1,
            let firstChar = plainString.unicodeScalars.first, self.matchingOpeningBracketsSet.contains(firstChar)
        {
            // wrap selection with brackets if some text is selected
            if selectedRange().length > 0 {
                let wrappingFormat: String = {
                    switch firstChar {
                    case "[":
                        return "[%@]"
                    case "{":
                        return "{%@}"
                    case "(":
                        return "(%@)"
                    case "\"":
                        return "\"%@\""
                    default:
                        fatalError()
                    }
                }()
                
                let replacementString: String = {
                    if !wrappingFormat.isEmpty, let wholeString = self.string {
                        let selectedString = (wholeString as NSString).substring(with: self.selectedRange())
                        return String(format: wrappingFormat, selectedString)
                    }
                    return ""
                }()
                
                if self.shouldChangeText(in: self.rangeForUserTextChange, replacementString: replacementString) {
                    self.replaceCharacters(in: self.rangeForUserTextChange, with: replacementString)
                    self.didChangeText()
                    return
                }
                
            // check if insertion point is in a word
            } else if !CharacterSet.alphanumerics.contains(self.characterAfterInsertion ?? UnicodeScalar(0)) {
                let pairedBrackets: String = {
                    switch firstChar {
                    case "[":
                        return "[]"
                    case "{":
                        return "{}"
                    case "(":
                        return "()"
                    case "\"":
                        return "\"\""
                    default:
                        return plainString
                    }
                }()
            
                super.insertText(pairedBrackets, replacementRange: replacementRange)
                self.setSelectedRange(NSRange(location: self.selectedRange().location - 1, length: 0))
                
                // set flag
                self.textStorage?.addAttribute(AutoBalancedClosingBracketAttributeName, value: NSNumber.no,
                                               range: NSRange(location: self.selectedRange().location, length: 1))
                
                return
            }
        }
        
        // just move cursor if closed bracket is already typed
        if self.balancesBrackets && replacementRange.length == 0,
            let firstCharacter = plainString.unicodeScalars.first, self.matchingClosingBracketsSet.contains(firstCharacter), firstCharacter == self.characterAfterInsertion {
            if self.textStorage?.attribute(AutoBalancedClosingBracketAttributeName, at: self.selectedRange().location, effectiveRange: nil) as? Bool ?? false {
                self.setSelectedRange(NSRange(location: self.selectedRange().location + 1, length: 0))
                return
            }
        }
        
        // smart outdent with '}' charcter
        if self.isAutomaticIndentEnabled && self.isSmartIndentEnabled &&
            replacementRange.length == 0 && plainString == "}",
            let wholeString = self.string,
            let insretionIndex = String.UTF16Index(self.selectedRange().max).samePosition(in: wholeString)
        {
            let lineRange = wholeString.lineRange(at: insretionIndex)
            
            // decrease indent level if the line is consists of only whitespaces
            if wholeString.range(of: "^[ \\t]+\\n?$", options: .regularExpression, range: lineRange) != nil {
                // find correspondent opening-brace
                var precedingIndex = wholeString.index(before: insretionIndex)
                var skipMatchingBrace = 0
                
                braceLoop: while skipMatchingBrace > 0 {
                    let characterToCheck = wholeString.characters[precedingIndex]
                    switch characterToCheck {
                    case "{":
                        guard skipMatchingBrace > 0 else { break braceLoop }  // found
                        skipMatchingBrace -= 1
                    case "}":
                        skipMatchingBrace += 1
                    default: break
                    }
                    precedingIndex = wholeString.index(before: insretionIndex)
                }
                
                // outdent
                if precedingIndex != wholeString.startIndex {
                    let desiredLevel = wholeString.indentLevel(at: precedingIndex, tabWidth: self.tabWidth)
                    let currentLevel = wholeString.indentLevel(at: insretionIndex, tabWidth: self.tabWidth)
                    let levelToReduce = currentLevel - desiredLevel
                    
                    for _ in 0..<levelToReduce {
                        self.deleteBackward(self)
                    }
                }
            }
        }
        
        super.insertText(plainString, replacementRange: replacementRange)
        
        // auto completion
        if UserDefaults.standard.bool(forKey: DefaultKey.autoComplete) {
            let delay: TimeInterval = UserDefaults.standard.double(forKey: DefaultKey.autoCompletionDelay)
            self.complete(after: delay)
        }
    }
    
    
    /// insert tab & expand tab
    override func insertTab(_ sender: AnyObject?) {
        
        if self.isAutomaticTabExpansionEnabled, let string = self.string {
            let tabWidth = self.tabWidth
            let column = string.column(of: self.rangeForUserTextChange.location, tabWidth: tabWidth)
            let length = tabWidth - (column % tabWidth)
            let spaces = String(repeating: Character(" "), count: length)
            
            return super.insertText(spaces, replacementRange: self.rangeForUserTextChange)
        }
        
        super.insertTab(sender)
    }
    
    
    /// insert new line & perform auto-indent
    override func insertNewline(_ sender: AnyObject?) {
        
        guard let string = self.string, self.isAutomaticIndentEnabled else {
            return super.insertNewline(sender)
        }
        
        let selectedRange = self.selectedRange()
        let indentRange = string.rangeOfIndent(at: selectedRange.location)
        
        // don't auto-indent if indent is selected (2008-12-13)
        guard selectedRange != indentRange else {
            return super.insertNewline(sender)
        }
        
        let indent: String = {
            if indentRange.location != NSNotFound {
                let baseIndentRange = NSIntersectionRange(indentRange, NSRange(location: 0, length: selectedRange.location))
                return (string as NSString).substring(with: baseIndentRange)
            }
            return ""
        }()
        
        // calculation for smart indent
        var shouldIncreaseIndentLevel = false
        var shouldExpandBlock = false
        if self.isSmartIndentEnabled {
            let lastChar = self.characterBeforeInsertion
            let nextChar = self.characterAfterInsertion
            
            // expand idnent block if returned inside `{}`
            shouldExpandBlock = (lastChar == "{" && nextChar == "}")
            
            // increace font indent level if the character just before the return is `:` or `{`
            shouldIncreaseIndentLevel = (lastChar == ":" || lastChar == "{")
        }
        
        super.insertNewline(sender)
        
        // auto indent
        if !indent.isEmpty {
            super.insertText(indent, replacementRange: self.rangeForUserTextChange)
        }
        
        // smart indent
        if shouldExpandBlock {
            self.insertTab(sender)
            let selection = self.selectedRange()
            super.insertNewline(sender)
            super.insertText(indent, replacementRange: self.rangeForUserTextChange)
            self.setSelectedRange(selection)
            
        } else if shouldIncreaseIndentLevel {
            self.insertTab(sender)
        }
    }
    
    
    /// delete & adjust indent
    override func deleteBackward(_ sender: AnyObject?) {
        
        defer {
            super.deleteBackward(sender)
        }
        
        guard let string = self.string, self.selectedRange().length == 0 else { return }
        
        let selectedRange = self.selectedRange()
        
        // delete tab
        if self.isAutomaticTabExpansionEnabled {
            let indentRange = string.rangeOfIndent(at: selectedRange.location)
            
            if selectedRange.location <= indentRange.max {
                let tabWidth = self.tabWidth
                let column = string.column(of: selectedRange.location, tabWidth: tabWidth)
                let targetLength = tabWidth - (column % tabWidth)
                
                if selectedRange.location >= targetLength {
                    let targetRange = NSRange(location: selectedRange.location - targetLength, length: targetLength)
                    if (string as NSString).substring(with: targetRange) == String(repeating: " ", targetLength) {
                        self.setSelectedRange(targetRange)
                    }
                }
            }
        }
        
        // balance brackets
        if self.balancesBrackets, selectedRange.location > 0,
            let characterBeforeInsertion = self.characterBeforeInsertion,
            selectedRange.location < string.utf16.count && matchingOpeningBracketsSet.contains(characterBeforeInsertion)
        {
            let targetRange = NSRange(location: selectedRange.location - 1, length: 2)
            let surroundingCharacters = (string as NSString).substring(with: targetRange)
            
            if ["{}", "[]", "()", "\"\""].contains(surroundingCharacters) {
                self.setSelectedRange(targetRange)
            }
        }
    }
    
    
    /// customize context menu
    override func menu(for event: NSEvent) -> NSMenu? {
        
        guard let menu = super.menu(for: event) else { return nil }
        
        // remove unwanted "Font" menu and its submenus
        if let fontMenuItem = menu.item(withTitle: NSLocalizedString("Font", comment: "menu item title in the context menu")) {
            menu.removeItem(fontMenuItem)
        }
        
        // add "Inspect Character" menu item if single character is selected
        if (self.string as NSString?)?.substring(with: self.selectedRange()).numberOfComposedCharacters == 1 {
            menu.insertItem(withTitle: NSLocalizedString("Inspect Character", comment: ""),
                            action: #selector(showSelectionInfo(_:)),
                            keyEquivalent: "",
                            at: 1)
        }
        
        // add "Copy as Rich Text" menu item
        let copyIndex = menu.indexOfItem(withTarget: nil, andAction: #selector(copy(_:)))
        if copyIndex >= 0 {  // -1 == not found
            menu.insertItem(withTitle: NSLocalizedString("Copy as Rich Text", comment: ""),
                            action: #selector(copyWithStyle(_:)),
                            keyEquivalent: "",
                            at: copyIndex + 1)
        }
        
        // add "Select All" menu item
        let pasteIndex = menu.indexOfItem(withTarget: nil, andAction: #selector(paste(_:)))
        if pasteIndex >= 0 {  // -1 == not found
            menu.insertItem(withTitle: NSLocalizedString("Select All", comment: ""),
                            action: #selector(selectAll(_:)),
                            keyEquivalent: "",
                            at: pasteIndex + 1)
        }
        
        return menu
    }
    
    
    /// text font
    override var font: NSFont? {
        
        get {
            // make sure to return by user defined font
            return (self.layoutManager as? LayoutManager)?.textFont ?? super.font
        }
        
        set (font) {
            guard let font = font else { return }
            
            // 複合フォントで行間が等間隔でなくなる問題を回避するため、LayoutManager にもフォントを持たせておく
            // -> [NSTextView font] を使うと、「1バイトフォントを指定して日本語が入力されている」場合に
            //    日本語フォントを返してくることがあるため、LayoutManager からは [textView font] を使わない
            (self.layoutManager as? LayoutManager)?.textFont = font
            
            super.font = font
            
            self.invalidateDefaultParagraphStyle()
        }
    }
    
    
    /// change font via font panel
    override func changeFont(_ sender: AnyObject?) {
        
        guard let manager = sender as? NSFontManager else { return }
        
        guard let currentFont = self.font, let textStorage = self.textStorage else { return }
        
        let font = manager.convert(currentFont)
        
        // apply to all text views sharing textStorage
        for layoutManager in textStorage.layoutManagers {
            layoutManager.firstTextView?.font = font
        }
    }
    
    
    /// draw background
    override func drawBackground(in rect: NSRect) {
        
        super.drawBackground(in: rect)
        
        // draw current line highlight
        if let highlightColor = self.lineHighLightColor,
            let highlightRect = self.lineHighlightRect,
            rect.intersects(highlightRect)
        {
            NSGraphicsContext.saveGraphicsState()
            
            highlightColor.setFill()
            NSBezierPath.fill(highlightRect)
            
            NSGraphicsContext.restoreGraphicsState()
        }
    }
    
    /// draw view
    override func draw(_ dirtyRect: NSRect) {
        
        super.draw(dirtyRect)
        
        // draw page guide
        if self.showsPageGuide,
            let textColor = self.textColor,
            let spaceWidth = (self.layoutManager as? LayoutManager)?.spaceWidth
        {
            let column = UserDefaults.standard.cgFloat(forKey: .pageGuideColumn)
            let inset = self.textContainerOrigin.x
            let linePadding = self.textContainer?.lineFragmentPadding ?? 0
            let x = floor(spaceWidth * column + inset + linePadding) + 2.5  // +2px for an esthetic adjustment
            
            NSGraphicsContext.saveGraphicsState()
            
            textColor.withAlphaComponent(0.2).setStroke()
            NSBezierPath.strokeLine(from: NSPoint(x: x, y: dirtyRect.minY),
                                    to: NSPoint(x: x, y: dirtyRect.maxY))
            
            NSGraphicsContext.restoreGraphicsState()
        }
    }
    
    /// scroll to display specific range
    override func scrollRangeToVisible(_ range: NSRange) {
        
        // scroll line by line if an arrow key is pressed
        if NSEvent.modifierFlags().contains(NSNumericPadKeyMask),
            let layoutManager = self.layoutManager,
            let textContainer = self.textContainer
        {
            let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var glyphRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            glyphRect = glyphRect.offsetBy(dx: self.textContainerOrigin.x, dy: self.textContainerOrigin.y)
            
            super.scrollToVisible(glyphRect)  // move minimum distance
            return
        }
        
        super.scrollRangeToVisible(range)
    }
    
    
    /// change text layout orientation
    override func setLayoutOrientation(_ orientation: NSTextLayoutOrientation) {
        
        // reset text wrapping
        if orientation != self.layoutOrientation && self.wrapsLines {
            self.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        }
        
        super.setLayoutOrientation(orientation)
        
        // enable non-contiguous layout only on normal horizontal layout (2016-06 on OS X 10.11 El Capitan)
        //  -> Otherwise by vertical layout, the view scrolls occasionally to a strange position on typing.
        self.layoutManager?.allowsNonContiguousLayout = (orientation == .horizontal)
    }
    
    
    /// read pasted/dropped item from NSPaseboard (involed in `performDragOperation(_:)`)
    override func readSelection(from pboard: NSPasteboard, type: String) -> Bool {
        
        // apply link to pasted string
        DispatchQueue.main.async {
            self.detectLinkIfNeeded()
        }
        
        // on file drop
        if let filePaths = pboard.propertyList(forType: NSFilenamesPboardType) as? [String] {
            let documentURL = self.document?.fileURL
            var replacementString = ""
            
            for path in filePaths {
                let url = URL(fileURLWithPath: path)
                if let dropText = FileDropComposer.dropText(forFileURL: url, documentURL: documentURL) {
                    replacementString += dropText
                    
                } else {
                    // jsut insert the absolute path if no specific setting for the file type was found
                    // -> This is the default behavior of NSTextView by file dropping.
                    if !replacementString.isEmpty {
                        replacementString += "\n"
                    }
                    replacementString.append(path)
                }
            }
            
            // insert drop text to view
            if self.shouldChangeText(in: self.rangeForUserTextChange, replacementString: replacementString) {
                self.replaceCharacters(in: self.rangeForUserTextChange, with: replacementString)
                self.didChangeText()
                return true
            }
        }
        
        return super.readSelection(from: pboard, type: type)
    }
    
    
    /// Pasetboard 内文字列の改行コードを書類に設定されたものに置換する
    override func writeSelection(to pboard: NSPasteboard, types: [String]) -> Bool {
        
    let success = super.writeSelection(to: pboard, types: types)
        
        guard let lineEnding = self.documentLineEnding, lineEnding == .LF else { return success }
        
        for type in types {
            guard let string = pboard.string(forType: type) else { continue }
            
            pboard.setString(string.replacingLineEndings(with: lineEnding), forType: type)
        }
        
        return success
    }
    
    
    /// update font panel to set current font
    override func updateFontPanel() {
        
        // フォントのみをフォントパネルに渡す
        // -> super にやらせると、テキストカラーもフォントパネルに送り、フォントパネルがさらにカラーパネル（= カラーコードパネル）にそのテキストカラーを渡すので、
        // それを断つために自分で渡す
        guard let font = self.font else { return }
        
        NSFontManager.shared().setSelectedFont(font, isMultiple: false)
    }
    
    
    /// let line number view update
    override func updateRuler() {
        
        (self.enclosingScrollView as? EditorScrollView)?.invalidateLineNumber()
    }
    
    
    
    // MARK: KVO
    
    /// apply change of user setting
    override func observeValue(forKeyPath keyPath: String?, of object: AnyObject?, change: [NSKeyValueChangeKey : AnyObject]?, context: UnsafeMutablePointer<Void>?) {
        
        guard let keyPath = keyPath, let newValue = change?[.newKey] else { return }
        
        switch DefaultKey(keyPath) {
        case DefaultKey.autoExpandTab:
            self.isAutomaticTabExpansionEnabled = newValue as! Bool
            
        case DefaultKey.autoIndent:
            self.isAutomaticIndentEnabled = newValue as! Bool
            
        case DefaultKey.enableSmartIndent:
            self.isSmartIndentEnabled = newValue as! Bool
            
        case DefaultKey.balancesBrackets:
            self.balancesBrackets = newValue as! Bool
            
        case DefaultKey.shouldAntialias:
            self.usesAntialias = newValue as! Bool
            
        case DefaultKey.smartInsertAndDelete:
            self.smartInsertDeleteEnabled = newValue as! Bool
            
        case DefaultKey.enableSmartQuotes:
            self.isAutomaticQuoteSubstitutionEnabled = newValue as! Bool
            
        case DefaultKey.enableSmartDashes:
            self.isAutomaticDashSubstitutionEnabled = newValue as! Bool
            
        case DefaultKey.checkSpellingAsType:
            self.isContinuousSpellCheckingEnabled = newValue as! Bool
            
        case DefaultKey.autoLinkDetection:
            self.isAutomaticLinkDetectionEnabled = newValue as! Bool
            if isAutomaticLinkDetectionEnabled {
                self.detectLinkIfNeeded()
            } else {
                if let textStorage = self.textStorage {
                    textStorage.removeAttribute(NSLinkAttributeName, range: textStorage.string.nsRange)
                }
            }
            
        case DefaultKey.pageGuideColumn:
            self.setNeedsDisplay(self.visibleRect, avoidAdditionalLayout: true)
            
        case DefaultKey.tabWidth:
            self.tabWidth = newValue as! Int
            
        case DefaultKey.lineHeight:
            self.lineHeight = newValue as! CGFloat
            
            // reset visible area
            self.centerSelectionInVisibleArea(self)
            
        case DefaultKey.enablesHangingIndent, DefaultKey.hangingIndentWidth:
            if let textStorage = self.textStorage {
                let wholeRange = textStorage.string.nsRange
                if keyPath == DefaultKey.enablesHangingIndent && !(newValue as! Bool) {
                    textStorage.addAttribute(NSParagraphStyleAttributeName, value: self.defaultParagraphStyle!, range: wholeRange)
                } else {
                    (self.layoutManager as? LayoutManager)?.invalidateIndent(in: wholeRange)
                }
            }
            
        default: break
        }
    }
    
    
    // MARK: Protocol
    
    /// apply current state to related menu items
    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        
        guard let action = menuItem.action else { return false }
        
        switch action {
        case #selector(copyWithStyle),
             #selector(exchangeFullwidthRoman),
             #selector(exchangeHalfwidthRoman),
             #selector(exchangeKatakana),
             #selector(exchangeHiragana),
             #selector(normalizeUnicodeWithNFD),
             #selector(normalizeUnicodeWithNFC),
             #selector(normalizeUnicodeWithNFKD),
             #selector(normalizeUnicodeWithNFKC),
             #selector(normalizeUnicodeWithNFKCCF),
             #selector(normalizeUnicodeWithModifiedNFC),
             #selector(normalizeUnicodeWithModifiedNFD):
            return self.selectedRange().length > 0
            // -> The color code panel is always valid.
            
        case #selector(showSelectionInfo):
            let selection = (self.string as NSString?)?.substring(with: self.selectedRange())
            return selection?.numberOfComposedCharacters == 1
            
        case #selector(toggleComment):
            let canComment = self.canUncomment(range: self.selectedRange(), partly: false)
            let title = canComment ? "Uncomment" : "Comment Out"
            menuItem.title = NSLocalizedString(title, comment: "")
            return (self.inlineCommentDelimiter != nil) || (self.blockCommentDelimiters != nil)
            
        case #selector(inlineCommentOut):
            return (self.inlineCommentDelimiter != nil)
            
        case #selector(blockCommentOut):
            return (self.blockCommentDelimiters != nil)
            
        case #selector(uncomment(_:)):
            return self.canUncomment(range: self.selectedRange(), partly: true)
            
        default: break
        }
        
        return super.validateMenuItem(menuItem)
    }
    
    
    /// apply current state to related toolbar items
    override func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        
        guard let action = item.action else { return false }
        
        switch action {
        case #selector(toggleComment):
            return (self.inlineCommentDelimiter != nil) || (self.blockCommentDelimiters != nil)
            
        default: break
        }
        
        return true
    }
    
    
    
    // MARK: Public Accessors
    
    /// coloring settings
    var theme: Theme? {
        
        didSet {
            self.applyTheme()
        }
    }
    
    
    /// tab width in number of spaces
    var tabWidth: Int {
        
        didSet {
            if tabWidth == 0 {
                tabWidth = oldValue
            }
            guard tabWidth != oldValue else { return }
            
            // apply to view
            self.invalidateDefaultParagraphStyle()
        }
    }
    
    
    /// line height multiple
    var lineHeight: CGFloat {
        
        didSet {
            if lineHeight == 0 {
                lineHeight = oldValue
            }
            guard lineHeight != oldValue else { return }
            
            // apply to view
            self.invalidateDefaultParagraphStyle()
        }
    }
    
    /// whether text is antialiased
    var usesAntialias: Bool {
        
        get {
            return (self.layoutManager as? LayoutManager)?.usesAntialias ?? true
        }
        set {
            (self.layoutManager as? LayoutManager)?.usesAntialias = newValue
            self.setNeedsDisplay(self.visibleRect, avoidAdditionalLayout: true)
        }
    }
    
    
    /// whether invisible characters are shown
    var showsInvisibles: Bool {
        
        get {
            return (self.layoutManager as? LayoutManager)?.showsInvisibles ?? false
        }
        set {
            (self.layoutManager as? LayoutManager)?.showsInvisibles = newValue
        }
    }
    
    
    
    // MARK: Public Methods
    
    /// invalidate string attributes
    func invalidateStyle() {
        
        guard let textStorage = self.textStorage else { return }
        
        let range = textStorage.string.nsRange
        
        guard range.length > 0 else { return }
        
        textStorage.addAttributes(self.typingAttributes, range: range)
        (self.layoutManager as? LayoutManager?)??.invalidateIndent(in: range)
        self.detectLinkIfNeeded()
    }
    
    
    
    // MARK: Action Messages
    
    /// copy selection with syntax highlight and font style
    @IBAction func copyWithStyle(_ sender: AnyObject?) {
        
        guard let string = self.string, self.selectedRange().length > 0 else {
            NSBeep()
            return
        }
        
        var selections = [NSAttributedString]()
        var propertyList = [NSNumber]()
        let lineEnding = String((self.documentLineEnding ?? .LF).rawValue)
        
        // substring all selected attributed strings
        let selectedRanges = self.selectedRanges as! [NSRange]
        for selectedRange in selectedRanges {
            let plainText = (string as NSString).substring(with: selectedRange)
            let styledText = NSMutableAttributedString(string: plainText, attributes: self.typingAttributes)
            
            // apply syntax highlight that is set as temporary attributes in layout manager to attributed string
            if let layoutManager = self.layoutManager {
                var characterIndex = selectedRange.location
                while characterIndex < selectedRange.max {
                    var effectiveRange = NSRange.notFound
                    guard let color = layoutManager.temporaryAttribute(NSForegroundColorAttributeName,
                                                                       atCharacterIndex: characterIndex,
                                                                       longestEffectiveRange: &effectiveRange,
                                                                       in: selectedRange) else
                    {
                        characterIndex += 1
                        continue
                    }
                    
                    let localRange = NSRange(location: effectiveRange.location - selectedRange.location, length: effectiveRange.length)
                    styledText.addAttribute(NSForegroundColorAttributeName, value: color, range: localRange)
                    
                    characterIndex = effectiveRange.max
                }
            }
            
            // apply document's line ending
            if self.documentLineEnding != .LF {
                for characterIndex in (0...plainText.utf16.count).reversed() {  // process backwards
                    if (plainText as NSString).character(at: characterIndex) == "\n".utf16.first! {
                        let characterRange = NSRange(location: characterIndex, length: 1)
                        styledText.replaceCharacters(in: characterRange, with: lineEnding)
                    }
                }
            }
            
            selections.append(styledText)
            propertyList.append(NSNumber(value: plainText.components(separatedBy: "\n").count))
        }
        
        var pasteboardString = NSAttributedString()
        
        // join attributed strings
        let attrLineEnding = NSAttributedString(string: lineEnding)
        for selection in selections {
            // join with newline string
            if !pasteboardString.string.isEmpty {
                pasteboardString = pasteboardString + attrLineEnding
            }
            pasteboardString = pasteboardString + selection
        }
        
        // set to paste board
        let pboard = NSPasteboard.general()
        pboard.clearContents()
        pboard.declareTypes(self.writablePasteboardTypes, owner: nil)
        if pboard.canReadItem(withDataConformingToTypes: [NSPasteboardTypeMultipleTextSelection]) {
            pboard.setPropertyList(propertyList, forType: NSPasteboardTypeMultipleTextSelection)
        }
        pboard.writeObjects([pasteboardString])
    }
    
    
    /// input an Yen sign (¥)
    @IBAction func inputYenMark(_ sender: AnyObject?) {
        
        super.insertText("¥", replacementRange: self.rangeForUserTextChange)
    }
    
    
    ///input a backslash (/)
    @IBAction func inputBackSlash(_ sender: AnyObject?) {
        
        super.insertText("\\", replacementRange: self.rangeForUserTextChange)
    }
    
    
    /// display character information by popover
    @IBAction func showSelectionInfo(_ sender: AnyObject?) {
        
        guard var selectedString = (self.string as NSString?)?.substring(with: self.selectedRange()) else { return }
        
        // apply document's line ending
        if let documentLineEnding = self.documentLineEnding,
            documentLineEnding != .LF && selectedString.detectedLineEnding == .LF
        {
            selectedString = selectedString.replacingLineEndings(with: documentLineEnding)
        }
        
        guard let popoverController = CharacterPopoverController(character: selectedString),
            var selectedRect = self.overlayRect(range: self.selectedRange()) else { return }
        
        selectedRect.origin.y -= 4
        popoverController.showPopover(relativeTo: selectedRect, of: self)
        self.showFindIndicator(for: self.selectedRange())
    }
    
    
    
    // MARK: Notification
    
    /// window's opacity did change
    func didWindowOpacityChange(_ notification: Notification?) {
        
        let isOpaque = self.window?.isOpaque ?? true
        
        // let text view have own background if possible
        self.drawsBackground = isOpaque
        
        // redraw visible area
        self.setNeedsDisplay(self.visibleRect, avoidAdditionalLayout: true)
    }
    
    
    
    // MARK: Private Methods
    
    /// document object representing the text view contents
    private var document: Document? {
        
        return self.window?.windowController?.document as? Document
    }
    
    
    /// true new line type of document
    private var documentLineEnding: LineEnding? {
        
        return self.document?.lineEnding
    }
    
    
    /// update coloring settings
    private func applyTheme() {
        
        guard let theme = self.theme else { return }
        
        self.window?.backgroundColor = theme.backgroundColor
        
        self.backgroundColor = theme.backgroundColor
        self.textColor = theme.textColor
        self.lineHighLightColor = theme.lineHighLightColor
        self.insertionPointColor = theme.insertionPointColor
        self.selectedTextAttributes = [NSBackgroundColorAttributeName: theme.selectionColor]
        
        (self.layoutManager as? LayoutManager)?.invisiblesColor = theme.invisiblesColor
        
        // set scroller color considering background color
        self.enclosingScrollView?.scrollerKnobStyle = theme.isDarkTheme ? .light : .default
        
        self.setNeedsDisplay(self.visibleRect, avoidAdditionalLayout: true)
    }
    
    
    /// set defaultParagraphStyle based on font, tab width, and line height
    private func invalidateDefaultParagraphStyle() {
        
        let paragraphStyle = NSParagraphStyle.default().mutableCopy() as! NSMutableParagraphStyle
        
        // set line height
        //   -> The actual line height will be calculated in LayoutManager and ATSTypesetter based on this line height multiple.
        //      Because the default Cocoa Text System calculate line height differently
        //      if the first character of the document is drawn with another font (typically by a composite font).
        paragraphStyle.lineHeightMultiple = self.lineHeight
        
        // calculate tab interval
        if let font = self.font, let displayFont = self.layoutManager?.substituteFont(for: font) {
            paragraphStyle.tabStops = []
            paragraphStyle.defaultTabInterval = CGFloat(self.tabWidth) * displayFont.advancement(character: " ").width
        }
        
        self.defaultParagraphStyle = paragraphStyle
        
        // add paragraph style also to the typing attributes
        //   -> textColor and font are added automatically.
        self.typingAttributes[NSParagraphStyleAttributeName] = paragraphStyle
        
        // tell line height also to scroll view so that scroll view can scroll line by line
        if let lineHeight = (self.layoutManager as? LayoutManager)?.lineHeight {
            self.enclosingScrollView?.lineScroll = lineHeight
        }
        
        // apply new style to current text
        self.invalidateStyle()
    }
    
    
    /// make link-like text clickable
    private func detectLinkIfNeeded() {
        
        guard self.isAutomaticLinkDetectionEnabled else { return }
        
        self.undoManager?.disableUndoRegistration()
        
        let currentCheckingType = self.enabledTextCheckingTypes
        self.enabledTextCheckingTypes = NSTextCheckingResult.CheckingType.link.rawValue
        self.checkTextInDocument(nil)
        self.enabledTextCheckingTypes = currentCheckingType
        
        self.undoManager?.enableUndoRegistration()
    }
    
}



private extension NSTextView {
    
    /// character just before the insertion or 0
    var characterBeforeInsertion: UnicodeScalar? {
        
        guard let string = self.string else { return nil }
        
        let location = self.selectedRange().location - 1
        
        guard location >= 0 else { return nil }
        
        guard let index = string.utf16.index(string.utf16.startIndex, offsetBy: location).samePosition(in: string.unicodeScalars) else { return nil }
        
        return string.unicodeScalars[safe: index]
    }
    
    
    /// character just after the insertion
    var characterAfterInsertion: UnicodeScalar? {
        
        guard let string = self.string else { return nil }
        
        let location = self.selectedRange().max
        guard let index = string.utf16.index(string.utf16.startIndex, offsetBy: location).samePosition(in: string.unicodeScalars) else { return nil }
        
        return string.unicodeScalars[safe: index]
    }
    
    
    /// rect for given character range
    func overlayRect(range: NSRange) -> NSRect? {
        
        guard
            let layoutManager = self.layoutManager,
            let textContainer = self.textContainer else { return nil }
        
        let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        let containerOrigin = self.textContainerOrigin
        
        rect.origin.x += containerOrigin.x
        rect.origin.y += containerOrigin.y
        
        return self.convertToLayer(rect)
    }
    
}



// MARK: - Word Completion

extension EditorTextView {
    
    // MARK: Text View Methods
    
    /// return range for word completion
    override var rangeForUserCompletion: NSRange {
        
        let range = super.rangeForUserCompletion
        
        guard let characterSet = self.firstSyntaxCompletionCharacterSet,
            let string = self.string, !string.isEmpty else { return range }
        
        // 入力補完文字列の先頭となりえない文字が出てくるまで補完文字列対象を広げる
        var begin = range.location
        while begin > 0 && characterSet.contains(UnicodeScalar((string as NSString).character(at: begin - 1))) {
            begin -= 1
        }
        
        return NSRange(location: begin, length: range.max - begin)
    }
    
    
    /// display completion candidate and list
    override func insertCompletion(_ word: String, forPartialWordRange charRange: NSRange, movement: Int, isFinal flag: Bool) {
        
        self.completionTimer?.invalidate()
        
        guard let string = self.string else { return }
        
        let event = self.window?.currentEvent
        var didComplete = false
        
        var newMovement = movement
        var newFlag = flag
        var newWord = word
        
        // store original string
        if self.particalCompletionWord == nil {
            self.particalCompletionWord = (string as NSString).substring(with: charRange)
        }
        
        // raise frag to proceed word completion again, if a normal key input is performed during displaying the completion list
        //   -> The flag will be used in EditorTextViewController > `textDidChange`
        if flag, let event = event, event.type == .keyDown && !event.modifierFlags.contains(.command) {
            let inputChar = event.charactersIgnoringModifiers
            let character = inputChar?.utf16.first
            
            if inputChar == event.characters {  // exclude key-bindings
                // fix that underscore is treated as the right arrow key
                if inputChar == "_" && movement == NSRightTextMovement {
                    newMovement = NSIllegalTextMovement
                    newFlag = false
                }
                if movement == NSIllegalTextMovement && character < 0xF700 && character != UInt16(NSDeleteCharacter) {  // standard key-input
                    self.needsRecompletion = true
                }
            }
        }
        
        if newFlag {
            if newMovement == NSIllegalTextMovement || newMovement == NSRightTextMovement {  // treat as cancelled
                // restore original input
                //   -> In case if the letter case is changed from the original.
                if let originalWord = self.particalCompletionWord {
                    newWord = originalWord
                }
            } else {
                didComplete = true
            }
            
            // discard stored orignal word
            self.particalCompletionWord = nil
        }
        
        super.insertCompletion(newWord, forPartialWordRange: charRange, movement: newMovement, isFinal: newFlag)
        
        if didComplete {
            // slect inside of "()" if completion word has ()
            var rangeToSelect = (newWord as NSString).range(of: "(?<=\\().*(?=\\))", options: .regularExpression)
            if rangeToSelect.location != NSNotFound {
                rangeToSelect.location += charRange.location
                self.setSelectedRange(rangeToSelect)
            }
        }
    }
    
    
    
    // MARK: Public Methods
    
    /// display word completion list with a delay
    func complete(after delay: TimeInterval) {
        
        if let timer = self.completionTimer, timer.isValid {
            timer.fireDate = Date(timeIntervalSinceNow: delay)
        } else {
            self.completionTimer = Timer.scheduledTimer(timeInterval: delay,
                                                        target: self,
                                                        selector: #selector(completion(timer:)),
                                                        userInfo: nil,
                                                        repeats: false)
        }
    }
    
    
    
    // MARK: Private Methods
    
    /// display word completion list
    func completion(timer: Timer) {
        
        self.completionTimer?.invalidate()
        
        // abord if:
        guard !self.hasMarkedText(),  // input is not specified (for Japanese input)
            self.selectedRange().length == 0,  // selected
            let nextCharacter = self.characterAfterInsertion, !CharacterSet.alphanumerics.contains(nextCharacter),  // caret is (probably) at the middle of a word
            let lastCharacter = self.characterBeforeInsertion, !CharacterSet.whitespacesAndNewlines.contains(lastCharacter)  // previous character is blank
            else { return }
        
        self.complete(self)
    }
    
}



// MARK: - Word Selection

extension EditorTextView {
    
    // MARK: Text View Methods
    
    /// adjust word selection range
    override func selectionRange(forProposedRange proposedCharRange: NSRange, granularity: NSSelectionGranularity) -> NSRange {
        
        // This method is partly based on Smultron's SMLTextView by Peter Borg (2006-09-09)
        // Smultron 2 was distributed on <http://smultron.sourceforge.net> under the terms of the BSD license.
        // Copyright (c) 2004-2006 Peter Borg
        
        let range = super.selectionRange(forProposedRange: proposedCharRange, granularity: granularity)
        
        guard let string = self.string, granularity == .selectByWord, string.utf16.count != proposedCharRange.location else {
            return range
        }
        
        var wordRange = range
        
        // treat additional specific chars as separator (see `wordRange(at:)` for details)
        if wordRange.length > 0 {
            wordRange = self.wordRange(at: proposedCharRange.location)
            if proposedCharRange.length > 1 {
                wordRange = NSUnionRange(wordRange, self.wordRange(at: proposedCharRange.max - 1))
            }
        }
        
        // settle result on expanding selection or if there is no possibility for clicking brackets
        guard proposedCharRange.length == 0 && wordRange.length == 1 else { return wordRange }
        
        let characterIndex = String.UTF16Index(wordRange.location).samePosition(in: string)!
        let clickedCharacter = string.characters[characterIndex]
        
        // select (syntax-highlighted) quoted text by double-clicking
        if clickedCharacter == "\"" || clickedCharacter == "'" || clickedCharacter == "`" {
            var highlightRange = NSRange.notFound
            _ = self.layoutManager?.temporaryAttribute(NSForegroundColorAttributeName, atCharacterIndex: wordRange.location, longestEffectiveRange: &highlightRange, in: string.nsRange)
            
            let highlightCharacterRange = string.range(from: highlightRange)!
            let firstHighlightIndex = highlightCharacterRange.lowerBound
            let lastHighlightIndex = string.index(before: highlightCharacterRange.upperBound)
            
            if (firstHighlightIndex == characterIndex && string.characters[firstHighlightIndex] == clickedCharacter) ||  // smart quote
                (lastHighlightIndex == characterIndex && string.characters[lastHighlightIndex] == clickedCharacter)  // end quote
            {
                return highlightRange
            }
        }
        
        // select inside of brackets by double-clicking
        var braces: (begin: Character, end: Character)
        var isEndBrace: Bool
        switch clickedCharacter {
        case "(":
            braces = (begin: "(", end: ")")
            isEndBrace = false
        case ")":
            braces = (begin: "(", end: ")")
            isEndBrace = true
            
        case "{":
            braces = (begin: "{", end: "}")
            isEndBrace = false
        case "}":
            braces = (begin: "{", end: "}")
            isEndBrace = true
            
        case "[":
            braces = (begin: "[", end: "]")
            isEndBrace = false
        case "]":
            braces = (begin: "[", end: "]")
            isEndBrace = true
            
        case "<":
            braces = (begin: "<", end: ">")
            isEndBrace = false
        case ">":
            braces = (begin: "<", end: ">")
            isEndBrace = true
            
        default:
            return wordRange
        }
        
        var index = characterIndex
        var skippedBraceCount = 0
        
        if isEndBrace {
            while index > string.startIndex {
                index = string.index(before: index)
                
                switch string.characters[index] {
                case braces.begin:
                    guard skippedBraceCount > 0 else {
                        let location = index.samePosition(in: string.utf16).distance(to: string.utf16.startIndex)
                        return NSRange(location: location, length: wordRange.location - location + 1)
                    }
                    skippedBraceCount -= 1
                    
                case braces.end:
                    skippedBraceCount += 1
                    
                default: break
                }
            }
        } else {
            while index < string.endIndex {
                index = string.index(after: index)
                
                switch string.characters[index] {
                case braces.end:
                    guard skippedBraceCount > 0 else {
                        let location = index.samePosition(in: string.utf16).distance(to: string.utf16.startIndex)
                        return NSRange(location: wordRange.location, length: location - wordRange.location + 1)
                    }
                    skippedBraceCount -= 1
                    
                case braces.begin:
                    skippedBraceCount += 1
                    
                default: break
                }
            }
        }
        NSBeep()
        
        // If it has a found a "starting" brace but not found a match, a double-click should only select the "starting" brace and not what it usually would select at a double-click
        return super.selectionRange(forProposedRange: NSRange(location: proposedCharRange.location, length: 1), granularity: .selectByCharacter)
    }
    
    
    
    // MARK: Private Methods
    
    /// word range includes location
    private func wordRange(at location: Int) -> NSRange {
        
        let proposedWordRange = super.selectionRange(forProposedRange: NSRange(location: location, length: 0), granularity: .selectByWord)
        
        guard proposedWordRange.length > 1, let string = self.string else { return proposedWordRange }
        
        var wordRange = proposedWordRange
        let word = (string as NSString).substring(with: proposedWordRange)
        let scanner = Scanner(string: word)
        let breakCharacterSet = CharacterSet(charactersIn: ".:")
        
        while scanner.scanUpToCharacters(from: breakCharacterSet, into: nil) {
            let breakLocation = scanner.scanLocation
            
            if proposedWordRange.location + breakLocation < location {
                wordRange.location = proposedWordRange.location + breakLocation + 1
                wordRange.length = proposedWordRange.length - (breakLocation + 1)
                
            } else if proposedWordRange.location + breakLocation == location {
                wordRange = NSRange(location: location, length: 1)
                break
            } else {
                wordRange.length -= proposedWordRange.length - breakLocation
                break
            }
            scanner.scanUpToCharacters(from: breakCharacterSet, into: nil)
        }
        
        return wordRange
    }
    
}
